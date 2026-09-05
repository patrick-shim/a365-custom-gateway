using System.Net;
using FluentAssertions;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Infrastructure;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;

namespace Gateway.AdminUi.Tests.Services;

public sealed class ProtectionGatewayApiClientTests
{
    private readonly IGatewayAccessTokenProvider _tokenProvider =
        Substitute.For<IGatewayAccessTokenProvider>();

    [Fact]
    public async Task ProtectionReads_UseExactAuthenticatedRoutesAndPreserveResponseMetadata()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>())
            .Returns("synthetic-access-token");
        var generationId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var connectionId = Guid.NewGuid();
        var capabilityId = Guid.NewGuid();
        var knowYourDataId = Guid.NewGuid();
        var sensitiveInformationTypeId = Guid.NewGuid();
        var responses = new Queue<HttpResponseMessage>(
        [
            WithMetadata($$"""
                {
                  "items":[{
                    "id":"{{capabilityId:D}}",
                    "capability":"Purview",
                    "status":"Installed",
                    "resourceIdentifiers":{
                      "agent365RegistryApiApplicationId":null,
                      "contentSafetyAccountResourceId":null,
                      "contentSafetyEndpoint":null,
                      "gatewayApiManagedIdentityPrincipalObjectId":null,
                      "purviewRuntimeManagedIdentityPrincipalObjectId":null,
                      "purviewAutomationApplicationId":null,
                      "purviewAutomationServicePrincipalObjectId":null,
                      "keyVaultResourceId":null,
                      "certificateName":null
                    },
                    "lastReadbackAtUtc":"2026-09-05T00:00:00Z",
                    "lastFailureCode":null,
                    "rowVersion":"capability-row-version"
                  }]
                }
                """, "\"capabilities\"", "capability-correlation"),
            WithMetadata($$"""
                {
                  "connection":{
                    "id":"{{connectionId:D}}",
                    "tenantId":"{{tenantId:D}}",
                    "status":"Connected",
                    "authorityKind":"Application",
                    "authorityApplicationId":null,
                    "authorityServicePrincipalObjectId":null,
                    "activeInventoryGenerationId":"{{generationId:D}}",
                    "authorizedAtUtc":"2026-09-05T00:00:00Z",
                    "expiresAtUtc":"2026-09-05T01:00:00Z",
                    "lastVerifiedAtUtc":"2026-09-05T00:00:00Z",
                    "lastFailureCode":null,
                    "rowVersion":"connection-row-version"
                  }
                }
                """, "\"connection\"", "connection-correlation"),
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "generationId":"{{generationId:D}}",
                  "tenantId":"{{tenantId:D}}",
                  "retrievedAtUtc":"2026-09-05T00:00:00Z",
                  "expiresAtUtc":"2026-09-05T01:00:00Z",
                  "isExpired":false,
                  "items":[]
                }
                """),
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "configuration":{
                    "id":"{{knowYourDataId:D}}",
                    "tenantConnectionId":"{{connectionId:D}}",
                    "groupId":"ee1680d0-702f-4090-b26c-c49091e86531",
                    "scopeType":"Group",
                    "enforcementPlane":"Application",
                    "inventoryGenerationId":"{{generationId:D}}",
                    "sensitiveInformationTypeId":"{{sensitiveInformationTypeId:D}}",
                    "sensitiveInformationTypeName":"EU Passport Number",
                    "mode":"Enforce",
                    "activities":["uploadText"],
                    "ingestionEnabled":true,
                    "status":"Ready",
                    "readbackStatus":"Ready",
                    "collectionPolicyProviderId":null,
                    "lastReadbackAtUtc":"2026-09-05T00:00:00Z",
                    "lastFailureCode":null,
                    "rowVersion":"kyd-row-version"
                  }
                }
                """),
            RecordingHttpMessageHandler.JsonResponse("""{"items":[]}""")
        ]);
        var handler = new RecordingHttpMessageHandler(_ => responses.Dequeue());
        var client = CreateClient(handler);

        var capabilities = await client.GetProtectionCapabilitiesAsync();
        var connection = await client.GetPurviewTenantConnectionAsync();
        var inventory = await client.GetPurviewSensitiveInformationTypesAsync();
        var knowYourData = await client.GetPurviewKnowYourDataAsync();
        var profiles = await client.GetPurviewDlpProfilesAsync();

        capabilities.Value.Items.Should().ContainSingle(item =>
            item.Id == capabilityId &&
            item.Capability == "Purview" &&
            item.Status == "Installed");
        capabilities.ETag.Should().Be("\"capabilities\"");
        capabilities.CorrelationId.Should().Be("capability-correlation");
        connection.Value.Connection.Should().NotBeNull();
        connection.Value.Connection!.Id.Should().Be(connectionId);
        connection.Value.Connection.Status.Should().Be("Connected");
        connection.ETag.Should().Be("\"connection\"");
        connection.CorrelationId.Should().Be("connection-correlation");
        inventory.Value.GenerationId.Should().Be(generationId);
        inventory.Value.TenantId.Should().Be(tenantId);
        knowYourData.Value.Configuration.Should().NotBeNull();
        knowYourData.Value.Configuration!.GroupId.Should().Be(
            Guid.Parse("ee1680d0-702f-4090-b26c-c49091e86531"));
        knowYourData.Value.Configuration.ScopeType.Should().Be("Group");
        profiles.Value.Items.Should().BeEmpty();

        handler.Requests.Select(request => request.Uri.AbsolutePath).Should().Equal(
            "/api/v1/protection/capabilities",
            "/api/v1/protection/purview/connection",
            "/api/v1/protection/purview/sensitive-information-types",
            "/api/v1/protection/purview/know-your-data",
            "/api/v1/protection/purview/dlp-profiles");
        handler.Requests.Should().OnlyContain(request =>
            request.Method == HttpMethod.Get &&
            request.Header("Authorization") == "Bearer synthetic-access-token" &&
            IsGuid(request.Header("X-Correlation-ID")));
    }

    [Fact]
    public async Task KnowYourDataReviewConfirmationAndMutation_UseOneTimeInMemoryTickets()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var tenantId = Guid.NewGuid();
        var connectionId = Guid.NewGuid();
        var reviewId = Guid.NewGuid();
        var confirmationId = Guid.NewGuid();
        var operationId = Guid.NewGuid();
        var idempotencyKey = Guid.NewGuid();
        const string rowVersion = "\"kyd-row-version\"";
        const string reviewToken = "synthetic-review-token";
        const string confirmationToken = "synthetic-confirmation-token";
        var responses = new Queue<HttpResponseMessage>(
        [
            ReviewResponse(
                reviewId,
                reviewToken,
                tenantId,
                "ConfigureKnowYourData",
                "PurviewKnowYourData",
                "tenant-wide"),
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "reviewTokenId":"{{reviewId:D}}",
                  "confirmationTokenId":"{{confirmationId:D}}",
                  "confirmationToken":"{{confirmationToken}}",
                  "expiresAtUtc":"2026-09-05T01:00:00Z"
                }
                """),
            AcceptedResponse(operationId)
        ]);
        var handler = new RecordingHttpMessageHandler(_ => responses.Dequeue());
        var client = CreateClient(handler);
        var reviewRequest = new ReviewPurviewKnowYourDataOperationRequest(
            connectionId,
            new PurviewSensitiveInformationTypeSelectionDto(
                Guid.NewGuid(),
                Guid.NewGuid(),
                "EU Passport Number"),
            "Enforce",
            ["uploadText"],
            IngestionEnabled: true,
            ExpectedRowVersion: rowVersion);

        var reviewed = await client.ReviewPurviewKnowYourDataOperationAsync(reviewRequest);
        var confirmed = await client.ConfirmProtectionOperationReviewAsync(reviewed.Value);
        var accepted = await client.StartPurviewKnowYourDataOperationAsync(
            confirmed.Value,
            idempotencyKey,
            rowVersion);

        accepted.Value.OperationId.Should().Be(operationId);
        reviewed.Value.IsAvailable.Should().BeFalse();
        confirmed.Value.IsAvailable.Should().BeFalse();
        reviewed.Value.ToString().Should().NotContain(reviewToken);
        confirmed.Value.ToString().Should().NotContain(confirmationToken);

        var reviewCall = handler.Requests[0];
        reviewCall.Uri.AbsolutePath.Should().Be(
            "/api/v1/protection/purview/know-your-data-operations:review");
        reviewCall.Header("If-Match").Should().Be(rowVersion);
        reviewCall.Header("Idempotency-Key").Should().BeNull();

        var confirmationCall = handler.Requests[1];
        confirmationCall.Uri.AbsolutePath.Should().Be(
            "/api/v1/protection/operation-reviews:confirm");
        confirmationCall.Body.Should().Contain(reviewToken);
        confirmationCall.Body.Should().NotContain(confirmationToken);

        var mutationCall = handler.Requests[2];
        mutationCall.Uri.AbsolutePath.Should().Be(
            "/api/v1/protection/purview/know-your-data-operations");
        mutationCall.Header("Idempotency-Key").Should().Be(idempotencyKey.ToString("D"));
        mutationCall.Header("If-Match").Should().Be(rowVersion);
        mutationCall.Body.Should().Contain(confirmationToken);

        var secondUse = () => client.StartPurviewKnowYourDataOperationAsync(
            confirmed.Value,
            Guid.NewGuid(),
            rowVersion);
        await secondUse.Should().ThrowAsync<InvalidOperationException>();
        handler.Requests.Should().HaveCount(3);
    }

    [Fact]
    public async Task ConnectionStartAndCompletion_SendExactTenantEvidenceAndMutationHeaders()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var tenantId = Guid.NewGuid();
        var administratorId = Guid.NewGuid();
        var operationId = Guid.NewGuid();
        var reviewId = Guid.NewGuid();
        var confirmationId = Guid.NewGuid();
        var startKey = Guid.NewGuid();
        var completionKey = Guid.NewGuid();
        var generationId = Guid.NewGuid();
        var launchExpiry =
            new DateTimeOffset(2026, 9, 5, 0, 15, 0, TimeSpan.Zero);
        const string rowVersion = "\"connection-row-version\"";
        var observedAt =
            new DateTimeOffset(2026, 9, 5, 0, 5, 0, TimeSpan.Zero);
        var evidence = new PurviewTenantConnectionEvidenceDto(
            tenantId,
            administratorId,
            [
                "DlpPolicy.ReadWrite",
                "DlpRule.ReadWrite",
                "KnowYourData.ReadWrite",
                "SensitiveInformationTypes.Read"
            ],
            observedAt,
            launchExpiry,
            [
                new PurviewSensitiveInformationTypeDto(
                    Guid.NewGuid(),
                    "EU Passport Number",
                    "Microsoft")
            ]);
        var evidenceDigest =
            PurviewTenantConnectionEvidenceDigest.Compute(
                operationId,
                generationId,
                evidence);
        var completionReviewId = Guid.NewGuid();
        var completionConfirmationId = Guid.NewGuid();
        var responses = new Queue<HttpResponseMessage>(
        [
            ReviewResponse(
                reviewId,
                "connection-review-token",
                tenantId,
                "ConnectPurviewTenant",
                "PurviewTenantConnection",
                tenantId.ToString("D")),
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "reviewTokenId":"{{reviewId:D}}",
                  "confirmationTokenId":"{{confirmationId:D}}",
                  "confirmationToken":"connection-confirmation-token",
                  "expiresAtUtc":"2026-09-05T01:00:00Z"
                }
                """),
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "operationId":"{{operationId:D}}",
                  "status":"AwaitingAdministrator",
                  "correlationId":"{{Guid.NewGuid():D}}",
                  "companionLaunch":{
                    "operationId":"{{operationId:D}}",
                    "inventoryGenerationId":"{{generationId:D}}",
                    "expiresAtUtc":"{{launchExpiry:O}}",
                    "scriptRelativePath":"Automation/Connect-PurviewTenant.ps1",
                    "arguments":["-OperationId","{{operationId:D}}"]
                  }
                }
                """, HttpStatusCode.Accepted),
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "reviewTokenId":"{{completionReviewId:D}}",
                  "reviewToken":"completion-review-token",
                  "reviewedPayloadHash":"payload-hash",
                  "expiresAtUtc":"2026-09-05T01:00:00Z",
                  "review":{
                    "tenantId":"{{tenantId:D}}",
                    "operationType":"CompletePurviewTenantConnection",
                    "targetType":"PurviewTenantConnection",
                    "targetIdentifier":"{{tenantId:D}}",
                    "blueprintApplicationId":null,
                    "sensitiveInformationTypeId":null,
                    "sensitiveInformationTypeName":null,
                    "mode":null,
                    "activities":[],
                    "actions":[],
                    "scopeType":"Tenant",
                    "enforcementPlane":"Application",
                    "readinessDisclaimer":"Readback is not readiness proof.",
                    "sourceOperationId":"{{operationId:D}}",
                    "inventoryGenerationId":"{{generationId:D}}",
                    "evidenceDigest":"{{evidenceDigest}}"
                  }
                }
                """),
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "reviewTokenId":"{{completionReviewId:D}}",
                  "confirmationTokenId":"{{completionConfirmationId:D}}",
                  "confirmationToken":"completion-confirmation-token",
                  "expiresAtUtc":"2026-09-05T01:00:00Z"
                }
                """),
            AcceptedResponse(operationId)
        ]);
        var handler = new RecordingHttpMessageHandler(_ => responses.Dequeue());
        var client = CreateClient(handler);

        var connectionReview = await client.ReviewPurviewTenantConnectionAsync(
            new ReviewPurviewTenantConnectionRequest(tenantId, rowVersion));
        var startConfirmation = await client.ConfirmProtectionOperationReviewAsync(
            connectionReview.Value);
        var started = await client.StartPurviewTenantConnectionOperationAsync(
            startConfirmation.Value,
            startKey,
            rowVersion);
        started.Value.CompanionLaunch!.InventoryGenerationId.Should().Be(
            generationId);
        var completionReview =
            await client.ReviewPurviewTenantConnectionCompletionAsync(
                operationId,
                generationId,
                evidence,
                rowVersion);
        var completionConfirmation =
            await client.ConfirmProtectionOperationReviewAsync(
                completionReview.Value);
        await client.CompletePurviewTenantConnectionOperationAsync(
            operationId,
            evidence,
            completionConfirmation.Value,
            completionKey,
            rowVersion);

        handler.Requests[0].Uri.AbsolutePath.Should().Be(
            "/api/v1/protection/purview/connection-operations:review");
        handler.Requests[1].Uri.AbsolutePath.Should().Be(
            "/api/v1/protection/operation-reviews:confirm");

        var start = handler.Requests[2];
        start.Uri.AbsolutePath.Should().Be(
            "/api/v1/protection/purview/connection-operations");
        start.Header("Idempotency-Key").Should().Be(startKey.ToString("D"));
        start.Header("If-Match").Should().Be(rowVersion);
        start.Body.Should().Contain($"\"tenantId\":\"{tenantId:D}\"");

        var completionReviewCall = handler.Requests[3];
        completionReviewCall.Uri.AbsolutePath.Should().Be(
            $"/api/v1/protection/purview/connection-operations/{operationId:D}:review-completion");
        completionReviewCall.Body.Should().Contain(evidenceDigest);
        completionReviewCall.Body.Should().Contain(
            $"\"inventoryGenerationId\":\"{generationId:D}\"");
        handler.Requests[4].Uri.AbsolutePath.Should().Be(
            "/api/v1/protection/operation-reviews:confirm");

        var complete = handler.Requests[5];
        complete.Uri.AbsolutePath.Should().Be(
            $"/api/v1/protection/purview/connection-operations/{operationId:D}:complete");
        complete.Header("Idempotency-Key").Should().Be(completionKey.ToString("D"));
        complete.Header("If-Match").Should().Be(rowVersion);
        complete.Body.Should().Contain($"\"administratorObjectId\":\"{administratorId:D}\"");
        complete.Body.Should().Contain(evidenceDigest);
        complete.Body.Should().Contain("\"authorizedCapabilities\"");
        complete.Body.Should().NotContain("providerBody");
    }

    [Fact]
    public async Task DlpProfileMethods_PreserveAllStatesAndUseExactMutationRoutes()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var tenantId = Guid.NewGuid();
        var profileId = Guid.NewGuid();
        var blueprintId = Guid.NewGuid();
        var operationId = Guid.NewGuid();
        const string rowVersion = "\"dlp-row-version\"";
        var responses = new Queue<HttpResponseMessage>(
        [
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "items":[{
                    "id":"{{profileId:D}}",
                    "blueprintApplicationId":"{{blueprintId:D}}",
                    "displayName":"Research profile",
                    "sensitiveInformationTypeId":"{{Guid.NewGuid():D}}",
                    "sensitiveInformationTypeName":"EU Passport Number",
                    "mode":"Enforce",
                    "activities":["uploadText","downloadText"],
                    "actions":[{"activity":"uploadText","action":"block"}],
                    "status":"PendingPropagation",
                    "readiness":{
                      "capability":"Installed",
                      "readback":"Ready",
                      "propagation":"Pending",
                      "tokenRoles":"Unknown",
                      "runtimeVerdict":"NotTested",
                      "isReady":false,
                      "blockers":["PropagationPending"],
                      "evaluatedAtUtc":"2026-09-05T00:00:00Z"
                    },
                    "dlpPolicyProviderId":null,
                    "dlpRuleProviderId":null,
                    "lastReadbackAtUtc":"2026-09-05T00:00:00Z",
                    "rowVersion":"dlp-row-version"
                  }]
                }
                """),
            ReviewResponse(
                Guid.NewGuid(),
                "dlp-review-token",
                tenantId,
                "UpdateDlpProfile",
                "PurviewDlpProfile",
                profileId.ToString("D"),
                blueprintId),
            AcceptedResponse(operationId),
            AcceptedResponse(operationId),
            AcceptedResponse(operationId)
        ]);
        var handler = new RecordingHttpMessageHandler(_ => responses.Dequeue());
        var client = CreateClient(handler);

        var profiles = await client.GetPurviewDlpProfilesAsync();
        var review = await client.ReviewPurviewDlpProfileOperationAsync(
            new ReviewPurviewDlpProfileOperationRequest(
                profileId,
                Guid.NewGuid(),
                blueprintId,
                "Research profile",
                new PurviewSensitiveInformationTypeSelectionDto(
                    Guid.NewGuid(),
                    Guid.NewGuid(),
                    "EU Passport Number"),
                "Enforce",
                ["uploadText", "downloadText"],
                [new PurviewDlpRuleActionDto("uploadText", "block")],
                rowVersion));
        await client.StartPurviewDlpProfileOperationAsync(
            CreateConfirmationTicket(
                tenantId,
                "UpdateDlpProfile",
                "PurviewDlpProfile",
                profileId.ToString("D"),
                rowVersion),
            Guid.NewGuid(),
            rowVersion);
        await client.ReconcilePurviewDlpProfileAsync(
            profileId,
            CreateConfirmationTicket(
                tenantId,
                "ReconcileDlpProfile",
                "PurviewDlpProfile",
                profileId.ToString("D"),
                rowVersion),
            Guid.NewGuid(),
            rowVersion);
        await client.ValidatePurviewDlpProfileRuntimeAsync(
            profileId,
            CreateConfirmationTicket(
                tenantId,
                "ValidateDlpProfileRuntime",
                "PurviewDlpProfile",
                profileId.ToString("D"),
                rowVersion),
            Guid.NewGuid(),
            rowVersion);

        var profile = profiles.Value.Items.Should().ContainSingle().Subject;
        profile.Status.Should().Be("PendingPropagation");
        profile.Readiness.IsReady.Should().BeFalse();
        profile.Readiness.Propagation.Should().Be("Pending");
        review.Value.Review.BlueprintApplicationId.Should().Be(blueprintId);

        handler.Requests.Select(request => request.Uri.AbsolutePath).Should().Equal(
            "/api/v1/protection/purview/dlp-profiles",
            "/api/v1/protection/purview/dlp-profile-operations:review",
            "/api/v1/protection/purview/dlp-profile-operations",
            $"/api/v1/protection/purview/dlp-profiles/{profileId:D}:reconcile",
            $"/api/v1/protection/purview/dlp-profiles/{profileId:D}:validate-runtime");
        handler.Requests.Skip(2).Should().OnlyContain(request =>
            request.Header("Idempotency-Key") != null &&
            request.Header("If-Match") == rowVersion);
    }

    [Fact]
    public async Task DlpActionReviewsUseDistinctExactOperationRoutes()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>())
            .Returns("token");
        var tenantId = Guid.NewGuid();
        var profileId = Guid.NewGuid();
        const string rowVersion = "\"dlp-row-version\"";
        var responses = new Queue<HttpResponseMessage>(
        [
            ReviewResponse(
                Guid.NewGuid(),
                "reconcile-review",
                tenantId,
                "ReconcileDlpProfile",
                "DlpProfile",
                profileId.ToString("D")),
            ReviewResponse(
                Guid.NewGuid(),
                "runtime-review",
                tenantId,
                "ValidateDlpRuntime",
                "DlpProfile",
                profileId.ToString("D"))
        ]);
        var handler = new RecordingHttpMessageHandler(_ =>
            responses.Dequeue());
        var client = CreateClient(handler);

        var reconcile =
            await client.ReviewReconcilePurviewDlpProfileAsync(
                profileId,
                rowVersion);
        var runtime =
            await client.ReviewValidatePurviewDlpRuntimeAsync(
                profileId,
                rowVersion);

        reconcile.Value.Review.OperationType.Should().Be(
            "ReconcileDlpProfile");
        runtime.Value.Review.OperationType.Should().Be(
            "ValidateDlpRuntime");
        handler.Requests.Select(request => request.Uri.AbsolutePath)
            .Should().Equal(
                $"/api/v1/protection/purview/dlp-profiles/{profileId:D}:review-reconcile",
                $"/api/v1/protection/purview/dlp-profiles/{profileId:D}:review-runtime-validation");
        handler.Requests.Should().OnlyContain(request =>
            request.Header("If-Match") == rowVersion &&
            request.Header("Idempotency-Key") == null);
    }

    [Fact]
    public async Task DurableProtectionOperation_PreservesStagesBlockersAndCorrelation()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var operationId = Guid.NewGuid();
        var tenantId = Guid.NewGuid();
        var correlationId = Guid.NewGuid();
        var stepId = Guid.NewGuid();
        var handler = new RecordingHttpMessageHandler(_ =>
        {
            var response = RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "operation":{
                    "id":"{{operationId:D}}",
                    "workflowVersion":1,
                    "type":"ReconcileDlpProfile",
                    "status":"WaitingForPropagation",
                    "tenantId":"{{tenantId:D}}",
                    "actorObjectId":"administrator",
                    "targetType":"PurviewDlpProfile",
                    "targetIdentifier":"profile",
                    "reviewedPayloadHash":"payload-hash",
                    "idempotencyKey":"{{Guid.NewGuid():D}}",
                    "expectedRowVersion":"row-version",
                    "retryDisposition":"Scheduled",
                    "attemptCount":1,
                    "maximumAttempts":5,
                    "nextAttemptAtUtc":"2026-09-05T01:00:00Z",
                    "canRetry":false,
                    "requiresManualIntervention":false,
                    "correlationId":"{{correlationId:D}}",
                    "readbackReferenceId":null,
                    "failureCode":null,
                    "requiredAction":"WaitForPropagation",
                    "blockers":["PropagationPending"],
                    "createdAtUtc":"2026-09-05T00:00:00Z",
                    "startedAtUtc":"2026-09-05T00:01:00Z",
                    "completedAtUtc":null,
                    "updatedAtUtc":"2026-09-05T00:02:00Z",
                    "steps":[{
                      "id":"{{stepId:D}}",
                      "orderIndex":0,
                      "step":"DiscoverProviderState",
                      "status":"Completed",
                      "attemptCount":1,
                      "retryDisposition":"None",
                      "nextAttemptAtUtc":null,
                      "canRetry":false,
                      "requiresManualIntervention":false,
                      "readbackReferenceId":null,
                      "failureCode":null,
                      "startedAtUtc":"2026-09-05T00:01:00Z",
                      "completedAtUtc":"2026-09-05T00:02:00Z"
                    }],
                    "rowVersion":"operation-row-version"
                  }
                }
                """);
            response.Headers.TryAddWithoutValidation("X-Correlation-ID", "operation-correlation");
            return response;
        });
        var client = CreateClient(handler);

        var resource = await client.GetProtectionAdminOperationAsync(operationId);

        resource.CorrelationId.Should().Be("operation-correlation");
        resource.Value.Operation.Status.Should().Be("WaitingForPropagation");
        resource.Value.Operation.Blockers.Should().Equal("PropagationPending");
        resource.Value.Operation.Steps.Should().ContainSingle(step =>
            step.Id == stepId && step.Status == "Completed");
        handler.Requests.Should().ContainSingle().Which.Uri.AbsolutePath.Should().Be(
            $"/api/v1/protection/operations/{operationId:D}");
    }

    [Fact]
    public async Task DefaultsAndRegistrationFeatures_PreserveEffectiveReadinessAndMutationHeaders()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var agentId = Guid.NewGuid();
        var profileId = Guid.NewGuid();
        var blueprintId = Guid.NewGuid();
        var idempotencyKey = Guid.NewGuid();
        const string rowVersion = "\"registration-row-version\"";
        var responses = new Queue<HttpResponseMessage>(
        [
            RecordingHttpMessageHandler.JsonResponse(
                """
                {
                  "provisioningMode":"Automatic",
                  "defaultObservabilityMode":"Agent365",
                  "defaultPurviewEnabled":true,
                  "defaultPurviewMode":"Enforce",
                  "retentionDaysActivityReceipts":30,
                  "retentionDaysAuditEvents":90,
                  "retentionDaysIdempotencyRecords":7,
                  "retentionDaysOutboxMessages":14,
                  "rateLimitPerClient":100,
                  "rateLimitPerAgent":200,
                  "rateLimitGlobal":1000,
                  "reconciliationEnabled":true,
                  "reconciliationIntervalHours":24,
                  "stuckTransitionTimeoutDays":7,
                  "useGraphAgentRegistration":false,
                  "useCliProvisioningFallback":false,
                  "defaultPromptShieldEnabled":true,
                  "promptShieldAvailable":true,
                  "rowVersion":"system-row-version"
                }
                """),
            RecordingHttpMessageHandler.JsonResponse(
                """
                {
                  "provisioningMode":"Automatic",
                  "defaultObservabilityMode":"Agent365",
                  "defaultPurviewEnabled":true,
                  "defaultPurviewMode":"Enforce",
                  "retentionDaysActivityReceipts":30,
                  "retentionDaysAuditEvents":90,
                  "retentionDaysIdempotencyRecords":7,
                  "retentionDaysOutboxMessages":14,
                  "rateLimitPerClient":100,
                  "rateLimitPerAgent":200,
                  "rateLimitGlobal":1000,
                  "reconciliationEnabled":true,
                  "reconciliationIntervalHours":24,
                  "stuckTransitionTimeoutDays":7,
                  "useGraphAgentRegistration":false,
                  "useCliProvisioningFallback":false,
                  "defaultPromptShieldEnabled":true,
                  "promptShieldAvailable":true,
                  "rowVersion":"system-row-version-next"
                }
                """),
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "agentId":"{{agentId:D}}",
                  "features":{
                    "observabilityMode":"Agent365",
                    "purviewEnabled":true,
                    "purviewMode":"Enforce",
                    "promptShieldEnabled":true,
                    "purviewDlpProfile":{
                      "profileId":"{{profileId:D}}",
                      "blueprintApplicationId":"{{blueprintId:D}}",
                      "expectedProfileRowVersion":"profile-row-version"
                    },
                    "purviewEffectivelyEnabled":false,
                    "purviewReadiness":{
                      "capability":"Installed",
                      "readback":"Ready",
                      "propagation":"Pending",
                      "tokenRoles":"Ready",
                      "runtimeVerdict":"NotTested",
                      "isReady":false,
                      "blockers":["PropagationPending"],
                      "evaluatedAtUtc":"2026-09-05T00:00:00Z"
                    },
                    "promptShieldEffectivelyEnabled":true,
                    "promptShieldCapabilityStatus":"Installed"
                  },
                  "updatedAtUtc":"2026-09-05T00:00:00Z"
                }
                """)
        ]);
        var handler = new RecordingHttpMessageHandler(_ => responses.Dequeue());
        var client = CreateClient(handler);

        var defaults = await client.GetSystemConfigAsync();
        await client.UpdateSystemConfigAsync(new UpdateSystemConfigRequest(
            ProvisioningMode: null,
            DefaultObservabilityMode: null,
            DefaultPurviewEnabled: true,
            DefaultPurviewMode: "Enforce",
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
            DefaultPromptShieldEnabled: true,
            IdempotencyKey: idempotencyKey,
            ExpectedRowVersion: rowVersion));
        var features = await client.UpdateAgentFeaturesAsync(
            agentId,
            new UpdateFeaturesRequest(
                ObservabilityMode: null,
                PurviewEnabled: true,
                PurviewMode: "Enforce",
                PromptShieldEnabled: true,
                PurviewDlpProfile: new PurviewDlpProfileSelectionDto(
                    profileId,
                    blueprintId,
                    "profile-row-version"),
                IdempotencyKey: idempotencyKey,
                ExpectedRowVersion: rowVersion));

        defaults.DefaultPromptShieldEnabled.Should().BeTrue();
        defaults.PromptShieldAvailable.Should().BeTrue();
        defaults.RowVersion.Should().Be("system-row-version");
        features.Features.PurviewEffectivelyEnabled.Should().BeFalse();
        features.Features.PurviewReadiness.Should().NotBeNull();
        features.Features.PurviewReadiness!.Blockers.Should().Equal("PropagationPending");
        features.Features.PromptShieldEffectivelyEnabled.Should().BeTrue();

        handler.Requests[1].Header("Idempotency-Key").Should().Be(
            idempotencyKey.ToString("D"));
        handler.Requests[1].Header("If-Match").Should().Be(rowVersion);
        handler.Requests[2].Header("Idempotency-Key").Should().Be(
            idempotencyKey.ToString("D"));
        handler.Requests[2].Header("If-Match").Should().Be(rowVersion);
    }

    [Fact]
    public async Task RegisterAgentAsync_SerializesAdditiveDlpProfileSelection()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var agentId = Guid.NewGuid();
        var operationId = Guid.NewGuid();
        var profileId = Guid.NewGuid();
        var blueprintId = Guid.NewGuid();
        var handler = new RecordingHttpMessageHandler(_ =>
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "agentId":"{{agentId:D}}",
                  "externalAgentId":"external-agent",
                  "name":"Research agent",
                  "status":"Provisioning",
                  "operationId":"{{operationId:D}}",
                  "createdAtUtc":"2026-09-05T00:00:00Z",
                  "links":null
                }
                """, HttpStatusCode.Accepted));
        var client = CreateClient(handler);

        await client.RegisterAgentAsync(new RegisterAgentRequest(
            "external-agent",
            "Research agent",
            null,
            "owner",
            "Development",
            null,
            Blueprint: null,
            PurviewPolicyProfile: null,
            PurviewDlpProfile: new PurviewDlpProfileSelectionDto(
                profileId,
                blueprintId,
                "profile-row-version")));

        var request = handler.Requests.Should().ContainSingle().Subject;
        request.Body.Should().Contain($"\"profileId\":\"{profileId:D}\"");
        request.Body.Should().Contain($"\"blueprintApplicationId\":\"{blueprintId:D}\"");
        request.Body.Should().Contain("\"expectedProfileRowVersion\":\"profile-row-version\"");
    }

    [Fact]
    public async Task ProtectionProblemDetails_PreservesSafeClaimsChallengeAndCorrelation()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        const string providerBody = "provider-body-must-not-surface";
        var handler = new RecordingHttpMessageHandler(_ =>
        {
            var response = RecordingHttpMessageHandler.JsonResponse(
                """
                {
                  "type":"https://gateway.test/problems/protection-authorization",
                  "title":"Additional authorization is required",
                  "status":401,
                  "detail":"Complete the supported sign-in flow.",
                  "errorCode":"PURVIEW_TENANT_NOT_CONNECTED",
                  "correlationId":"protection-correlation",
                  "challengeType":"claims_challenge",
                  "claimsChallenge":true,
                  "requiredScopes":["Protection.ReadWrite"]
                }
                """,
                HttpStatusCode.Unauthorized);
            response.Headers.TryAddWithoutValidation("X-Provider-Body", providerBody);
            return response;
        });
        var client = CreateClient(handler);

        var action = () => client.GetProtectionCapabilitiesAsync();

        var exception = (await action.Should().ThrowAsync<GatewayApiException>()).Which;
        exception.CorrelationId.Should().Be("protection-correlation");
        exception.RequiresUserInteraction.Should().BeTrue();
        exception.HasClaimsChallenge.Should().BeTrue();
        exception.RequiredScopes.Should().Equal("Protection.ReadWrite");
        exception.Message.Should().NotContain(providerBody);
    }

    [Fact]
    public async Task ProtectionMutation_RejectsInvalidHeadersBeforeConsumingConfirmation()
    {
        var handler = new RecordingHttpMessageHandler(_ =>
            throw new InvalidOperationException("No network call was expected."));
        var client = CreateClient(handler);
        var reviewedTenantId = Guid.NewGuid();
        var confirmation = CreateConfirmationTicket(
            reviewedTenantId,
            "ReconcileDlpProfile",
            "PurviewDlpProfile",
            Guid.NewGuid().ToString("D"));
        var nonVersionFourKey = Guid.Parse("00000000-0000-1000-8000-000000000001");

        var action = () => client.ReconcilePurviewDlpProfileAsync(
            Guid.NewGuid(),
            confirmation,
            nonVersionFourKey,
            "row-version");

        await action.Should().ThrowAsync<ArgumentException>();
        confirmation.IsAvailable.Should().BeTrue();
        handler.Requests.Should().BeEmpty();

        var rowVersionMismatch = () => client.ReconcilePurviewDlpProfileAsync(
            Guid.NewGuid(),
            confirmation,
            Guid.NewGuid(),
            "changed-row-version");

        await rowVersionMismatch.Should().ThrowAsync<ArgumentException>();
        confirmation.IsAvailable.Should().BeTrue();
        handler.Requests.Should().BeEmpty();

        var mismatchedEvidence = new PurviewTenantConnectionEvidenceDto(
            reviewedTenantId == Guid.Parse("00000000-0000-4000-8000-000000000001")
                ? Guid.Parse("00000000-0000-4000-8000-000000000002")
                : Guid.Parse("00000000-0000-4000-8000-000000000001"),
            Guid.NewGuid(),
            [],
            DateTime.UtcNow,
            DateTime.UtcNow.AddMinutes(5),
            []);
        var tenantMismatch = () => client.CompletePurviewTenantConnectionOperationAsync(
            Guid.NewGuid(),
            mismatchedEvidence,
            confirmation,
            Guid.NewGuid(),
            "row-version");

        await tenantMismatch.Should().ThrowAsync<ArgumentException>();
        confirmation.IsAvailable.Should().BeTrue();
        handler.Requests.Should().BeEmpty();
    }

    [Fact]
    public async Task ProtectionMutation_DoesNotLogConfirmationOrProviderBody()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        const string confirmationToken = "confirmation-value-must-not-be-logged";
        const string providerBody = "provider-body-must-not-be-logged";
        var profileId = Guid.NewGuid();
        var logger = new RecordingLogger<GatewayApiClient>();
        var handler = new RecordingHttpMessageHandler(_ =>
            RecordingHttpMessageHandler.JsonResponse(
                $$"""
                {
                  "title":"Protection operation failed",
                  "status":502,
                  "detail":"The provider outcome could not be verified.",
                  "errorCode":"PROTECTION_PROVIDER_OUTCOME_UNKNOWN",
                  "providerBody":"{{providerBody}}"
                }
                """,
                HttpStatusCode.BadGateway));
        var client = CreateClient(handler, logger);
        var reviewTokenId = Guid.NewGuid();
        var confirmation = new ProtectionOperationConfirmationTicket(
            new ProtectionOperationConfirmationResponse(
                reviewTokenId,
                Guid.NewGuid(),
                confirmationToken,
                DateTime.UtcNow.AddMinutes(5)),
            new ProtectionOperationReviewSummaryDto(
                Guid.NewGuid(),
                "ReconcileDlpProfile",
                "PurviewDlpProfile",
                profileId.ToString("D"),
                null,
                null,
                null,
                null,
                [],
                [],
                "Individual",
                "Application",
                "Readback is not readiness proof."),
            "row-version");

        var action = () => client.ReconcilePurviewDlpProfileAsync(
            profileId,
            confirmation,
            Guid.NewGuid(),
            "row-version");

        var exception = (await action.Should().ThrowAsync<GatewayApiException>()).Which;
        exception.Message.Should().NotContain(providerBody);
        logger.Messages.Should().NotContain(message =>
            message.Contains(confirmationToken, StringComparison.Ordinal) ||
            message.Contains(providerBody, StringComparison.Ordinal));
    }

    [Fact]
    public async Task ProtectionRead_PropagatesCallerCancellationWithoutSendingRequest()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        _tokenProvider.GetAccessTokenAsync(cancellation.Token)
            .Returns(Task.FromCanceled<string>(cancellation.Token));
        var handler = new RecordingHttpMessageHandler(_ =>
            throw new InvalidOperationException("No request was expected."));
        var client = CreateClient(handler);

        var action = () => client.GetProtectionCapabilitiesAsync(cancellation.Token);

        await action.Should().ThrowAsync<OperationCanceledException>();
        _ = _tokenProvider.Received(1).GetAccessTokenAsync(cancellation.Token);
        handler.Requests.Should().BeEmpty();
    }

    private GatewayApiClient CreateClient(
        HttpMessageHandler handler,
        ILogger<GatewayApiClient>? logger = null) =>
        new(
            new HttpClient(handler)
            {
                BaseAddress = new Uri("https://gateway.test/")
            },
            _tokenProvider,
            logger ?? NullLogger<GatewayApiClient>.Instance);

    private static HttpResponseMessage WithMetadata(
        string json,
        string etag,
        string correlationId)
    {
        var response = RecordingHttpMessageHandler.JsonResponse(json);
        response.Headers.TryAddWithoutValidation("ETag", etag);
        response.Headers.TryAddWithoutValidation("X-Correlation-ID", correlationId);
        return response;
    }

    private static HttpResponseMessage AcceptedResponse(Guid operationId) =>
        RecordingHttpMessageHandler.JsonResponse($$"""
            {
              "operationId":"{{operationId:D}}",
              "status":"Accepted",
              "correlationId":"{{Guid.NewGuid():D}}"
            }
            """, HttpStatusCode.Accepted);

    private static HttpResponseMessage ReviewResponse(
        Guid reviewTokenId,
        string reviewToken,
        Guid tenantId,
        string operationType,
        string targetType,
        string targetIdentifier,
        Guid? blueprintApplicationId = null)
    {
        var scopeType = targetType switch
        {
            "PurviewKnowYourData" => "Group",
            "PurviewDlpProfile" => "Individual",
            _ => "Tenant"
        };

        return RecordingHttpMessageHandler.JsonResponse($$"""
            {
              "reviewTokenId":"{{reviewTokenId:D}}",
              "reviewToken":"{{reviewToken}}",
              "reviewedPayloadHash":"payload-hash",
              "expiresAtUtc":"2026-09-05T01:00:00Z",
              "review":{
                "tenantId":"{{tenantId:D}}",
                "operationType":"{{operationType}}",
                "targetType":"{{targetType}}",
                "targetIdentifier":"{{targetIdentifier}}",
                "blueprintApplicationId":{{JsonGuid(blueprintApplicationId)}},
                "sensitiveInformationTypeId":"{{Guid.NewGuid():D}}",
                "sensitiveInformationTypeName":"EU Passport Number",
                "mode":"Enforce",
                "activities":["uploadText"],
                "actions":[{"activity":"uploadText","action":"block"}],
                "scopeType":"{{scopeType}}",
                "enforcementPlane":"Application",
                "readinessDisclaimer":"Readback is not readiness proof."
              }
            }
            """);
    }

    private static ProtectionOperationConfirmationTicket CreateConfirmationTicket(
        Guid tenantId,
        string operationType,
        string targetType,
        string targetIdentifier,
        string expectedRowVersion = "row-version")
    {
        var reviewTokenId = Guid.NewGuid();
        return new ProtectionOperationConfirmationTicket(
            new ProtectionOperationConfirmationResponse(
                reviewTokenId,
                Guid.NewGuid(),
                $"synthetic-confirmation-{Guid.NewGuid():D}",
                DateTime.UtcNow.AddMinutes(5)),
            new ProtectionOperationReviewSummaryDto(
                tenantId,
                operationType,
                targetType,
                targetIdentifier,
                null,
                null,
                null,
                null,
                [],
                [],
                targetType switch
                {
                    "PurviewKnowYourData" => "Group",
                    "PurviewDlpProfile" => "Individual",
                    _ => "Tenant"
                },
                "Application",
                "Readback is not readiness proof."),
            expectedRowVersion);
    }

    private static bool IsGuid(string? value) => Guid.TryParse(value, out _);

    private static string JsonGuid(Guid? value) =>
        value is null ? "null" : $"\"{value.Value:D}\"";

    private sealed class RecordingLogger<T> : ILogger<T>
    {
        public List<string> Messages { get; } = [];

        public IDisposable? BeginScope<TState>(TState state)
            where TState : notnull =>
            null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter) =>
            Messages.Add(formatter(state, exception));
    }
}
