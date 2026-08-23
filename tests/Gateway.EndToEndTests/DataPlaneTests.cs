using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.Domain.Enums;
using Gateway.Domain.ValueObjects;
using Gateway.EndToEndTests.Fixtures;
using Gateway.Infrastructure.Persistence;
using FluentAssertions;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.EndToEndTests;

[Collection(EndToEndTestCollection.Name)]
public class DataPlaneTests : IDisposable
{
    private readonly GatewayWebApplicationFactory _factory;
    private readonly HttpClient _client;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public DataPlaneTests(GatewayWebApplicationFactory factory)
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
    public async Task SubmitActivity_Should_Return400_When_IdempotencyKeyMissing()
    {
        // Arrange
        HttpClientExtensions.SetExternalAgent("client-no-idemp-001");

        var request = new SubmitActivityRequest(
            ExternalAgentId: "some-agent-001",
            ActivityId: "act-001",
            SessionId: null,
            ActivityType: "ToolInvocation",
            OccurredAtUtc: DateTime.UtcNow,
            Actor: new ActorDto("User"),
            Tool: null,
            Attributes: null);

        // Act - POST without Idempotency-Key header
        var response = await _client.PostAsJsonAsync("/api/v1/agent-activities", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);

        var content = await response.Content.ReadAsStringAsync();
        content.Should().Contain("Idempotency-Key");
    }

    [Fact]
    public async Task SubmitActivity_Should_Return202_When_ValidRequestWithMatchingIdentity()
    {
        // Arrange - Create an active agent with matching ExternalClientId
        var agentId = await SetupActiveAgentAsync("data-plane-agent-001", "data-plane-client-001");

        HttpClientExtensions.SetExternalAgent("data-plane-client-001");

        var request = new SubmitActivityRequest(
            ExternalAgentId: "data-plane-agent-001",
            ActivityId: "activity-001",
            SessionId: "session-001",
            ActivityType: "ToolInvocation",
            OccurredAtUtc: DateTime.UtcNow,
            Actor: new ActorDto("User"),
            Tool: null,
            Attributes: null);

        var httpRequest = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities");
        httpRequest.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString());
        httpRequest.Content = JsonContent.Create(request, options: JsonOptions);

        // Act
        var response = await _client.SendAsync(httpRequest);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Accepted);

        var receipt = await response.Content.ReadFromJsonAsync<ActivityReceiptDto>(JsonOptions);
        receipt.Should().NotBeNull();
        receipt!.ActivityId.Should().Be("activity-001");
        receipt.Status.Should().Be("Accepted");
        receipt.ReceiptId.Should().NotBeEmpty();
    }

    [Fact]
    public async Task SubmitActivity_Should_Return403IdentityMismatch_When_ClientIdDoesNotMatch()
    {
        // Arrange - Agent is registered with clientId "correct-client" but caller has "wrong-client"
        var agentId = await SetupActiveAgentAsync("data-plane-agent-mismatch", "correct-client-id");

        HttpClientExtensions.SetExternalAgent("wrong-client-id");

        var request = new SubmitActivityRequest(
            ExternalAgentId: "data-plane-agent-mismatch",
            ActivityId: "activity-mismatch-001",
            SessionId: null,
            ActivityType: "ToolInvocation",
            OccurredAtUtc: DateTime.UtcNow,
            Actor: new ActorDto("User"),
            Tool: null,
            Attributes: null);

        var httpRequest = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities");
        httpRequest.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString());
        httpRequest.Content = JsonContent.Create(request, options: JsonOptions);

        // Act
        var response = await _client.SendAsync(httpRequest);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);

        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);
        problemDetails.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("AGENT_IDENTITY_MISMATCH");
    }

    [Fact]
    public async Task SubmitActivity_Should_Return403AgentDisabled_When_AgentIsNotActive()
    {
        // Arrange - Agent exists but is in Draft status (not Active)
        var agentId = await SetupAgentWithStatusAsync(
            "data-plane-agent-disabled",
            "disabled-client-001",
            AgentStatus.Disabled);

        HttpClientExtensions.SetExternalAgent("disabled-client-001");

        var request = new SubmitActivityRequest(
            ExternalAgentId: "data-plane-agent-disabled",
            ActivityId: "activity-disabled-001",
            SessionId: null,
            ActivityType: "ToolInvocation",
            OccurredAtUtc: DateTime.UtcNow,
            Actor: new ActorDto("User"),
            Tool: null,
            Attributes: null);

        var httpRequest = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities");
        httpRequest.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString());
        httpRequest.Content = JsonContent.Create(request, options: JsonOptions);

        // Act
        var response = await _client.SendAsync(httpRequest);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);

        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);
        problemDetails.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("AGENT_DISABLED");
    }

    [Fact]
    public async Task SubmitActivity_Should_ReturnCachedResponse_When_DuplicateIdempotencyKey()
    {
        // Arrange
        var agentId = await SetupActiveAgentAsync("data-plane-agent-idemp", "idemp-client-001");

        HttpClientExtensions.SetExternalAgent("idemp-client-001");
        var idempotencyKey = Guid.NewGuid().ToString();

        var request = new SubmitActivityRequest(
            ExternalAgentId: "data-plane-agent-idemp",
            ActivityId: "activity-idemp-001",
            SessionId: null,
            ActivityType: "ToolInvocation",
            OccurredAtUtc: DateTime.UtcNow,
            Actor: new ActorDto("User"),
            Tool: null,
            Attributes: null);

        // First request
        var firstHttpRequest = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities");
        firstHttpRequest.Headers.Add("Idempotency-Key", idempotencyKey);
        firstHttpRequest.Content = JsonContent.Create(request, options: JsonOptions);

        var firstResponse = await _client.SendAsync(firstHttpRequest);
        firstResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        var firstReceipt = await firstResponse.Content.ReadFromJsonAsync<ActivityReceiptDto>(JsonOptions);

        // Act - Second request with same idempotency key
        var secondHttpRequest = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities");
        secondHttpRequest.Headers.Add("Idempotency-Key", idempotencyKey);
        secondHttpRequest.Content = JsonContent.Create(request, options: JsonOptions);

        var secondResponse = await _client.SendAsync(secondHttpRequest);

        // Assert - Should return the cached response
        secondResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        var secondReceipt = await secondResponse.Content.ReadFromJsonAsync<ActivityReceiptDto>(JsonOptions);
        secondReceipt.Should().NotBeNull();
        secondReceipt!.ReceiptId.Should().Be(firstReceipt!.ReceiptId);
        secondReceipt.ActivityId.Should().Be(firstReceipt.ActivityId);
    }

    [Fact]
    public async Task SubmitActivity_Should_Return404_When_AgentDoesNotExist()
    {
        // Arrange
        HttpClientExtensions.SetExternalAgent("nonexistent-client-001");

        var request = new SubmitActivityRequest(
            ExternalAgentId: "nonexistent-agent-xyz",
            ActivityId: "activity-notfound-001",
            SessionId: null,
            ActivityType: "ToolInvocation",
            OccurredAtUtc: DateTime.UtcNow,
            Actor: new ActorDto("User"),
            Tool: null,
            Attributes: null);

        var httpRequest = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities");
        httpRequest.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString());
        httpRequest.Content = JsonContent.Create(request, options: JsonOptions);

        // Act
        var response = await _client.SendAsync(httpRequest);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task SubmitInteraction_Should_Return400_When_IdempotencyKeyMissing()
    {
        // Arrange
        HttpClientExtensions.SetExternalAgent("interaction-client-001");

        var request = new SubmitInteractionRequest(
            ExternalAgentId: "some-agent",
            InteractionId: "int-001",
            SessionId: null,
            OccurredAtUtc: DateTime.UtcNow,
            UserContext: null,
            Prompt: new ContentDto("text/plain", "Hello"),
            Response: new ContentDto("text/plain", "Hi there"),
            Model: null,
            Metadata: null);

        // Act - POST without Idempotency-Key header
        var response = await _client.PostAsJsonAsync("/api/v1/ai-interactions", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);

        var content = await response.Content.ReadAsStringAsync();
        content.Should().Contain("Idempotency-Key");
    }

    /// <summary>
    /// Helper method: registers an agent and directly sets its status to Active
    /// and assigns the ExternalClientId in the database.
    /// </summary>
    private async Task<Guid> SetupActiveAgentAsync(string externalAgentId, string externalClientId)
    {
        return await SetupAgentWithStatusAsync(externalAgentId, externalClientId, AgentStatus.Active);
    }

    /// <summary>
    /// Helper method: registers an agent and directly sets its status and ExternalClientId.
    /// </summary>
    private async Task<Guid> SetupAgentWithStatusAsync(
        string externalAgentId,
        string externalClientId,
        AgentStatus status)
    {
        using var scope = _factory.Services.CreateScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();

        var agent = new Gateway.Domain.Entities.AgentRegistration
        {
            Id = Guid.NewGuid(),
            ExternalAgentId = new ExternalAgentId(externalAgentId),
            Name = $"Test Agent {externalAgentId}",
            Description = "Auto-created for E2E data-plane testing",
            OwnerObjectId = "owner-oid-001",
            Environment = AgentEnvironment.Development,
            Status = status,
            ExternalClientId = externalClientId,
            CreatedAtUtc = DateTime.UtcNow,
            UpdatedAtUtc = DateTime.UtcNow,
            CreatedByObjectId = TestAuthHandler.DefaultObjectId,
            UpdatedByObjectId = TestAuthHandler.DefaultObjectId
        };

        var features = new Gateway.Domain.Entities.AgentFeatureConfiguration
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            ObservabilityMode = ObservabilityMode.GatewayOnly,
            PurviewEnabled = false,
            PurviewMode = null,
            UpdatedAtUtc = DateTime.UtcNow
        };

        agent.FeatureConfiguration = features;

        dbContext.AgentRegistrations.Add(agent);
        await dbContext.SaveChangesAsync();

        return agent.Id;
    }
}
