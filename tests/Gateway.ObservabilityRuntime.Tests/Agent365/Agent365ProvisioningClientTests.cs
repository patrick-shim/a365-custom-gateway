using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Azure.Core;
using FluentAssertions;
using Gateway.Agent365;
using Gateway.Contracts;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Microsoft.Extensions.Logging;

namespace Gateway.ObservabilityRuntime.Tests.Agent365;

public sealed class Agent365ProvisioningClientTests
{
    private const string DependencyBodySentinel =
        "dependency-response-body-sentinel-must-never-escape";
    private const string SecretTextSentinel =
        "generated-secret-text-sentinel-must-never-be-loggable";

    private static readonly Guid TenantId =
        Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid OwnerObjectId =
        Guid.Parse("22222222-2222-4222-8222-222222222222");
    private static readonly Guid AgentRegistrationId =
        Guid.Parse("33333333-3333-4333-8333-333333333333");
    private static readonly Guid GatewayApiClientId =
        Guid.Parse("44444444-4444-4444-8444-444444444444");
    private static readonly Guid ObservabilityApplicationClientId =
        Guid.Parse("45454545-4545-4545-8545-454545454545");
    private static readonly Guid GatewayManagedIdentityPrincipalId =
        Guid.Parse("46464646-4646-4646-8646-464646464646");
    private static readonly Guid ManagerApplicationId =
        Guid.Parse("55555555-5555-4555-8555-555555555555");
    private static readonly Guid SecondManagerApplicationId =
        Guid.Parse("dddddddd-dddd-4ddd-8ddd-dddddddddddd");
    private static readonly Guid UnexpectedManagerApplicationId =
        Guid.Parse("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee");
    private static readonly Guid ApplicationObjectId =
        Guid.Parse("66666666-6666-4666-8666-666666666666");
    private static readonly Guid ApplicationClientId =
        Guid.Parse("77777777-7777-4777-8777-777777777777");
    private static readonly Guid BlueprintObjectId =
        Guid.Parse("88888888-8888-4888-8888-888888888888");
    private static readonly Guid BlueprintClientId =
        Guid.Parse("99999999-9999-4999-8999-999999999999");
    private static readonly Guid BlueprintPrincipalObjectId =
        Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    private static readonly Guid AgentIdentityObjectId =
        Guid.Parse("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    private static readonly Guid PlannedRegistryId =
        Guid.Parse("12121212-1212-4212-8212-121212121212");
    private static readonly Guid UnexpectedAgent365RegistrationId =
        Guid.Parse("13131313-1313-4313-8313-131313131313");
    private static readonly Guid PasswordCredentialKeyId =
        Guid.Parse("cccccccc-cccc-4ccc-8ccc-cccccccccccc");
    private static readonly DateTimeOffset CredentialExpiry =
        new(2027, 1, 2, 3, 4, 5, TimeSpan.Zero);
    private static readonly TimeSpan[] FiveImmediateVerificationAttempts =
    [
        TimeSpan.Zero,
        TimeSpan.Zero,
        TimeSpan.Zero,
        TimeSpan.Zero,
        TimeSpan.Zero
    ];
    private const string BlueprintDisplayName =
        "A365 Blueprint - Test agent - 33333333333343338333333333333333";
    private const string BlueprintKey = "84f13f2750f66ea354305e97";

    [Theory]
    [InlineData("non-development", ErrorCodes.PROVISIONING_PREVIEW_DISABLED)]
    [InlineData("missing-manager-applications", ErrorCodes.AGENT365_PLATFORM_ACCEPTANCE_UNCONFIGURED)]
    public async Task ExecuteStepAsync_InvalidWorkerPreflight_MakesZeroHttpCalls(
        string scenario,
        string expectedErrorCode)
    {
        var options = CreateValidOptions();
        var request = CreateRequest(ProvisioningStepType.CreateAppRegistration);
        switch (scenario)
        {
            case "non-development":
                request = request with
                {
                    Agent = request.Agent with { Environment = "Production" }
                };
                break;
            case "missing-manager-applications":
                options.ManagerApplicationIds = [];
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(scenario));
        }

        var handler = new RecordingHttpMessageHandler((_, _) =>
            throw new InvalidOperationException("HTTP must not be called after failed preflight."));
        var tokenProvider = new RecordingTokenProvider();
        var credentialStore = new RecordingCredentialStore();
        var client = CreateClient(
            handler,
            tokenProvider,
            credentialStore,
            new RecordingLogger<Agent365ProvisioningClient>(),
            options);

        var action = () => client.ExecuteStepAsync(request, CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(expectedErrorCode);
        handler.Requests.Should().BeEmpty();
        tokenProvider.CallCount.Should().Be(0);
        credentialStore.FindCallCount.Should().Be(0);
        credentialStore.StoreCallCount.Should().Be(0);
    }

    [Fact]
    public async Task ExecuteCreateAgentIdentity_UsesBlueprintClientIdFromPersistedState()
    {
        var expectedDisplayName =
            $"A365 Identity - Test agent - {AgentRegistrationId:N}";
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => AgentIdentityResponse(expectedDisplayName),
            2 => AgentIdentityResponse(expectedDisplayName, HttpStatusCode.OK),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(handler);
        var request = CreateRequest(
            ProvisioningStepType.CreateAgentIdentity,
            new Agent365ProvisioningState
            {
                BlueprintObjectId = BlueprintObjectId.ToString("D"),
                BlueprintClientId = BlueprintClientId.ToString("D"),
                BlueprintPrincipalObjectId = BlueprintPrincipalObjectId.ToString("D")
            });

        var result = await client.ExecuteStepAsync(request, CancellationToken.None);

        var createRequest = handler.Requests.Should()
            .ContainSingle(candidate => candidate.Method == HttpMethod.Post)
            .Subject;
        createRequest.Uri.Should().Be(
            "https://graph.microsoft.com/v1.0/servicePrincipals/microsoft.graph.agentIdentity");
        using var document = JsonDocument.Parse(createRequest.Body!);
        document.RootElement.GetProperty("agentIdentityBlueprintId").GetString().Should().Be(
            BlueprintClientId.ToString("D"));
        createRequest.Body.Should().NotContain(BlueprintObjectId.ToString("D"));
        result.State.AgentIdentityObjectId.Should().Be(AgentIdentityObjectId.ToString("D"));
        handler.Requests.Should().HaveCount(3);
        handler.Requests[2].Uri.Should().Be(
            $"https://graph.microsoft.com/v1.0/servicePrincipals/{AgentIdentityObjectId:D}/microsoft.graph.agentIdentity?$select=id,appId,displayName,appRoles,agentIdentityBlueprintId&$expand=sponsors($select=id)");
    }

    [Fact]
    public async Task ExecuteCreateAgentIdentity_DelayedKnownIdReadbackSucceedsWithoutReposting()
    {
        var expectedDisplayName =
            $"A365 Identity - Test agent - {AgentRegistrationId:N}";
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => AgentIdentityResponse(expectedDisplayName),
            2 => JsonResponse(HttpStatusCode.NotFound, new { }),
            3 => AgentIdentityResponse(expectedDisplayName, HttpStatusCode.OK),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: [TimeSpan.Zero, TimeSpan.Zero]);

        var result = await client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.CreateAgentIdentity,
                CreateAgentIdentityState()),
            CancellationToken.None);

        result.State.AgentIdentityObjectId.Should().Be(AgentIdentityObjectId.ToString("D"));
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
        handler.Requests.Skip(2).Should().OnlyContain(candidate =>
            candidate.Method == HttpMethod.Get &&
            candidate.Uri.Contains(AgentIdentityObjectId.ToString("D"), StringComparison.Ordinal));
    }

    [Fact]
    public async Task ExecuteCreateAgentIdentity_MissingAfterBoundedKnownIdReadsFailsWithoutReposting()
    {
        var expectedDisplayName =
            $"A365 Identity - Test agent - {AgentRegistrationId:N}";
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => AgentIdentityResponse(expectedDisplayName),
            >= 2 and <= 6 => JsonResponse(HttpStatusCode.NotFound, new { }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: FiveImmediateVerificationAttempts);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.CreateAgentIdentity,
                CreateAgentIdentityState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(7);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteCreateAgentIdentity_MismatchedKnownIdReadbackFailsWithoutReposting()
    {
        var expectedDisplayName =
            $"A365 Identity - Test agent - {AgentRegistrationId:N}";
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => AgentIdentityResponse(expectedDisplayName),
            2 => JsonResponse(HttpStatusCode.OK, new
            {
                id = AgentIdentityObjectId,
                appId = AgentIdentityObjectId,
                displayName = expectedDisplayName,
                agentIdentityBlueprintId = UnexpectedManagerApplicationId,
                sponsors = new[] { new { id = OwnerObjectId } }
            }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: [TimeSpan.Zero]);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.CreateAgentIdentity,
                CreateAgentIdentityState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_STATE_INVALID);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteCreateAgentIdentity_InvalidCreatedIdFailsBeforeAnyRecoveryLookup()
    {
        var expectedDisplayName =
            $"A365 Identity - Test agent - {AgentRegistrationId:N}";
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => JsonResponse(HttpStatusCode.Created, new
            {
                id = "not-a-guid",
                appId = AgentIdentityObjectId,
                displayName = expectedDisplayName,
                agentIdentityBlueprintId = BlueprintClientId
            }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: FiveImmediateVerificationAttempts);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.CreateAgentIdentity,
                CreateAgentIdentityState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(2);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteCreateAgentIdentity_CancellationStopsReadbackWithoutReposting()
    {
        using var cancellation = new CancellationTokenSource();
        var expectedDisplayName =
            $"A365 Identity - Test agent - {AgentRegistrationId:N}";
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => AgentIdentityResponse(expectedDisplayName),
            2 => CancelAndReturnNotFound(cancellation),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays:
            [TimeSpan.Zero, TimeSpan.FromMinutes(1)]);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.CreateAgentIdentity,
                CreateAgentIdentityState()),
            cancellation.Token);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(3);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteCreateBlueprint_ManagerApplicationsMatchAsAnOrderInsensitiveExactSet()
    {
        var expectedDisplayName =
            $"A365 Blueprint - Test agent - {AgentRegistrationId:N}";
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 or 1 => BlueprintResponse(
                expectedDisplayName,
                SecondManagerApplicationId,
                ManagerApplicationId),
            2 or 3 => JsonResponse(HttpStatusCode.OK, new
            {
                value = new[] { new { id = OwnerObjectId } }
            }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var options = CreateValidOptions();
        options.ManagerApplicationIds =
        [
            ManagerApplicationId.ToString("D"),
            SecondManagerApplicationId.ToString("D")
        ];
        var client = CreateClient(handler, options: options);
        var request = CreateRequest(
            ProvisioningStepType.CreateBlueprint,
            CreateBlueprintState());

        var result = await client.ExecuteStepAsync(request, CancellationToken.None);

        result.State.BlueprintObjectId.Should().Be(BlueprintObjectId.ToString("D"));
        result.State.BlueprintClientId.Should().Be(BlueprintClientId.ToString("D"));
        result.State.PlannedAgent365RegistrationId.Should().BeNull();
        result.CompletionEvidence.Should().Be("GatewayAgentIdentityBlueprintVerified");
        handler.Requests.Should().HaveCount(4);
        handler.Requests[2].Uri.Should().Be(
            $"https://graph.microsoft.com/v1.0/applications/{BlueprintObjectId:D}/microsoft.graph.agentIdentityBlueprint/owners?$select=id&$top=999");
        handler.Requests[3].Uri.Should().Be(
            $"https://graph.microsoft.com/v1.0/applications/{BlueprintObjectId:D}/microsoft.graph.agentIdentityBlueprint/sponsors?$select=id&$top=999");
    }

    [Fact]
    public async Task ExecuteCreateBlueprint_RetriesExactReadAfterSuccessfulCreateWithoutReposting()
    {
        var expectedDisplayName =
            $"A365 Blueprint - Test agent - {AgentRegistrationId:N}";
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => BlueprintResponse(expectedDisplayName, ManagerApplicationId),
            2 => JsonResponse(HttpStatusCode.NotFound, new { }),
            3 => BlueprintResponse(expectedDisplayName, ManagerApplicationId),
            4 or 5 => JsonResponse(HttpStatusCode.OK, new
            {
                value = new[] { new { id = OwnerObjectId } }
            }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays:
            [TimeSpan.Zero, TimeSpan.Zero]);

        var result = await client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.CreateBlueprint,
                new Agent365ProvisioningState()),
            CancellationToken.None);

        result.State.BlueprintObjectId.Should().Be(BlueprintObjectId.ToString("D"));
        handler.Requests.Should().HaveCount(6);
        handler.Requests.Count(candidate => candidate.Method == HttpMethod.Post)
            .Should().Be(1);
        handler.Requests[2].Uri.Should().Be(handler.Requests[3].Uri);
    }

    [Fact]
    public async Task ExecuteEnsureBlueprintPrincipal_RetriesExactReadAfterSuccessfulCreateWithoutReposting()
    {
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.NotFound, new { }),
            1 => JsonResponse(HttpStatusCode.Created, new
            {
                id = BlueprintPrincipalObjectId,
                appId = BlueprintClientId
            }),
            2 => JsonResponse(HttpStatusCode.NotFound, new { }),
            3 => JsonResponse(HttpStatusCode.OK, new
            {
                id = BlueprintPrincipalObjectId,
                appId = BlueprintClientId
            }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays:
            [TimeSpan.Zero, TimeSpan.Zero]);

        var result = await client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.EnsureBlueprintPrincipal,
                CreateBlueprintState()),
            CancellationToken.None);

        result.State.BlueprintPrincipalObjectId.Should().Be(
            BlueprintPrincipalObjectId.ToString("D"));
        handler.Requests.Should().HaveCount(4);
        handler.Requests.Count(candidate => candidate.Method == HttpMethod.Post)
            .Should().Be(1);
        handler.Requests[2].Uri.Should().Be(handler.Requests[3].Uri);
    }

    [Fact]
    public async Task ExecuteCreateBlueprint_PreservesExistingPlannedRegistryId()
    {
        var expectedDisplayName =
            $"A365 Blueprint - Test agent - {AgentRegistrationId:N}";
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 or 1 => BlueprintResponse(expectedDisplayName, ManagerApplicationId),
            2 or 3 => JsonResponse(HttpStatusCode.OK, new
            {
                value = new[] { new { id = OwnerObjectId } }
            }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(handler);
        var state = CreateBlueprintState() with
        {
            PlannedAgent365RegistrationId = PlannedRegistryId.ToString("D")
        };

        var result = await client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.CreateBlueprint, state),
            CancellationToken.None);

        result.State.PlannedAgent365RegistrationId.Should().Be(
            PlannedRegistryId.ToString("D"));
    }

    [Fact]
    public async Task ExecuteCreateBlueprint_UnexpectedManagerApplicationFailsClosed()
    {
        var expectedDisplayName =
            $"A365 Blueprint - Test agent - {AgentRegistrationId:N}";
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 or 1 => BlueprintResponse(
                expectedDisplayName,
                ManagerApplicationId,
                UnexpectedManagerApplicationId),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(handler);
        var request = CreateRequest(
            ProvisioningStepType.CreateBlueprint,
            CreateBlueprintState());

        var action = () => client.ExecuteStepAsync(request, CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(
            ErrorCodes.AGENT365_PLATFORM_ACCEPTANCE_UNCONFIGURED);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(2);
    }

    // Historical workflow-v2 app-only Registry tests are retained only as source
    // archaeology. Workflow v3 makes this adapter path unreachable.
#if false
    [Fact]
    public async Task ExecuteRegisterAgent_UsesBetaRouteOnlyAfterPreviewPreflightPasses()
    {
        var registryId = PlannedRegistryId.ToString("D");
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.NotFound, new { }),
            1 => AgentRegistrationResponse(registryId, HttpStatusCode.Created),
            2 => AgentRegistrationResponse(registryId, HttpStatusCode.OK),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(handler);
        var request = CreateRequest(
            ProvisioningStepType.RegisterAgent,
            CreateRegistryState());

        var result = await client.ExecuteStepAsync(request, CancellationToken.None);

        handler.Requests.Should().HaveCount(3);
        handler.Requests[1].Method.Should().Be(HttpMethod.Post);
        handler.Requests[1].Uri.Should().Be(
            "https://graph.microsoft.com/beta/copilot/agentRegistrations");
        using (var document = JsonDocument.Parse(handler.Requests[1].Body!))
        {
            document.RootElement.GetProperty("id").GetString().Should().Be(registryId);
            document.RootElement.GetProperty("managedByAppId").GetString().Should().Be(
                GatewayApiClientId.ToString("D"));
        }
        handler.Requests.Should().OnlyContain(request =>
            !request.Headers.ContainsKey("ConsistencyLevel"));
        handler.Requests[0].Method.Should().Be(HttpMethod.Get);
        handler.Requests[0].Uri.Should().Be(
            $"https://graph.microsoft.com/beta/copilot/agentRegistrations/{registryId}");
        handler.Requests[2].Method.Should().Be(HttpMethod.Get);
        handler.Requests[2].Uri.Should().Be(
            $"https://graph.microsoft.com/beta/copilot/agentRegistrations/{registryId}");
        result.State.Agent365RegistrationId.Should().Be(registryId);
        result.State.PlannedAgent365RegistrationId.Should().Be(registryId);
        result.State.RegistryProvider.Should().Be(Agent365Options.DirectRegistryPreviewProvider);
    }

    [Fact]
    public async Task ExecuteRegisterAgent_ExistingPlannedRecordCompletesWithoutPost()
    {
        var registryId = PlannedRegistryId.ToString("D");
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => AgentRegistrationResponse(registryId, HttpStatusCode.OK),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(handler);

        var result = await client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.RegisterAgent, CreateRegistryState()),
            CancellationToken.None);

        result.State.Agent365RegistrationId.Should().Be(registryId);
        handler.Requests.Should().ContainSingle();
        handler.Requests[0].Method.Should().Be(HttpMethod.Get);
    }

    [Fact]
    public async Task ExecuteRegisterAgent_RunningRecoveryAllowsBoundedGetPropagationWithoutPost()
    {
        var registryId = PlannedRegistryId.ToString("D");
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.NotFound, new { }),
            1 => AgentRegistrationResponse(registryId, HttpStatusCode.OK),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: [TimeSpan.Zero, TimeSpan.Zero]);
        var recoveryState = CreateRegistryState() with
        {
            Agent365RegistrationId = registryId,
            RegistryProvider = null
        };

        var result = await client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.RegisterAgent, recoveryState),
            CancellationToken.None);

        result.State.Agent365RegistrationId.Should().Be(registryId);
        handler.Requests.Should().HaveCount(2);
        handler.Requests.Should().OnlyContain(candidate => candidate.Method == HttpMethod.Get);
    }

    [Fact]
    public async Task ExecuteRegisterAgent_AmbiguousMutationReconcilesKnownIdWithoutReposting()
    {
        var registryId = PlannedRegistryId.ToString("D");
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.NotFound, new { }),
            1 => ErrorResponse(HttpStatusCode.InternalServerError, DependencyBodySentinel),
            2 => AgentRegistrationResponse(registryId, HttpStatusCode.OK),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: [TimeSpan.Zero]);

        var result = await client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.RegisterAgent, CreateRegistryState()),
            CancellationToken.None);

        result.State.Agent365RegistrationId.Should().Be(registryId);
        handler.Requests.Should().HaveCount(3);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
        handler.Requests.Count(candidate => candidate.Method == HttpMethod.Get).Should().Be(2);
        handler.Requests.Where(candidate => candidate.Method == HttpMethod.Get).Should().OnlyContain(candidate =>
            candidate.Method == HttpMethod.Get &&
            candidate.Uri.EndsWith($"/{registryId}", StringComparison.Ordinal));
    }

    [Fact]
    public async Task ExecuteRegisterAgent_AmbiguousMutationMissingKnownIdFailsManualWithoutReposting()
    {
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.NotFound, new { }),
            1 => ErrorResponse(HttpStatusCode.InternalServerError, DependencyBodySentinel),
            >= 2 and <= 6 => JsonResponse(HttpStatusCode.NotFound, new { }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: FiveImmediateVerificationAttempts);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.RegisterAgent, CreateRegistryState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        exception.Which.IsTransient.Should().BeFalse();
        exception.Which.Message.Should().NotContain(DependencyBodySentinel);
        exception.Which.SafeSummary.Should().NotContain(DependencyBodySentinel);
        handler.Requests.Should().HaveCount(7);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteRegisterAgent_RawPostFailureReconcilesThenFailsManualWithoutReposting()
    {
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.NotFound, new { }),
            1 => throw new InvalidOperationException("raw post transport failure"),
            >= 2 and <= 6 => JsonResponse(HttpStatusCode.NotFound, new { }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: FiveImmediateVerificationAttempts);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.RegisterAgent, CreateRegistryState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        exception.Which.IsTransient.Should().BeFalse();
        exception.Which.SafeSummary.Should().NotContain("raw post transport failure");
        handler.Requests.Should().HaveCount(7);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteRegisterAgent_DelayedKnownIdReadbackSucceedsWithoutReposting()
    {
        var registryId = PlannedRegistryId.ToString("D");
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.NotFound, new { }),
            1 => AgentRegistrationResponse(registryId, HttpStatusCode.Created),
            2 => JsonResponse(HttpStatusCode.NotFound, new { }),
            3 => AgentRegistrationResponse(registryId, HttpStatusCode.OK),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: [TimeSpan.Zero, TimeSpan.Zero]);

        var result = await client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.RegisterAgent, CreateRegistryState()),
            CancellationToken.None);

        result.State.Agent365RegistrationId.Should().Be(registryId);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
        handler.Requests.Where(candidate => candidate.Method == HttpMethod.Get).Should().OnlyContain(candidate =>
            candidate.Method == HttpMethod.Get &&
            candidate.Uri.EndsWith($"/{registryId}", StringComparison.Ordinal));
    }

    [Fact]
    public async Task ExecuteRegisterAgent_MissingAfterBoundedKnownIdReadsFailsWithoutReposting()
    {
        var registryId = PlannedRegistryId.ToString("D");
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.NotFound, new { }),
            1 => AgentRegistrationResponse(registryId, HttpStatusCode.Created),
            >= 2 and <= 6 => JsonResponse(HttpStatusCode.NotFound, new { }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: FiveImmediateVerificationAttempts);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.RegisterAgent, CreateRegistryState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(7);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    public async Task ExecuteRegisterAgent_PostCreateReadRejectionIsAlwaysAmbiguousManual(
        HttpStatusCode readStatus)
    {
        var registryId = PlannedRegistryId.ToString("D");
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.NotFound, new { }),
            1 => AgentRegistrationResponse(registryId, HttpStatusCode.Created),
            2 => ErrorResponse(readStatus, DependencyBodySentinel),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: [TimeSpan.Zero]);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.RegisterAgent, CreateRegistryState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        exception.Which.IsTransient.Should().BeFalse();
        exception.Which.SafeSummary.Should().NotContain(DependencyBodySentinel);
        handler.Requests.Should().HaveCount(3);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteRegisterAgent_MismatchedKnownIdReadbackFailsWithoutReposting()
    {
        var registryId = PlannedRegistryId.ToString("D");
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.NotFound, new { }),
            1 => AgentRegistrationResponse(registryId, HttpStatusCode.Created),
            2 => JsonResponse(HttpStatusCode.OK, new
            {
                id = registryId,
                sourceAgentId = "external-agent-1",
                managedByAppId = UnexpectedManagerApplicationId,
                agentIdentityId = AgentIdentityObjectId,
                agentIdentityBlueprintId = BlueprintClientId
            }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: FiveImmediateVerificationAttempts);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.RegisterAgent, CreateRegistryState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(3);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteRegisterAgent_ResponseIdMismatchAndMissingPlannedReadbackFailsWithoutRepost()
    {
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.NotFound, new { }),
            1 => AgentRegistrationResponse(
                UnexpectedAgent365RegistrationId.ToString("D"),
                HttpStatusCode.Created),
            >= 2 and <= 6 => JsonResponse(HttpStatusCode.NotFound, new { }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: FiveImmediateVerificationAttempts);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.RegisterAgent, CreateRegistryState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(7);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteRegisterAgent_ResponseIdMismatchReconcilesPlannedIdWithoutRepost()
    {
        var registryId = PlannedRegistryId.ToString("D");
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.NotFound, new { }),
            1 => AgentRegistrationResponse(
                UnexpectedAgent365RegistrationId.ToString("D"),
                HttpStatusCode.Created),
            2 => AgentRegistrationResponse(registryId, HttpStatusCode.OK),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: [TimeSpan.Zero]);

        var result = await client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.RegisterAgent, CreateRegistryState()),
            CancellationToken.None);

        result.State.Agent365RegistrationId.Should().Be(registryId);
        handler.Requests.Should().HaveCount(3);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("not-a-guid")]
    public async Task ExecuteRegisterAgent_MissingOrInvalidPlannedIdFailsBeforePost(
        string? plannedId)
    {
        var handler = new RecordingHttpMessageHandler((_, _) =>
            throw new InvalidOperationException("No Graph request was expected."));
        var client = CreateClient(handler);
        var state = CreateRegistryState() with
        {
            PlannedAgent365RegistrationId = plannedId
        };

        var action = () => client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.RegisterAgent, state),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_STATE_INVALID);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().BeEmpty();
    }

    [Fact]
    public async Task ExecuteRegisterAgent_CancellationAfterCreateFailsManualWithoutReposting()
    {
        using var cancellation = new CancellationTokenSource();
        var registryId = PlannedRegistryId.ToString("D");
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.NotFound, new { }),
            1 => AgentRegistrationResponse(registryId, HttpStatusCode.Created),
            2 => CancelAndReturnNotFound(cancellation),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays:
            [TimeSpan.Zero, TimeSpan.FromMinutes(1)]);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.RegisterAgent, CreateRegistryState()),
            cancellation.Token);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(3);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }
#endif

    [Fact]
    public async Task ExecuteRegisterAgent_RequiresDelegatedAdministratorAndNeverCallsGraph()
    {
        var handler = new RecordingHttpMessageHandler((_, _) =>
            throw new InvalidOperationException("The worker must not call Graph Registry."));
        var options = CreateValidOptions();
        options.RegistryProvider = Agent365Options.DisabledRegistryProvider;
        options.DirectRegistryPreviewEnabled = false;
        var client = CreateClient(handler, options: options);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.RegisterAgent, CreateAssignAgent365AccessState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.AGENT365_REGISTRY_ACTION_REQUIRED);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().BeEmpty();
    }

    [Fact]
    public async Task ExecuteCreateApplication_ForbiddenIsNormalizedWithoutResponseBodyLeakage()
    {
        var handler = new RecordingHttpMessageHandler((_, _) => ErrorResponse(
            HttpStatusCode.Forbidden,
            DependencyBodySentinel));
        var client = CreateClient(handler);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.CreateAppRegistration),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_DEPENDENCY_FORBIDDEN);
        exception.Which.IsTransient.Should().BeFalse();
        exception.Which.RequiresManualIntervention.Should().BeFalse();
        exception.Which.Message.Should().NotContain(DependencyBodySentinel);
        exception.Which.SafeSummary.Should().NotContain(DependencyBodySentinel);
    }

    [Fact]
    public async Task ExecuteCreateApplication_ThrottleIsNormalizedAsRetryableThrottle()
    {
        var handler = new RecordingHttpMessageHandler((_, _) => ErrorResponse(
            HttpStatusCode.TooManyRequests,
            DependencyBodySentinel));
        var client = CreateClient(handler);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.CreateAppRegistration),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_DEPENDENCY_THROTTLED);
        exception.Which.IsTransient.Should().BeTrue();
        exception.Which.RequiresManualIntervention.Should().BeFalse();
        exception.Which.Message.Should().NotContain(DependencyBodySentinel);
        exception.Which.SafeSummary.Should().NotContain(DependencyBodySentinel);
    }

    [Fact]
    public async Task ExecuteStoreCredentials_SecretTextIsAbsentFromResultAndLogs()
    {
        var credentialDisplayName = $"a365-gateway:{AgentRegistrationId:D}";
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => ApplicationCredentialResponse(credentialDisplayName, includeCredential: false),
            1 => JsonResponse(HttpStatusCode.OK, new
            {
                keyId = PasswordCredentialKeyId,
                displayName = credentialDisplayName,
                endDateTime = CredentialExpiry,
                secretText = SecretTextSentinel
            }),
            2 => ApplicationCredentialResponse(credentialDisplayName, includeCredential: true),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var credentialStore = new RecordingCredentialStore
        {
            StoredResult = new StoredPasswordCredential(
                PasswordCredentialKeyId.ToString("D"),
                "https://unit-test-vault.vault.azure.net/secrets/agent-credential/version",
                CredentialExpiry)
        };
        var logger = new RecordingLogger<Agent365ProvisioningClient>();
        var client = CreateClient(
            handler,
            new RecordingTokenProvider(),
            credentialStore,
            logger,
            CreateValidOptions());
        var request = CreateRequest(
            ProvisioningStepType.StoreCredentials,
            new Agent365ProvisioningState
            {
                ApplicationObjectId = ApplicationObjectId.ToString("D")
            });

        var result = await client.ExecuteStepAsync(request, CancellationToken.None);

        credentialStore.CapturedSecretText.Should().Be(SecretTextSentinel);
        result.State.PasswordCredentialKeyId.Should().Be(PasswordCredentialKeyId.ToString("D"));
        result.State.KeyVaultSecretUri.Should().Be(credentialStore.StoredResult.KeyVaultSecretUri);
        var serializedResult = JsonSerializer.Serialize(result);
        serializedResult.Should().NotContain(SecretTextSentinel);
        serializedResult.ToLowerInvariant().Should().NotContain("secrettext");
        string.Join("|", logger.Messages).Should().NotContain(SecretTextSentinel);
    }

    [Fact]
    public async Task ExecuteLegacyAssignRoles_StillAssignsExternalAgentToLegacyClientPrincipal()
    {
        var gatewayResourcePrincipalId = Guid.Parse("10101010-1010-4010-8010-101010101010");
        var externalAgentRoleId = Guid.Parse("30303030-3030-4030-8030-303030303030");
        const string gatewayAssignmentId = "legacy-gateway-assignment-id";
        var assignments = new[]
        {
            new
            {
                id = gatewayAssignmentId,
                principalId = ApplicationObjectId,
                resourceId = gatewayResourcePrincipalId,
                appRoleId = externalAgentRoleId
            }
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => ServicePrincipalWithRoleResponse(
                gatewayResourcePrincipalId,
                GatewayApiClientId,
                externalAgentRoleId,
                "ExternalAgent"),
            1 => JsonResponse(HttpStatusCode.OK, new { value = assignments }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(handler);
        var request = CreateRequest(
            ProvisioningStepType.AssignRoles,
            new Agent365ProvisioningState
            {
                ServicePrincipalObjectId = ApplicationObjectId.ToString("D"),
                AppRoleAssignmentId = gatewayAssignmentId
            });

        var result = await client.ExecuteStepAsync(request, CancellationToken.None);

        result.State.AppRoleAssignmentId.Should().Be(gatewayAssignmentId);
        result.CompletionEvidence.Should().Be("ExternalAgentAppRoleAssignmentVerified");
        handler.Requests.Should().HaveCount(2);
        handler.Requests.Should().OnlyContain(candidate => candidate.Method == HttpMethod.Get);
    }

    [Fact]
    public async Task ExecuteAssignAgent365Access_VerifiesAndPersistsOnlyObservabilityAssignment()
    {
        var observabilityResourcePrincipalId = Guid.Parse("20202020-2020-4020-8020-202020202020");
        var observabilityRoleId = Guid.Parse("40404040-4040-4040-8040-404040404040");
        const string observabilityAssignmentId = "observability-assignment-id";
        var assignments = new[]
        {
            new
            {
                id = observabilityAssignmentId,
                principalId = AgentIdentityObjectId,
                resourceId = observabilityResourcePrincipalId,
                appRoleId = observabilityRoleId
            }
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => ServicePrincipalWithRoleResponse(
                observabilityResourcePrincipalId,
                ObservabilityApplicationClientId,
                observabilityRoleId,
                "Agent365.Observability.OtelWrite"),
            1 => JsonResponse(HttpStatusCode.OK, new { value = assignments }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var options = CreateValidOptions();
        options.ExternalAgentAppRoleValue = string.Empty;
        var client = CreateClient(handler, options: options);
        var request = CreateRequest(
            ProvisioningStepType.AssignAgent365Access,
            new Agent365ProvisioningState
            {
                BlueprintObjectId = BlueprintObjectId.ToString("D"),
                BlueprintClientId = BlueprintClientId.ToString("D"),
                AgentIdentityObjectId = AgentIdentityObjectId.ToString("D"),
                AgentIdentityClientId = ApplicationClientId.ToString("D"),
                ObservabilityAppRoleAssignmentId = observabilityAssignmentId
            });

        var result = await client.ExecuteStepAsync(request, CancellationToken.None);

        result.State.ObservabilityAppRoleAssignmentId.Should().Be(observabilityAssignmentId);
        result.CompletionEvidence.Should().Be("AgentIdentityObservabilityAppRoleVerified");
        handler.Requests.Should().HaveCount(2);
        handler.Requests.Should().OnlyContain(candidate => candidate.Method == HttpMethod.Get);
        handler.Requests.Should().NotContain(candidate =>
            candidate.Uri.Contains(GatewayApiClientId.ToString("D"), StringComparison.Ordinal));
    }

    [Fact]
    public async Task ExecuteAssignAgent365Access_DelayedExactAssignmentSucceedsWithoutReposting()
    {
        var resourcePrincipalId = Guid.Parse("20202020-2020-4020-8020-202020202020");
        var roleId = Guid.Parse("40404040-4040-4040-8040-404040404040");
        const string assignmentId = "observability-assignment-id";
        var assignment = new
        {
            id = assignmentId,
            principalId = AgentIdentityObjectId,
            resourceId = resourcePrincipalId,
            appRoleId = roleId
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => ServicePrincipalWithRoleResponse(
                resourcePrincipalId,
                ObservabilityApplicationClientId,
                roleId,
                "Agent365.Observability.OtelWrite"),
            1 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            2 => JsonResponse(HttpStatusCode.Created, assignment),
            3 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            4 => JsonResponse(HttpStatusCode.OK, new { value = new[] { assignment } }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: [TimeSpan.Zero, TimeSpan.Zero]);

        var result = await client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.AssignAgent365Access,
                CreateAssignAgent365AccessState()),
            CancellationToken.None);

        result.State.ObservabilityAppRoleAssignmentId.Should().Be(assignmentId);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
        handler.Requests.Skip(3).Should().OnlyContain(candidate =>
            candidate.Method == HttpMethod.Get &&
            candidate.Uri.Contains("/appRoleAssignments", StringComparison.Ordinal));
    }

    [Fact]
    public async Task ExecuteAssignAgent365Access_ExplicitNotFoundBeforeMutation_RetriesExactAssignment()
    {
        var resourcePrincipalId = Guid.Parse("20202020-2020-4020-8020-202020202020");
        var roleId = Guid.Parse("40404040-4040-4040-8040-404040404040");
        var assignment = new
        {
            id = "observability-assignment-id",
            principalId = AgentIdentityObjectId,
            resourceId = resourcePrincipalId,
            appRoleId = roleId
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => ServicePrincipalWithRoleResponse(
                resourcePrincipalId,
                ObservabilityApplicationClientId,
                roleId,
                "Agent365.Observability.OtelWrite"),
            1 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            2 => JsonResponse(HttpStatusCode.NotFound, new { error = new { code = "Request_ResourceNotFound" } }),
            3 => JsonResponse(HttpStatusCode.Created, assignment),
            4 => JsonResponse(HttpStatusCode.OK, new { value = new[] { assignment } }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: [TimeSpan.Zero, TimeSpan.Zero]);

        var result = await client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.AssignAgent365Access,
                CreateAssignAgent365AccessState()),
            CancellationToken.None);

        result.State.ObservabilityAppRoleAssignmentId.Should()
            .Be("observability-assignment-id");
        handler.Requests.Count(request => request.Method == HttpMethod.Post).Should().Be(2);
    }

    [Fact]
    public async Task ExecuteAssignAgent365Access_DelayedPrincipalRelationshipSucceedsWithoutReposting()
    {
        var resourcePrincipalId = Guid.Parse("20202020-2020-4020-8020-202020202020");
        var roleId = Guid.Parse("40404040-4040-4040-8040-404040404040");
        const string assignmentId = "observability-assignment-id";
        var assignment = new
        {
            id = assignmentId,
            principalId = AgentIdentityObjectId,
            resourceId = resourcePrincipalId,
            appRoleId = roleId
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => ServicePrincipalWithRoleResponse(
                resourcePrincipalId,
                ObservabilityApplicationClientId,
                roleId,
                "Agent365.Observability.OtelWrite"),
            1 => JsonResponse(HttpStatusCode.NotFound, new { }),
            2 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            3 => JsonResponse(HttpStatusCode.Created, assignment),
            4 => JsonResponse(HttpStatusCode.OK, new { value = new[] { assignment } }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: [TimeSpan.Zero, TimeSpan.Zero]);

        var result = await client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.AssignAgent365Access,
                CreateAssignAgent365AccessState()),
            CancellationToken.None);

        result.State.ObservabilityAppRoleAssignmentId.Should().Be(assignmentId);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
        handler.Requests.Should().HaveCount(5);
    }

    [Fact]
    public async Task ExecuteAssignAgent365Access_DuplicateReadbackFailsWithoutReposting()
    {
        var resourcePrincipalId = Guid.Parse("20202020-2020-4020-8020-202020202020");
        var roleId = Guid.Parse("40404040-4040-4040-8040-404040404040");
        const string assignmentId = "observability-assignment-id";
        var assignment = new
        {
            id = assignmentId,
            principalId = AgentIdentityObjectId,
            resourceId = resourcePrincipalId,
            appRoleId = roleId
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => ServicePrincipalWithRoleResponse(
                resourcePrincipalId,
                ObservabilityApplicationClientId,
                roleId,
                "Agent365.Observability.OtelWrite"),
            1 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            2 => JsonResponse(HttpStatusCode.Created, assignment),
            3 => JsonResponse(HttpStatusCode.OK, new { value = new[] { assignment, assignment } }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: FiveImmediateVerificationAttempts);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.AssignAgent365Access,
                CreateAssignAgent365AccessState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteAssignAgent365Access_DifferentVerifiedIdFailsWithoutReposting()
    {
        var resourcePrincipalId = Guid.Parse("20202020-2020-4020-8020-202020202020");
        var roleId = Guid.Parse("40404040-4040-4040-8040-404040404040");
        var createdAssignment = new
        {
            id = "created-observability-assignment-id",
            principalId = AgentIdentityObjectId,
            resourceId = resourcePrincipalId,
            appRoleId = roleId
        };
        var differentAssignment = new
        {
            id = "different-observability-assignment-id",
            principalId = AgentIdentityObjectId,
            resourceId = resourcePrincipalId,
            appRoleId = roleId
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => ServicePrincipalWithRoleResponse(
                resourcePrincipalId,
                ObservabilityApplicationClientId,
                roleId,
                "Agent365.Observability.OtelWrite"),
            1 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            2 => JsonResponse(HttpStatusCode.Created, createdAssignment),
            3 => JsonResponse(HttpStatusCode.OK, new { value = new[] { differentAssignment } }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: FiveImmediateVerificationAttempts);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.AssignAgent365Access,
                CreateAssignAgent365AccessState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteAssignAgent365Access_MissingAfterBoundedReadsFailsWithoutReposting()
    {
        var resourcePrincipalId = Guid.Parse("20202020-2020-4020-8020-202020202020");
        var roleId = Guid.Parse("40404040-4040-4040-8040-404040404040");
        var assignment = new
        {
            id = "observability-assignment-id",
            principalId = AgentIdentityObjectId,
            resourceId = resourcePrincipalId,
            appRoleId = roleId
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => ServicePrincipalWithRoleResponse(
                resourcePrincipalId,
                ObservabilityApplicationClientId,
                roleId,
                "Agent365.Observability.OtelWrite"),
            1 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            2 => JsonResponse(HttpStatusCode.Created, assignment),
            >= 3 and <= 7 => JsonResponse(
                HttpStatusCode.OK,
                new { value = Array.Empty<object>() }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays: FiveImmediateVerificationAttempts);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.AssignAgent365Access,
                CreateAssignAgent365AccessState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(8);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteAssignAgent365Access_CancellationFailsManualWithoutReposting()
    {
        using var cancellation = new CancellationTokenSource();
        var resourcePrincipalId = Guid.Parse("20202020-2020-4020-8020-202020202020");
        var roleId = Guid.Parse("40404040-4040-4040-8040-404040404040");
        var assignment = new
        {
            id = "observability-assignment-id",
            principalId = AgentIdentityObjectId,
            resourceId = resourcePrincipalId,
            appRoleId = roleId
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => ServicePrincipalWithRoleResponse(
                resourcePrincipalId,
                ObservabilityApplicationClientId,
                roleId,
                "Agent365.Observability.OtelWrite"),
            1 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            2 => JsonResponse(HttpStatusCode.Created, assignment),
            3 => CancelAndReturnEmptyCollection(cancellation),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            postMutationVerificationLookupDelays:
            [TimeSpan.Zero, TimeSpan.FromMinutes(1)]);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.AssignAgent365Access,
                CreateAssignAgent365AccessState()),
            cancellation.Token);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(4);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteConfigureGatewayFederation_DerivesCallerAndCreatesOneGatewayFederation()
    {
        const string gatewayCredentialId = "gateway-federated-credential-id";
        var issuer = $"https://login.microsoftonline.com/{TenantId:D}/v2.0";
        var credential = new
        {
            id = gatewayCredentialId,
            name = $"a365-gateway-{GatewayManagedIdentityPrincipalId:N}",
            issuer,
            subject = GatewayManagedIdentityPrincipalId.ToString("D"),
            audiences = new[] { "api://AzureADTokenExchange" }
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => JsonResponse(HttpStatusCode.Created, credential),
            2 => JsonResponse(HttpStatusCode.OK, new { value = new[] { credential } }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var tokenProvider = new RecordingTokenProvider(GatewayManagedIdentityPrincipalId);
        var client = CreateClient(handler, tokenProvider);
        var request = CreateRequest(
            ProvisioningStepType.ConfigureGatewayFederation,
            CreateBlueprintState());

        var result = await client.ExecuteStepAsync(request, CancellationToken.None);

        result.State.GatewayManagedIdentityPrincipalId.Should()
            .Be(GatewayManagedIdentityPrincipalId.ToString("D"));
        result.State.GatewayFederatedCredentialId.Should().Be(gatewayCredentialId);
        result.CompletionEvidence.Should().Be("BlueprintGatewayFederationVerified");
        handler.Requests.Should().HaveCount(3);
        handler.Requests.Should().ContainSingle(request => request.Method == HttpMethod.Post);
        handler.Requests.Single(request => request.Method == HttpMethod.Post).Body.Should()
            .Contain($"a365-gateway-{GatewayManagedIdentityPrincipalId:N}")
            .And.Contain(GatewayManagedIdentityPrincipalId.ToString("D"));
    }

    [Fact]
    public async Task ExecuteConfigureGatewayFederation_ExactExistingCredentialIsReusedWithoutMutation()
    {
        const string gatewayCredentialId = "fea6b67c-008a-49aa-9672-6b98500d3d97";
        var credential = new
        {
            id = gatewayCredentialId,
            name = $"a365-gateway-{GatewayManagedIdentityPrincipalId:N}",
            issuer = $"https://login.microsoftonline.com/{TenantId:D}/v2.0",
            subject = GatewayManagedIdentityPrincipalId.ToString("D"),
            audiences = new[] { "api://AzureADTokenExchange" }
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = new[] { credential } }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var tokenProvider = new RecordingTokenProvider(GatewayManagedIdentityPrincipalId);
        var client = CreateClient(handler, tokenProvider);

        var result = await client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.ConfigureGatewayFederation,
                CreateBlueprintState()),
            CancellationToken.None);

        result.State.GatewayManagedIdentityPrincipalId.Should()
            .Be(GatewayManagedIdentityPrincipalId.ToString("D"));
        result.State.GatewayFederatedCredentialId.Should().Be(gatewayCredentialId);
        result.CompletionEvidence.Should().Be("BlueprintGatewayFederationVerified");
        var lookup = handler.Requests.Should().ContainSingle().Subject;
        lookup.Method.Should().Be(HttpMethod.Get);
        lookup.Uri.Should().Be(
            $"https://graph.microsoft.com/v1.0/applications/{BlueprintObjectId:D}/federatedIdentityCredentials?$select=id,name,issuer,subject,audiences&$top=100");
        handler.Requests.Should().OnlyContain(request => request.Method == HttpMethod.Get);
    }

    [Fact]
    public async Task ExecuteConfigureGatewayFederation_ExistingCredentialWithExtraAudienceFailsBeforeMutation()
    {
        var issuer = $"https://login.microsoftonline.com/{TenantId:D}/v2.0";
        var credential = new
        {
            id = "gateway-federated-credential-id",
            name = $"a365-gateway-{GatewayManagedIdentityPrincipalId:N}",
            issuer,
            subject = GatewayManagedIdentityPrincipalId.ToString("D"),
            audiences = new[]
            {
                "api://AzureADTokenExchange",
                "api://unexpected-audience"
            }
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = new[] { credential } }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            new RecordingTokenProvider(GatewayManagedIdentityPrincipalId));

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.ConfigureGatewayFederation,
                CreateBlueprintState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_STATE_INVALID);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Get);
        handler.Requests.Should().NotContain(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteConfigureGatewayFederation_PostCreateReadbackWithExtraAudienceFailsWithoutReposting()
    {
        var issuer = $"https://login.microsoftonline.com/{TenantId:D}/v2.0";
        var createdCredential = new
        {
            id = "gateway-federated-credential-id",
            name = $"a365-gateway-{GatewayManagedIdentityPrincipalId:N}",
            issuer,
            subject = GatewayManagedIdentityPrincipalId.ToString("D"),
            audiences = new[] { "api://AzureADTokenExchange" }
        };
        var readbackCredential = new
        {
            createdCredential.id,
            createdCredential.name,
            createdCredential.issuer,
            createdCredential.subject,
            audiences = new[]
            {
                "api://AzureADTokenExchange",
                "api://unexpected-audience"
            }
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => JsonResponse(HttpStatusCode.Created, createdCredential),
            2 => JsonResponse(HttpStatusCode.OK, new { value = new[] { readbackCredential } }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            new RecordingTokenProvider(GatewayManagedIdentityPrincipalId),
            federatedCredentialVerificationLookupDelays: [TimeSpan.Zero]);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.ConfigureGatewayFederation,
                CreateBlueprintState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_STATE_INVALID);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(3);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteConfigureGatewayFederation_ReconcilesDelayedSuccessfulCreateWithoutReposting()
    {
        const string gatewayCredentialId = "gateway-federated-credential-id";
        var issuer = $"https://login.microsoftonline.com/{TenantId:D}/v2.0";
        var credential = new
        {
            id = gatewayCredentialId,
            name = $"a365-gateway-{GatewayManagedIdentityPrincipalId:N}",
            issuer,
            subject = GatewayManagedIdentityPrincipalId.ToString("D"),
            audiences = new[] { "api://AzureADTokenExchange" }
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => JsonResponse(HttpStatusCode.Created, credential),
            2 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            3 => JsonResponse(HttpStatusCode.OK, new { value = new[] { credential } }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            new RecordingTokenProvider(GatewayManagedIdentityPrincipalId),
            federatedCredentialVerificationLookupDelays:
            [TimeSpan.Zero, TimeSpan.FromMilliseconds(10)]);

        var result = await client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.ConfigureGatewayFederation,
                CreateBlueprintState()),
            CancellationToken.None);

        result.State.GatewayFederatedCredentialId.Should().Be(gatewayCredentialId);
        result.CompletionEvidence.Should().Be("BlueprintGatewayFederationVerified");
        handler.Requests.Should().HaveCount(4);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
        handler.Requests.Where(candidate => candidate.Method == HttpMethod.Get).Should().HaveCount(3);
    }

    [Fact]
    public async Task ExecuteConfigureGatewayFederation_DelayedDuplicateResultFailsAmbiguousWithoutReposting()
    {
        const string gatewayCredentialId = "gateway-federated-credential-id";
        var issuer = $"https://login.microsoftonline.com/{TenantId:D}/v2.0";
        var credential = new
        {
            id = gatewayCredentialId,
            name = $"a365-gateway-{GatewayManagedIdentityPrincipalId:N}",
            issuer,
            subject = GatewayManagedIdentityPrincipalId.ToString("D"),
            audiences = new[] { "api://AzureADTokenExchange" }
        };
        var duplicate = new
        {
            id = "duplicate-federated-credential-id",
            credential.name,
            credential.issuer,
            credential.subject,
            credential.audiences
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => JsonResponse(HttpStatusCode.Created, credential),
            2 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            3 => JsonResponse(HttpStatusCode.OK, new { value = new[] { credential, duplicate } }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            new RecordingTokenProvider(GatewayManagedIdentityPrincipalId),
            federatedCredentialVerificationLookupDelays:
            [TimeSpan.Zero, TimeSpan.FromMilliseconds(10)]);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.ConfigureGatewayFederation,
                CreateBlueprintState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(4);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteConfigureGatewayFederation_DelayedMismatchedResultFailsClosedWithoutReposting()
    {
        const string gatewayCredentialId = "gateway-federated-credential-id";
        var issuer = $"https://login.microsoftonline.com/{TenantId:D}/v2.0";
        var createdCredential = new
        {
            id = gatewayCredentialId,
            name = $"a365-gateway-{GatewayManagedIdentityPrincipalId:N}",
            issuer,
            subject = GatewayManagedIdentityPrincipalId.ToString("D"),
            audiences = new[] { "api://AzureADTokenExchange" }
        };
        var mismatchedCredential = new
        {
            id = gatewayCredentialId,
            createdCredential.name,
            createdCredential.issuer,
            subject = Guid.Parse("78787878-7878-4787-8787-787878787878").ToString("D"),
            createdCredential.audiences
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => JsonResponse(HttpStatusCode.Created, createdCredential),
            2 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            3 => JsonResponse(
                HttpStatusCode.OK,
                new { value = new[] { mismatchedCredential } }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            new RecordingTokenProvider(GatewayManagedIdentityPrincipalId),
            federatedCredentialVerificationLookupDelays:
            [TimeSpan.Zero, TimeSpan.FromMilliseconds(10)]);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.ConfigureGatewayFederation,
                CreateBlueprintState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_STATE_INVALID);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(4);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteConfigureGatewayFederation_DifferentVerifiedIdFailsAmbiguousWithoutReposting()
    {
        var issuer = $"https://login.microsoftonline.com/{TenantId:D}/v2.0";
        var createdCredential = new
        {
            id = "created-federated-credential-id",
            name = $"a365-gateway-{GatewayManagedIdentityPrincipalId:N}",
            issuer,
            subject = GatewayManagedIdentityPrincipalId.ToString("D"),
            audiences = new[] { "api://AzureADTokenExchange" }
        };
        var differentCredential = new
        {
            id = "different-federated-credential-id",
            createdCredential.name,
            createdCredential.issuer,
            createdCredential.subject,
            createdCredential.audiences
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => JsonResponse(HttpStatusCode.Created, createdCredential),
            2 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            3 => JsonResponse(HttpStatusCode.OK, new { value = new[] { differentCredential } }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            new RecordingTokenProvider(GatewayManagedIdentityPrincipalId),
            federatedCredentialVerificationLookupDelays:
            [TimeSpan.Zero, TimeSpan.FromMilliseconds(10)]);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.ConfigureGatewayFederation,
                CreateBlueprintState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(4);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteConfigureGatewayFederation_MissingResultAfterBoundedReconciliationFailsAmbiguous()
    {
        var issuer = $"https://login.microsoftonline.com/{TenantId:D}/v2.0";
        var credential = new
        {
            id = "gateway-federated-credential-id",
            name = $"a365-gateway-{GatewayManagedIdentityPrincipalId:N}",
            issuer,
            subject = GatewayManagedIdentityPrincipalId.ToString("D"),
            audiences = new[] { "api://AzureADTokenExchange" }
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => JsonResponse(HttpStatusCode.Created, credential),
            2 or 3 or 4 => JsonResponse(
                HttpStatusCode.OK,
                new { value = Array.Empty<object>() }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            new RecordingTokenProvider(GatewayManagedIdentityPrincipalId),
            federatedCredentialVerificationLookupDelays:
            [TimeSpan.Zero, TimeSpan.FromMilliseconds(1), TimeSpan.FromMilliseconds(1)]);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.ConfigureGatewayFederation,
                CreateBlueprintState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().HaveCount(5);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteConfigureGatewayFederation_CancellationStopsDelayedReconciliationWithoutReposting()
    {
        using var cancellation = new CancellationTokenSource();
        var issuer = $"https://login.microsoftonline.com/{TenantId:D}/v2.0";
        var credential = new
        {
            id = "gateway-federated-credential-id",
            name = $"a365-gateway-{GatewayManagedIdentityPrincipalId:N}",
            issuer,
            subject = GatewayManagedIdentityPrincipalId.ToString("D"),
            audiences = new[] { "api://AzureADTokenExchange" }
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => JsonResponse(HttpStatusCode.Created, credential),
            2 => CancelAndReturnEmpty(cancellation),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            new RecordingTokenProvider(GatewayManagedIdentityPrincipalId),
            federatedCredentialVerificationLookupDelays:
            [TimeSpan.Zero, TimeSpan.FromMilliseconds(10)]);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.ConfigureGatewayFederation,
                CreateBlueprintState()),
            cancellation.Token);

        await action.Should().ThrowAsync<OperationCanceledException>();
        handler.Requests.Should().HaveCount(3);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteConfigureGatewayFederation_MutationExceptionStillRecoversWithoutReposting()
    {
        const string gatewayCredentialId = "gateway-federated-credential-id";
        var issuer = $"https://login.microsoftonline.com/{TenantId:D}/v2.0";
        var credential = new
        {
            id = gatewayCredentialId,
            name = $"a365-gateway-{GatewayManagedIdentityPrincipalId:N}",
            issuer,
            subject = GatewayManagedIdentityPrincipalId.ToString("D"),
            audiences = new[] { "api://AzureADTokenExchange" }
        };
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            1 => ErrorResponse(HttpStatusCode.Conflict, "create-conflict"),
            2 => JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() }),
            3 or 4 => JsonResponse(HttpStatusCode.OK, new { value = new[] { credential } }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            new RecordingTokenProvider(GatewayManagedIdentityPrincipalId));

        var result = await client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.ConfigureGatewayFederation,
                CreateBlueprintState()),
            CancellationToken.None);

        result.State.GatewayFederatedCredentialId.Should().Be(gatewayCredentialId);
        result.CompletionEvidence.Should().Be("BlueprintGatewayFederationVerified");
        handler.Requests.Should().HaveCount(5);
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Post);
    }

    [Fact]
    public async Task ExecuteConfigureGatewayFederation_ConfiguredIdentityMismatchMakesZeroGraphMutations()
    {
        var unexpectedCaller = Guid.Parse("47474747-4747-4747-8747-474747474747");
        var handler = new RecordingHttpMessageHandler((_, _) =>
            throw new InvalidOperationException("Graph must not be mutated for an identity mismatch."));
        var client = CreateClient(handler, new RecordingTokenProvider(unexpectedCaller));

        var action = () => client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.ConfigureGatewayFederation, CreateBlueprintState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_CONFIGURATION_INVALID);
        handler.Requests.Should().BeEmpty();
    }

    [Fact]
    public async Task ExecuteConfigureGatewayFederation_NullCredentialCollectionFailsBeforeMutation()
    {
        var handler = new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => JsonResponse(HttpStatusCode.OK, new { unexpected = Array.Empty<object>() }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
        var client = CreateClient(
            handler,
            new RecordingTokenProvider(GatewayManagedIdentityPrincipalId));

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.ConfigureGatewayFederation,
                CreateBlueprintState()),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().ContainSingle(candidate => candidate.Method == HttpMethod.Get);
        handler.Requests.Should().NotContain(candidate => candidate.Method == HttpMethod.Post);
    }

    private static HttpResponseMessage CancelAndReturnEmpty(CancellationTokenSource cancellation)
    {
        cancellation.Cancel();
        return JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() });
    }

    [Fact]
    public async Task ExecuteVerifyAgent365Connection_TrustsDelegatedEvidenceAndVerifiesMicrosoftResources()
    {
        const string gatewayCredentialId = "gateway-federated-credential-id";
        var handler = CreateAgent365ConnectionVerificationHandler(gatewayCredentialId);
        var tokenProvider = new RecordingTokenProvider(GatewayManagedIdentityPrincipalId);
        var observabilityTokenProvider = new RecordingObservabilityTokenProvider();
        var client = CreateClient(
            handler,
            tokenProvider,
            observabilityTokenProvider: observabilityTokenProvider);
        var request = CreateRequest(
            ProvisioningStepType.VerifyAgent365Connection,
            CreateAgent365ConnectionVerificationState(gatewayCredentialId));

        var result = await client.ExecuteStepAsync(request, CancellationToken.None);

        result.State.Agent365ConnectionVerifiedAtUtc.Should().NotBeNull();
        result.State.GatewayFederatedCredentialId.Should().Be(gatewayCredentialId);
        result.CompletionEvidence.Should().Be("Agent365ObservabilityTokenAndConnectionVerified");
        observabilityTokenProvider.CallCount.Should().Be(1);
        handler.Requests.Should().HaveCount(6);
        handler.Requests[1].Uri.Should().Be(
            $"https://graph.microsoft.com/v1.0/servicePrincipals/{BlueprintPrincipalObjectId:D}/microsoft.graph.agentIdentityBlueprintPrincipal?$select=id,appId,displayName,appRoles");
        handler.Requests.Should().NotContain(candidate =>
            candidate.Uri.Contains("agent-runtime/readiness", StringComparison.Ordinal));
        handler.Requests.Should().NotContain(candidate =>
            candidate.Uri.Contains(GatewayApiClientId.ToString("D"), StringComparison.Ordinal));
        handler.Requests.Should().NotContain(candidate =>
            candidate.Uri.Contains("/beta/copilot/agentRegistrations", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("transient")]
    [InlineData("missing-role")]
    public async Task ExecuteVerifyAgent365Connection_PropagationFailureRetriesThenSucceeds(
        string scenario)
    {
        const string gatewayCredentialId = "gateway-federated-credential-id";
        var handler = CreateAgent365ConnectionVerificationHandler(gatewayCredentialId);
        var firstResult = scenario == "transient"
            ? (Exception)new Agent365ObservabilityTransientException("BlueprintTokenHttp503")
            : new Agent365ObservabilityConfigurationException("MissingOtelWriteRole");
        var observabilityTokenProvider = new SequenceObservabilityTokenProvider(
            firstResult,
            new AccessToken(
                "validated-agent-365-observability-token",
                DateTimeOffset.UtcNow.AddMinutes(10)));
        var client = CreateClient(
            handler,
            new RecordingTokenProvider(GatewayManagedIdentityPrincipalId),
            observabilityTokenProvider: observabilityTokenProvider,
            postMutationVerificationLookupDelays: [TimeSpan.Zero, TimeSpan.Zero]);

        var result = await client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.VerifyAgent365Connection,
                CreateAgent365ConnectionVerificationState(gatewayCredentialId)),
            CancellationToken.None);

        result.State.Agent365ConnectionVerifiedAtUtc.Should().NotBeNull();
        observabilityTokenProvider.CallCount.Should().Be(2);
    }

    [Theory]
    [InlineData("AgentIdentityMismatch")]
    [InlineData("InvalidAudience")]
    [InlineData("TenantIdentityMismatch")]
    public async Task ExecuteVerifyAgent365Connection_PermanentTokenMismatchIsNotRetried(
        string errorCode)
    {
        const string gatewayCredentialId = "gateway-federated-credential-id";
        var handler = CreateAgent365ConnectionVerificationHandler(gatewayCredentialId);
        var observabilityTokenProvider = new SequenceObservabilityTokenProvider(
            new Agent365ObservabilityConfigurationException(errorCode),
            new AccessToken(
                "must-not-be-requested",
                DateTimeOffset.UtcNow.AddMinutes(10)));
        var client = CreateClient(
            handler,
            new RecordingTokenProvider(GatewayManagedIdentityPrincipalId),
            observabilityTokenProvider: observabilityTokenProvider,
            postMutationVerificationLookupDelays: FiveImmediateVerificationAttempts);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.VerifyAgent365Connection,
                CreateAgent365ConnectionVerificationState(gatewayCredentialId)),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_CONFIGURATION_INVALID);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        observabilityTokenProvider.CallCount.Should().Be(1);
    }

    [Fact]
    public async Task ExecuteVerifyAgent365Connection_MissingBlueprintPrincipalFailsBeforeDependencyCalls()
    {
        var handler = new RecordingHttpMessageHandler((_, _) =>
            throw new InvalidOperationException("HTTP must not be called for invalid persisted proof."));
        var client = CreateClient(handler);
        var invalidState = CreateAgent365ConnectionVerificationState(
            "gateway-federated-credential-id") with
        {
            BlueprintPrincipalObjectId = null
        };

        var action = () => client.ExecuteStepAsync(
            CreateRequest(ProvisioningStepType.VerifyAgent365Connection, invalidState),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_STATE_INVALID);
        exception.Which.RequiresManualIntervention.Should().BeTrue();
        handler.Requests.Should().BeEmpty();
    }

    [Theory]
    [InlineData("transient", ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE, true, false)]
    [InlineData("missing-role", ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE, true, false)]
    [InlineData("identity-mismatch", ErrorCodes.PROVISIONING_CONFIGURATION_INVALID, false, true)]
    [InlineData("empty-token", ErrorCodes.PROVISIONING_CONFIGURATION_INVALID, false, true)]
    [InlineData("expired-token", ErrorCodes.PROVISIONING_CONFIGURATION_INVALID, false, true)]
    [InlineData("unconfigured", ErrorCodes.PROVISIONING_CONFIGURATION_INVALID, false, true)]
    public async Task ExecuteVerifyAgent365Connection_TokenProofFailuresFailClosed(
        string scenario,
        string expectedErrorCode,
        bool expectedTransient,
        bool expectedManualIntervention)
    {
        const string gatewayCredentialId = "gateway-federated-credential-id";
        var handler = CreateAgent365ConnectionVerificationHandler(gatewayCredentialId);
        IAgent365ObservabilityTokenProvider? observabilityTokenProvider = scenario switch
        {
            "transient" => new RecordingObservabilityTokenProvider(
                exception: new Agent365ObservabilityTransientException("Http503")),
            "missing-role" => new RecordingObservabilityTokenProvider(
                exception: new Agent365ObservabilityConfigurationException("MissingOtelWriteRole")),
            "identity-mismatch" => new RecordingObservabilityTokenProvider(
                exception: new Agent365ObservabilityConfigurationException("AgentIdentityMismatch")),
            "empty-token" => new RecordingObservabilityTokenProvider(
                token: new AccessToken(string.Empty, DateTimeOffset.UtcNow.AddMinutes(10))),
            "expired-token" => new RecordingObservabilityTokenProvider(
                token: new AccessToken("expired-token", DateTimeOffset.UtcNow.AddMinutes(-1))),
            "unconfigured" => null,
            _ => throw new ArgumentOutOfRangeException(nameof(scenario))
        };
        var client = CreateClient(
            handler,
            new RecordingTokenProvider(GatewayManagedIdentityPrincipalId),
            observabilityTokenProvider: observabilityTokenProvider,
            postMutationVerificationLookupDelays: [TimeSpan.Zero]);

        var action = () => client.ExecuteStepAsync(
            CreateRequest(
                ProvisioningStepType.VerifyAgent365Connection,
                CreateAgent365ConnectionVerificationState(gatewayCredentialId)),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ProvisioningException>();
        exception.Which.ErrorCode.Should().Be(expectedErrorCode);
        exception.Which.IsTransient.Should().Be(expectedTransient);
        exception.Which.RequiresManualIntervention.Should().Be(expectedManualIntervention);
        if (observabilityTokenProvider is RecordingObservabilityTokenProvider recordingProvider)
            recordingProvider.CallCount.Should().Be(1);
    }

    private static Agent365ProvisioningClient CreateClient(
        RecordingHttpMessageHandler handler,
        RecordingTokenProvider? tokenProvider = null,
        RecordingCredentialStore? credentialStore = null,
        RecordingLogger<Agent365ProvisioningClient>? logger = null,
        Agent365Options? options = null,
        IAgent365ObservabilityTokenProvider? observabilityTokenProvider = null,
        IReadOnlyList<TimeSpan>? federatedCredentialVerificationLookupDelays = null,
        IReadOnlyList<TimeSpan>? postMutationVerificationLookupDelays = null)
    {
        tokenProvider ??= new RecordingTokenProvider();
        credentialStore ??= new RecordingCredentialStore();
        logger ??= new RecordingLogger<Agent365ProvisioningClient>();
        options ??= CreateValidOptions();
        var graph = new MicrosoftGraphProvisioningClient(
            new HttpClient(handler, disposeHandler: false)
            {
                BaseAddress = MicrosoftGraphProvisioningClient.OfficialBaseAddress
            },
            tokenProvider);
        return new Agent365ProvisioningClient(
            logger,
            options,
            graph,
            credentialStore,
            observabilityTokenProvider,
            federatedCredentialVerificationLookupDelays,
            postMutationVerificationLookupDelays);
    }

    private static Agent365Options CreateValidOptions()
    {
        return new Agent365Options
        {
            TenantId = TenantId.ToString("D"),
            RegistryProvider = Agent365Options.DirectRegistryPreviewProvider,
            DirectRegistryPreviewEnabled = true,
            GatewayApiApplicationClientId = GatewayApiClientId.ToString("D"),
            ObservabilityApplicationClientId = ObservabilityApplicationClientId.ToString("D"),
            ProvisioningManagedIdentityPrincipalId = GatewayManagedIdentityPrincipalId.ToString("D"),
            CredentialKeyVaultUri = "https://unit-test-vault.vault.azure.net/",
            ManagerApplicationIds = [ManagerApplicationId.ToString("D")],
            ExternalAgentAppRoleValue = "ExternalAgent",
            RegistryOriginatingStore = "A365CustomGateway",
            ApplicationPasswordLifetimeDays = 180,
            ProvisioningHttpTimeoutSeconds = 30
        };
    }

    private static Agent365ProvisioningStepRequest CreateRequest(
        ProvisioningStepType stepType,
        Agent365ProvisioningState? state = null)
    {
        return new Agent365ProvisioningStepRequest(
            stepType,
            new AgentProvisioningRequest(
                AgentRegistrationId,
                "external-agent-1",
                "Test agent",
                 "Test description",
                 OwnerObjectId.ToString("D"),
                 "Development",
                 "CreateNew",
                 RequestedBlueprintObjectId: null,
                 RequestedBlueprintDisplayName: BlueprintDisplayName),
            state ?? new Agent365ProvisioningState(),
            "correlation-1");
    }

    private static Agent365ProvisioningState CreateRegistryState()
    {
        return new Agent365ProvisioningState
        {
            BlueprintObjectId = BlueprintObjectId.ToString("D"),
            BlueprintClientId = BlueprintClientId.ToString("D"),
            AgentIdentityObjectId = AgentIdentityObjectId.ToString("D"),
            PlannedAgent365RegistrationId = PlannedRegistryId.ToString("D")
        };
    }

    private static Agent365ProvisioningState CreateAgentIdentityState()
    {
        return new Agent365ProvisioningState
        {
            BlueprintObjectId = BlueprintObjectId.ToString("D"),
            BlueprintClientId = BlueprintClientId.ToString("D"),
            BlueprintPrincipalObjectId = BlueprintPrincipalObjectId.ToString("D")
        };
    }

    private static Agent365ProvisioningState CreateAssignAgent365AccessState()
    {
        return new Agent365ProvisioningState
        {
            AgentIdentityObjectId = AgentIdentityObjectId.ToString("D"),
            AgentIdentityClientId = AgentIdentityObjectId.ToString("D")
        };
    }

    private static Agent365ProvisioningState CreateBlueprintState()
    {
        return new Agent365ProvisioningState
        {
            BlueprintObjectId = BlueprintObjectId.ToString("D"),
            BlueprintClientId = BlueprintClientId.ToString("D")
        };
    }

    private static Agent365ProvisioningState CreateAgent365ConnectionVerificationState(
        string gatewayCredentialId) => new()
        {
            BlueprintObjectId = BlueprintObjectId.ToString("D"),
            BlueprintClientId = BlueprintClientId.ToString("D"),
            BlueprintPrincipalObjectId = BlueprintPrincipalObjectId.ToString("D"),
            GatewayManagedIdentityPrincipalId = GatewayManagedIdentityPrincipalId.ToString("D"),
            GatewayFederatedCredentialId = gatewayCredentialId,
            AgentIdentityObjectId = AgentIdentityObjectId.ToString("D"),
            AgentIdentityClientId = AgentIdentityObjectId.ToString("D"),
            ObservabilityAppRoleAssignmentId = "observability-assignment-id",
            Agent365RegistrationId = PlannedRegistryId.ToString("D"),
            RegistryProvider = Agent365Options.DirectRegistryPreviewProvider,
            RegistryAuthenticationMode = Agent365Options.DelegatedAdministratorAuthenticationMode,
            RegistryCreatedByObjectId = OwnerObjectId.ToString("D"),
            Agent365RegistrationVerifiedAtUtc = DateTimeOffset.UtcNow
        };

    private static RecordingHttpMessageHandler CreateAgent365ConnectionVerificationHandler(
        string gatewayCredentialId)
    {
        var observabilityResourcePrincipalId = Guid.Parse("20202020-2020-4020-8020-202020202020");
        var observabilityRoleId = Guid.Parse("40404040-4040-4040-8040-404040404040");
        var assignments = new[]
        {
            new
            {
                id = "observability-assignment-id",
                principalId = AgentIdentityObjectId,
                resourceId = observabilityResourcePrincipalId,
                appRoleId = observabilityRoleId
            }
        };
        var issuer = $"https://login.microsoftonline.com/{TenantId:D}/v2.0";
        var credentials = new[]
        {
            new
            {
                id = gatewayCredentialId,
                name = $"a365-gateway-{GatewayManagedIdentityPrincipalId:N}",
                issuer,
                subject = GatewayManagedIdentityPrincipalId.ToString("D"),
                audiences = new[] { "api://AzureADTokenExchange" }
            }
        };

        var expectedIdentityDisplayName =
            $"A365 Identity - Test agent - {AgentRegistrationId:N}";
        return new RecordingHttpMessageHandler((_, index) => index switch
        {
            0 => BlueprintResponse(BlueprintDisplayName, ManagerApplicationId),
            1 => JsonResponse(HttpStatusCode.OK, new
            {
                id = BlueprintPrincipalObjectId,
                appId = BlueprintClientId
            }),
            2 => AgentIdentityResponse(expectedIdentityDisplayName, HttpStatusCode.OK),
            3 => ServicePrincipalWithRoleResponse(
                observabilityResourcePrincipalId,
                ObservabilityApplicationClientId,
                observabilityRoleId,
                "Agent365.Observability.OtelWrite"),
            4 => JsonResponse(HttpStatusCode.OK, new { value = assignments }),
            5 => JsonResponse(HttpStatusCode.OK, new { value = credentials }),
            _ => throw new InvalidOperationException("Unexpected Graph request.")
        });
    }

    private static HttpResponseMessage BlueprintResponse(
        string displayName,
        params Guid[] managerApplicationIds)
    {
        return JsonResponse(HttpStatusCode.OK, new
        {
            id = BlueprintObjectId,
            appId = BlueprintClientId,
            displayName,
            tags = new[]
            {
                "A365CustomGateway",
                $"GatewayBlueprint:{BlueprintKey}"
            },
            managerApplications = managerApplicationIds
        });
    }

    private static HttpResponseMessage AgentIdentityResponse(
        string displayName,
        HttpStatusCode status = HttpStatusCode.Created)
    {
        return JsonResponse(status, new
        {
            id = AgentIdentityObjectId,
            appId = AgentIdentityObjectId,
            displayName,
            agentIdentityBlueprintId = BlueprintClientId,
            sponsors = new[] { new { id = OwnerObjectId } }
        });
    }

    private static HttpResponseMessage ServicePrincipalWithRoleResponse(
        Guid resourcePrincipalId,
        Guid applicationClientId,
        Guid roleId,
        string roleValue)
    {
        return JsonResponse(HttpStatusCode.OK, new
        {
            id = resourcePrincipalId,
            appId = applicationClientId,
            appRoles = new[]
            {
                new
                {
                    id = roleId,
                    value = roleValue,
                    isEnabled = true,
                    allowedMemberTypes = new[] { "Application" }
                }
            }
        });
    }

    private static HttpResponseMessage AgentRegistrationResponse(
        string registryId,
        HttpStatusCode status)
    {
        return JsonResponse(status, new
        {
            id = registryId,
            sourceAgentId = "external-agent-1",
            managedByAppId = GatewayApiClientId,
            agentIdentityId = AgentIdentityObjectId,
            agentIdentityBlueprintId = BlueprintClientId,
            ownerIds = new[] { OwnerObjectId },
            createdBy = OwnerObjectId
        });
    }

    private static HttpResponseMessage ApplicationCredentialResponse(
        string credentialDisplayName,
        bool includeCredential)
    {
        var credentials = includeCredential
            ? new[]
            {
                new
                {
                    keyId = PasswordCredentialKeyId,
                    displayName = credentialDisplayName,
                    endDateTime = CredentialExpiry
                }
            }
            : [];
        return JsonResponse(HttpStatusCode.OK, new
        {
            id = ApplicationObjectId,
            appId = ApplicationClientId,
            passwordCredentials = credentials
        });
    }

    private static HttpResponseMessage JsonResponse(HttpStatusCode status, object body)
    {
        return new HttpResponseMessage(status)
        {
            Content = JsonContent.Create(body)
        };
    }

    private static HttpResponseMessage ErrorResponse(HttpStatusCode status, string sentinel)
    {
        return new HttpResponseMessage(status)
        {
            Content = new StringContent(
                $"{{\"error\":{{\"message\":\"{sentinel}\"}}}}",
                Encoding.UTF8,
                "application/json")
        };
    }

    private static HttpResponseMessage CancelAndReturnNotFound(
        CancellationTokenSource cancellation)
    {
        cancellation.Cancel();
        return JsonResponse(HttpStatusCode.NotFound, new { });
    }

    private static HttpResponseMessage CancelAndReturnEmptyCollection(
        CancellationTokenSource cancellation)
    {
        cancellation.Cancel();
        return JsonResponse(HttpStatusCode.OK, new { value = Array.Empty<object>() });
    }

    private sealed record RecordedRequest(
        HttpMethod Method,
        string Uri,
        string? Body,
        IReadOnlyDictionary<string, string[]> Headers);

    private sealed class RecordingHttpMessageHandler(
        Func<RecordedRequest, int, HttpResponseMessage> responseFactory) : HttpMessageHandler
    {
        public List<RecordedRequest> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            var recorded = new RecordedRequest(
                request.Method,
                request.RequestUri!.AbsoluteUri,
                request.Content is null
                    ? null
                    : await request.Content.ReadAsStringAsync(cancellationToken),
                request.Headers.ToDictionary(
                    header => header.Key,
                    header => header.Value.ToArray(),
                    StringComparer.OrdinalIgnoreCase));
            Requests.Add(recorded);
            return responseFactory(recorded, Requests.Count - 1);
        }
    }

    private sealed class RecordingTokenProvider : IAgent365ProvisioningTokenProvider
    {
        private readonly string _token;

        public RecordingTokenProvider(Guid? objectId = null)
        {
            _token = objectId is null ? "opaque-provisioning-token" : CreateToken(objectId.Value);
        }

        public int CallCount { get; private set; }

        public ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken)
        {
            CallCount++;
            return ValueTask.FromResult(new AccessToken(
                _token,
                DateTimeOffset.UtcNow.AddMinutes(10)));
        }

        private static string CreateToken(Guid objectId)
        {
            static string Encode(byte[] bytes) => Convert.ToBase64String(bytes)
                .TrimEnd('=')
                .Replace('+', '-')
                .Replace('/', '_');

            var header = Encode(Encoding.UTF8.GetBytes("{\"alg\":\"none\"}"));
            var payload = Encode(JsonSerializer.SerializeToUtf8Bytes(new
            {
                oid = objectId.ToString("D")
            }));
            return $"{header}.{payload}.";
        }
    }

    private sealed class RecordingObservabilityTokenProvider(
        AccessToken? token = null,
        Exception? exception = null) : IAgent365ObservabilityTokenProvider
    {
        public int CallCount { get; private set; }

        public ValueTask<AccessToken> GetTokenAsync(
            string agentIdentityClientId,
            string blueprintClientId,
            string expectedTenantId,
            CancellationToken cancellationToken)
        {
            CallCount++;
            agentIdentityClientId.Should().Be(AgentIdentityObjectId.ToString("D"));
            blueprintClientId.Should().Be(BlueprintClientId.ToString("D"));
            expectedTenantId.Should().Be(TenantId.ToString("D"));
            if (exception is not null)
                return ValueTask.FromException<AccessToken>(exception);

            return ValueTask.FromResult(token ?? new AccessToken(
                "validated-agent-365-observability-token",
                DateTimeOffset.UtcNow.AddMinutes(10)));
        }
    }

    private sealed class SequenceObservabilityTokenProvider(
        params object[] results) : IAgent365ObservabilityTokenProvider
    {
        private readonly Queue<object> _results = new(results);

        public int CallCount { get; private set; }

        public ValueTask<AccessToken> GetTokenAsync(
            string agentIdentityClientId,
            string blueprintClientId,
            string expectedTenantId,
            CancellationToken cancellationToken)
        {
            CallCount++;
            agentIdentityClientId.Should().Be(AgentIdentityObjectId.ToString("D"));
            blueprintClientId.Should().Be(BlueprintClientId.ToString("D"));
            expectedTenantId.Should().Be(TenantId.ToString("D"));
            _results.Should().NotBeEmpty();

            return _results.Dequeue() switch
            {
                AccessToken token => ValueTask.FromResult(token),
                Exception exception => ValueTask.FromException<AccessToken>(exception),
                _ => throw new InvalidOperationException("Unexpected token-provider test result.")
            };
        }
    }

    private sealed class RecordingCredentialStore : IProvisioningCredentialStore
    {
        public int FindCallCount { get; private set; }
        public int StoreCallCount { get; private set; }
        public string? CapturedSecretText { get; private set; }
        public StoredPasswordCredential? ExistingResult { get; init; }
        public StoredPasswordCredential StoredResult { get; init; } = new(
            PasswordCredentialKeyId.ToString("D"),
            "https://unit-test-vault.vault.azure.net/secrets/agent-credential/version",
            CredentialExpiry);

        public Task<StoredPasswordCredential?> FindAsync(
            Guid agentRegistrationId,
            string applicationObjectId,
            CancellationToken cancellationToken)
        {
            FindCallCount++;
            return Task.FromResult(ExistingResult);
        }

        public Task<StoredPasswordCredential> StoreAsync(
            Guid agentRegistrationId,
            string applicationObjectId,
            string passwordCredentialKeyId,
            string secretText,
            DateTimeOffset expiresAtUtc,
            CancellationToken cancellationToken)
        {
            StoreCallCount++;
            CapturedSecretText = secretText;
            return Task.FromResult(StoredResult);
        }
    }

    private sealed class RecordingLogger<T> : ILogger<T>
    {
        public List<string> Messages { get; } = [];

        public IDisposable BeginScope<TState>(TState state) where TState : notnull =>
            NoopScope.Instance;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            Messages.Add(formatter(state, exception));
        }
    }

    private sealed class NoopScope : IDisposable
    {
        public static NoopScope Instance { get; } = new();

        public void Dispose()
        {
        }
    }
}
