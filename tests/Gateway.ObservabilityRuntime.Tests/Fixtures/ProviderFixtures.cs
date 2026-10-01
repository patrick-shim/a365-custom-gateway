using System.Text;
using System.Text.Json;
using Azure.Core;
using Gateway.Agent365;
using Gateway.ContentSafety;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Purview;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Gateway.ObservabilityRuntime.Tests.Fixtures;

internal static class FixtureIds
{
    public static readonly Guid Tenant = Guid.Parse("11111111-1111-4111-8111-111111111111");
    public static readonly Guid Actor = Guid.Parse("22222222-2222-4222-8222-222222222222");
    public static readonly Guid Agent = Guid.Parse("33333333-3333-4333-8333-333333333333");
    public static readonly Guid Child = Guid.Parse("44444444-4444-4444-8444-444444444444");
    public static readonly Guid Blueprint = Guid.Parse("55555555-5555-4555-8555-555555555555");
    public static readonly Guid Principal = Guid.Parse("66666666-6666-4666-8666-666666666666");
    public static readonly Guid Registry = Guid.Parse("77777777-7777-4777-8777-777777777777");
    public static readonly DateTime Timestamp = new(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
    public static readonly AccessToken Token = new("offline-fixture-token-not-a-credential", DateTimeOffset.MaxValue);
}

internal sealed class FixtureCredential : TokenCredential
{
    public FiniteCalls<TokenRequestContext, AccessToken> Calls { get; } = new();
    public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
        throw new UnexpectedFixtureCallException("Synchronous credential acquisition is not part of this fixture.");
    public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return ValueTask.FromResult(Calls.Invoke(requestContext));
    }
}

internal sealed class PromptShieldFixture : IDisposable
{
    public const string Endpoint = "https://baseline-fixture.cognitiveservices.azure.com/";
    public const string EvaluationUri = Endpoint + "contentsafety/text:shieldPrompt?api-version=2024-09-01";
    private readonly ServiceProvider services;
    public ScriptedTransport Transport { get; } = new();
    public FixtureCredential Credential { get; } = new();
    public IPromptShieldClient Client => services.GetRequiredService<IPromptShieldClient>();
    public IConfigurationRoot Configuration { get; }

    public PromptShieldFixture(bool enabled = true, string? configuredEndpoint = null)
    {
        Configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["PromptShield:Enabled"] = enabled.ToString(),
            ["PromptShield:Endpoint"] = configuredEndpoint ?? Endpoint,
            ["BootstrapCapabilities:Enabled"] = "true",
            ["BootstrapCapabilities:DeploymentOwnershipId"] = FixtureIds.Registry.ToString("D"),
            ["BootstrapCapabilities:AcceptedSourceFingerprint"] = "sha256:" + new string('a', 64),
            ["BootstrapCapabilities:AttestedAtUtc"] = "2026-01-01T00:00:00Z",
            ["BootstrapCapabilities:PromptShields:Status"] = "Installed",
            ["BootstrapCapabilities:PromptShields:ContentSafetyAccountResourceId"] =
                $"/subscriptions/{FixtureIds.Tenant:D}/resourceGroups/offline-fixture/providers/Microsoft.CognitiveServices/accounts/baseline-fixture",
            ["BootstrapCapabilities:PromptShields:ContentSafetyEndpoint"] = Endpoint,
            ["BootstrapCapabilities:PromptShields:GatewayApiManagedIdentityPrincipalObjectId"] = FixtureIds.Principal.ToString("D")
        }).Build();
        var collection = new ServiceCollection();
        collection.AddLogging();
        collection.AddPromptShieldServices(Configuration);

        collection.RemoveAll<IPromptShieldTokenProvider>();
        collection.AddSingleton<IPromptShieldTokenProvider>(
            new ManagedIdentityPromptShieldTokenProvider(Credential));
        collection.RemoveAll<IHttpClientFactory>();
        collection.AddSingleton<IHttpClientFactory>(
            new ClosedHttpClientFactory(nameof(PromptShieldClient), Transport, new Uri(configuredEndpoint ?? Endpoint)));
        services = collection.BuildServiceProvider();
    }

    public void ExpectToken(Guid? principal = null)
    {
        var payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(
            new { oid = (principal ?? FixtureIds.Principal).ToString("D") })))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
        Credential.Calls.Expect(request =>
        {
            Assert.Equal(["https://cognitiveservices.azure.com/.default"], request.Scopes);
            return new AccessToken($"offline.{payload}.not-a-signature", DateTimeOffset.MaxValue);
        });
    }

    public void AssertComplete()
    {
        Transport.AssertComplete();
        Credential.Calls.AssertComplete();
    }

    public void Dispose()
    {
        services.Dispose();
        Transport.Dispose();
        (Configuration as IDisposable)?.Dispose();
    }
}

internal sealed class PurviewTokenFixture : IPurviewTokenProvider
{
    public FiniteCalls<CancellationToken, AccessToken> Calls { get; } = new();
    public ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return ValueTask.FromResult(Calls.Invoke(cancellationToken));
    }
}

internal sealed class PurviewFixture : IDisposable
{
    private readonly MemoryCache cache = new(new MemoryCacheOptions());
    public ScriptedTransport Transport { get; } = new();
    public PurviewTokenFixture Tokens { get; } = new();
    public PurviewPolicyClient Client { get; }
    public static string UserUri(string suffix, Guid? actor = null) =>
        $"https://graph.microsoft.com/v1.0/users/{actor ?? FixtureIds.Actor:D}/dataSecurityAndGovernance/{suffix}";

    public PurviewFixture(bool enabled = true)
    {
        var graph = new PurviewGraphClient(
            new ClosedHttpClientFactory(nameof(PurviewGraphClient), Transport, PurviewGraphClient.OfficialBaseAddress),
            Tokens);
        Client = new PurviewPolicyClient(NullLogger<PurviewPolicyClient>.Instance,
            Options.Create(new PurviewOptions { Enabled = enabled }), cache, graph);
    }

    public void ExpectToken() => Tokens.Calls.Expect(_ => FixtureIds.Token);
    public void AssertComplete()
    {
        Transport.AssertComplete();
        Tokens.Calls.AssertComplete();
    }
    public void Dispose()
    {
        cache.Dispose();
        Transport.Dispose();
    }
}

internal sealed record ObservabilityTokenRequest(string Child, string Blueprint, string Tenant);

internal sealed class ObservabilityTokenFixture : IAgent365ObservabilityTokenProvider
{
    public FiniteCalls<ObservabilityTokenRequest, AccessToken> Calls { get; } = new();
    public ValueTask<AccessToken> GetTokenAsync(
        string agentIdentityClientId, string blueprintClientId, string expectedTenantId, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return ValueTask.FromResult(Calls.Invoke(new(agentIdentityClientId, blueprintClientId, expectedTenantId)));
    }
}

internal sealed class Agent365Fixture : IDisposable
{
    public static string ExportUri =>
        $"https://agent365.svc.cloud.microsoft/observabilityService/tenants/{FixtureIds.Tenant:D}/otlp/agents/{FixtureIds.Child:D}/traces?api-version=1";
    public ScriptedTransport Transport { get; } = new();
    public ObservabilityTokenFixture Tokens { get; } = new();
    public ObservabilityExporter Client { get; }

    public Agent365Fixture()
    {
        Client = new ObservabilityExporter(NullLogger<ObservabilityExporter>.Instance,
            Options.Create(new Agent365Options
            {
                TenantId = FixtureIds.Tenant.ToString("D"),
                ObservabilityServerAddress = "gateway.invalid"
            }),
            new ClosedHttpClientFactory(nameof(ObservabilityExporter), Transport), Tokens);
    }

    public void ExpectToken() => Tokens.Calls.Expect(request =>
    {
        Assert.Equal(new(FixtureIds.Child.ToString("D"), FixtureIds.Blueprint.ToString("D"), FixtureIds.Tenant.ToString("D")), request);
        return FixtureIds.Token;
    });
    public void AssertComplete()
    {
        Transport.AssertComplete();
        Tokens.Calls.AssertComplete();
    }
    public void Dispose() => Transport.Dispose();
}

internal sealed class DelegatedTokenFixture : IAgent365DelegatedTokenProvider
{
    public FiniteCalls<CancellationToken, string> Calls { get; } = new();
    public Task<string> GetTokenAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(Calls.Invoke(cancellationToken));
    }
}
