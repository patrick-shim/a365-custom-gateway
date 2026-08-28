using FluentAssertions;
using Gateway.Application.Agents.Queries;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public sealed class GetAgentHandlerTests
{
    private readonly IAgentRepository _agentRepository = Substitute.For<IAgentRepository>();
    private readonly IProvisioningJobRepository _jobRepository =
        Substitute.For<IProvisioningJobRepository>();

    [Fact]
    public async Task Handle_Should_ExposeSupportedForRetrySafeCurrentFailure()
    {
        var agent = CreateAgent(AgentStatus.Failed);
        var job = CreateCurrentJob(agent.Id, JobStatus.Failed);
        job.ErrorCode = ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE;
        job.Steps.ElementAt(0).Status = StepStatus.Failed;

        var result = await HandleAsync(agent, [job]);

        result.RetryProvisioning.Should().NotBeNull();
        result.RetryProvisioning!.Supported.Should().BeTrue();
        result.RetryProvisioning.Reason.Should().Contain("safely retryable");
    }

    [Fact]
    public async Task Handle_Should_RejectRetryWhenActiveJobExistsForFailedAgent()
    {
        var agent = CreateAgent(AgentStatus.Failed);
        var job = CreateCurrentJob(agent.Id, JobStatus.Running);
        job.Steps.ElementAt(0).Status = StepStatus.Running;

        var result = await HandleAsync(agent, [job]);

        result.RetryProvisioning.Should().NotBeNull();
        result.RetryProvisioning!.Supported.Should().BeFalse();
        result.RetryProvisioning.Reason.Should().Contain("pending or running");
    }

    [Fact]
    public async Task Handle_Should_RejectRetryWhenAnyJobIsLegacy()
    {
        var agent = CreateAgent(AgentStatus.Failed);
        var currentJob = CreateCurrentJob(agent.Id, JobStatus.Failed);
        currentJob.ErrorCode = ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE;
        currentJob.Steps.ElementAt(0).Status = StepStatus.Failed;
        var legacyJob = CreateCurrentJob(agent.Id, JobStatus.Failed);
        legacyJob.WorkflowVersion = ProvisioningWorkflow.LegacyVersion;
        legacyJob.CreatedAtUtc = currentJob.CreatedAtUtc.AddMinutes(-1);

        var result = await HandleAsync(agent, [currentJob, legacyJob]);

        result.RetryProvisioning.Should().NotBeNull();
        result.RetryProvisioning!.Supported.Should().BeFalse();
        result.RetryProvisioning.Reason.Should().Contain("non-replayable legacy");
    }

    [Fact]
    public async Task Handle_Should_RejectAmbiguousRegistryFailureEvenIfAgentIsFailed()
    {
        var agent = CreateAgent(AgentStatus.Failed);
        var job = CreateCurrentJob(agent.Id, JobStatus.Failed);
        job.ErrorCode = ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT;
        job.Steps.ElementAt(5).Status = StepStatus.Failed;

        var result = await HandleAsync(agent, [job]);

        result.RetryProvisioning.Should().NotBeNull();
        result.RetryProvisioning!.Supported.Should().BeFalse();
        result.RetryProvisioning.Reason.Should().Contain("ambiguous");
        result.RetryProvisioning.Reason.Should().Contain("Reconcile Microsoft resource state manually");
    }

    [Fact]
    public async Task Handle_Should_RejectUnsafeManualHistoryWithoutImplyingReplay()
    {
        var agent = CreateAgent(AgentStatus.RequiresManualIntervention);
        var job = CreateCurrentJob(agent.Id, JobStatus.RequiresManualIntervention);
        job.ErrorCode = ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT;
        job.Steps.ElementAt(5).Status = StepStatus.Failed;

        var result = await HandleAsync(agent, [job]);

        result.RetryProvisioning.Should().NotBeNull();
        result.RetryProvisioning!.Supported.Should().BeFalse();
        result.RetryProvisioning.Reason.Should().Contain("ambiguous");
        result.RetryProvisioning.Reason.Should().Contain("Reconcile Microsoft resource state manually");
    }

    private async Task<Gateway.Contracts.Responses.AgentDetailDto> HandleAsync(
        AgentRegistration agent,
        List<ProvisioningJob> jobs)
    {
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(agent);
        _jobRepository.GetByAgentIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(jobs);
        var handler = new GetAgentHandler(_agentRepository, _jobRepository);

        return await handler.Handle(new GetAgentQuery(agent.Id), CancellationToken.None);
    }

    private static AgentRegistration CreateAgent(AgentStatus status) => new()
    {
        Id = Guid.NewGuid(),
        ExternalAgentId = new ExternalAgentId("retry-policy-agent"),
        Name = "Retry policy agent",
        OwnerObjectId = Guid.NewGuid().ToString("D"),
        Environment = AgentEnvironment.Development,
        Status = status,
        CreatedAtUtc = DateTime.UtcNow.AddDays(-1),
        CreatedByObjectId = "creator-object-id",
        UpdatedAtUtc = DateTime.UtcNow,
        UpdatedByObjectId = "updater-object-id",
        RowVersion = [1],
        FeatureConfiguration = new AgentFeatureConfiguration
        {
            ObservabilityMode = ObservabilityMode.GatewayOnly,
            UpdatedAtUtc = DateTime.UtcNow
        }
    };

    private static ProvisioningJob CreateCurrentJob(Guid agentId, JobStatus status)
    {
        var job = new ProvisioningJob
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agentId,
            Type = OperationType.ProvisionAgent,
            Status = status,
            WorkflowVersion = ProvisioningWorkflow.CurrentVersion,
            CreatedAtUtc = DateTime.UtcNow.AddMinutes(-1),
            StartedAtUtc = DateTime.UtcNow.AddMinutes(-1)
        };
        job.Steps = ProvisioningWorkflow.CurrentSteps
            .Select((stepType, index) => new ProvisioningJobStep
            {
                Id = Guid.NewGuid(),
                ProvisioningJobId = job.Id,
                StepType = stepType,
                Status = StepStatus.Pending,
                OrderIndex = index
            })
            .ToList();
        return job;
    }
}
