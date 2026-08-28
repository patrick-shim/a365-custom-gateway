using FluentAssertions;
using Gateway.Application.Agents.Queries;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public class GetOperationStatusHandlerTests
{
    private readonly IProvisioningJobRepository _repository =
        Substitute.For<IProvisioningJobRepository>();

    [Fact]
    public async Task Handle_Should_MarkExactCurrentWorkflowAsCurrentReplayableAndPollable()
    {
        var job = CreateJob(
            ProvisioningWorkflow.CurrentVersion,
            ProvisioningWorkflow.CurrentSteps,
            JobStatus.Running);
        _repository.GetByIdAsync(job.Id, Arg.Any<CancellationToken>()).Returns(job);
        var handler = new GetOperationStatusHandler(_repository);

        var result = await handler.Handle(new GetOperationStatusQuery(job.Id), CancellationToken.None);

        result.WorkflowVersion.Should().Be(ProvisioningWorkflow.CurrentVersion);
        result.Legacy.Should().BeFalse();
        result.ReplaySupported.Should().BeTrue();
        result.PollingRecommended.Should().BeTrue();
        result.Steps!.Select(step => step.Step)
            .Should().Equal(ProvisioningWorkflow.CurrentSteps.Select(step => step.ToString()));
    }

    [Fact]
    public async Task Handle_Should_MarkVersionOneWorkflowAsLegacyNonReplayableAndNonPollable()
    {
        var legacySteps = new[]
        {
            ProvisioningStepType.CreateAppRegistration,
            ProvisioningStepType.CreateServicePrincipal,
            ProvisioningStepType.AssignRoles,
            ProvisioningStepType.StoreCredentials,
            ProvisioningStepType.CreateBlueprint,
            ProvisioningStepType.CreateBlueprintPrincipal,
            ProvisioningStepType.RegisterAgent
        };
        var job = CreateJob(ProvisioningWorkflow.LegacyVersion, legacySteps, JobStatus.Running);
        _repository.GetByIdAsync(job.Id, Arg.Any<CancellationToken>()).Returns(job);
        var handler = new GetOperationStatusHandler(_repository);

        var result = await handler.Handle(new GetOperationStatusQuery(job.Id), CancellationToken.None);

        result.WorkflowVersion.Should().Be(ProvisioningWorkflow.LegacyVersion);
        result.Legacy.Should().BeTrue();
        result.ReplaySupported.Should().BeFalse();
        result.PollingRecommended.Should().BeFalse();
    }

    [Fact]
    public async Task Handle_Should_MarkManualAmbiguousWorkflowAsNonReplayableAndNonPollable()
    {
        var job = CreateJob(
            ProvisioningWorkflow.CurrentVersion,
            ProvisioningWorkflow.CurrentSteps,
            JobStatus.RequiresManualIntervention);
        job.ErrorCode = ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT;
        job.Steps.ElementAt(0).Status = StepStatus.Failed;
        _repository.GetByIdAsync(job.Id, Arg.Any<CancellationToken>()).Returns(job);
        var handler = new GetOperationStatusHandler(_repository);

        var result = await handler.Handle(new GetOperationStatusQuery(job.Id), CancellationToken.None);

        result.Legacy.Should().BeFalse();
        result.ReplaySupported.Should().BeFalse();
        result.PollingRecommended.Should().BeFalse();
    }

    [Fact]
    public async Task Handle_Should_MarkInFlightRegistryCreateAsNonReplayableWhileStillPollable()
    {
        var job = CreateJob(
            ProvisioningWorkflow.CurrentVersion,
            ProvisioningWorkflow.CurrentSteps,
            JobStatus.Running);
        foreach (var step in job.Steps.Take(5))
            step.Status = StepStatus.Completed;
        job.Steps.ElementAt(5).Status = StepStatus.Running;
        job.Steps.ElementAt(6).Status = StepStatus.Pending;
        _repository.GetByIdAsync(job.Id, Arg.Any<CancellationToken>()).Returns(job);
        var handler = new GetOperationStatusHandler(_repository);

        var result = await handler.Handle(new GetOperationStatusQuery(job.Id), CancellationToken.None);

        result.ReplaySupported.Should().BeFalse();
        result.PollingRecommended.Should().BeTrue();
        result.CurrentStep.Should().Be(ProvisioningStepType.RegisterAgent.ToString());
    }

    [Fact]
    public async Task Handle_ShouldExposeDelegatedRegistryActionWithoutPollingOrReplay()
    {
        var job = CreateJob(
            ProvisioningWorkflow.CurrentVersion,
            ProvisioningWorkflow.CurrentSteps,
            JobStatus.AwaitingAdministratorAction);
        foreach (var step in job.Steps.Take(5))
            step.Status = StepStatus.Completed;
        job.Steps.ElementAt(5).Status = StepStatus.Pending;
        job.Steps.ElementAt(6).Status = StepStatus.Pending;
        job.PercentComplete = 71;
        _repository.GetByIdAsync(job.Id, Arg.Any<CancellationToken>()).Returns(job);
        var handler = new GetOperationStatusHandler(_repository);

        var result = await handler.Handle(
            new GetOperationStatusQuery(job.Id),
            CancellationToken.None);

        result.Legacy.Should().BeFalse();
        result.Status.Should().Be(JobStatus.AwaitingAdministratorAction.ToString());
        result.CurrentStep.Should().Be(ProvisioningStepType.RegisterAgent.ToString());
        result.PercentComplete.Should().Be(71);
        result.RequiredAction.Should().Be("CompleteAgent365Registration");
        result.ReplaySupported.Should().BeFalse();
        result.PollingRecommended.Should().BeFalse();
    }

    [Fact]
    public async Task Handle_ShouldKeepGetOnlyRegistryRecoveryAsAdministratorAction()
    {
        var job = CreateJob(
            ProvisioningWorkflow.CurrentVersion,
            ProvisioningWorkflow.CurrentSteps,
            JobStatus.AwaitingAdministratorAction);
        foreach (var step in job.Steps.Take(5))
            step.Status = StepStatus.Completed;
        job.Steps.ElementAt(5).Status = StepStatus.Running;
        job.Steps.ElementAt(6).Status = StepStatus.Pending;
        _repository.GetByIdAsync(job.Id, Arg.Any<CancellationToken>()).Returns(job);
        var handler = new GetOperationStatusHandler(_repository);

        var result = await handler.Handle(
            new GetOperationStatusQuery(job.Id),
            CancellationToken.None);

        result.RequiredAction.Should().Be("CompleteAgent365Registration");
        result.CurrentStep.Should().Be(ProvisioningStepType.RegisterAgent.ToString());
        result.ReplaySupported.Should().BeFalse();
        result.PollingRecommended.Should().BeFalse();
    }

    [Fact]
    public async Task Handle_ShouldNeverExposeDelegatedActionForHistoricalVersionTwoJob()
    {
        var job = CreateJob(
            workflowVersion: 2,
            ProvisioningWorkflow.CurrentSteps,
            JobStatus.AwaitingAdministratorAction);
        foreach (var step in job.Steps.Take(5))
            step.Status = StepStatus.Completed;
        job.Steps.ElementAt(5).Status = StepStatus.Pending;
        job.Steps.ElementAt(6).Status = StepStatus.Pending;
        _repository.GetByIdAsync(job.Id, Arg.Any<CancellationToken>()).Returns(job);
        var handler = new GetOperationStatusHandler(_repository);

        var result = await handler.Handle(
            new GetOperationStatusQuery(job.Id),
            CancellationToken.None);

        result.Legacy.Should().BeTrue();
        result.RequiredAction.Should().BeNull();
        result.ReplaySupported.Should().BeFalse();
        result.PollingRecommended.Should().BeFalse();
    }

    private static ProvisioningJob CreateJob(
        int workflowVersion,
        IReadOnlyList<ProvisioningStepType> stepTypes,
        JobStatus status)
    {
        var job = new ProvisioningJob
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = Guid.NewGuid(),
            Type = OperationType.ProvisionAgent,
            Status = status,
            WorkflowVersion = workflowVersion,
            StartedAtUtc = DateTime.UtcNow,
            CreatedAtUtc = DateTime.UtcNow
        };

        job.Steps = stepTypes.Select((stepType, index) => new ProvisioningJobStep
        {
            Id = Guid.NewGuid(),
            ProvisioningJobId = job.Id,
            StepType = stepType,
            Status = index == 0 ? StepStatus.Running : StepStatus.Pending,
            OrderIndex = index
        }).ToList();

        return job;
    }
}
