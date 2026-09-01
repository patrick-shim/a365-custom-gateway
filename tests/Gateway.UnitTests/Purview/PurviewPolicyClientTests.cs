using System.Net;
using System.Text;
using System.Text.Json;
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
    private const string SensitiveInformationTypeId =
        "50842eb7-edc8-4019-85dd-5a5c1f2bb085";

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
    public void Options_ShouldNotProvideStaticSensitiveInformationTypeDefaults()
    {
        var options = new PurviewOptions();

        options.DefaultSensitiveInformationTypeId.Should().BeEmpty();
        options.DefaultSensitiveInformationType.Should().BeEmpty();
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

    [Theory]
    [InlineData("")]
    [InlineData("not-a-guid")]
    [InlineData("00000000-0000-0000-0000-000000000000")]
    public void Options_ShouldRequireCanonicalNonEmptySensitiveInformationTypeId(string invalidId)
    {
        var validator = new PurviewOptionsValidator();
        var result = validator.Validate(null, new PurviewOptions
        {
            Enabled = true,
            PolicyProvisioningEnabled = true,
            PolicyProvisioningOrganization = "tenant.onmicrosoft.com",
            PolicyProvisioningApplicationId = Guid.NewGuid().ToString("D"),
            PolicyProvisioningCertificateSecretUri =
                "https://gateway.vault.azure.net/secrets/certificate",
            DefaultSensitiveInformationTypeId = invalidId
        });

        result.Failed.Should().BeTrue();
        result.FailureMessage.Should().Contain("DefaultSensitiveInformationTypeId");
    }

    [Fact]
    public void Options_ShouldAcceptExactUnicodeSensitiveInformationTypeNameAt255Characters()
    {
        var validator = new PurviewOptionsValidator();
        var options = CreateValidPolicyProvisioningOptions(new string('\u754c', 255));

        var result = validator.Validate(null, options);

        result.Succeeded.Should().BeTrue();
        options.DefaultSensitiveInformationType.Should().HaveLength(255);
    }

    [Fact]
    public void Options_ShouldRejectSensitiveInformationTypeNameAt256OrWithAsciiControls()
    {
        var validator = new PurviewOptionsValidator();
        foreach (var invalidName in new[]
                 {
                     new string('\u754c', 256),
                     "Exact\u0007Name",
                     "Exact\u007fName"
                 })
        {
            var result = validator.Validate(
                null,
                CreateValidPolicyProvisioningOptions(invalidName));

            result.Failed.Should().BeTrue();
            result.FailureMessage.Should().Contain("DefaultSensitiveInformationType");
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

    private static PurviewOptions CreateValidPolicyProvisioningOptions(string classifierName) =>
        new()
        {
            Enabled = true,
            PolicyProvisioningEnabled = true,
            PolicyProvisioningOrganization = "tenant.onmicrosoft.com",
            PolicyProvisioningApplicationId = Guid.NewGuid().ToString("D"),
            PolicyProvisioningCertificateSecretUri =
                "https://gateway.vault.azure.net/secrets/certificate",
            DefaultSensitiveInformationTypeId = SensitiveInformationTypeId,
            DefaultSensitiveInformationType = classifierName
        };

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

public sealed class PurviewPolicyProvisioningReadbackTests
{
    private const string BlueprintApplicationId =
        "11111111-1111-4111-8111-111111111111";
    private const string SensitiveInformationTypeId =
        "50842eb7-edc8-4019-85dd-5a5c1f2bb085";

    [Fact]
    public void ParseResult_ExactTypedEvidence_IsAccepted()
    {
        var result = PowerShellPurviewPolicyProvisioningClient.ParseResult(
            CreateOutput(),
            CreateRequest(),
            "Credit Card Number",
            SensitiveInformationTypeId);

        result.CollectionPolicyId.Should().Be("collection-id");
        result.DlpBlueprintApplicationIds.Should().ContainSingle(BlueprintApplicationId);
        result.Evidence.CollectionLocation.LocationIds.Should().ContainSingle(
            PurviewPolicyLocationContract.EnterpriseAiAppsCollectionLocationId);
        result.Evidence.CollectionLocation.LocationType.Should().Be(
            PurviewPolicyLocationContract.CollectionLocationType);
        result.Evidence.DlpLocation.LocationType.Should().Be(
            PurviewPolicyLocationContract.DlpLocationType);
        result.Evidence.RuleActions.Should().ContainSingle(action =>
            action.Setting == "UploadText" && action.Value == "Block");
    }

    [Fact]
    public void ParseResult_WrongPersistedProviderId_IsRejected()
    {
        var action = () => PowerShellPurviewPolicyProvisioningClient.ParseResult(
            CreateOutput(collectionPolicyId: "different-collection-id"),
            CreateRequest(),
            "Credit Card Number",
            SensitiveInformationTypeId);

        var exception = action.Should().Throw<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_POLICY_READBACK_INVALID");
    }

    [Fact]
    public void ParseResult_WrongBlueprintApplicationScope_IsRejected()
    {
        var action = () => PowerShellPurviewPolicyProvisioningClient.ParseResult(
            CreateOutput(dlpBlueprintApplicationIds:
                ["22222222-2222-4222-8222-222222222222"]),
            CreateRequest(),
            "Credit Card Number",
            SensitiveInformationTypeId);

        var exception = action.Should().Throw<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_POLICY_READBACK_INVALID");
    }

    [Fact]
    public void ParseResult_ExtraProviderApplicationScope_IsRejected()
    {
        var action = () => PowerShellPurviewPolicyProvisioningClient.ParseResult(
            CreateOutput(dlpBlueprintApplicationIds:
                [BlueprintApplicationId, "22222222-2222-4222-8222-222222222222"]),
            CreateRequest(),
            "Credit Card Number",
            SensitiveInformationTypeId);

        var exception = action.Should().Throw<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_POLICY_READBACK_INVALID");
    }

    [Fact]
    public void ParseResult_BlueprintScopedCollectionLocation_IsRejected()
    {
        var action = () => PowerShellPurviewPolicyProvisioningClient.ParseResult(
            CreateOutput(
                collectionLocationId: BlueprintApplicationId,
                collectionLocationType: PurviewPolicyLocationContract.DlpLocationType),
            CreateRequest(),
            "Credit Card Number",
            SensitiveInformationTypeId);

        var exception = action.Should().Throw<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_POLICY_READBACK_INVALID");
    }

    [Fact]
    public void ParseResult_GroupScopedDlpLocation_IsRejected()
    {
        var action = () => PowerShellPurviewPolicyProvisioningClient.ParseResult(
            CreateOutput(dlpLocationType: PurviewPolicyLocationContract.CollectionLocationType),
            CreateRequest(),
            "Credit Card Number",
            SensitiveInformationTypeId);

        var exception = action.Should().Throw<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_POLICY_READBACK_INVALID");
    }

    [Fact]
    public void ParseResult_DlpLocationIdsDifferFromAuthorizedScope_IsRejected()
    {
        var action = () => PowerShellPurviewPolicyProvisioningClient.ParseResult(
            CreateOutput(dlpLocationIds: ["22222222-2222-4222-8222-222222222222"]),
            CreateRequest(),
            "Credit Card Number",
            SensitiveInformationTypeId);

        var exception = action.Should().Throw<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_POLICY_READBACK_INVALID");
    }

    [Fact]
    public void ParseResult_WrongClassifierIdWithExactName_IsRejected()
    {
        var action = () => PowerShellPurviewPolicyProvisioningClient.ParseResult(
            CreateOutput(classifierIds: ["11111111-1111-4111-8111-111111111111"]),
            CreateRequest(),
            "Credit Card Number",
            SensitiveInformationTypeId);

        var exception = action.Should().Throw<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_POLICY_READBACK_INVALID");
    }

    [Fact]
    public void ParseResult_ExactUnicodeClassifierName_IsAccepted()
    {
        var result = PowerShellPurviewPolicyProvisioningClient.ParseResult(
            CreateOutput(classifierName: "신용 카드 번호"),
            CreateRequest(),
            "신용 카드 번호",
            SensitiveInformationTypeId);

        result.Evidence.ClassifierNames.Should().ContainSingle("신용 카드 번호");
    }

    [Fact]
    public void ValidateExpectedScope_MissingPriorMemberFromExpectedUnion_IsRejected()
    {
        var request = CreateRequest() with
        {
            ExpectedPriorDlpBlueprintApplicationIds =
                ["22222222-2222-4222-8222-222222222222"],
            ExpectedDlpBlueprintApplicationIds = [BlueprintApplicationId]
        };

        var action = () =>
            PowerShellPurviewPolicyProvisioningClient.ValidateExpectedScope(request);

        var exception = action.Should().Throw<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_POLICY_EXPECTED_SCOPE_INVALID");
    }

    [Fact]
    public async Task ReadBoundedAsync_RetainsOnlyTheConfiguredLimitAndReportsTruncation()
    {
        using var reader = new StringReader(new string('x', 100));

        var capture = await PowerShellPurviewPolicyProvisioningClient.ReadBoundedAsync(
            reader,
            16,
            CancellationToken.None);

        capture.Text.Should().HaveLength(16);
        capture.TotalCharacters.Should().Be(100);
        capture.Truncated.Should().BeTrue();
    }

    [Fact]
    public void EnsureCleanupProven_UnprovenCleanupFailsClosed()
    {
        var action = () =>
            PowerShellPurviewPolicyProvisioningClient.EnsureCleanupProven(false);

        var exception = action.Should().Throw<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be(
            "PURVIEW_POLICY_TEMPORARY_FILE_CLEANUP_FAILED");
        exception.Which.IsTransient.Should().BeFalse();
    }

    [Fact]
    public async Task DeleteDirectoryAndVerifyAsync_RemovesTemporaryMaterialAndProvesAbsence()
    {
        var path = Path.Combine(
            Path.GetTempPath(),
            $"a365gw-purview-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        await File.WriteAllTextAsync(Path.Combine(path, "temporary.bin"), "test-only");

        try
        {
            var removed = await PowerShellPurviewPolicyProvisioningClient
                .DeleteDirectoryAndVerifyAsync(path);

            removed.Should().BeTrue();
            Directory.Exists(path).Should().BeFalse();
        }
        finally
        {
            if (Directory.Exists(path))
                Directory.Delete(path, recursive: true);
        }
    }

    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void ParseResult_ExtraConditionOrAction_IsRejected(
        bool hasExtraConditions,
        bool hasExtraActions)
    {
        var action = () => PowerShellPurviewPolicyProvisioningClient.ParseResult(
            CreateOutput(
                hasExtraConditions: hasExtraConditions,
                hasExtraActions: hasExtraActions),
            CreateRequest(),
            "Credit Card Number",
            SensitiveInformationTypeId);

        var exception = action.Should().Throw<PurviewPolicyException>();
        exception.Which.FailureCode.Should().Be("PURVIEW_POLICY_READBACK_INVALID");
    }

    private static PurviewPolicyProvisioningRequest CreateRequest() => new(
        Guid.Parse("33333333-3333-4333-8333-333333333333"),
        "Enterprise AI protection",
        "AllSensitiveInformation",
        "Enforce",
        "collection",
        "policy",
        "rule",
        BlueprintApplicationId,
        "Protected blueprint",
        "collection-id",
        "policy-id",
        "rule-id",
        [],
        [BlueprintApplicationId]);

    private static string CreateOutput(
        string collectionPolicyId = "collection-id",
        string[]? dlpBlueprintApplicationIds = null,
        string collectionLocationId = PurviewPolicyLocationContract.EnterpriseAiAppsCollectionLocationId,
        string collectionLocationType = PurviewPolicyLocationContract.CollectionLocationType,
        string dlpLocationType = PurviewPolicyLocationContract.DlpLocationType,
        string[]? dlpLocationIds = null,
        string[]? classifierIds = null,
        string classifierName = "Credit Card Number",
        bool hasExtraConditions = false,
        bool hasExtraActions = false)
    {
        var expectedDlpApplicationIds = dlpBlueprintApplicationIds ?? [BlueprintApplicationId];
        var json = JsonSerializer.Serialize(new
        {
            collectionPolicyId,
            dlpPolicyId = "policy-id",
            dlpRuleId = "rule-id",
            dlpBlueprintApplicationIds = expectedDlpApplicationIds,
            collectionMode = "Enable",
            collectionActivities = new[] { "UploadText", "DownloadText" },
            collectionEnforcementPlanes = new[] { "Application" },
            collectionSensitiveTypeIds = new[] { "All" },
            collectionIngestionEnabled = true,
            collectionLocation = new
            {
                workload = PurviewPolicyLocationContract.ApplicationWorkload,
                locationSource = PurviewPolicyLocationContract.EntraLocationSource,
                locationType = collectionLocationType,
                locationIds = new[] { collectionLocationId }
            },
            dlpMode = "Enable",
            dlpEnforcementPlanes = new[] { "Application" },
            dlpLocation = new
            {
                workload = PurviewPolicyLocationContract.ApplicationWorkload,
                locationSource = PurviewPolicyLocationContract.EntraLocationSource,
                locationType = dlpLocationType,
                locationIds = dlpLocationIds ?? expectedDlpApplicationIds
            },
            classifierIds = classifierIds ?? [SensitiveInformationTypeId],
            classifierNames = new[] { classifierName },
            ruleActions = new[] { new { setting = "UploadText", value = "Block" } },
            hasExclusions = false,
            hasBypass = false,
            hasExtraConditions,
            hasExtraActions,
            verifiedAtUtc = DateTimeOffset.UtcNow
        });
        return "A365GW_RESULT:" + Convert.ToBase64String(Encoding.UTF8.GetBytes(json));
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
