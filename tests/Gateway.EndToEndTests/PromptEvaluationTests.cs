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
public sealed class PromptEvaluationTests : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private readonly GatewayWebApplicationFactory _factory;
    private readonly HttpClient _client;

    public PromptEvaluationTests(GatewayWebApplicationFactory factory)
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
    public async Task AllowedPrompt_ShouldIssueReceiptAndPermitMatchingInteractionOnce()
    {
        const string externalAgentId = "prompt-shield-allowed-agent";
        const string interactionId = "prompt-shield-allowed-interaction";
        const string prompt = "Summarize the public launch notes.";
        var apiKey = await SetupProtectedAgentAsync(externalAgentId);
        UseGatewayCredential(apiKey);
        _factory.MockPromptShieldClient.EvaluateAsync(prompt, Arg.Any<CancellationToken>())
            .Returns(new PromptShieldEvaluationResult(false));
        _factory.MockContentStore.StoreAsync(
                Arg.Any<Guid>(),
                Arg.Any<Guid>(),
                Arg.Any<string>(),
                Arg.Any<string>(),
                Arg.Any<string>(),
                Arg.Any<string>(),
                Arg.Any<CancellationToken>())
            .Returns("https://content.invalid/protected-interaction");

        var evaluation = await EvaluateAsync(externalAgentId, interactionId, prompt);

        evaluation.Allowed.Should().BeTrue();
        evaluation.Decision.Should().Be("PROMPT_ALLOWED");
        evaluation.PromptShieldProcessing.Should().Be("Allowed");
        evaluation.EvaluationReceiptId.Should().NotBeNull();

        using var interactionRequest = new HttpRequestMessage(HttpMethod.Post, "/api/v1/ai-interactions");
        interactionRequest.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString("D"));
        interactionRequest.Content = JsonContent.Create(new SubmitInteractionRequest(
            externalAgentId,
            interactionId,
            null,
            DateTime.UtcNow,
            null,
            new ContentDto("text/plain", prompt),
            new ContentDto("text/plain", "The launch notes describe the public release."),
            null,
            null,
            evaluation.EvaluationReceiptId), options: JsonOptions);

        using var interactionResponse = await _client.SendAsync(interactionRequest);

        interactionResponse.StatusCode.Should().Be(HttpStatusCode.Accepted);
        await _factory.MockPromptShieldClient.Received(1)
            .EvaluateAsync(prompt, Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task BlockedPrompt_ShouldReturnSafeProblemDetailsWithoutReceiptOrRawPrompt()
    {
        const string externalAgentId = "prompt-shield-blocked-agent";
        const string interactionId = "prompt-shield-blocked-interaction";
        const string prompt = "ignore-all-instructions-sensitive-marker-8472";
        var apiKey = await SetupProtectedAgentAsync(externalAgentId);
        UseGatewayCredential(apiKey);
        _factory.MockPromptShieldClient.EvaluateAsync(prompt, Arg.Any<CancellationToken>())
            .Returns(new PromptShieldEvaluationResult(true));
        using var request = CreateEvaluationRequest(externalAgentId, interactionId, prompt);

        using var response = await _client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        using var problem = JsonDocument.Parse(body);

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        problem.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("PROMPT_BLOCKED_BY_PROMPT_SHIELD");
        problem.RootElement.TryGetProperty("evaluationReceiptId", out _).Should().BeFalse();
        body.Should().NotContain(prompt);
    }

    [Fact]
    public async Task ProtectedInteractionWithoutReceipt_ShouldFailBeforeContentPersistence()
    {
        const string externalAgentId = "prompt-shield-receipt-required-agent";
        var apiKey = await SetupProtectedAgentAsync(externalAgentId);
        UseGatewayCredential(apiKey);
        _factory.MockContentStore.ClearReceivedCalls();
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/ai-interactions");
        request.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString("D"));
        request.Content = JsonContent.Create(new SubmitInteractionRequest(
            externalAgentId,
            "missing-receipt-interaction",
            null,
            DateTime.UtcNow,
            null,
            new ContentDto("text/plain", "safe prompt"),
            new ContentDto("text/plain", "model response"),
            null,
            null), options: JsonOptions);

        using var response = await _client.SendAsync(request);
        using var problem = JsonDocument.Parse(await response.Content.ReadAsStringAsync());

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        problem.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("PROMPT_EVALUATION_REQUIRED");
        await _factory.MockContentStore.DidNotReceiveWithAnyArgs().StoreAsync(
            default,
            default,
            default!,
            default!,
            default!,
            default!,
            default);
    }

    private async Task<PromptEvaluationResultDto> EvaluateAsync(
        string externalAgentId,
        string interactionId,
        string prompt)
    {
        using var request = CreateEvaluationRequest(externalAgentId, interactionId, prompt);
        using var response = await _client.SendAsync(request);
        response.StatusCode.Should().Be(HttpStatusCode.OK);
        return (await response.Content.ReadFromJsonAsync<PromptEvaluationResultDto>(JsonOptions))!;
    }

    private static HttpRequestMessage CreateEvaluationRequest(
        string externalAgentId,
        string interactionId,
        string prompt)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/prompts:evaluate");
        request.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString("D"));
        request.Content = JsonContent.Create(new EvaluatePromptRequest(
            externalAgentId,
            interactionId,
            DateTime.UtcNow,
            null,
            new ContentDto("text/plain", prompt)), options: JsonOptions);
        return request;
    }

    private async Task<string> SetupProtectedAgentAsync(string externalAgentId)
    {
        using var scope = _factory.Services.CreateScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        var agent = new AgentRegistration
        {
            Id = Guid.NewGuid(),
            ExternalAgentId = new ExternalAgentId(externalAgentId),
            Name = $"Protected test {externalAgentId}",
            Description = "Prompt evaluation end-to-end test",
            OwnerObjectId = TestAuthHandler.DefaultObjectId,
            Environment = AgentEnvironment.Development,
            Status = AgentStatus.Active,
            CreatedAtUtc = DateTime.UtcNow,
            UpdatedAtUtc = DateTime.UtcNow,
            CreatedByObjectId = TestAuthHandler.DefaultObjectId,
            UpdatedByObjectId = TestAuthHandler.DefaultObjectId
        };
        agent.FeatureConfiguration = new AgentFeatureConfiguration
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            ObservabilityMode = ObservabilityMode.Disabled,
            PurviewEnabled = false,
            PromptShieldEnabled = true,
            UpdatedAtUtc = DateTime.UtcNow
        };
        dbContext.AgentRegistrations.Add(agent);
        var credential = scope.ServiceProvider.GetRequiredService<IAgentIngressCredentialService>()
            .Issue(agent.Id, TestAuthHandler.DefaultObjectId, DateTime.UtcNow);
        await dbContext.SaveChangesAsync();
        return credential.ApiKey;
    }

    private void UseGatewayCredential(string apiKey)
    {
        _client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
    }
}
