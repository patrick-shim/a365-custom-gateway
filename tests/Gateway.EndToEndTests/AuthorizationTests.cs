using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Gateway.Contracts;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.EndToEndTests.Fixtures;
using FluentAssertions;

namespace Gateway.EndToEndTests;

[Collection(EndToEndTestCollection.Name)]
public class AuthorizationTests : IDisposable
{
    private readonly GatewayWebApplicationFactory _factory;
    private readonly HttpClient _client;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public AuthorizationTests(GatewayWebApplicationFactory factory)
    {
        _factory = factory;
        _client = factory.CreateAuthenticatedClient();
    }

    public void Dispose()
    {
        _client.Dispose();
        TestAuthHandler.Reset();
    }

    [Fact]
    public async Task RegisterAgent_Should_Return401_When_Unauthenticated()
    {
        // Arrange
        HttpClientExtensions.SetUnauthenticated();

        var request = new RegisterAgentRequest(
            ExternalAgentId: "test-unauth-001",
            Name: "Unauthorized Agent",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null,
            Blueprint: TestRequestData.ValidBlueprint);

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task RegisterAgent_Should_Return403_When_RoleIsAuditor()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Auditor");

        var request = new RegisterAgentRequest(
            ExternalAgentId: "test-auditor-001",
            Name: "Auditor Agent",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null,
            Blueprint: TestRequestData.ValidBlueprint);

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task RegisterAgent_Should_Return403_When_RoleIsOperator()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Operator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: "test-operator-001",
            Name: "Operator Agent",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null,
            Blueprint: TestRequestData.ValidBlueprint);

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task ListAgents_Should_Return403_When_RoleIsExternalAgent()
    {
        // Arrange
        HttpClientExtensions.SetExternalAgent("some-client-id");

        // Act
        var response = await _client.GetAsync("/api/v1/agents");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task ListAgents_Should_Return200_When_RoleIsAdministrator()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        // Act
        var response = await _client.GetAsync("/api/v1/agents");

        // Assert
        response.StatusCode.Should().NotBe(HttpStatusCode.Forbidden);
        response.StatusCode.Should().NotBe(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task ListAgents_Should_Return200_When_RoleIsOperator()
    {
        // Arrange - Operator is in AllControlPlane policy
        HttpClientExtensions.SetRole("Gateway.Operator");

        // Act
        var response = await _client.GetAsync("/api/v1/agents");

        // Assert
        response.StatusCode.Should().NotBe(HttpStatusCode.Forbidden);
        response.StatusCode.Should().NotBe(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task ListAgents_Should_Return200_When_RoleIsAuditor()
    {
        // Arrange - Auditor is in AllControlPlane policy
        HttpClientExtensions.SetRole("Gateway.Auditor");

        // Act
        var response = await _client.GetAsync("/api/v1/agents");

        // Assert
        response.StatusCode.Should().NotBe(HttpStatusCode.Forbidden);
        response.StatusCode.Should().NotBe(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task ListAgents_Should_Return200_When_RoleIsSupportReader()
    {
        // Arrange - SupportReader is in AllControlPlane policy
        HttpClientExtensions.SetRole("Gateway.SupportReader");

        // Act
        var response = await _client.GetAsync("/api/v1/agents");

        // Assert
        response.StatusCode.Should().NotBe(HttpStatusCode.Forbidden);
        response.StatusCode.Should().NotBe(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task EnableAgent_Should_ReturnNon403_When_RoleIsOperator()
    {
        // Arrange - First register an agent as Admin
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var registerRequest = new RegisterAgentRequest(
            ExternalAgentId: "test-enable-op-001",
            Name: "Enable Op Agent",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null,
            Blueprint: TestRequestData.ValidBlueprint);

        var registerResponse = await _client.PostAsJsonAsync("/api/v1/agents", registerRequest, JsonOptions);
        var registered = await registerResponse.Content.ReadFromJsonAsync<RegisterAgentResponse>(JsonOptions);

        // Switch to Operator
        HttpClientExtensions.SetRole("Gateway.Operator");

        // Act
        var response = await _client.PostAsync($"/api/v1/agents/{registered!.AgentId}:enable", null);

        // Assert - Operator can call enable (may get 409 if state is invalid, but not 403)
        response.StatusCode.Should().NotBe(HttpStatusCode.Forbidden);
        response.StatusCode.Should().NotBe(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task RegisterAgent_Should_Return403_When_RoleIsExternalAgent()
    {
        // Arrange
        HttpClientExtensions.SetExternalAgent("external-client-001");

        var request = new RegisterAgentRequest(
            ExternalAgentId: "test-external-register-001",
            Name: "External Agent Registration",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null,
            Blueprint: TestRequestData.ValidBlueprint);

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task SubmitActivity_Should_Return401_When_ControlPlaneTokenIsUsed()
    {
        // Arrange - Admin should not access data-plane endpoints (ExternalAgentOnly)
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new SubmitActivityRequest(
            ExternalAgentId: "some-agent",
            ActivityId: "act-001",
            SessionId: null,
            ActivityType: "ToolInvocation",
            OccurredAtUtc: DateTime.UtcNow,
            Actor: new Gateway.Contracts.Dtos.ActorDto("User"),
            Tool: null,
            Attributes: null);

        var httpRequest = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities");
        httpRequest.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString());
        httpRequest.Content = JsonContent.Create(request, options: JsonOptions);

        // Act
        var response = await _client.SendAsync(httpRequest);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task AgentRuntimeReadiness_Should_Return204_When_GatewayCredentialIsValid()
    {
        var apiKey = await RegisterAndGetGatewayCredentialAsync(
            $"runtime-readiness-{Guid.NewGuid():N}");
        _client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", apiKey);

        var response = await _client.GetAsync("/api/v1/agent-runtime/readiness");

        response.StatusCode.Should().Be(HttpStatusCode.NoContent);
    }

    [Fact]
    public async Task AgentRuntimeReadiness_Should_Return401_When_ControlPlaneTokenIsUsed()
    {
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var response = await _client.GetAsync("/api/v1/agent-runtime/readiness");

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task AgentRuntimeReadiness_Should_Return401_When_Unauthenticated()
    {
        HttpClientExtensions.SetUnauthenticated();

        var response = await _client.GetAsync("/api/v1/agent-runtime/readiness");

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task AgentRuntimeReadiness_Should_Return401_When_GatewayCredentialIsInvalid()
    {
        const string correlationId = "invalid-gateway-key-correlation";
        _client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue(
                "Bearer",
                "a365gw_v1_00000000000000000000000000000000.invalid");
        _client.DefaultRequestHeaders.Add("X-Correlation-Id", correlationId);

        var response = await _client.GetAsync("/api/v1/agent-runtime/readiness");

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        response.Content.Headers.ContentType!.MediaType.Should().Be("application/problem+json");
        response.Headers.WwwAuthenticate.Should().ContainSingle();

        var problem = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        var root = problem.RootElement;
        root.GetProperty("status").GetInt32().Should().Be(401);
        root.GetProperty("errorCode").GetString().Should()
            .Be(ErrorCodes.AUTHENTICATION_REQUIRED);
        root.GetProperty("correlationId").GetString().Should().Be(correlationId);
        root.GetProperty("instance").GetString().Should()
            .Be("/api/v1/agent-runtime/readiness");
        root.GetRawText().Should().NotContain("00000000000000000000000000000000");
    }

    [Fact]
    public async Task GetAgent_Should_Return401_When_Unauthenticated()
    {
        // Arrange
        HttpClientExtensions.SetUnauthenticated();

        // Act
        var response = await _client.GetAsync($"/api/v1/agents/{Guid.NewGuid()}");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    private async Task<string> RegisterAndGetGatewayCredentialAsync(
        string externalAgentId)
    {
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: externalAgentId,
            Name: "Runtime readiness agent",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null,
            Blueprint: TestRequestData.ValidBlueprint);

        var response = await _client.PostAsJsonAsync(
            "/api/v1/agents",
            request,
            JsonOptions);
        response.StatusCode.Should().Be(HttpStatusCode.Accepted);

        var registered = await response.Content
            .ReadFromJsonAsync<RegisterAgentResponse>(JsonOptions);

        registered!.GatewayCredential.Should().NotBeNull();
        return registered.GatewayCredential!.ApiKey;
    }
}
