using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Gateway.Contracts;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.EndToEndTests.Fixtures;
using Gateway.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.EndToEndTests;

[Collection(EndToEndTestCollection.Name)]
public sealed class RetryProvisioningTests : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly GatewayWebApplicationFactory _factory;
    private readonly HttpClient _client;

    public RetryProvisioningTests(GatewayWebApplicationFactory factory)
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
    public async Task RetryFailedProvisioning_SecondRequestIsConflictAndOnlyOneJobIsCreated()
    {
        var agentId = Guid.NewGuid();
        await SeedFailureAsync(agentId, AgentStatus.Failed, JobStatus.Failed,
            ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE);
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var first = await _client.PostAsync(
            $"/api/v1/agents/{agentId:D}:retry-provisioning",
            content: null);
        var second = await _client.PostAsync(
            $"/api/v1/agents/{agentId:D}:retry-provisioning",
            content: null);

        first.StatusCode.Should().Be(HttpStatusCode.Accepted);
        var accepted = await first.Content.ReadFromJsonAsync<AsyncOperationResponse>(JsonOptions);
        accepted!.Status.Should().Be(AgentStatus.Provisioning.ToString());
        second.StatusCode.Should().Be(HttpStatusCode.Conflict);
        var conflict = await second.Content.ReadFromJsonAsync<JsonElement>(JsonOptions);
        conflict.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.INVALID_STATE_TRANSITION);

        await using var scope = _factory.Services.CreateAsyncScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        (await dbContext.AgentRegistrations.SingleAsync(agent => agent.Id == agentId))
            .Status.Should().Be(AgentStatus.Provisioning);
        (await dbContext.ProvisioningJobs.CountAsync(job =>
            job.AgentRegistrationId == agentId && job.Type == OperationType.RetryProvisioning))
            .Should().Be(1);
    }

    [Fact]
    public async Task RetryManualAmbiguousProvisioning_IsRejectedWithoutCreatingWork()
    {
        var agentId = Guid.NewGuid();
        await SeedFailureAsync(
            agentId,
            AgentStatus.RequiresManualIntervention,
            JobStatus.RequiresManualIntervention,
            ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var response = await _client.PostAsync(
            $"/api/v1/agents/{agentId:D}:retry-provisioning",
            content: null);

        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
        await using var scope = _factory.Services.CreateAsyncScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        (await dbContext.ProvisioningJobs.CountAsync(job =>
            job.AgentRegistrationId == agentId && job.Type == OperationType.RetryProvisioning))
            .Should().Be(0);
        (await dbContext.OutboxMessages.CountAsync(message =>
            message.MessageType == "RetryProvisioning" &&
            message.Payload.Contains(agentId.ToString())))
            .Should().Be(0);
    }

    private async Task SeedFailureAsync(
        Guid agentId,
        AgentStatus agentStatus,
        JobStatus jobStatus,
        string errorCode)
    {
        await using var scope = _factory.Services.CreateAsyncScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        var now = DateTime.UtcNow.AddMinutes(-1);
        var agent = new AgentRegistration
        {
            Id = agentId,
            ExternalAgentId = new ExternalAgentId($"retry-e2e-{agentId:N}"),
            Name = "Retry E2E agent",
            OwnerObjectId = "02ed1e89-4ad1-4073-8e90-4aa865784896",
            Environment = AgentEnvironment.Development,
            Status = agentStatus,
            BlueprintSelectionMode = "CreateNew",
            RequestedBlueprintDisplayName = "Retry E2E blueprint",
            LastProvisioningErrorCode = errorCode,
            LastProvisioningErrorSummary = "Safe persisted failure.",
            CreatedAtUtc = now,
            UpdatedAtUtc = now,
            CreatedByObjectId = "test-caller",
            UpdatedByObjectId = "test-caller",
            FeatureConfiguration = new AgentFeatureConfiguration
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agentId,
                ObservabilityMode = ObservabilityMode.Agent365,
                UpdatedAtUtc = now
            }
        };
        var job = new ProvisioningJob
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agentId,
            Type = OperationType.ProvisionAgent,
            Status = jobStatus,
            ErrorCode = errorCode,
            ErrorSummary = "Safe persisted failure.",
            WorkflowVersion = ProvisioningWorkflow.CurrentVersion,
            StartedAtUtc = now,
            CompletedAtUtc = now,
            CreatedAtUtc = now
        };
        job.Steps = ProvisioningWorkflow.CurrentSteps
            .Select((stepType, index) => new ProvisioningJobStep
            {
                Id = Guid.NewGuid(),
                ProvisioningJobId = job.Id,
                StepType = stepType,
                Status = index == 0 ? StepStatus.Failed : StepStatus.Pending,
                ErrorCode = index == 0 ? errorCode : null,
                ErrorMessage = index == 0 ? "Safe persisted failure." : null,
                OrderIndex = index
            })
            .ToList();

        dbContext.AgentRegistrations.Add(agent);
        dbContext.ProvisioningJobs.Add(job);
        await dbContext.SaveChangesAsync();
    }
}
