using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Azure.Core;
using FluentAssertions;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Purview;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Gateway.UnitTests.Purview;

public sealed class PurviewPolicyClientTests
{
    [Fact]
    public void DependencyInjection_ShouldResolveDisabledAdapter()
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Purview:Enabled"] = "false"
            })
            .Build();
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddPurviewServices(configuration);

        using var provider = services.BuildServiceProvider();

        provider.GetRequiredService<Gateway.Domain.Interfaces.IPurviewPolicyClient>()
            .IsEnabled.Should().BeFalse();
        provider.GetRequiredService<Gateway.Domain.Interfaces.IPurviewPolicyProvisioningClient>()
            .IsEnabled.Should().BeFalse();
    }

    [Fact]
    public void Options_ShouldFailClosed_WhenPolicyProvisioningIdentityIsIncomplete()
    {
        var validator = new PurviewOptionsValidator();
        var options = new PurviewOptions
        {
            Enabled = true,
            PolicyProvisioningEnabled = true,
            PolicyProvisioningOrganization = "tenant.onmicrosoft.com",
            PolicyProvisioningApplicationId = Guid.NewGuid().ToString("D")
        };

        var result = validator.Validate(null, options);

        result.Failed.Should().BeTrue();
        result.FailureMessage.Should().Contain("CertificateSecretUri");
    }

    [Fact]
    public void Options_ShouldRejectUntrustedOrVersionedCertificateSecretUris()
    {
        var validator = new PurviewOptionsValidator();
        foreach (var invalidUri in new[]
                 {
                     "https://attacker.example/secrets/certificate",
                     "https://gateway.vault.azure.net/secrets/certificate/version"
                 })
        {
            var result = validator.Validate(null, new PurviewOptions
            {
                Enabled = true,
                PolicyProvisioningEnabled = true,
                PolicyProvisioningOrganization = "tenant.onmicrosoft.com",
                PolicyProvisioningApplicationId = Guid.NewGuid().ToString("D"),
                PolicyProvisioningCertificateSecretUri = invalidUri
            });

            result.Failed.Should().BeTrue();
            result.FailureMessage.Should().Contain("versionless HTTPS Azure Key Vault");
        }
    }

    [Fact]
    public async Task Evaluate_ShouldFailClosed_WhenAdapterIsDisabled()
    {
        var client = CreateClient(new RecordingGraphClient(_ => throw new InvalidOperationException()), enabled: false);

        var action = () => client.EvaluateInteractionAsync(CreateInteraction(), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_NOT_CONFIGURED");
    }

    [Fact]
    public async Task AuditOnly_ShouldSubmitMetadataWithoutRawContent()
    {
        var graph = new RecordingGraphClient(_ => Response(HttpStatusCode.Created));
        var client = CreateClient(graph);
        var interaction = CreateInteraction() with
        {
            ExecutionMode = PurviewExecutionMode.EvaluateOffline,
            PromptContent = "raw-prompt-secret",
            ResponseContent = "raw-response-secret"
        };

        var result = await client.EvaluateInteractionAsync(interaction, CancellationToken.None);

        result.Decision.Should().Be(PurviewDecisionType.AuditLogged);
        graph.Calls.Should().HaveCount(2);
        graph.Calls.Should().OnlyContain(call =>
            call.Path.EndsWith("activities/contentActivities", StringComparison.Ordinal));
        graph.Calls.Select(call => call.Body.ToJsonString()).Should().OnlyContain(json =>
            !json.Contains("raw-prompt-secret", StringComparison.Ordinal)
            && !json.Contains("raw-response-secret", StringComparison.Ordinal)
            && !json.Contains("\"content\"", StringComparison.Ordinal)
            && !json.Contains("\"agents\"", StringComparison.Ordinal)
            && !json.Contains("microsoft.graph.aiAgentInfo", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Enforce_ShouldUseBlueprintApplicationLocationAndChildAgentAttribution()
    {
        var graph = new RecordingGraphClient(call => call.Operation switch
        {
            "computeProtectionScopes" => ScopeResponse("evaluateInline", "uploadText,downloadText"),
            "processContent" => Response(HttpStatusCode.OK, """
                {
                  "protectionScopeState": "notModified",
                  "policyActions": [
                    { "action": "restrictAccess", "restrictionAction": "block" }
                  ],
                  "processingErrors": []
                }
                """),
            _ => throw new InvalidOperationException(call.Operation)
        });
        var client = CreateClient(graph);
        var interaction = CreateInteraction();

        var result = await client.EvaluateInteractionAsync(interaction, CancellationToken.None);

        result.IsAllowed.Should().BeFalse();
        result.Decision.Should().Be(PurviewDecisionType.Blocked);
        result.PolicyAction.Should().Be("RestrictAccess:block");
        graph.Calls.Should().HaveCount(2);
        var computeJson = graph.Calls[0].Body.ToJsonString();
        computeJson.Should().Contain(interaction.BlueprintClientId);
        computeJson.Should().NotContain(interaction.AgentIdentityClientId);
        var processJson = graph.Calls[1].Body.ToJsonString();
        processJson.Should().Contain(interaction.PromptContent);
        processJson.Should().Contain(interaction.AgentIdentityClientId);
        processJson.Should().Contain(interaction.BlueprintClientId);
    }

    [Fact]
    public async Task Enforce_ShouldRefreshScopeOnce_WhenGraphReportsModified()
    {
        var computeCount = 0;
        var processCount = 0;
        var graph = new RecordingGraphClient(call => call.Operation switch
        {
            "computeProtectionScopes" => ScopeResponse(
                "evaluateInline",
                "uploadText,downloadText",
                etag: $"\"scope-{++computeCount}\""),
            "processContent" => Response(HttpStatusCode.OK, $$"""
                {
                  "protectionScopeState": "{{(++processCount == 1 ? "modified" : "notModified")}}",
                  "policyActions": [],
                  "processingErrors": []
                }
                """),
            _ => throw new InvalidOperationException(call.Operation)
        });
        var client = CreateClient(graph);

        var result = await client.EvaluateInteractionAsync(CreateInteraction(), CancellationToken.None);

        result.IsAllowed.Should().BeTrue();
        computeCount.Should().Be(2);
        graph.Calls.Where(call => call.Operation == "processContent")
            .Select(call => call.IfNoneMatch)
            .Should().ContainInOrder("\"scope-1\"", "\"scope-2\"");
    }

    [Fact]
    public async Task Enforce_ShouldFailClosed_WhenInlineDecisionHasNoBody()
    {
        var graph = new RecordingGraphClient(call => call.Operation switch
        {
            "computeProtectionScopes" => ScopeResponse("evaluateInline", "uploadText"),
            "processContent" => Response(HttpStatusCode.Accepted),
            _ => Response(HttpStatusCode.Created)
        });
        var client = CreateClient(graph);

        var action = () => client.EvaluateInteractionAsync(CreateInteraction(), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_INLINE_DECISION_MISSING");
    }

    [Fact]
    public async Task Enforce_ShouldSubmitOfflineContentWithoutRequiringInlineDecision()
    {
        var graph = new RecordingGraphClient(call => call.Operation switch
        {
            "computeProtectionScopes" => ScopeResponse("evaluateOffline", "uploadText,downloadText"),
            "processContent" => Response(HttpStatusCode.Accepted),
            _ => throw new InvalidOperationException(call.Operation)
        });
        var client = CreateClient(graph);

        var result = await client.EvaluateInteractionAsync(CreateInteraction(), CancellationToken.None);

        result.IsAllowed.Should().BeTrue();
        result.Decision.Should().Be(PurviewDecisionType.AuditLogged);
        graph.Calls.Count(call => call.Operation == "processContent").Should().Be(2);
    }

    [Fact]
    public async Task Enforce_ShouldFailClosed_WhenExecutionModeIsUnknown()
    {
        var graph = new RecordingGraphClient(call => call.Operation switch
        {
            "computeProtectionScopes" => ScopeResponse("unknownFutureValue", "uploadText,downloadText"),
            _ => throw new InvalidOperationException(call.Operation)
        });
        var client = CreateClient(graph);

        var action = () => client.EvaluateInteractionAsync(CreateInteraction(), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_SCOPE_INVALID_EXECUTION_MODE");
        graph.Calls.Should().ContainSingle(call => call.Operation == "computeProtectionScopes");
    }

    [Fact]
    public async Task Enforce_ShouldEvaluateUploadInlineAndSubmitDownloadOffline()
    {
        var processCount = 0;
        var graph = new RecordingGraphClient(call => call.Operation switch
        {
            "computeProtectionScopes" => Response(HttpStatusCode.OK, """
                {
                  "value": [
                    {
                      "activities": "uploadText",
                      "executionMode": "evaluateInline",
                      "policyActions": []
                    },
                    {
                      "activities": "downloadText",
                      "executionMode": "evaluateOffline",
                      "policyActions": []
                    }
                  ]
                }
                """),
            "processContent" => ++processCount == 1
                ? Response(HttpStatusCode.OK, """
                    { "protectionScopeState": "notModified", "policyActions": [], "processingErrors": [] }
                    """)
                : Response(HttpStatusCode.Accepted),
            _ => throw new InvalidOperationException(call.Operation)
        });
        var client = CreateClient(graph);
        var interaction = CreateInteraction();

        var result = await client.EvaluateInteractionAsync(interaction, CancellationToken.None);

        result.IsAllowed.Should().BeTrue();
        result.Decision.Should().Be(PurviewDecisionType.AuditLogged);
        var processedBodies = graph.Calls
            .Where(call => call.Operation == "processContent")
            .Select(call => call.Body.ToJsonString())
            .ToArray();
        processedBodies.Should().HaveCount(2);
        processedBodies[0].Should().Contain(interaction.PromptContent);
        processedBodies[1].Should().Contain(interaction.ResponseContent);
    }

    [Fact]
    public async Task Enforce_ShouldNotCacheOfflineScopeWhilePolicyDistributionIsPending()
    {
        var computeCount = 0;
        var graph = new RecordingGraphClient(call => call.Operation switch
        {
            "computeProtectionScopes" => ScopeResponse(
                ++computeCount == 1 ? "evaluateOffline" : "evaluateInline",
                "uploadText,downloadText"),
            "processContent" => computeCount == 1
                ? Response(HttpStatusCode.Accepted)
                : Response(HttpStatusCode.OK, """
                    { "protectionScopeState": "notModified", "policyActions": [], "processingErrors": [] }
                    """),
            _ => throw new InvalidOperationException(call.Operation)
        });
        var client = CreateClient(graph);

        var first = await client.EvaluateInteractionAsync(CreateInteraction(), CancellationToken.None);
        first.Decision.Should().Be(PurviewDecisionType.AuditLogged);

        var second = await client.EvaluateInteractionAsync(CreateInteraction(), CancellationToken.None);

        second.IsAllowed.Should().BeTrue();
        computeCount.Should().Be(2);
    }

    [Fact]
    public async Task Enforce_ShouldFailClosed_WhenNoApplicableScopeExists()
    {
        var graph = new RecordingGraphClient(call => call.Operation switch
        {
            "computeProtectionScopes" => Response(HttpStatusCode.OK, "{ \"value\": [] }"),
            _ => throw new InvalidOperationException(call.Operation)
        });
        var client = CreateClient(graph);

        var action = () => client.EvaluateInteractionAsync(CreateInteraction(), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_SCOPE_MISSING");
    }

    [Fact]
    public async Task ScopeCache_ShouldBeSharedByChildrenAndIsolatedByUserAndBlueprint()
    {
        var graph = new RecordingGraphClient(call => call.Operation switch
        {
            "computeProtectionScopes" => ScopeResponse("evaluateInline", "uploadText,downloadText"),
            "processContent" => Response(HttpStatusCode.OK, """
                { "protectionScopeState": "notModified", "policyActions": [], "processingErrors": [] }
                """),
            _ => throw new InvalidOperationException(call.Operation)
        });
        var client = CreateClient(graph);
        var first = CreateInteraction();
        var secondAgent = first with { AgentIdentityClientId = Guid.NewGuid().ToString("D") };
        var secondBlueprint = first with { BlueprintClientId = Guid.NewGuid().ToString("D") };

        await client.EvaluateInteractionAsync(first, CancellationToken.None);
        await client.EvaluateInteractionAsync(secondAgent, CancellationToken.None);
        await client.EvaluateInteractionAsync(secondBlueprint, CancellationToken.None);

        graph.Calls.Count(call => call.Operation == "computeProtectionScopes").Should().Be(2);
    }

    private static PurviewPolicyClient CreateClient(
        IPurviewGraphClient graph,
        bool enabled = true) =>
        new(
            NullLogger<PurviewPolicyClient>.Instance,
            Options.Create(new PurviewOptions
            {
                Enabled = enabled,
                AppName = "A365 Gateway Tests",
                AppVersion = "1.0",
                ProtectionScopeCacheMinutes = 30
            }),
            new MemoryCache(new MemoryCacheOptions()),
            graph);

    private static PurviewInteraction CreateInteraction() =>
        new(
            Guid.NewGuid(),
            Guid.NewGuid().ToString("D"),
            Guid.NewGuid().ToString("D"),
            "test prompt",
            "text/plain",
            "test response",
            "text/plain",
            "test-provider",
            "test-model",
            Guid.NewGuid().ToString("D"),
            Guid.NewGuid().ToString("D"),
            "Test Agent",
            DateTime.UtcNow,
            PurviewExecutionMode.EvaluateInline,
            Guid.NewGuid().ToString("D"));


    private static PurviewGraphResponse ScopeResponse(
        string executionMode,
        string activities,
        string? etag = null) =>
        Response(HttpStatusCode.OK, $$"""
            {
              "value": [
                {
                  "activities": "{{activities}}",
                  "executionMode": "{{executionMode}}",
                  "policyActions": []
                }
              ]
            }
            """, etag);

    private static PurviewGraphResponse Response(
        HttpStatusCode status,
        string? json = null,
        string? etag = null) =>
        new(
            json is null ? new JsonObject() : JsonNode.Parse(json)!.AsObject(),
            etag,
            status);

    private sealed record GraphCall(
        string Operation,
        string Path,
        JsonObject Body,
        string? IfNoneMatch);

    private sealed class RecordingGraphClient(
        Func<GraphCall, PurviewGraphResponse> responder) : IPurviewGraphClient
    {
        public List<GraphCall> Calls { get; } = [];

        public Task<PurviewGraphResponse> PostAsync(
            string operation,
            string relativePath,
            JsonObject body,
            string? ifNoneMatch,
            CancellationToken cancellationToken)
        {
            var call = new GraphCall(
                operation,
                relativePath,
                JsonNode.Parse(body.ToJsonString())!.AsObject(),
                ifNoneMatch);
            Calls.Add(call);
            return Task.FromResult(responder(call));
        }
    }
}

public sealed class PurviewGraphClientTests
{
    [Fact]
    public async Task Post_ShouldSendBearerAndEtag_WithoutExposingGraphBodyOnFailure()
    {
        HttpRequestMessage? captured = null;
        var handler = new DelegateHandler(async request =>
        {
            captured = await CloneRequestAsync(request);
            return new HttpResponseMessage(HttpStatusCode.Forbidden)
            {
                Content = new StringContent("raw-sensitive-graph-body", Encoding.UTF8, "application/json")
            };
        });
        var httpClient = new HttpClient(handler) { BaseAddress = PurviewGraphClient.OfficialBaseAddress };
        var client = new PurviewGraphClient(
            new StaticHttpClientFactory(httpClient),
            new StaticTokenProvider("test-token"));

        var action = () => client.PostAsync(
            "processContent",
            "users/test/dataSecurityAndGovernance/processContent",
            new JsonObject { ["test"] = true },
            "\"scope-etag\"",
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<PurviewPolicyException>();
        exception.Which.Message.Should().NotContain("raw-sensitive-graph-body");
        captured.Should().NotBeNull();
        captured!.Headers.Authorization!.Scheme.Should().Be("Bearer");
        captured.Headers.Authorization.Parameter.Should().Be("test-token");
        captured.Headers.GetValues("If-None-Match").Should().ContainSingle("\"scope-etag\"");
    }

    [Fact]
    public async Task Post_ShouldSurfaceOnlySanitizedGraphErrorCode()
    {
        var handler = new DelegateHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.Forbidden)
        {
            Content = new StringContent(
                """
                { "error": { "code": "Authorization_RequestDenied", "message": "sensitive detail" } }
                """,
                Encoding.UTF8,
                "application/json")
        }));
        var httpClient = new HttpClient(handler) { BaseAddress = PurviewGraphClient.OfficialBaseAddress };
        var client = new PurviewGraphClient(
            new StaticHttpClientFactory(httpClient),
            new StaticTokenProvider("test-token"));

        var action = () => client.PostAsync(
            "computeProtectionScopes",
            "users/test/dataSecurityAndGovernance/protectionScopes/compute",
            new JsonObject { ["test"] = true },
            ifNoneMatch: null,
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be(
            "PURVIEW_GRAPH_HTTP_403_AUTHORIZATION_REQUESTDENIED");
        exception.Which.Message.Should().NotContain("sensitive detail");
    }

    private static async Task<HttpRequestMessage> CloneRequestAsync(HttpRequestMessage request)
    {
        var clone = new HttpRequestMessage(request.Method, request.RequestUri);
        foreach (var header in request.Headers)
            clone.Headers.TryAddWithoutValidation(header.Key, header.Value);
        if (request.Content is not null)
            clone.Content = new StringContent(await request.Content.ReadAsStringAsync());
        return clone;
    }

    private sealed class StaticTokenProvider(string token) : IPurviewTokenProvider
    {
        public ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken) =>
            ValueTask.FromResult(new AccessToken(token, DateTimeOffset.UtcNow.AddHours(1)));
    }

    private sealed class StaticHttpClientFactory(HttpClient client) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => client;
    }

    private sealed class DelegateHandler(
        Func<HttpRequestMessage, Task<HttpResponseMessage>> handler) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => handler(request);
    }
}
