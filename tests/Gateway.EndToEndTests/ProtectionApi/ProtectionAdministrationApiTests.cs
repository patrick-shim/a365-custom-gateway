using System.Net;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Text.Json;
using Gateway.Application.Protection;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Messages;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.EndToEndTests.Fixtures;
using Gateway.Infrastructure.Persistence;
using FluentAssertions;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.EndToEndTests.ProtectionApi;

[Collection(EndToEndTestCollection.Name)]
public sealed class ProtectionAdministrationApiTests : IDisposable
{
    private readonly GatewayWebApplicationFactory _factory;
    private readonly HttpClient _client;
    private readonly Guid _tenantId = Guid.NewGuid();

    public ProtectionAdministrationApiTests(
        GatewayWebApplicationFactory factory)
    {
        _factory = factory;
        _client = factory.CreateAuthenticatedClient();
        SetDelegatedAdministrator();
    }

    public void Dispose()
    {
        using var scope = _factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        db.ProtectionCapabilities.RemoveRange(
            db.ProtectionCapabilities.Where(
                item => item.Kind == ProtectionCapabilityKind.Purview));
        db.ProtectionAdminOperations.RemoveRange(
            db.ProtectionAdminOperations.Where(
                item => item.TenantId == new EntraTenantId(_tenantId)));
        db.PurviewKnowYourDataConfigurations.RemoveRange(
            db.PurviewKnowYourDataConfigurations.Where(configuration =>
                db.PurviewTenantConnections.Any(connection =>
                    connection.Id ==
                        configuration.PurviewTenantConnectionId &&
                    connection.TenantId ==
                        new EntraTenantId(_tenantId))));
        db.PurviewDlpProfiles.RemoveRange(
            db.PurviewDlpProfiles.Where(profile =>
                db.PurviewTenantConnections.Any(connection =>
                    connection.Id == profile.PurviewTenantConnectionId &&
                    connection.TenantId ==
                        new EntraTenantId(_tenantId))));
        db.PurviewSensitiveInformationTypeSnapshotGenerations.RemoveRange(
            db.PurviewSensitiveInformationTypeSnapshotGenerations.Where(
                item => item.TenantId == new EntraTenantId(_tenantId)));
        db.PurviewTenantConnections.RemoveRange(
            db.PurviewTenantConnections.Where(
                item => item.TenantId == new EntraTenantId(_tenantId)));
        db.SaveChanges();
        _client.Dispose();
        TestAuthHandler.Reset();
    }

    [Fact]
    public async Task CompanionSubmission_RemainsPendingUntilIndependentWorkerVerification()
    {
        await SeedPurviewCapabilityAsync();

        var reviewResponse = await SendReviewAsync(
            "/api/v1/protection/purview/connection-operations:review",
            new ReviewPurviewTenantConnectionRequest(_tenantId, "*"),
            "*");
        reviewResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        reviewResponse.Headers.CacheControl!.NoStore.Should().BeTrue();
        var review = await reviewResponse.Content
            .ReadFromJsonAsync<ProtectionOperationReviewResponse>();
        review.Should().NotBeNull();

        var confirmation = await ConfirmAsync(review!);
        var startKey = Guid.NewGuid();
        var startRequest = new StartPurviewTenantConnectionOperationRequest(
            _tenantId,
            confirmation.ConfirmationTokenId,
            confirmation.ConfirmationToken,
            startKey,
            "*");
        var startResponse = await SendMutationAsync(
            "/api/v1/protection/purview/connection-operations",
            startRequest,
            startKey,
            "*");
        startResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        var accepted = await startResponse.Content
            .ReadFromJsonAsync<ProtectionOperationAcceptedResponse>();
        accepted!.Status.Should().Be("AwaitingAdministrator");
        accepted.CompanionLaunch.Should().NotBeNull();
        var launch = accepted.CompanionLaunch!;
        launch.OperationId.Should().Be(accepted.OperationId);
        launch.InventoryGenerationId.Should().NotBeEmpty();
        launch.ExpiresAtUtc.Offset.Should().Be(TimeSpan.Zero);
        launch.ScriptRelativePath.Should().Be(
            "Automation/Connect-PurviewTenant.ps1");
        launch.Arguments.Should().ContainInOrder(
            "-OperationId",
            accepted.OperationId.ToString("D"),
            "-InventoryGenerationId",
            launch.InventoryGenerationId.ToString("D"));
        var awaitingResponse = await _client.GetAsync(
            $"/api/v1/protection/operations/{accepted.OperationId:D}");
        var awaiting = await awaitingResponse.Content
            .ReadFromJsonAsync<ProtectionAdminOperationResponse>();
        awaiting!.Operation.RequiredAction.Should().Be(
            ProtectionRequiredActionCodes.CompletePurviewTenantConnection);

        var connectionResponse = await _client.GetAsync(
            "/api/v1/protection/purview/connection");
        connectionResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var connection = await connectionResponse.Content
            .ReadFromJsonAsync<PurviewTenantConnectionResponse>();
        connection!.Connection!.Status.Should().Be("AwaitingAdministrator");

        var observedAtUtc = DateTimeOffset.UtcNow;
        var sitId = Guid.NewGuid();
        var evidence = new PurviewTenantConnectionEvidenceDto(
            _tenantId,
            Guid.Parse(TestAuthHandler.DefaultObjectId),
            [
                "DlpPolicy.ReadWrite",
                "DlpRule.ReadWrite",
                "KnowYourData.ReadWrite",
                "SensitiveInformationTypes.Read"
            ],
            observedAtUtc,
            launch.ExpiresAtUtc,
            [
                new PurviewSensitiveInformationTypeDto(
                    sitId,
                    "Synthetic customer identifier",
                    "Microsoft")
            ]);
        var evidenceDigest =
            PurviewTenantConnectionEvidenceDigest.Compute(
                accepted.OperationId,
                launch.InventoryGenerationId,
                evidence);
        var completionReviewResponse = await SendReviewAsync(
            $"/api/v1/protection/purview/connection-operations/{accepted.OperationId:D}:review-completion",
            new ReviewPurviewTenantConnectionCompletionRequest(
                accepted.OperationId,
                launch.InventoryGenerationId,
                evidenceDigest,
                connection.Connection.RowVersion,
                evidence),
            connection.Connection.RowVersion);
        var completionReview = await completionReviewResponse.Content
            .ReadFromJsonAsync<ProtectionOperationReviewResponse>();
        completionReview!.Review.OperationType.Should().Be(
            "CompletePurviewTenantConnection");
        completionReview.Review.SourceOperationId.Should().Be(
            accepted.OperationId);
        completionReview.Review.EvidenceDigest.Should().Be(
            evidenceDigest);
        var completionConfirmation = await ConfirmAsync(completionReview);
        var completeKey = Guid.NewGuid();
        var completeRequest =
            new CompletePurviewTenantConnectionOperationRequest(
                completionConfirmation.ConfirmationTokenId,
                completionConfirmation.ConfirmationToken,
                completeKey,
                connection.Connection.RowVersion,
                launch.InventoryGenerationId,
                evidenceDigest,
                evidence);
        var completeResponse = await SendMutationAsync(
            $"/api/v1/protection/purview/connection-operations/{accepted.OperationId:D}:complete",
            completeRequest,
            completeKey,
            connection.Connection.RowVersion);
        completeResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        var submitted = await completeResponse.Content
            .ReadFromJsonAsync<ProtectionOperationAcceptedResponse>();
        submitted!.Status.Should().Be("Pending");
        var exactReplay = await SendMutationAsync(
            $"/api/v1/protection/purview/connection-operations/{accepted.OperationId:D}:complete",
            completeRequest,
            completeKey,
            connection.Connection.RowVersion);
        exactReplay.StatusCode.Should().Be(HttpStatusCode.Accepted);
        var changedEvidencePayload = completeRequest.Evidence with
        {
            SensitiveInformationTypes =
            [
                completeRequest.Evidence.SensitiveInformationTypes[0]
                with
                {
                    ExactName = "Different synthetic identifier"
                }
            ]
        };
        var changedEvidence = completeRequest with
        {
            Evidence = changedEvidencePayload,
            EvidenceDigest =
                PurviewTenantConnectionEvidenceDigest.Compute(
                    accepted.OperationId,
                    launch.InventoryGenerationId,
                    changedEvidencePayload)
        };
        var changedReplay = await SendMutationAsync(
            $"/api/v1/protection/purview/connection-operations/{accepted.OperationId:D}:complete",
            changedEvidence,
            completeKey,
            connection.Connection.RowVersion);
        changedReplay.StatusCode.Should().Be(HttpStatusCode.Conflict);
        var malformedEvidence = completeRequest with
        {
            Evidence = completeRequest.Evidence with
            {
                SensitiveInformationTypes = []
            }
        };
        var malformedReplay = await SendMutationAsync(
            $"/api/v1/protection/purview/connection-operations/{accepted.OperationId:D}:complete",
            malformedEvidence,
            completeKey,
            connection.Connection.RowVersion);
        malformedReplay.StatusCode.Should().Be(HttpStatusCode.BadRequest);

        var inventoryResponse = await _client.GetAsync(
            "/api/v1/protection/purview/sensitive-information-types");
        inventoryResponse.StatusCode.Should().Be(HttpStatusCode.Conflict);

        var operationResponse = await _client.GetAsync(
            $"/api/v1/protection/operations/{accepted.OperationId:D}");
        operationResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var operation = await operationResponse.Content
            .ReadFromJsonAsync<ProtectionAdminOperationResponse>();
        operation!.Operation.Status.Should().Be("Pending");
        operation.Operation.Steps.Should().HaveCount(8);
        operation.Operation.Steps[1].Status.Should().Be("Pending");

        using var scope = _factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        var storedConnection = db.PurviewTenantConnections.Single(
            item => item.TenantId == new EntraTenantId(_tenantId));
        storedConnection.Status.Should().Be(
            PurviewTenantConnectionStatus.PendingVerification);
        storedConnection.ActiveInventoryGenerationId.Should().BeNull();
        storedConnection.AuthorizedAtUtc.Should().BeNull();
        operation.Operation.TargetIdentifier.Should().Be(
            storedConnection.Id.ToString("D"));
        db.ProtectionAdminOperations
            .Where(item =>
                item.TenantId == new EntraTenantId(_tenantId) &&
                item.Type ==
                    ProtectionAdminOperationType.ConnectPurviewTenant)
            .Should().NotContain(item =>
                item.Status ==
                    ProtectionAdminOperationStatus.Completed);
        var submission = db.ProtectionAdminOperations.Single(item =>
            item.TenantId == new EntraTenantId(_tenantId) &&
            item.IdempotencyKey ==
                new ProtectionIdempotencyKey(completeKey));
        submission.AcceptedRequestHash.Should().StartWith("sha256:");
        submission.AcceptedRequestHash.Should().NotContain(
            completionConfirmation.ConfirmationToken);
        submission.ResultJson.Should().NotContain(
            completionConfirmation.ConfirmationToken);
        var outbox = db.OutboxMessages.Should().ContainSingle(message =>
            message.MessageType == "ProtectionAdminOperationMessage" &&
            message.Payload.Contains(
                accepted.OperationId.ToString("D"),
                StringComparison.OrdinalIgnoreCase)).Subject;
        var queued = JsonSerializer.Deserialize<ProtectionAdminOperationMessage>(
            outbox.Payload);
        queued!.OperationId.Should().Be(accepted.OperationId);
        queued.ExpectedStepIndex.Should().Be(1);
    }

    [Fact]
    public async Task KnowYourDataMutation_EnqueuesV1OnceAndKeepsFixedGroupSeparate()
    {
        var seeded = await SeedConnectedTenantAsync();
        var initialOutboxCount = CountProtectionOutbox();
        var reviewRequest = new ReviewPurviewKnowYourDataOperationRequest(
            seeded.ConnectionId,
            new PurviewSensitiveInformationTypeSelectionDto(
                seeded.GenerationId,
                seeded.SensitiveInformationTypeId,
                seeded.SensitiveInformationTypeName),
            "Enforce",
            ["UploadText"],
            IngestionEnabled: true,
            ExpectedRowVersion: "*");
        var reviewResponse = await SendReviewAsync(
            "/api/v1/protection/purview/know-your-data-operations:review",
            reviewRequest,
            "*");
        var review = await reviewResponse.Content
            .ReadFromJsonAsync<ProtectionOperationReviewResponse>();
        var confirmation = await ConfirmAsync(review!);
        var idempotencyKey = Guid.NewGuid();
        var mutation = new StartPurviewKnowYourDataOperationRequest(
            confirmation.ConfirmationTokenId,
            confirmation.ConfirmationToken,
            idempotencyKey,
            "*");

        var first = await SendMutationAsync(
            "/api/v1/protection/purview/know-your-data-operations",
            mutation,
            idempotencyKey,
            "*");
        var replay = await SendMutationAsync(
            "/api/v1/protection/purview/know-your-data-operations",
            mutation,
            idempotencyKey,
            "*");
        first.StatusCode.Should().Be(HttpStatusCode.Accepted);
        replay.StatusCode.Should().Be(HttpStatusCode.Accepted);

        using var scope = _factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        var configuration = db.PurviewKnowYourDataConfigurations.Single(
            item => item.PurviewTenantConnectionId == seeded.ConnectionId);
        configuration.GroupId.Should().Be(
            PurviewPolicyLocationContract.EnterpriseAiAppsGroupId);
        configuration.ScopeType.Should().Be(PurviewPolicyScopeType.Group);
        configuration.EnforcementPlane.Should().Be(
            PurviewEnforcementPlane.Application);
        db.OutboxMessages.Count(message =>
                message.MessageType == "ProtectionAdminOperationMessage")
            .Should().Be(initialOutboxCount + 1);
        db.AuditEvents.Should().Contain(item =>
            item.EventType == "PurviewKnowYourDataOperationAccepted");
    }

    [Fact]
    public async Task DlpProfile_AllStatesAndReconcileUseReviewedIndividualScope()
    {
        var seeded = await SeedConnectedTenantAsync();
        var initialOutboxCount = CountProtectionOutbox();
        var blueprintApplicationId = Guid.Parse(
            TestRequestData.ValidBlueprint.BlueprintObjectId!);
        var createReviewRequest =
            new ReviewPurviewDlpProfileOperationRequest(
                ProfileId: null,
                seeded.ConnectionId,
                blueprintApplicationId,
                "Synthetic blueprint DLP",
                new PurviewSensitiveInformationTypeSelectionDto(
                    seeded.GenerationId,
                    seeded.SensitiveInformationTypeId,
                    seeded.SensitiveInformationTypeName),
                "Enforce",
                ["UploadText"],
                [new PurviewDlpRuleActionDto("UploadText", "Block")],
                ExpectedRowVersion: "*");
        var createReviewResponse = await SendReviewAsync(
            "/api/v1/protection/purview/dlp-profile-operations:review",
            createReviewRequest,
            "*");
        createReviewResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var createReview = await createReviewResponse.Content
            .ReadFromJsonAsync<ProtectionOperationReviewResponse>();
        createReview!.Review.ScopeType.Should().Be("Individual");
        createReview.Review.BlueprintApplicationId.Should().Be(
            blueprintApplicationId);
        var createConfirmation = await ConfirmAsync(createReview);
        var createKey = Guid.NewGuid();
        var createResponse = await SendMutationAsync(
            "/api/v1/protection/purview/dlp-profile-operations",
            new StartPurviewDlpProfileOperationRequest(
                createConfirmation.ConfirmationTokenId,
                createConfirmation.ConfirmationToken,
                createKey,
                "*"),
            createKey,
            "*");
        createResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);

        var listResponse = await _client.GetAsync(
            "/api/v1/protection/purview/dlp-profiles");
        listResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var profiles = await listResponse.Content
            .ReadFromJsonAsync<PurviewDlpProfileListResponse>();
        var profile = profiles!.Items.Should().ContainSingle().Subject;
        profile.Status.Should().Be("Pending");
        profile.Readiness.IsReady.Should().BeFalse();

        var reconcileReviewResponse = await SendReviewAsync(
            $"/api/v1/protection/purview/dlp-profiles/{profile.Id:D}:review-reconcile",
            new ReviewReconcilePurviewDlpProfileRequest(
                profile.Id,
                profile.RowVersion),
            profile.RowVersion);
        var reconcileReview = await reconcileReviewResponse.Content
            .ReadFromJsonAsync<ProtectionOperationReviewResponse>();
        reconcileReview!.Review.OperationType.Should().Be(
            "ReconcileDlpProfile");
        var reconcileConfirmation = await ConfirmAsync(reconcileReview);
        var reconcileKey = Guid.NewGuid();
        var reconcileResponse = await SendMutationAsync(
            $"/api/v1/protection/purview/dlp-profiles/{profile.Id:D}:reconcile",
            new ReconcilePurviewDlpProfileRequest(
                reconcileConfirmation.ConfirmationTokenId,
                reconcileConfirmation.ConfirmationToken,
                reconcileKey,
                profile.RowVersion),
            reconcileKey,
            profile.RowVersion);
        reconcileResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        var runtimeReviewResponse = await SendReviewAsync(
            $"/api/v1/protection/purview/dlp-profiles/{profile.Id:D}:review-runtime-validation",
            new ReviewValidatePurviewDlpRuntimeRequest(
                profile.Id,
                profile.RowVersion),
            profile.RowVersion);
        var runtimeReview = await runtimeReviewResponse.Content
            .ReadFromJsonAsync<ProtectionOperationReviewResponse>();
        runtimeReview!.Review.OperationType.Should().Be(
            "ValidateDlpRuntime");

        using var scope = _factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        var stored = db.PurviewDlpProfiles.Single(
            item => item.Id == new PurviewDlpProfileId(profile.Id));
        stored.BlueprintApplicationId.Value.Should().Be(
            blueprintApplicationId);
        stored.ScopeType.Should().Be(PurviewPolicyScopeType.Individual);
        stored.EnforcementPlane.Should().Be(
            PurviewEnforcementPlane.Application);
        db.OutboxMessages.Count(message =>
                message.MessageType == "ProtectionAdminOperationMessage")
            .Should().Be(initialOutboxCount + 2);
    }

    [Fact]
    public async Task MutationHeadersAndDelegatedClaimsFailClosedWithProblemDetails()
    {
        await SeedPurviewCapabilityAsync();
        var reviewResponse = await SendReviewAsync(
            "/api/v1/protection/purview/connection-operations:review",
            new ReviewPurviewTenantConnectionRequest(_tenantId, "*"),
            "*");
        var review = await reviewResponse.Content
            .ReadFromJsonAsync<ProtectionOperationReviewResponse>();
        var confirmation = await ConfirmAsync(review!);
        var key = Guid.NewGuid();
        var request = new StartPurviewTenantConnectionOperationRequest(
            _tenantId,
            confirmation.ConfirmationTokenId,
            confirmation.ConfirmationToken,
            key,
            "*");
        var missingHeaders = await _client.PostAsJsonAsync(
            "/api/v1/protection/purview/connection-operations",
            request);
        missingHeaders.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        missingHeaders.Content.Headers.ContentType!.MediaType.Should().Be(
            "application/problem+json");

        TestAuthHandler.DefaultRole = "Gateway.Operator";
        var operatorMutation = await SendReviewAsync(
            "/api/v1/protection/purview/connection-operations:review",
            new ReviewPurviewTenantConnectionRequest(_tenantId, "*"),
            "*");
        operatorMutation.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        operatorMutation.Content.Headers.ContentType!.MediaType.Should().Be(
            "application/problem+json");

        TestAuthHandler.DefaultRole = "Gateway.Administrator";
        TestAuthHandler.Claims =
        [
            new Claim("tid", _tenantId.ToString("D")),
            new Claim("scp", "access_as_user"),
            new Claim("idtyp", "app")
        ];
        var appOnly = await _client.GetAsync(
            "/api/v1/protection/capabilities");
        appOnly.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        appOnly.Content.Headers.ContentType!.MediaType.Should().Be(
            "application/problem+json");
    }

    [Fact]
    public async Task OpenApiContainsEveryTypedAdminClientProtectionRoute()
    {
        var response = await _client.GetAsync("/openapi/v1.json");
        response.StatusCode.Should().Be(HttpStatusCode.OK);
        using var document = JsonDocument.Parse(
            await response.Content.ReadAsStringAsync());
        var paths = document.RootElement.GetProperty("paths");
        string[] expectedPaths =
        [
            "/api/v1/protection/capabilities",
            "/api/v1/protection/purview/connection",
            "/api/v1/protection/purview/connection-operations:review",
            "/api/v1/protection/operation-reviews:confirm",
            "/api/v1/protection/purview/connection-operations",
            "/api/v1/protection/purview/connection-operations/{operationId}:review-completion",
            "/api/v1/protection/purview/connection-operations/{operationId}:complete",
            "/api/v1/protection/purview/sensitive-information-types",
            "/api/v1/protection/purview/know-your-data",
            "/api/v1/protection/purview/know-your-data-operations:review",
            "/api/v1/protection/purview/know-your-data-operations",
            "/api/v1/protection/purview/dlp-profiles",
            "/api/v1/protection/purview/dlp-profile-operations:review",
            "/api/v1/protection/purview/dlp-profile-operations",
            "/api/v1/protection/purview/dlp-profiles/{profileId}:reconcile",
            "/api/v1/protection/purview/dlp-profiles/{profileId}:review-reconcile",
            "/api/v1/protection/purview/dlp-profiles/{profileId}:validate-runtime",
            "/api/v1/protection/purview/dlp-profiles/{profileId}:review-runtime-validation",
            "/api/v1/protection/operations/{operationId}"
        ];

        foreach (var path in expectedPaths)
            paths.TryGetProperty(path, out _).Should().BeTrue(path);
    }

    [Fact]
    public async Task ProtectionDefaultsAndFeaturesRejectAppOnlyOrMissingDelegatedBinding()
    {
        TestAuthHandler.Claims = [];
        var key = Guid.NewGuid();
        var systemRequest = CreateSystemUpdate(
            defaultPurviewMode: "Enforce",
            key,
            "*");
        var systemResponse = await SendPatchMutationAsync(
            "/api/v1/system/config",
            systemRequest,
            key,
            "*");
        systemResponse.StatusCode.Should().Be(HttpStatusCode.Forbidden);

        var featureRequest = new UpdateFeaturesRequest(
            ObservabilityMode: null,
            PurviewEnabled: true,
            PurviewMode: "Enforce",
            IdempotencyKey: key,
            ExpectedRowVersion: "*");
        var featureResponse = await SendPatchMutationAsync(
            $"/api/v1/agents/{Guid.NewGuid():D}/features",
            featureRequest,
            key,
            "*");
        featureResponse.StatusCode.Should().Be(HttpStatusCode.Forbidden);

        TestAuthHandler.Claims =
        [
            new Claim("tid", _tenantId.ToString("D")),
            new Claim("scp", "access_as_user"),
            new Claim("idtyp", "app")
        ];
        var appOnlyResponse = await SendPatchMutationAsync(
            "/api/v1/system/config",
            systemRequest,
            key,
            "*");
        appOnlyResponse.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task EveryRegistrationRequiresDelegatedActor()
    {
        TestAuthHandler.Claims = [];
        TestAuthHandler.DefaultRole = "Gateway.Administrator";
        var protectedRequest = new RegisterAgentRequest(
            $"protected-register-{Guid.NewGuid():N}",
            "Protected registration",
            null,
            TestAuthHandler.DefaultObjectId,
            "Development",
            new AgentFeaturesDto(
                ObservabilityMode: "Agent365",
                PurviewEnabled: false,
                PurviewMode: null,
                PromptShieldEnabled: true),
            TestRequestData.ValidBlueprint);

        var protectedResponse = await _client.PostAsJsonAsync(
            "/api/v1/agents",
            protectedRequest);
        protectedResponse.StatusCode.Should().Be(HttpStatusCode.Forbidden);

        var dlpChoiceResponse = await _client.PostAsJsonAsync(
            "/api/v1/agents",
            protectedRequest with
            {
                ExternalAgentId = $"dlp-choice-{Guid.NewGuid():N}",
                Features = null,
                PurviewDlpProfile = new PurviewDlpProfileSelectionDto(
                    Guid.NewGuid(),
                    Guid.NewGuid())
            });
        dlpChoiceResponse.StatusCode.Should().Be(HttpStatusCode.Forbidden);

        TestAuthHandler.Claims =
        [
            new Claim("tid", _tenantId.ToString("D")),
            new Claim("scp", "access_as_user"),
            new Claim("idtyp", "app")
        ];
        var appOnlyResponse = await _client.PostAsJsonAsync(
            "/api/v1/agents",
            protectedRequest with
            {
                ExternalAgentId = $"app-only-{Guid.NewGuid():N}"
            });
        appOnlyResponse.StatusCode.Should().Be(HttpStatusCode.Forbidden);

        TestAuthHandler.Claims = [];
        var unprotectedResponse = await _client.PostAsJsonAsync(
            "/api/v1/agents",
            protectedRequest with
            {
                ExternalAgentId =
                    $"unprotected-register-{Guid.NewGuid():N}",
                Features = new AgentFeaturesDto(
                    ObservabilityMode: "Agent365",
                    PurviewEnabled: false,
                    PurviewMode: null,
                    PromptShieldEnabled: false),
                PurviewDlpProfile = null
            });
        unprotectedResponse.StatusCode.Should().Be(
            HttpStatusCode.Forbidden);

        SetDelegatedAdministrator();
        var delegatedResponse = await _client.PostAsJsonAsync(
            "/api/v1/agents",
            protectedRequest with
            {
                ExternalAgentId =
                    $"delegated-register-{Guid.NewGuid():N}",
                Features = new AgentFeaturesDto(
                    ObservabilityMode: "Agent365",
                    PurviewEnabled: false,
                    PurviewMode: null,
                    PromptShieldEnabled: false),
                PurviewDlpProfile = null
            });
        delegatedResponse.StatusCode.Should().Be(
            HttpStatusCode.Accepted);
    }

    [Fact]
    public async Task SystemProtectionDefaultsPersistExactIdempotencyResultUnderTenantLock()
    {
        await SeedSystemConfigurationAsync();
        var getResponse = await _client.GetAsync("/api/v1/system/config");
        getResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var current = await getResponse.Content
            .ReadFromJsonAsync<SystemConfigDto>();
        var key = Guid.NewGuid();
        var request = CreateSystemUpdate(
            defaultPurviewMode: "AuditOnly",
            key,
            current!.RowVersion!);

        var first = await SendPatchMutationAsync(
            "/api/v1/system/config",
            request,
            key,
            current.RowVersion!);
        var replay = await SendPatchMutationAsync(
            "/api/v1/system/config",
            request,
            key,
            current.RowVersion!);
        first.StatusCode.Should().Be(HttpStatusCode.OK);
        replay.StatusCode.Should().Be(HttpStatusCode.OK);
        (await first.Content.ReadFromJsonAsync<SystemConfigDto>())
            .Should().BeEquivalentTo(
                await replay.Content.ReadFromJsonAsync<SystemConfigDto>());

        var changed = request with { DefaultPurviewMode = "Enforce" };
        var conflict = await SendPatchMutationAsync(
            "/api/v1/system/config",
            changed,
            key,
            current.RowVersion!);
        conflict.StatusCode.Should().Be(HttpStatusCode.Conflict);

        using var scope = _factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        db.ProtectionAdminOperations.Should().ContainSingle(operation =>
            operation.TenantId == new EntraTenantId(_tenantId) &&
            operation.IdempotencyKey ==
                new ProtectionIdempotencyKey(key) &&
            operation.Type ==
                ProtectionAdminOperationType.UpdateProtectionDefaults &&
            operation.AcceptedRequestHash != null &&
            operation.ResultJson != null);
    }

    private async Task SeedPurviewCapabilityAsync()
    {
        using var scope = _factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        db.ProtectionCapabilities.RemoveRange(
            db.ProtectionCapabilities.Where(
                item => item.Kind == ProtectionCapabilityKind.Purview));
        db.ProtectionCapabilities.Add(new ProtectionCapability
        {
            Id = Guid.NewGuid(),
            Kind = ProtectionCapabilityKind.Purview,
            Status = ProtectionCapabilityStatus.Installed,
            ResourceIdentifiers =
                new ProtectionCapabilityResourceIdentifiers(),
            LastReadbackAtUtc = DateTime.UtcNow,
            CreatedAtUtc = DateTime.UtcNow,
            UpdatedAtUtc = DateTime.UtcNow
        });
        await db.SaveChangesAsync();
    }

    private async Task<SeededTenant> SeedConnectedTenantAsync()
    {
        await SeedPurviewCapabilityAsync();
        using var scope = _factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        var connectionId = Guid.NewGuid();
        var generationId = Guid.NewGuid();
        var sitId = Guid.NewGuid();
        var now = DateTime.UtcNow;
        db.PurviewTenantConnections.Add(new PurviewTenantConnection
        {
            Id = connectionId,
            TenantId = new EntraTenantId(_tenantId),
            Status = PurviewTenantConnectionStatus.Connected,
            AuthorityKind = "InteractiveDelegatedAdministrator",
            ActiveInventoryGenerationId =
                new SensitiveInformationTypeSnapshotGenerationId(generationId),
            AuthorizedAtUtc = now,
            LastVerifiedAtUtc = now,
            ExpiresAtUtc = now.AddHours(1),
            CreatedByObjectId = TestAuthHandler.DefaultObjectId,
            CreatedAtUtc = now,
            UpdatedAtUtc = now
        });
        var generation =
            new PurviewSensitiveInformationTypeSnapshotGeneration
            {
                Id =
                    new SensitiveInformationTypeSnapshotGenerationId(
                        generationId),
                PurviewTenantConnectionId = connectionId,
                TenantId = new EntraTenantId(_tenantId),
                RetrievedAtUtc = now,
                ExpiresAtUtc = now.AddHours(1),
                ItemCount = 1,
                CreatedAtUtc = now
            };
        generation.Items.Add(new PurviewSensitiveInformationTypeSnapshot
        {
            Id = Guid.NewGuid(),
            GenerationId =
                new SensitiveInformationTypeSnapshotGenerationId(
                    generationId),
            SensitiveInformationTypeId =
                new SensitiveInformationTypeId(sitId),
            ExactName = "Synthetic customer identifier",
            Publisher = "Microsoft",
            SortOrder = 0
        });
        db.PurviewSensitiveInformationTypeSnapshotGenerations.Add(
            generation);
        await db.SaveChangesAsync();
        return new SeededTenant(
            connectionId,
            generationId,
            sitId,
            "Synthetic customer identifier");
    }

    private async Task SeedSystemConfigurationAsync()
    {
        using var scope = _factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        db.SystemConfigurations.RemoveRange(db.SystemConfigurations);
        db.SystemConfigurations.Add(new SystemConfiguration
        {
            Id = Guid.NewGuid(),
            ProvisioningMode = "Automatic",
            DefaultObservabilityMode = "Agent365",
            DefaultPurviewEnabled = false,
            RetentionDaysActivityReceipts = 30,
            RetentionDaysAuditEvents = 30,
            RetentionDaysIdempotencyRecords = 30,
            RetentionDaysOutboxMessages = 30,
            RateLimitPerClient = 100,
            RateLimitPerAgent = 100,
            RateLimitGlobal = 1000,
            UpdatedAtUtc = DateTime.UtcNow
        });
        await db.SaveChangesAsync();
    }

    private async Task<HttpResponseMessage> SendReviewAsync<T>(
        string path,
        T body,
        string expectedRowVersion)
    {
        var message = new HttpRequestMessage(HttpMethod.Post, path)
        {
            Content = JsonContent.Create(body)
        };
        message.Headers.TryAddWithoutValidation(
            "If-Match",
            expectedRowVersion);
        return await _client.SendAsync(message);
    }

    private async Task<ProtectionOperationConfirmationResponse> ConfirmAsync(
        ProtectionOperationReviewResponse review)
    {
        var response = await _client.PostAsJsonAsync(
            "/api/v1/protection/operation-reviews:confirm",
            new ConfirmProtectionOperationReviewRequest(
                review.ReviewTokenId,
                review.ReviewToken));
        response.StatusCode.Should().Be(HttpStatusCode.OK);
        response.Headers.CacheControl!.NoStore.Should().BeTrue();
        return (await response.Content
            .ReadFromJsonAsync<ProtectionOperationConfirmationResponse>())!;
    }

    private async Task<HttpResponseMessage> SendMutationAsync<T>(
        string path,
        T body,
        Guid idempotencyKey,
        string expectedRowVersion)
    {
        var message = new HttpRequestMessage(HttpMethod.Post, path)
        {
            Content = JsonContent.Create(body)
        };
        message.Headers.TryAddWithoutValidation(
            "Idempotency-Key",
            idempotencyKey.ToString("D"));
        message.Headers.TryAddWithoutValidation(
            "If-Match",
            expectedRowVersion);
        return await _client.SendAsync(message);
    }

    private async Task<HttpResponseMessage> SendPatchMutationAsync<T>(
        string path,
        T body,
        Guid idempotencyKey,
        string expectedRowVersion)
    {
        var message = new HttpRequestMessage(HttpMethod.Patch, path)
        {
            Content = JsonContent.Create(body)
        };
        message.Headers.TryAddWithoutValidation(
            "Idempotency-Key",
            idempotencyKey.ToString("D"));
        message.Headers.TryAddWithoutValidation(
            "If-Match",
            expectedRowVersion);
        return await _client.SendAsync(message);
    }

    private static UpdateSystemConfigRequest CreateSystemUpdate(
        string defaultPurviewMode,
        Guid idempotencyKey,
        string expectedRowVersion) =>
        new(
            ProvisioningMode: null,
            DefaultObservabilityMode: null,
            DefaultPurviewEnabled: null,
            DefaultPurviewMode: defaultPurviewMode,
            RetentionDaysActivityReceipts: null,
            RetentionDaysAuditEvents: null,
            RetentionDaysIdempotencyRecords: null,
            RetentionDaysOutboxMessages: null,
            RateLimitPerClient: null,
            RateLimitPerAgent: null,
            RateLimitGlobal: null,
            ReconciliationEnabled: null,
            ReconciliationIntervalHours: null,
            StuckTransitionTimeoutDays: null,
            UseGraphAgentRegistration: null,
            UseCliProvisioningFallback: null,
            IdempotencyKey: idempotencyKey,
            ExpectedRowVersion: expectedRowVersion);

    private void SetDelegatedAdministrator()
    {
        TestAuthHandler.DefaultRole = "Gateway.Administrator";
        TestAuthHandler.Claims =
        [
            new Claim("tid", _tenantId.ToString("D")),
            new Claim("scp", "profile access_as_user")
        ];
    }

    private int CountProtectionOutbox()
    {
        using var scope = _factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        return db.OutboxMessages.Count(message =>
            message.MessageType == "ProtectionAdminOperationMessage");
    }

    private sealed record SeededTenant(
        Guid ConnectionId,
        Guid GenerationId,
        Guid SensitiveInformationTypeId,
        string SensitiveInformationTypeName);
}
