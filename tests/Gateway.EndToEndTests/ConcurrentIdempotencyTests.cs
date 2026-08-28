using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.EndToEndTests.Fixtures;
using Gateway.Infrastructure.Persistence;
using Microsoft.Extensions.DependencyInjection;
using NSubstitute;

namespace Gateway.EndToEndTests;

[Collection(EndToEndTestCollection.Name)]
public sealed class ConcurrentIdempotencyTests : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private readonly GatewayWebApplicationFactory _factory;
    private readonly List<HttpClient> _clients = [];

    public ConcurrentIdempotencyTests(GatewayWebApplicationFactory factory)
    {
        _factory = factory;
    }

    public void Dispose()
    {
        foreach (var client in _clients)
            client.Dispose();

        TestAuthHandler.Reset();
    }

    [Fact]
    public async Task ConcurrentMatchingInteractionRequests_ShouldExecuteBlobAndPurviewOnceAndReplay()
    {
        var registration = await CreateActiveRegistrationAsync(
            $"concurrent-replay-{Guid.NewGuid():N}",
            purviewEnabled: true);
        var idempotencyKey = Guid.NewGuid().ToString("D");
        var request = CreateInteractionRequest(
            registration.ExternalAgentId,
            "interaction-replay",
            "blocked-prompt");
        var storeEntered = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseStore = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var storeCalls = 0;

        ConfigureBlockingContentStore(
            "blocked-prompt",
            storeEntered,
            releaseStore,
            () => Interlocked.Increment(ref storeCalls));
        ConfigureAllowedPurview();

        var first = SendInteractionAsync(
            CreateGatewayClient(registration.ApiKey),
            idempotencyKey,
            request);
        await storeEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        var second = SendInteractionAsync(
            CreateGatewayClient(registration.ApiKey),
            idempotencyKey,
            request);
        await Task.Yield();
        releaseStore.TrySetResult(true);

        using var firstResponse = await first.WaitAsync(TimeSpan.FromSeconds(10));
        using var secondResponse = await second.WaitAsync(TimeSpan.FromSeconds(10));
        var firstReceipt = await firstResponse.Content
            .ReadFromJsonAsync<InteractionReceiptDto>(JsonOptions);
        var secondReceipt = await secondResponse.Content
            .ReadFromJsonAsync<InteractionReceiptDto>(JsonOptions);

        firstResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        secondResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        secondReceipt.Should().BeEquivalentTo(firstReceipt);
        storeCalls.Should().Be(1);
        await _factory.MockPurviewClient.Received(1).EvaluateInteractionAsync(
            Arg.Any<PurviewInteraction>(),
            Arg.Any<CancellationToken>());
        AssertPersistedCounts(registration.AgentRegistrationId, 1, 1);
    }

    [Fact]
    public async Task ConcurrentDifferentInteractionPayload_ShouldConflictBeforeBlobOrPurviewSideEffects()
    {
        var registration = await CreateActiveRegistrationAsync(
            $"concurrent-conflict-{Guid.NewGuid():N}",
            purviewEnabled: true);
        var idempotencyKey = Guid.NewGuid().ToString("D");
        var firstRequest = CreateInteractionRequest(
            registration.ExternalAgentId,
            "interaction-conflict",
            "blocked-prompt");
        var secondRequest = firstRequest with
        {
            Prompt = new ContentDto("text/plain", "different-prompt")
        };
        var storeEntered = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseStore = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var storeCalls = 0;

        ConfigureBlockingContentStore(
            "blocked-prompt",
            storeEntered,
            releaseStore,
            () => Interlocked.Increment(ref storeCalls));
        ConfigureAllowedPurview();

        var first = SendInteractionAsync(
            CreateGatewayClient(registration.ApiKey),
            idempotencyKey,
            firstRequest);
        await storeEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        var second = SendInteractionAsync(
            CreateGatewayClient(registration.ApiKey),
            idempotencyKey,
            secondRequest);
        await Task.Yield();
        releaseStore.TrySetResult(true);

        using var firstResponse = await first.WaitAsync(TimeSpan.FromSeconds(10));
        using var secondResponse = await second.WaitAsync(TimeSpan.FromSeconds(10));

        firstResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        secondResponse.StatusCode.Should().Be(HttpStatusCode.Conflict);
        using var problem = JsonDocument.Parse(
            await secondResponse.Content.ReadAsStringAsync());
        problem.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("IDEMPOTENCY_CONFLICT");
        storeCalls.Should().Be(1);
        await _factory.MockPurviewClient.Received(1).EvaluateInteractionAsync(
            Arg.Any<PurviewInteraction>(),
            Arg.Any<CancellationToken>());
        AssertPersistedCounts(registration.AgentRegistrationId, 1, 1);
    }

    [Fact]
    public async Task DifferentRegistrationOrKeyScopes_ShouldProceedIndependentlyWithoutCrossReplay()
    {
        var firstRegistration = await CreateActiveRegistrationAsync(
            $"scope-first-{Guid.NewGuid():N}",
            purviewEnabled: false);
        var secondRegistration = await CreateActiveRegistrationAsync(
            $"scope-second-{Guid.NewGuid():N}",
            purviewEnabled: false);
        var sharedKey = Guid.NewGuid().ToString("D");
        var independentKey = Guid.NewGuid().ToString("D");
        var storeEntered = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseStore = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var storeCalls = 0;

        ConfigureBlockingContentStore(
            "blocked-prompt",
            storeEntered,
            releaseStore,
            () => Interlocked.Increment(ref storeCalls));

        var blocked = SendInteractionAsync(
            CreateGatewayClient(firstRegistration.ApiKey),
            sharedKey,
            CreateInteractionRequest(
                firstRegistration.ExternalAgentId,
                "interaction-blocked",
                "blocked-prompt"));
        await storeEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        var otherRegistration = SendInteractionAsync(
            CreateGatewayClient(secondRegistration.ApiKey),
            sharedKey,
            CreateInteractionRequest(
                secondRegistration.ExternalAgentId,
                "interaction-other-registration",
                "independent-registration-prompt"));
        var otherKey = SendInteractionAsync(
            CreateGatewayClient(firstRegistration.ApiKey),
            independentKey,
            CreateInteractionRequest(
                firstRegistration.ExternalAgentId,
                "interaction-other-key",
                "independent-key-prompt"));

        var independentRequests = Task.WhenAll(otherRegistration, otherKey);
        var independentCompleted = await Task.WhenAny(
            independentRequests,
            Task.Delay(TimeSpan.FromSeconds(2))) == independentRequests;
        releaseStore.TrySetResult(true);

        using var blockedResponse = await blocked.WaitAsync(TimeSpan.FromSeconds(10));
        var independentResponses = await independentRequests.WaitAsync(TimeSpan.FromSeconds(10));
        using var otherRegistrationResponse = independentResponses[0];
        using var otherKeyResponse = independentResponses[1];
        var blockedReceipt = await blockedResponse.Content
            .ReadFromJsonAsync<InteractionReceiptDto>(JsonOptions);
        var otherRegistrationReceipt = await otherRegistrationResponse.Content
            .ReadFromJsonAsync<InteractionReceiptDto>(JsonOptions);
        var otherKeyReceipt = await otherKeyResponse.Content
            .ReadFromJsonAsync<InteractionReceiptDto>(JsonOptions);

        independentCompleted.Should().BeTrue();
        blockedResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        otherRegistrationResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        otherKeyResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        storeCalls.Should().Be(3);
        new[]
        {
            blockedReceipt!.ReceiptId,
            otherRegistrationReceipt!.ReceiptId,
            otherKeyReceipt!.ReceiptId
        }.Should().OnlyHaveUniqueItems();
        AssertPersistedCounts(firstRegistration.AgentRegistrationId, 2, 2);
        AssertPersistedCounts(secondRegistration.AgentRegistrationId, 1, 1);
    }

    private void ConfigureBlockingContentStore(
        string blockedPrompt,
        TaskCompletionSource<bool> storeEntered,
        TaskCompletionSource<bool> releaseStore,
        Action recordCall)
    {
        _factory.MockContentStore.ClearReceivedCalls();
        _factory.MockContentStore.StoreAsync(
                Arg.Any<Guid>(),
                Arg.Any<Guid>(),
                Arg.Any<string>(),
                Arg.Any<string>(),
                Arg.Any<string>(),
                Arg.Any<string>(),
                Arg.Any<CancellationToken>())
            .Returns(async callInfo =>
            {
                recordCall();
                if (string.Equals(
                        callInfo.ArgAt<string>(2),
                        blockedPrompt,
                        StringComparison.Ordinal))
                {
                    storeEntered.TrySetResult(true);
                    await releaseStore.Task.WaitAsync(
                        callInfo.ArgAt<CancellationToken>(6));
                }

                return $"https://content.invalid/{Guid.NewGuid():N}";
            });
    }

    private void ConfigureAllowedPurview()
    {
        _factory.MockPurviewClient.ClearReceivedCalls();
        _factory.MockPurviewClient.EvaluateInteractionAsync(
                Arg.Any<PurviewInteraction>(),
                Arg.Any<CancellationToken>())
            .Returns(new PurviewEvaluationResult(
                true,
                PurviewDecisionType.Allowed,
                null,
                null));
    }

    private HttpClient CreateGatewayClient(string apiKey)
    {
        var client = _factory.CreateAuthenticatedClient();
        client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", apiKey);
        _clients.Add(client);
        return client;
    }

    private void AssertPersistedCounts(
        Guid agentRegistrationId,
        int expectedInteractions,
        int expectedIdempotencyRecords)
    {
        using var scope = _factory.Services.CreateScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        dbContext.AiInteractionRecords.Count(record =>
                record.AgentRegistrationId == agentRegistrationId)
            .Should().Be(expectedInteractions);
        dbContext.IdempotencyRecords.Count(record =>
                record.AgentRegistrationId == agentRegistrationId &&
                record.Endpoint == "/api/v1/ai-interactions")
            .Should().Be(expectedIdempotencyRecords);
    }

    private static async Task<HttpResponseMessage> SendInteractionAsync(
        HttpClient client,
        string idempotencyKey,
        SubmitInteractionRequest request)
    {
        using var message = new HttpRequestMessage(
            HttpMethod.Post,
            "/api/v1/ai-interactions");
        message.Headers.Add("Idempotency-Key", idempotencyKey);
        message.Content = JsonContent.Create(request, options: JsonOptions);
        return await client.SendAsync(message);
    }

    private async Task<TestRegistration> CreateActiveRegistrationAsync(
        string externalAgentId,
        bool purviewEnabled)
    {
        using var scope = _factory.Services.CreateScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        var agent = new AgentRegistration
        {
            Id = Guid.NewGuid(),
            ExternalAgentId = new ExternalAgentId(externalAgentId),
            Name = $"Concurrent test {externalAgentId}",
            Description = "Concurrent idempotency test registration",
            OwnerObjectId = "owner-oid-concurrency",
            Environment = AgentEnvironment.Development,
            Status = AgentStatus.Active,
            Agent365AgentId = Guid.NewGuid().ToString("D"),
            BlueprintId = Guid.NewGuid().ToString("D"),
            CreatedAtUtc = DateTime.UtcNow,
            UpdatedAtUtc = DateTime.UtcNow,
            CreatedByObjectId = TestAuthHandler.DefaultObjectId,
            UpdatedByObjectId = TestAuthHandler.DefaultObjectId
        };
        agent.FeatureConfiguration = new AgentFeatureConfiguration
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            ObservabilityMode = ObservabilityMode.GatewayOnly,
            PurviewEnabled = purviewEnabled,
            PurviewMode = purviewEnabled ? PurviewMode.AuditOnly : null,
            UpdatedAtUtc = DateTime.UtcNow
        };

        dbContext.AgentRegistrations.Add(agent);
        var credentialService = scope.ServiceProvider
            .GetRequiredService<IAgentIngressCredentialService>();
        var credential = credentialService.Issue(
            agent.Id,
            TestAuthHandler.DefaultObjectId,
            DateTime.UtcNow);
        await dbContext.SaveChangesAsync();

        return new TestRegistration(agent.Id, externalAgentId, credential.ApiKey);
    }

    private static SubmitInteractionRequest CreateInteractionRequest(
        string externalAgentId,
        string interactionId,
        string prompt) =>
        new(
            externalAgentId,
            interactionId,
            "concurrent-session",
            DateTime.UtcNow.AddMinutes(-1),
            new UserContextDto(Guid.NewGuid().ToString("D")),
            new ContentDto("text/plain", prompt),
            new ContentDto("text/plain", "safe-response"),
            null,
            null);

    private sealed record TestRegistration(
        Guid AgentRegistrationId,
        string ExternalAgentId,
        string ApiKey);
}
