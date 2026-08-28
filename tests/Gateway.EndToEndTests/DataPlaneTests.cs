using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
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
        var apiKey = await SetupActiveAgentAsync("some-agent-001");
        UseGatewayCredential(apiKey);

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
    public async Task SubmitBatch_ShouldReturn400_WhenIdempotencyKeyMissing()
    {
        var apiKey = await SetupActiveAgentAsync("batch-missing-key-agent");
        UseGatewayCredential(apiKey);
        var request = new BatchActivityRequest(
            "batch-missing-key-agent",
            [new BatchActivityItemDto(
                "batch-missing-key",
                null,
                "Chat",
                DateTime.UtcNow.AddMinutes(-1),
                new ActorDto("User"),
                null,
                null)]);

        using var response = await _client.PostAsJsonAsync(
            "/api/v1/agent-activities:batch",
            request,
            JsonOptions);

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await response.Content.ReadAsStringAsync()).Should().Contain("Idempotency-Key");
    }

    [Fact]
    public async Task SubmitActivity_Should_Return202_When_ValidRequestWithMatchingIdentity()
    {
        // Arrange - create an active registration and use its one-time Gateway credential.
        var apiKey = await SetupActiveAgentAsync("data-plane-agent-001");
        UseGatewayCredential(apiKey);

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
    public async Task SubmitActivity_Should_Return403IdentityMismatch_When_CredentialBelongsToAnotherRegistration()
    {
        // Arrange - the request names one registration but authenticates as another.
        await SetupActiveAgentAsync("data-plane-agent-mismatch");
        var apiKey = await SetupActiveAgentAsync("different-caller-agent");
        UseGatewayCredential(apiKey);

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
        var apiKey = await SetupAgentWithStatusAsync(
            "data-plane-agent-disabled",
            AgentStatus.Disabled);
        UseGatewayCredential(apiKey);

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
        var apiKey = await SetupActiveAgentAsync("data-plane-agent-idemp");
        UseGatewayCredential(apiKey);
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
    public async Task SubmitActivity_Should_Return403WithoutEnumeratingBodyAgent_When_AgentDoesNotExist()
    {
        // Arrange
        var apiKey = await SetupActiveAgentAsync("authenticated-agent");
        UseGatewayCredential(apiKey);

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
        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        var content = await response.Content.ReadAsStringAsync();
        using var problem = JsonDocument.Parse(content);
        problem.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("AGENT_IDENTITY_MISMATCH");
    }

    [Fact]
    public async Task SubmitInteraction_Should_Return400_When_IdempotencyKeyMissing()
    {
        // Arrange
        var apiKey = await SetupActiveAgentAsync("some-agent");
        UseGatewayCredential(apiKey);

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

    [Fact]
    public async Task DataPlaneRoutes_ShouldReturn400_WhenIdempotencyKeyIsNotUuidV4()
    {
        var apiKey = await SetupActiveAgentAsync("invalid-idempotency-agent");
        UseGatewayCredential(apiKey);
        const string versionOneUuid = "550e8400-e29b-11d4-a716-446655440000";
        var occurredAtUtc = DateTime.UtcNow.AddMinutes(-1);

        var activity = new SubmitActivityRequest(
            "invalid-idempotency-agent",
            "activity-invalid-key",
            null,
            "Chat",
            occurredAtUtc,
            new ActorDto("User"),
            null,
            null);
        var batch = new BatchActivityRequest(
            "invalid-idempotency-agent",
            [new BatchActivityItemDto(
                "batch-invalid-key",
                null,
                "Chat",
                occurredAtUtc,
                new ActorDto("User"),
                null,
                null)]);
        var interaction = new SubmitInteractionRequest(
            "invalid-idempotency-agent",
            "interaction-invalid-key",
            null,
            occurredAtUtc,
            null,
            new ContentDto("text/plain", "prompt"),
            new ContentDto("text/plain", "response"),
            null,
            null);

        foreach (var (path, body) in new (string Path, object Body)[]
        {
            ("/api/v1/agent-activities", activity),
            ("/api/v1/agent-activities:batch", batch),
            ("/api/v1/ai-interactions", interaction)
        })
        {
            using var httpRequest = new HttpRequestMessage(HttpMethod.Post, path);
            httpRequest.Headers.Add("Idempotency-Key", versionOneUuid);
            httpRequest.Content = JsonContent.Create(body, options: JsonOptions);

            using var response = await _client.SendAsync(httpRequest);

            response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
            (await response.Content.ReadAsStringAsync())
                .Should().Contain("UUID version 4");
        }
    }

    [Fact]
    public async Task SubmitActivity_ShouldReturn409_WhenSameScopedKeyHasDifferentPayload()
    {
        var apiKey = await SetupActiveAgentAsync("activity-conflict-agent");
        UseGatewayCredential(apiKey);
        var idempotencyKey = Guid.NewGuid().ToString("D");
        var occurredAtUtc = DateTime.UtcNow.AddMinutes(-1);
        var first = new SubmitActivityRequest(
            "activity-conflict-agent",
            "activity-first",
            null,
            "Chat",
            occurredAtUtc,
            new ActorDto("User"),
            null,
            null);
        var second = first with { ActivityId = "activity-second" };

        using var firstHttpRequest = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities");
        firstHttpRequest.Headers.Add("Idempotency-Key", idempotencyKey);
        firstHttpRequest.Content = JsonContent.Create(first, options: JsonOptions);
        (await _client.SendAsync(firstHttpRequest)).StatusCode.Should().Be(HttpStatusCode.Accepted);

        using var secondHttpRequest = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities");
        secondHttpRequest.Headers.Add("Idempotency-Key", idempotencyKey);
        secondHttpRequest.Content = JsonContent.Create(second, options: JsonOptions);
        using var response = await _client.SendAsync(secondHttpRequest);

        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
        using var problem = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        problem.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("IDEMPOTENCY_CONFLICT");
    }

    [Fact]
    public async Task SubmitActivity_ShouldAllowSameKeyForDifferentRegistrations()
    {
        var firstApiKey = await SetupActiveAgentAsync("scope-agent-one");
        var secondApiKey = await SetupActiveAgentAsync("scope-agent-two");
        var idempotencyKey = Guid.NewGuid().ToString("D");
        var occurredAtUtc = DateTime.UtcNow.AddMinutes(-1);

        UseGatewayCredential(firstApiKey);
        using var firstRequest = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities");
        firstRequest.Headers.Add("Idempotency-Key", idempotencyKey);
        firstRequest.Content = JsonContent.Create(new SubmitActivityRequest(
            "scope-agent-one",
            "shared-activity",
            null,
            "Chat",
            occurredAtUtc,
            new ActorDto("User"),
            null,
            null), options: JsonOptions);
        using var firstResponse = await _client.SendAsync(firstRequest);

        UseGatewayCredential(secondApiKey);
        using var secondRequest = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities");
        secondRequest.Headers.Add("Idempotency-Key", idempotencyKey);
        secondRequest.Content = JsonContent.Create(new SubmitActivityRequest(
            "scope-agent-two",
            "shared-activity",
            null,
            "Chat",
            occurredAtUtc,
            new ActorDto("User"),
            null,
            null), options: JsonOptions);
        using var secondResponse = await _client.SendAsync(secondRequest);

        firstResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        secondResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
    }

    [Fact]
    public async Task SubmitBatch_ShouldReplayMatchingPayloadAndConflictOnDifferentPayload()
    {
        var apiKey = await SetupActiveAgentAsync("batch-idempotency-agent");
        UseGatewayCredential(apiKey);
        var idempotencyKey = Guid.NewGuid().ToString("D");
        var occurredAtUtc = DateTime.UtcNow.AddMinutes(-1);
        var request = new BatchActivityRequest(
            "batch-idempotency-agent",
            [new BatchActivityItemDto(
                "batch-activity-one",
                null,
                "Chat",
                occurredAtUtc,
                new ActorDto("User"),
                null,
                null)]);

        async Task<HttpResponseMessage> SendAsync(BatchActivityRequest body)
        {
            var message = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities:batch");
            message.Headers.Add("Idempotency-Key", idempotencyKey);
            message.Content = JsonContent.Create(body, options: JsonOptions);
            return await _client.SendAsync(message);
        }

        using var firstResponse = await SendAsync(request);
        var firstReceipt = await firstResponse.Content.ReadFromJsonAsync<BatchActivityResponse>(JsonOptions);
        using var replayResponse = await SendAsync(request);
        var replayReceipt = await replayResponse.Content.ReadFromJsonAsync<BatchActivityResponse>(JsonOptions);
        using var conflictResponse = await SendAsync(request with
        {
            Activities = [request.Activities[0] with { ActivityId = "batch-activity-two" }]
        });

        firstResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        replayResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        replayReceipt.Should().BeEquivalentTo(firstReceipt);
        conflictResponse.StatusCode.Should().Be(HttpStatusCode.Conflict);
        using var problem = JsonDocument.Parse(await conflictResponse.Content.ReadAsStringAsync());
        problem.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("IDEMPOTENCY_CONFLICT");
    }

    [Fact]
    public async Task SubmitBatch_ShouldReturn400_ForStructuralBatchValidationFailure()
    {
        var apiKey = await SetupActiveAgentAsync("batch-validation-agent");
        UseGatewayCredential(apiKey);
        var request = new BatchActivityRequest(
            "batch-validation-agent",
            [new BatchActivityItemDto(
                "activity-invalid-enum",
                null,
                "not-an-activity-type",
                DateTime.UtcNow.AddMinutes(-1),
                new ActorDto("User"),
                null,
                null)]);
        using var message = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities:batch");
        message.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString("D"));
        message.Content = JsonContent.Create(request, options: JsonOptions);

        using var response = await _client.SendAsync(message);

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await response.Content.ReadAsStringAsync()).Should().Contain("ActivityType");
    }

    [Fact]
    public async Task SubmitBatch_ShouldReturn413_WhenRequestExceedsOneMegabyte()
    {
        var apiKey = await SetupActiveAgentAsync("batch-size-agent");
        UseGatewayCredential(apiKey);
        var request = new BatchActivityRequest(
            "batch-size-agent",
            [new BatchActivityItemDto(
                "activity-large",
                null,
                "Chat",
                DateTime.UtcNow.AddMinutes(-1),
                new ActorDto("User"),
                null,
                new Dictionary<string, string>
                {
                    ["payload"] = new string('x', 1_100_000)
                })]);
        using var message = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities:batch");
        message.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString("D"));
        message.Content = JsonContent.Create(request, options: JsonOptions);

        using var response = await _client.SendAsync(message);

        response.StatusCode.Should().Be(HttpStatusCode.RequestEntityTooLarge);
    }

    [Fact]
    public async Task SubmitInteraction_ShouldReturn413_WhenRequestExceedsSixtyFourKilobytes()
    {
        var apiKey = await SetupActiveAgentAsync("interaction-size-agent");
        UseGatewayCredential(apiKey);
        var request = new SubmitInteractionRequest(
            "interaction-size-agent",
            "interaction-large",
            null,
            DateTime.UtcNow.AddMinutes(-1),
            null,
            new ContentDto("text/plain", new string('x', 70_000)),
            new ContentDto("text/plain", "response"),
            null,
            null);
        using var message = new HttpRequestMessage(HttpMethod.Post, "/api/v1/ai-interactions");
        message.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString("D"));
        message.Content = JsonContent.Create(request, options: JsonOptions);

        using var response = await _client.SendAsync(message);

        response.StatusCode.Should().Be(HttpStatusCode.RequestEntityTooLarge);
    }

    [Fact]
    public async Task SubmitActivity_ShouldReturn413_WhenRequestExceedsSixtyFourKilobytes()
    {
        var apiKey = await SetupActiveAgentAsync("activity-size-agent");
        UseGatewayCredential(apiKey);
        var request = new SubmitActivityRequest(
            "activity-size-agent",
            "activity-large",
            null,
            "Chat",
            DateTime.UtcNow.AddMinutes(-1),
            new ActorDto("User"),
            null,
            new Dictionary<string, string>
            {
                ["payload"] = new string('x', 70_000)
            });
        using var message = new HttpRequestMessage(HttpMethod.Post, "/api/v1/agent-activities");
        message.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString("D"));
        message.Content = JsonContent.Create(request, options: JsonOptions);

        using var response = await _client.SendAsync(message);

        response.StatusCode.Should().Be(HttpStatusCode.RequestEntityTooLarge);
    }

    /// <summary>
    /// Helper method: registers an agent, sets its status to Active, and issues
    /// a per-registration Gateway credential.
    /// </summary>
    private async Task<string> SetupActiveAgentAsync(string externalAgentId)
    {
        return await SetupAgentWithStatusAsync(externalAgentId, AgentStatus.Active);
    }

    /// <summary>
    /// Helper method: registers an agent and issues its Gateway credential.
    /// </summary>
    private async Task<string> SetupAgentWithStatusAsync(
        string externalAgentId,
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
        var credentialService = scope.ServiceProvider
            .GetRequiredService<IAgentIngressCredentialService>();
        var issuedCredential = credentialService.Issue(
            agent.Id,
            TestAuthHandler.DefaultObjectId,
            DateTime.UtcNow);
        await dbContext.SaveChangesAsync();

        return issuedCredential.ApiKey;
    }

    private void UseGatewayCredential(string apiKey)
    {
        _client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", apiKey);
    }
}
