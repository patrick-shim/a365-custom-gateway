using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using Azure.Core;
using FluentAssertions;
using Gateway.ContentSafety;
using Gateway.Domain.Models;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.ValueObjects;
using Gateway.Domain.Interfaces;
using Gateway.Application.Protection;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace Gateway.UnitTests.ContentSafety;

public sealed class PromptShieldClientTests
{
    private static readonly PromptShieldSubject UnattributedSubject = new(
        Guid.Parse("11111111-1111-1111-1111-111111111111"),
        null,
        null,
        "correlation-unattributed");
    private static readonly Guid ApiPrincipalObjectId =
        Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    private const string ContentSafetyResourceId =
        "/subscriptions/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/resourceGroups/gateway-rg/providers/Microsoft.CognitiveServices/accounts/content-safety";
    private const string ContentSafetyEndpoint =
        "https://content-safety.cognitiveservices.azure.com/";
    private const string SourceFingerprint =
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    private static readonly Guid DeploymentOwnershipId =
        Guid.Parse("dddddddd-dddd-4ddd-8ddd-dddddddddddd");
    private static readonly DateTime AttestedAtUtc =
        new(2026, 9, 5, 10, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void TokenProvider_UsesOnlyManagedIdentityCredential()
    {
        var credential = ManagedIdentityPromptShieldTokenProvider.CreateCredential(
            new PromptShieldOptions());

        credential.GetType().FullName.Should().Be("Azure.Identity.ManagedIdentityCredential");
    }

    [Fact]
    public void TokenProvider_UsesOnlyUserAssignedManagedIdentityCredential()
    {
        var credential = ManagedIdentityPromptShieldTokenProvider.CreateCredential(
            new PromptShieldOptions
            {
                ManagedIdentityClientId = "55555555-5555-4555-8555-555555555555"
            });

        credential.GetType().FullName.Should().Be("Azure.Identity.ManagedIdentityCredential");
    }

    [Fact]
    public void TokenProvider_BindsCanonicalUserAssignedManagedIdentityClientId()
    {
        string? boundClientId = null;
        var credential = ManagedIdentityPromptShieldTokenProvider.CreateCredential(
            new PromptShieldOptions
            {
                ManagedIdentityClientId = "{AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE}"
            },
            clientId =>
            {
                boundClientId = clientId;
                return new StubTokenCredential();
            });

        credential.Should().BeOfType<StubTokenCredential>();
        boundClientId.Should().Be("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee");
    }

    [Theory]
    [InlineData("not-a-guid")]
    [InlineData("00000000-0000-0000-0000-000000000000")]
    public void TokenProvider_RejectsInvalidManagedIdentityClientId(string clientId)
    {
        var action = () => ManagedIdentityPromptShieldTokenProvider.CreateCredential(
            new PromptShieldOptions { ManagedIdentityClientId = clientId });

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("PromptShield:ManagedIdentityClientId must be a non-empty GUID.");
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task EvaluateAsync_ReturnsOnlyTheDocumentedAttackFlag(bool attackDetected)
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(
                JsonSerializer.Serialize(new { userPromptAnalysis = new { attackDetected } }),
                Encoding.UTF8,
                "application/json")
        });
        var tokenProvider = new StubTokenProvider();
        var client = new PromptShieldClient(
            new HttpClient(handler) { BaseAddress = new Uri(ContentSafetyEndpoint) },
            tokenProvider,
            Options.Create(new PromptShieldOptions
            {
                Enabled = true,
                Endpoint = ContentSafetyEndpoint
            }),
            CreateBinding());

        var result = await client.EvaluateAsync("test prompt", UnattributedSubject, CancellationToken.None);

        result.AttackDetected.Should().Be(attackDetected);
        handler.LastRequest!.RequestUri!.PathAndQuery.Should()
            .Be("/contentsafety/text:shieldPrompt?api-version=2024-09-01");
        handler.LastRequest.Headers.Authorization!.Scheme.Should().Be("Bearer");
    }

    [Fact]
    public async Task EvaluateAsync_FailsClosedWhenTheResponseShapeIsInvalid()
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("{}", Encoding.UTF8, "application/json")
        });
        var tokenProvider = new StubTokenProvider();
        var client = new PromptShieldClient(
            new HttpClient(handler) { BaseAddress = new Uri(ContentSafetyEndpoint) },
            tokenProvider,
            Options.Create(new PromptShieldOptions
            {
                Enabled = true,
                Endpoint = ContentSafetyEndpoint
            }),
            CreateBinding());

        var action = () => client.EvaluateAsync("test prompt", UnattributedSubject, CancellationToken.None);

        (await action.Should().ThrowAsync<PromptShieldException>())
            .Which.FailureCode.Should().Be("PROMPT_SHIELD_INVALID_RESPONSE");
    }

    [Fact]
    public async Task EvaluateAsync_TranslatesTransportFailureToSafeProviderFailure()
    {
        var handler = new StubHandler(_ => throw new HttpRequestException("sensitive transport detail"));
        var client = new PromptShieldClient(
            new HttpClient(handler) { BaseAddress = new Uri(ContentSafetyEndpoint) },
            new StubTokenProvider(),
            Options.Create(new PromptShieldOptions
            {
                Enabled = true,
                Endpoint = ContentSafetyEndpoint
            }),
            CreateBinding());

        var action = () => client.EvaluateAsync("test prompt", UnattributedSubject, CancellationToken.None);

        var exception = (await action.Should().ThrowAsync<PromptShieldException>()).Which;
        exception.FailureCode.Should().Be("PROMPT_SHIELD_UNAVAILABLE");
        exception.Message.Should().NotContain("sensitive transport detail");
    }

    [Fact]
    public async Task EvaluateAsync_AttributesTheVerdictToTheCallingAgent365Identity()
    {
        var agent365AgentId = Guid.Parse("22222222-2222-2222-2222-222222222222");
        var blueprintId = Guid.Parse("33333333-3333-3333-3333-333333333333");
        var subject = new PromptShieldSubject(
            Guid.Parse("44444444-4444-4444-4444-444444444444"),
            agent365AgentId,
            blueprintId,
            "correlation-attributed");
        var handler = AllowingHandler();
        var client = CreateClient(handler);

        using var source = new ActivitySource(nameof(
            EvaluateAsync_AttributesTheVerdictToTheCallingAgent365Identity));
        using var listener = ListenTo(source);
        using var caller = source.StartActivity("prompt.evaluate");

        await client.EvaluateAsync("test prompt", subject, CancellationToken.None);

        // Prompt Shields is a per-agent control, so a verdict in the trace has to name
        // the individual Agent 365 identity that made the call.
        caller.Should().NotBeNull();
        caller!.GetTagItem("gateway.agent.registration_id").Should()
            .Be(subject.AgentRegistrationId.ToString("D"));
        caller.GetTagItem("gateway.a365.agent_id").Should().Be(agent365AgentId.ToString("D"));
        caller.GetTagItem("gateway.a365.blueprint_id").Should().Be(blueprintId.ToString("D"));
        caller.GetTagItem("gateway.correlation.id").Should().Be("correlation-attributed");

        // The identity stays inside the tenant. Prompt Shields has no field for it, so
        // adding one would ship tenant identifiers to the provider for no decision benefit.
        handler.LastRequestBody.Should().NotContain(agent365AgentId.ToString("D"));
        handler.LastRequestBody.Should().NotContain(blueprintId.ToString("D"));
        handler.LastRequestBody.Should().NotContain(subject.AgentRegistrationId.ToString("D"));
        handler.LastRequestBody.Should().NotContain("correlation-attributed");
    }

    [Fact]
    public async Task EvaluateAsync_ReportsAnAbsentAgent365IdentityAsUnknown()
    {
        var client = CreateClient(AllowingHandler());

        using var source = new ActivitySource(nameof(
            EvaluateAsync_ReportsAnAbsentAgent365IdentityAsUnknown));
        using var listener = ListenTo(source);
        using var caller = source.StartActivity("prompt.evaluate");

        await client.EvaluateAsync("test prompt", UnattributedSubject, CancellationToken.None);

        // An agent whose Agent 365 provisioning has not completed still gets a real
        // verdict. Recording the missing identity as missing keeps the trace honest;
        // a placeholder would make the evidence appear to confirm an attribution.
        caller!.GetTagItem("gateway.a365.agent_id").Should().Be("unknown");
        caller.GetTagItem("gateway.a365.blueprint_id").Should().Be("unknown");
        caller.GetTagItem("gateway.agent.registration_id").Should()
            .Be(UnattributedSubject.AgentRegistrationId.ToString("D"));
    }

    [Fact]
    public async Task EvaluateAsync_RejectsAnEvaluationThatNamesNoAgent()
    {
        var client = CreateClient(AllowingHandler());

        var action = () => client.EvaluateAsync("test prompt", null!, CancellationToken.None);

        await action.Should().ThrowAsync<ArgumentNullException>();
    }

    [Fact]
    public async Task EvaluateAsync_FailsClosedBeforeProviderWhenEndpointDriftsFromAttestation()
    {
        var handler = AllowingHandler();
        var client = new PromptShieldClient(
            new HttpClient(handler)
            {
                BaseAddress = new Uri("https://different.cognitiveservices.azure.com/")
            },
            new StubTokenProvider(),
            Options.Create(new PromptShieldOptions
            {
                Enabled = true,
                Endpoint = "https://different.cognitiveservices.azure.com/"
            }),
            CreateBinding());

        var action = () => client.EvaluateAsync(
            "test prompt",
            UnattributedSubject,
            CancellationToken.None);

        var exception = (await action.Should().ThrowAsync<PromptShieldException>()).Which;
        exception.FailureCode.Should().Be("PROMPT_SHIELD_CAPABILITY_BINDING_INVALID");
        exception.Message.Should().NotContain("different");
        handler.LastRequest.Should().BeNull();
    }

    [Fact]
    public async Task EvaluateAsync_FailsClosedBeforeProviderWhenTokenIdentityDoesNotMatchAttestation()
    {
        var handler = AllowingHandler();
        var client = new PromptShieldClient(
            new HttpClient(handler) { BaseAddress = new Uri(ContentSafetyEndpoint) },
            new StubTokenProvider(Guid.Parse("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")),
            Options.Create(new PromptShieldOptions
            {
                Enabled = true,
                Endpoint = ContentSafetyEndpoint
            }),
            CreateBinding());

        var action = () => client.EvaluateAsync(
            "test prompt",
            UnattributedSubject,
            CancellationToken.None);

        var exception = (await action.Should().ThrowAsync<PromptShieldException>()).Which;
        exception.FailureCode.Should().Be("PROMPT_SHIELD_CAPABILITY_BINDING_INVALID");
        exception.Message.Should().NotContain("eeeeeeee");
        handler.LastRequest.Should().BeNull();
    }

    [Fact]
    public void RuntimeBinding_MatchesOnlyTheExactMaterializedCapability()
    {
        var binding = CreateBinding();
        var capability = CreateCapability();

        binding.IsExact(capability).Should().BeTrue();

        capability.ResourceIdentifiers = capability.ResourceIdentifiers with
        {
            GatewayApiManagedIdentityPrincipalObjectId =
                new ServicePrincipalObjectId(Guid.NewGuid())
        };

        binding.IsExact(capability).Should().BeFalse();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ActualDependencyInjection_UsesTheValidatedRuntimeOptionsWithoutCycle(bool enabled)
    {
        var configuration = CreateConfiguration();
        configuration["PromptShield:Enabled"] = enabled.ToString();
        configuration["PromptShield:Endpoint"] = ContentSafetyEndpoint;
        var services = new ServiceCollection();
        services.AddSingleton<IConfiguration>(configuration);
        services.AddPromptShieldServices(configuration);
        using var provider = services.BuildServiceProvider(new ServiceProviderOptions { ValidateOnBuild = true });

        var options = provider.GetRequiredService<IOptions<PromptShieldOptions>>().Value;
        var client = provider.GetRequiredService<IPromptShieldClient>();
        var binding = provider.GetRequiredService<IBootstrapPromptShieldRuntimeBinding>();

        client.IsEnabled.Should().Be(enabled);
        binding.IsExact(CreateCapability()).Should().Be(enabled);
        if (enabled)
        {
            options.Endpoint = "https://different.cognitiveservices.azure.com/";
            binding.IsExact(CreateCapability()).Should().BeFalse();
        }
    }

    [Fact]
    public void ActualDependencyInjection_RejectsMismatchedRuntimeEndpointDuringOptionsValidation()
    {
        var configuration = CreateConfiguration();
        configuration["PromptShield:Enabled"] = "true";
        configuration["PromptShield:Endpoint"] = "https://different.cognitiveservices.azure.com/";
        var services = new ServiceCollection();
        services.AddSingleton<IConfiguration>(configuration);
        services.AddPromptShieldServices(configuration);
        using var provider = services.BuildServiceProvider(new ServiceProviderOptions { ValidateOnBuild = true });

        var action = () => provider.GetRequiredService<IOptions<PromptShieldOptions>>().Value;

        action.Should().Throw<OptionsValidationException>();
    }

    [Fact]
    public void RuntimeBinding_AcceptsMatchingManagedIdentityOidClaim()
    {
        var token = new AccessToken(
            CreateToken(ApiPrincipalObjectId),
            DateTimeOffset.UtcNow.AddMinutes(5));

        CreateBinding().IsTokenIdentityExact(token).Should().BeTrue();
    }

    private static StubHandler AllowingHandler() =>
        new(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(
                JsonSerializer.Serialize(new { userPromptAnalysis = new { attackDetected = false } }),
                Encoding.UTF8,
                "application/json")
        });

    private static PromptShieldClient CreateClient(StubHandler handler) =>
        new(
            new HttpClient(handler) { BaseAddress = new Uri(ContentSafetyEndpoint) },
            new StubTokenProvider(),
            Options.Create(new PromptShieldOptions
            {
                Enabled = true,
                Endpoint = ContentSafetyEndpoint
            }),
            CreateBinding());

    private static BootstrapPromptShieldRuntimeBinding CreateBinding() =>
        new(CreateConfiguration(), () => new PromptShieldOptions { Enabled = true, Endpoint = ContentSafetyEndpoint });

    private static IConfigurationRoot CreateConfiguration() =>
        new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["BootstrapCapabilities:Enabled"] = "true",
                ["BootstrapCapabilities:DeploymentOwnershipId"] =
                    DeploymentOwnershipId.ToString("D"),
                ["BootstrapCapabilities:AcceptedSourceFingerprint"] =
                    SourceFingerprint,
                ["BootstrapCapabilities:AttestedAtUtc"] =
                    new DateTimeOffset(AttestedAtUtc).ToString("O"),
                ["BootstrapCapabilities:PromptShields:Status"] = "Installed",
                ["BootstrapCapabilities:PromptShields:ContentSafetyAccountResourceId"] =
                    ContentSafetyResourceId,
                ["BootstrapCapabilities:PromptShields:ContentSafetyEndpoint"] =
                    ContentSafetyEndpoint,
                ["BootstrapCapabilities:PromptShields:GatewayApiManagedIdentityPrincipalObjectId"] =
                    ApiPrincipalObjectId.ToString("D")
            })
            .Build();

    private static ProtectionCapability CreateCapability() => new()
    {
        Id = Guid.NewGuid(),
        Kind = ProtectionCapabilityKind.PromptShields,
        Status = ProtectionCapabilityStatus.Installed,
        ResourceIdentifiers = new ProtectionCapabilityResourceIdentifiers(
            ContentSafetyAccountResourceId: ContentSafetyResourceId,
            ContentSafetyEndpoint: ContentSafetyEndpoint,
            GatewayApiManagedIdentityPrincipalObjectId:
                new ServicePrincipalObjectId(ApiPrincipalObjectId),
            BootstrapDeploymentOwnershipId: DeploymentOwnershipId,
            BootstrapSourceFingerprint: SourceFingerprint),
        LastReadbackAtUtc = AttestedAtUtc
    };

    // Scoped to one test-local source, because activity listeners are registered
    // process-wide and this project runs its classes in parallel.
    private static ActivityListener ListenTo(ActivitySource source)
    {
        var listener = new ActivityListener
        {
            ShouldListenTo = candidate => ReferenceEquals(candidate, source),
            Sample = (ref ActivityCreationOptions<ActivityContext> _) =>
                ActivitySamplingResult.AllDataAndRecorded
        };
        ActivitySource.AddActivityListener(listener);
        return listener;
    }

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> responseFactory)
        : HttpMessageHandler
    {
        public HttpRequestMessage? LastRequest { get; private set; }

        // The request is disposed as soon as the client returns, so the body has to be
        // captured while it is still live rather than read back from LastRequest.
        public string? LastRequestBody { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            LastRequest = request;
            LastRequestBody = request.Content is null
                ? null
                : await request.Content.ReadAsStringAsync(cancellationToken);
            return responseFactory(request);
        }
    }

    private sealed class StubTokenProvider(
        Guid? principalObjectId = null) : IPromptShieldTokenProvider
    {
        public ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken) =>
            ValueTask.FromResult(new AccessToken(
                CreateToken(principalObjectId ?? ApiPrincipalObjectId),
                DateTimeOffset.UtcNow.AddMinutes(5)));
    }

    private static string CreateToken(Guid principalObjectId)
    {
        static string Encode(byte[] bytes) =>
            Convert.ToBase64String(bytes)
                .TrimEnd('=')
                .Replace('+', '-')
                .Replace('/', '_');

        return string.Join(
            '.',
            Encode(JsonSerializer.SerializeToUtf8Bytes(new { alg = "none" })),
            Encode(JsonSerializer.SerializeToUtf8Bytes(
                new { oid = principalObjectId.ToString("D") })),
            "signature");
    }

    private sealed class StubTokenCredential : TokenCredential
    {
        public override AccessToken GetToken(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken) =>
            new("test-token", DateTimeOffset.UtcNow.AddMinutes(5));

        public override ValueTask<AccessToken> GetTokenAsync(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken) =>
            ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }
}
