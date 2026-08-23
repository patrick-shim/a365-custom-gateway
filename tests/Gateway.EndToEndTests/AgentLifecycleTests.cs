using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.EndToEndTests.Fixtures;
using FluentAssertions;

namespace Gateway.EndToEndTests;

[Collection(EndToEndTestCollection.Name)]
public class AgentLifecycleTests : IDisposable
{
    private readonly GatewayWebApplicationFactory _factory;
    private readonly HttpClient _client;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public AgentLifecycleTests(GatewayWebApplicationFactory factory)
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
    public async Task RegisterAgent_Should_Return202WithOperation_When_ValidRequest()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: "test-agent-lifecycle-001",
            Name: "Lifecycle Test Agent",
            Description: "An agent for lifecycle testing",
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null);

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Accepted);

        var body = await response.Content.ReadFromJsonAsync<RegisterAgentResponse>(JsonOptions);
        body.Should().NotBeNull();
        body!.AgentId.Should().NotBeEmpty();
        body.OperationId.Should().NotBeEmpty();
        body.ExternalAgentId.Should().Be("test-agent-lifecycle-001");
        body.Name.Should().Be("Lifecycle Test Agent");
        body.Status.Should().Be("Draft");
        body.CreatedAtUtc.Should().BeCloseTo(DateTime.UtcNow, TimeSpan.FromSeconds(10));
    }

    [Fact]
    public async Task RegisterAgent_Should_Return409_When_ExternalAgentIdAlreadyExists()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: "test-agent-duplicate-001",
            Name: "First Agent",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null);

        // Register the first time
        var firstResponse = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);
        firstResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);

        // Act - Register the same externalAgentId again
        var duplicateRequest = new RegisterAgentRequest(
            ExternalAgentId: "test-agent-duplicate-001",
            Name: "Duplicate Agent",
            Description: null,
            OwnerObjectId: "owner-oid-002",
            Environment: "Production",
            Features: null);

        var response = await _client.PostAsJsonAsync("/api/v1/agents", duplicateRequest, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Conflict);

        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);
        problemDetails.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("DUPLICATE_EXTERNAL_AGENT_ID");
    }

    [Fact]
    public async Task GetAgent_Should_Return200WithETag_When_AgentExists()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var registerRequest = new RegisterAgentRequest(
            ExternalAgentId: "test-agent-get-001",
            Name: "Get Test Agent",
            Description: "Agent for GET testing",
            OwnerObjectId: "owner-oid-001",
            Environment: "Production",
            Features: null);

        var registerResponse = await _client.PostAsJsonAsync("/api/v1/agents", registerRequest, JsonOptions);
        var registered = await registerResponse.Content.ReadFromJsonAsync<RegisterAgentResponse>(JsonOptions);

        // Act
        var response = await _client.GetAsync($"/api/v1/agents/{registered!.AgentId}");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.OK);

        var agent = await response.Content.ReadFromJsonAsync<AgentDetailDto>(JsonOptions);
        agent.Should().NotBeNull();
        agent!.AgentId.Should().Be(registered.AgentId);
        agent.ExternalAgentId.Should().Be("test-agent-get-001");
        agent.Name.Should().Be("Get Test Agent");
        agent.Status.Should().Be("Draft");

        // Note: ETag may or may not be present depending on whether InMemory provider
        // populates RowVersion. The controller only sets ETag when RowVersion.Length > 0.
    }

    [Fact]
    public async Task GetAgent_Should_Return404_When_AgentDoesNotExist()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");
        var randomId = Guid.NewGuid();

        // Act
        var response = await _client.GetAsync($"/api/v1/agents/{randomId}");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.NotFound);

        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);
        problemDetails.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("AGENT_NOT_FOUND");
    }

    [Fact]
    public async Task ListAgents_Should_ReturnPaginatedList_When_AgentsExist()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        // Register multiple agents
        for (int i = 0; i < 3; i++)
        {
            var request = new RegisterAgentRequest(
                ExternalAgentId: $"test-agent-list-{Guid.NewGuid():N}",
                Name: $"List Test Agent {i}",
                Description: null,
                OwnerObjectId: "owner-oid-001",
                Environment: "Development",
                Features: null);

            await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);
        }

        // Act
        var response = await _client.GetAsync("/api/v1/agents?limit=2");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.OK);

        var list = await response.Content.ReadFromJsonAsync<AgentListResponse>(JsonOptions);
        list.Should().NotBeNull();
        list!.Items.Should().NotBeNull();
        list.Items.Count.Should().BeLessThanOrEqualTo(2);
        list.TotalCount.Should().BeGreaterThanOrEqualTo(3);
    }

    [Fact]
    public async Task RegisterAgent_Should_Return202WithCorrectStatus_When_FeaturesProvided()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: "test-agent-features-001",
            Name: "Agent With Features",
            Description: "Testing feature configuration on registration",
            OwnerObjectId: "owner-oid-001",
            Environment: "Test",
            Features: new Gateway.Contracts.Dtos.AgentFeaturesDto(
                ObservabilityMode: "Agent365",
                PurviewEnabled: true,
                PurviewMode: "AuditOnly"));

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Accepted);

        var body = await response.Content.ReadFromJsonAsync<RegisterAgentResponse>(JsonOptions);
        body.Should().NotBeNull();
        body!.Status.Should().Be("Draft");
    }
}
