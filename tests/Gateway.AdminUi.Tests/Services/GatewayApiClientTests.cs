using System.Net;
using FluentAssertions;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Infrastructure;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;

namespace Gateway.AdminUi.Tests.Services;

public sealed class GatewayApiClientTests
{
    private readonly IGatewayAccessTokenProvider _tokenProvider =
        Substitute.For<IGatewayAccessTokenProvider>();

    [Fact]
    public async Task GetHealthAsync_DoesNotAcquireToken_AndSendsCorrelationId()
    {
        var handler = new RecordingHttpMessageHandler(_ =>
            RecordingHttpMessageHandler.JsonResponse("""{"status":"Healthy"}"""));
        var client = CreateClient(handler);

        var result = await client.GetHealthAsync();

        result.Status.Should().Be("Healthy");
        var request = handler.Requests.Should().ContainSingle().Subject;
        request.Method.Should().Be(HttpMethod.Get);
        request.Uri.AbsolutePath.Should().Be("/health");
        Guid.TryParse(request.Header("X-Correlation-ID"), out _).Should().BeTrue();
        request.Header("Authorization").Should().BeNull();
        await _tokenProvider.DidNotReceiveWithAnyArgs().GetAccessTokenAsync(default);
    }

    [Fact]
    public async Task GetReadinessAsync_ReturnsDocumentedUnavailableStatusFrom503()
    {
        var handler = new RecordingHttpMessageHandler(_ =>
            RecordingHttpMessageHandler.JsonResponse(
                """{"status":"Unavailable"}""",
                HttpStatusCode.ServiceUnavailable));
        var client = CreateClient(handler);

        var result = await client.GetReadinessAsync();

        result.Status.Should().Be("Unavailable");
        var request = handler.Requests.Should().ContainSingle().Subject;
        request.Uri.AbsolutePath.Should().Be("/health/ready");
        request.Header("Authorization").Should().BeNull();
        await _tokenProvider.DidNotReceiveWithAnyArgs().GetAccessTokenAsync(default);
    }

    [Fact]
    public async Task GetAgentsAsync_AddsBearerToken_AndEncodesOnlySpecifiedFilters()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>())
            .Returns("test-access-token");
        var handler = new RecordingHttpMessageHandler(_ =>
            RecordingHttpMessageHandler.JsonResponse(
                """{"items":[],"nextCursor":null,"totalCount":0}"""));
        var client = CreateClient(handler);

        var result = await client.GetAgentsAsync(new AgentListQuery(
            Status: "Active",
            Environment: null,
            Search: "Research & Sales",
            Limit: 25,
            Cursor: "cursor/value="));

        result.Items.Should().BeEmpty();
        var request = handler.Requests.Should().ContainSingle().Subject;
        request.Uri.AbsolutePath.Should().Be("/api/v1/agents");
        request.Uri.Query.Should().Contain("status=Active");
        request.Uri.Query.Should().Contain("search=Research%20%26%20Sales");
        request.Uri.Query.Should().Contain("limit=25");
        request.Uri.Query.Should().Contain("cursor=cursor%2Fvalue%3D");
        request.Uri.Query.Should().NotContain("environment=");
        request.Header("Authorization").Should().Be("Bearer test-access-token");
        await _tokenProvider.Received(1).GetAccessTokenAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task GetAgentAsync_ReturnsResponseMetadata()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var agentId = Guid.NewGuid();
        var handler = new RecordingHttpMessageHandler(_ =>
        {
            var response = RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "agentId":"{{agentId}}",
                  "externalAgentId":"external-agent",
                  "name":"Research agent",
                  "status":"Active",
                  "environment":"Development",
                  "createdAtUtc":"2026-01-01T00:00:00Z",
                  "updatedAtUtc":"2026-01-02T00:00:00Z",
                  "ownerObjectId":"owner",
                  "createdByObjectId":"creator",
                  "updatedByObjectId":"updater",
                  "rowVersion":"AQID"
                }
                """);
            response.Headers.ETag = new System.Net.Http.Headers.EntityTagHeaderValue("\"version-1\"");
            response.Headers.TryAddWithoutValidation("X-Correlation-ID", "server-correlation");
            return response;
        });
        var client = CreateClient(handler);

        var resource = await client.GetAgentAsync(agentId);

        resource.Value.AgentId.Should().Be(agentId);
        resource.Value.Name.Should().Be("Research agent");
        resource.ETag.Should().Be("\"version-1\"");
        resource.CorrelationId.Should().Be("server-correlation");
    }

    [Fact]
    public async Task CredentialLifecycleMethods_UseNamedRoutesWithoutUnsupportedMutationHeaders()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var agentId = Guid.NewGuid();
        var credentialId = Guid.NewGuid();
        var issuedCredentialId = Guid.NewGuid();
        var responses = new Queue<HttpResponseMessage>(
        [
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "agentId":"{{agentId:D}}",
                  "items":[{
                    "keyId":"{{credentialId:D}}",
                    "createdAtUtc":"2026-08-01T00:00:00Z",
                    "expiresAtUtc":"2027-08-01T00:00:00Z",
                    "revokedAtUtc":null
                  }]
                }
                """),
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "agentId":"{{agentId:D}}",
                  "externalAgentId":"external-agent",
                  "gatewayCredential":{
                    "keyId":"{{issuedCredentialId:D}}",
                    "apiKey":"a365gw_v1_one-time-value",
                    "expiresAtUtc":"2027-08-01T00:00:00Z"
                  }
                }
                """, HttpStatusCode.Created),
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "agentId":"{{agentId:D}}",
                  "credential":{
                    "keyId":"{{credentialId:D}}",
                    "createdAtUtc":"2026-08-01T00:00:00Z",
                    "expiresAtUtc":"2027-08-01T00:00:00Z",
                    "revokedAtUtc":"2026-08-25T00:00:00Z"
                  },
                  "alreadyRevoked":false
                }
                """)
        ]);
        var handler = new RecordingHttpMessageHandler(_ => responses.Dequeue());
        var client = CreateClient(handler);

        var list = await client.GetAgentIngressCredentialsAsync(agentId);
        var issued = await client.IssueAgentIngressCredentialAsync(agentId);
        var revoked = await client.RevokeAgentIngressCredentialAsync(
            agentId,
            credentialId);

        list.Items.Should().ContainSingle(item => item.KeyId == credentialId);
        issued.GatewayCredential.KeyId.Should().Be(issuedCredentialId);
        revoked.Credential.KeyId.Should().Be(credentialId);

        handler.Requests.Should().HaveCount(3);
        var listRequest = handler.Requests[0];
        listRequest.Method.Should().Be(HttpMethod.Get);
        listRequest.Uri.AbsolutePath.Should().Be(
            $"/api/v1/agents/{agentId:D}/credentials");

        var issueRequest = handler.Requests[1];
        issueRequest.Method.Should().Be(HttpMethod.Post);
        issueRequest.Uri.AbsolutePath.Should().Be(
            $"/api/v1/agents/{agentId:D}/credentials");
        issueRequest.Header("Idempotency-Key").Should().BeNull();

        var revokeRequest = handler.Requests[2];
        revokeRequest.Method.Should().Be(HttpMethod.Delete);
        revokeRequest.Uri.AbsolutePath.Should().Be(
            $"/api/v1/agents/{agentId:D}/credentials/{credentialId:D}");
        revokeRequest.Header("Idempotency-Key").Should().BeNull();
        revokeRequest.Header("If-Match").Should().BeNull();
    }

    [Fact]
    public async Task GetAgentIdentityBlueprintsAsync_AddsBearerTokenAndDeserializesTypedInventory()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>())
            .Returns("blueprint-token");
        var blueprintObjectId = Guid.NewGuid();
        var blueprintClientId = Guid.NewGuid();
        var handler = new RecordingHttpMessageHandler(_ =>
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "items":[
                    {
                      "blueprintObjectId":"{{blueprintObjectId:D}}",
                      "blueprintClientId":"{{blueprintClientId:D}}",
                      "displayName":"Shared research blueprint",
                      "isAgent365Compatible":true,
                      "agent365CompatibilityIssue":null
                    }
                  ]
                }
                """));
        var client = CreateClient(handler);

        var result = await client.GetAgentIdentityBlueprintsAsync();

        var blueprint = result.Items.Should().ContainSingle().Subject;
        blueprint.BlueprintObjectId.Should().Be(blueprintObjectId);
        blueprint.BlueprintClientId.Should().Be(blueprintClientId);
        blueprint.DisplayName.Should().Be("Shared research blueprint");
        blueprint.IsAgent365Compatible.Should().BeTrue();
        blueprint.Agent365CompatibilityIssue.Should().BeNull();
        var request = handler.Requests.Should().ContainSingle().Subject;
        request.Method.Should().Be(HttpMethod.Get);
        request.Uri.AbsolutePath.Should().Be("/api/v1/agent-identity-blueprints");
        request.Header("Authorization").Should().Be("Bearer blueprint-token");
        Guid.TryParse(request.Header("X-Correlation-ID"), out _).Should().BeTrue();
    }

    [Fact]
    public async Task EnableAgentAsync_UsesNamedRouteWithoutUnsupportedMutationHeaders()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var agentId = Guid.NewGuid();
        var handler = new RecordingHttpMessageHandler(_ =>
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "agentId":"{{agentId}}",
                  "status":"Active",
                  "effectiveAtUtc":"2026-01-01T00:00:00Z"
                }
                """));
        var client = CreateClient(handler);

        var result = await client.EnableAgentAsync(agentId);

        result.Status.Should().Be("Active");
        var request = handler.Requests.Should().ContainSingle().Subject;
        request.Method.Should().Be(HttpMethod.Post);
        request.Uri.AbsolutePath.Should().Be($"/api/v1/agents/{agentId:D}:enable");
        request.Header("Idempotency-Key").Should().BeNull();
        request.Header("If-Match").Should().BeNull();
    }

    [Fact]
    public async Task DeleteAgentAsync_DoesNotSendUnsupportedMutationHeaders()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var agentId = Guid.NewGuid();
        var operationId = Guid.NewGuid();
        var handler = new RecordingHttpMessageHandler(_ =>
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "agentId":"{{agentId}}",
                  "status":"Deleting",
                  "operationId":"{{operationId}}"
                }
                """));
        var client = CreateClient(handler);

        await client.DeleteAgentAsync(agentId);

        var request = handler.Requests.Should().ContainSingle().Subject;
        request.Method.Should().Be(HttpMethod.Delete);
        request.Uri.PathAndQuery.Should().Be(
            $"/api/v1/agents/{agentId:D}");
        request.Header("If-Match").Should().BeNull();
        request.Header("Idempotency-Key").Should().BeNull();
    }

    [Fact]
    public async Task CompleteAgent365RegistrationAsync_UsesAuthenticatedPostWithoutBodyOrAutomaticRetryKey()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>())
            .Returns("gateway-api-token");
        var operationId = Guid.NewGuid();
        var agentId = Guid.NewGuid();
        var registryId = Guid.NewGuid().ToString("D");
        var handler = new RecordingHttpMessageHandler(_ =>
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "operationId":"{{operationId:D}}",
                  "agentId":"{{agentId:D}}",
                  "agent365RegistrationId":"{{registryId}}",
                  "status":"Running"
                }
                """));
        var client = CreateClient(handler);

        var result = await client.CompleteAgent365RegistrationAsync(operationId);

        result.OperationId.Should().Be(operationId);
        result.AgentId.Should().Be(agentId);
        result.Agent365RegistrationId.Should().Be(registryId);
        var request = handler.Requests.Should().ContainSingle().Subject;
        request.Method.Should().Be(HttpMethod.Post);
        request.Uri.AbsolutePath.Should().Be(
            $"/api/v1/operations/{operationId:D}:complete-agent365-registration");
        request.Header("Authorization").Should().Be("Bearer gateway-api-token");
        request.Header("Idempotency-Key").Should().BeNull();
        request.Body.Should().BeNull();
        Guid.TryParse(request.Header("X-Correlation-ID"), out _).Should().BeTrue();
        await _tokenProvider.Received(1)
            .GetAccessTokenAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task UpdateAgentFeaturesAsync_SerializesPatchWithoutUnsupportedMutationHeaders()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var agentId = Guid.NewGuid();
        var handler = new RecordingHttpMessageHandler(_ =>
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "agentId":"{{agentId}}",
                  "features":{"observabilityMode":"Agent365AzureMonitor","purviewEnabled":true,"purviewMode":"Audit","agent365ObservabilityEnabled":true,"azureMonitorExportEnabled":true},
                  "updatedAtUtc":"2026-01-01T00:00:00Z"
                }
                """));
        var client = CreateClient(handler);

        await client.UpdateAgentFeaturesAsync(
            agentId,
            new UpdateFeaturesRequest("Agent365AzureMonitor", true, "Audit", true, true));

        var request = handler.Requests.Should().ContainSingle().Subject;
        request.Method.Should().Be(HttpMethod.Patch);
        request.Header("If-Match").Should().BeNull();
        request.Header("Idempotency-Key").Should().BeNull();
        request.Body.Should().Contain("\"observabilityMode\":\"Agent365AzureMonitor\"");
        request.Body.Should().Contain("\"agent365ObservabilityEnabled\":true");
        request.Body.Should().Contain("\"azureMonitorExportEnabled\":true");
        request.Body.Should().Contain("\"purviewEnabled\":true");
        request.Body.Should().Contain("\"purviewMode\":\"Audit\"");
    }

    [Fact]
    public async Task OtherControlPlaneMutations_DoNotSendUnsupportedMutationHeaders()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var agentId = Guid.NewGuid();
        var registrationOperationId = Guid.NewGuid();
        var retryOperationId = Guid.NewGuid();
        var responses = new Queue<HttpResponseMessage>(
        [
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "agentId":"{{agentId:D}}",
                  "externalAgentId":"external-agent",
                  "name":"Research agent",
                  "status":"Provisioning",
                  "operationId":"{{registrationOperationId:D}}",
                  "createdAtUtc":"2026-01-01T00:00:00Z"
                }
                """, HttpStatusCode.Created),
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "agentId":"{{agentId:D}}",
                  "status":"Disabled",
                  "effectiveAtUtc":"2026-01-01T00:00:00Z"
                }
                """),
            RecordingHttpMessageHandler.JsonResponse($$"""
                {
                  "agentId":"{{agentId:D}}",
                  "status":"Provisioning",
                  "operationId":"{{retryOperationId:D}}"
                }
                """, HttpStatusCode.Accepted),
            RecordingHttpMessageHandler.JsonResponse(
                """
                {
                  "provisioningMode":"Automatic",
                  "defaultObservabilityMode":"Agent365",
                  "defaultPurviewEnabled":false,
                  "defaultPurviewMode":"AuditOnly",
                  "retentionDaysActivityReceipts":30,
                  "retentionDaysAuditEvents":90,
                  "retentionDaysIdempotencyRecords":7,
                  "retentionDaysOutboxMessages":14,
                  "rateLimitPerClient":100,
                  "rateLimitPerAgent":200,
                  "rateLimitGlobal":1000,
                  "reconciliationEnabled":false,
                  "reconciliationIntervalHours":24,
                  "stuckTransitionTimeoutDays":7,
                  "useGraphAgentRegistration":false,
                  "useCliProvisioningFallback":false
                }
                """)
        ]);
        var handler = new RecordingHttpMessageHandler(_ => responses.Dequeue());
        var client = CreateClient(handler);

        await client.RegisterAgentAsync(new RegisterAgentRequest(
            "external-agent",
            "Research agent",
            null,
            "owner-object-id",
            "Development",
            null));
        await client.DisableAgentAsync(agentId);
        await client.RetryProvisioningAsync(agentId);
        await client.UpdateSystemConfigAsync(new UpdateSystemConfigRequest(
            ProvisioningMode: null,
            DefaultObservabilityMode: "Agent365",
            DefaultPurviewEnabled: null,
            DefaultPurviewMode: null,
            RetentionDaysActivityReceipts: null,
            RetentionDaysAuditEvents: null,
            RetentionDaysIdempotencyRecords: 7,
            RetentionDaysOutboxMessages: null,
            RateLimitPerClient: null,
            RateLimitPerAgent: null,
            RateLimitGlobal: null,
            ReconciliationEnabled: null,
            ReconciliationIntervalHours: null,
            StuckTransitionTimeoutDays: null,
            UseGraphAgentRegistration: null,
            UseCliProvisioningFallback: null));

        handler.Requests.Should().HaveCount(4);
        handler.Requests.Should().OnlyContain(request =>
            request.Header("Idempotency-Key") == null &&
            request.Header("If-Match") == null);
        handler.Requests.Select(request => request.Uri.AbsolutePath).Should().Equal(
            "/api/v1/agents",
            $"/api/v1/agents/{agentId:D}:disable",
            $"/api/v1/agents/{agentId:D}:retry-provisioning",
            "/api/v1/system/config");
    }

    [Fact]
    public async Task GetSystemConfigAsync_OldPayloadWithoutCanonicalDestinations_PreservesLegacyFallbackSignal()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var handler = new RecordingHttpMessageHandler(_ =>
            RecordingHttpMessageHandler.JsonResponse(
                """
                {
                  "provisioningMode":"Automatic",
                  "defaultObservabilityMode":"GatewayOnly",
                  "defaultPurviewEnabled":false,
                  "defaultPurviewMode":"AuditOnly",
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
                  "useCliProvisioningFallback":true
                }
                """));
        var client = CreateClient(handler);

        var result = await client.GetSystemConfigAsync();

        result.DefaultObservabilityMode.Should().Be("GatewayOnly");
        result.DefaultAgent365ObservabilityEnabled.Should().BeNull();
        result.DefaultAzureMonitorExportEnabled.Should().BeNull();
    }

    [Fact]
    public async Task ProblemDetailsResponse_MapsSafeDetailsValidationAndCorrelation()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var handler = new RecordingHttpMessageHandler(_ =>
        {
            var response = RecordingHttpMessageHandler.JsonResponse(
                """
                {
                  "type":"https://gateway.test/problems/validation",
                  "title":"Agent validation failed",
                  "status":400,
                  "detail":"Review the highlighted fields.",
                  "instance":"/api/v1/agents",
                  "errorCode":"GW-VAL-001",
                  "correlationId":"problem-correlation",
                  "errors":{"name":["Name is required."],"environment":"Unsupported environment."}
                }
                """,
                HttpStatusCode.BadRequest);
            response.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(
                TimeSpan.FromSeconds(12));
            return response;
        });
        var client = CreateClient(handler);

        var action = () => client.GetAgentsAsync();

        var exception = (await action.Should().ThrowAsync<GatewayApiException>()).Which;
        exception.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        exception.Title.Should().Be("Agent validation failed");
        exception.Detail.Should().Be("Review the highlighted fields.");
        exception.ErrorCode.Should().Be("GW-VAL-001");
        exception.CorrelationId.Should().Be("problem-correlation");
        exception.ValidationErrors["name"].Should().Equal("Name is required.");
        exception.ValidationErrors["environment"].Should().Equal("Unsupported environment.");
        exception.RetryAfter.Should().Be(TimeSpan.FromSeconds(12));
        exception.IsTransient.Should().BeFalse();
    }

    [Fact]
    public async Task DelegatedAuthorizationChallenge_PreservesSafeInteractionMetadataOnly()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        const string opaqueClaimsChallenge = "opaque-claims-challenge-must-not-surface";
        var handler = new RecordingHttpMessageHandler(_ =>
        {
            var response = RecordingHttpMessageHandler.JsonResponse(
                """
                {
                  "type":"https://gateway.example.com/problems/delegated-authorization-required",
                  "title":"Additional Microsoft Entra authorization is required",
                  "status":401,
                  "detail":"Conditional Access requires another Microsoft Entra interaction before Agent 365 registration can continue.",
                  "errorCode":"AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED",
                  "correlationId":"challenge-correlation",
                  "challengeType":"claims_challenge",
                  "claimsChallenge":true,
                  "requiredScopes":[
                    "https://graph.microsoft.com/AgentRegistration.ReadWrite.All",
                    "https://graph.microsoft.com/AgentRegistration.Read.All"
                  ]
                }
                """,
                HttpStatusCode.Unauthorized);
            response.Headers.TryAddWithoutValidation(
                "WWW-Authenticate",
                $"Bearer realm=\"tenant\", error=\"insufficient_claims\", claims=\"{opaqueClaimsChallenge}\"");
            return response;
        });
        var client = CreateClient(handler);

        var action = () => client.GetAgentsAsync();

        var exception = (await action.Should().ThrowAsync<GatewayApiException>()).Which;
        exception.RequiresUserInteraction.Should().BeTrue();
        exception.HasClaimsChallenge.Should().BeTrue();
        exception.RequiredScopes.Should().Equal(
            "https://graph.microsoft.com/AgentRegistration.ReadWrite.All",
            "https://graph.microsoft.com/AgentRegistration.Read.All");
        exception.CorrelationId.Should().Be("challenge-correlation");
        exception.Message.Should().NotContain(opaqueClaimsChallenge);
    }

    [Fact]
    public async Task NonProblemErrorBody_IsNeverSurfacedToTheCaller()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        const string upstreamBody = "sensitive upstream diagnostic content";
        var handler = new RecordingHttpMessageHandler(_ => new HttpResponseMessage(
            HttpStatusCode.InternalServerError)
        {
            Content = new StringContent(upstreamBody)
        });
        var client = CreateClient(handler);

        var action = () => client.GetAgentsAsync();

        var exception = (await action.Should().ThrowAsync<GatewayApiException>()).Which;
        exception.Title.Should().Be("The Gateway API is temporarily unavailable.");
        exception.Detail.Should().BeNull();
        exception.Message.Should().NotContain(upstreamBody);
        exception.IsTransient.Should().BeTrue();
    }

    [Theory]
    [InlineData(0)]
    [InlineData(101)]
    public async Task GetAgentsAsync_RejectsOutOfRangePageSizeBeforeNetworkCall(int limit)
    {
        var handler = new RecordingHttpMessageHandler(_ =>
            throw new InvalidOperationException("No network call was expected."));
        var client = CreateClient(handler);

        var action = () => client.GetAgentsAsync(new AgentListQuery(Limit: limit));

        await action.Should().ThrowAsync<ArgumentOutOfRangeException>();
        handler.Requests.Should().BeEmpty();
    }

    [Fact]
    public async Task SuccessfulResponseWithInvalidJson_ThrowsProtocolExceptionWithoutRawBody()
    {
        _tokenProvider.GetAccessTokenAsync(Arg.Any<CancellationToken>()).Returns("token");
        var handler = new RecordingHttpMessageHandler(_ =>
        {
            var response = RecordingHttpMessageHandler.JsonResponse("not-json");
            response.Headers.TryAddWithoutValidation("X-Correlation-ID", "response-correlation");
            return response;
        });
        var client = CreateClient(handler);

        var action = () => client.GetAgentsAsync();

        var exception = (await action.Should().ThrowAsync<GatewayApiProtocolException>()).Which;
        exception.Message.Should().Be("The Gateway API returned an unexpected response.");
        exception.Message.Should().NotContain("not-json");
        exception.CorrelationId.Should().Be("response-correlation");
    }

    private GatewayApiClient CreateClient(HttpMessageHandler handler) =>
        new(
            new HttpClient(handler)
            {
                BaseAddress = new Uri("https://gateway.test/")
            },
            _tokenProvider,
            NullLogger<GatewayApiClient>.Instance);
}
