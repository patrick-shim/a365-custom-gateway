using System.Text.Json;
using FluentAssertions;
using Gateway.Application.Agents.Commands;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Messages;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public class RetryProvisioningHandlerTests
{
    [Fact]
    public async Task Handle_Should_AtomicallyMoveFailedAgentToProvisioningAndCreateOneCurrentJob()
    {
        var fixture = new RetryFixture();
        var agent = CreateAgent(AgentStatus.Failed);
        agent.LastProvisioningErrorCode = ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE;
        agent.LastProvisioningErrorSummary = "A safe prior failure.";
        var priorJob = CreateCurrentJob(agent.Id, JobStatus.Failed);
        priorJob.ErrorCode = ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE;
        priorJob.ErrorSummary = "A safe prior failure.";
        priorJob.Steps.ElementAt(0).Status = StepStatus.Failed;
        fixture.Arrange(agent, [priorJob]);
        ProvisioningJob? addedJob = null;
        fixture.JobRepository.AddAsync(
                Arg.Do<ProvisioningJob>(job => addedJob = job),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);
        var handler = fixture.CreateHandler();

        var result = await handler.Handle(
            new RetryProvisioningCommand(agent.Id, "caller-object-id"),
            CancellationToken.None);

        result.Should().BeOfType<AsyncOperationResponse>();
        result.Status.Should().Be(AgentStatus.Provisioning.ToString());
        agent.Status.Should().Be(AgentStatus.Provisioning);
        agent.UpdatedByObjectId.Should().Be("caller-object-id");
        agent.LastProvisioningErrorCode.Should().BeNull();
        agent.LastProvisioningErrorSummary.Should().BeNull();
        addedJob.Should().NotBeNull();
        addedJob!.WorkflowVersion.Should().Be(ProvisioningWorkflow.CurrentVersion);
        addedJob.Status.Should().Be(JobStatus.Pending);
        addedJob.Steps.OrderBy(step => step.OrderIndex).Select(step => step.StepType)
            .Should().Equal(ProvisioningWorkflow.CurrentSteps);
        await fixture.UnitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_RejectManualInterventionWithoutSafePriorJob()
    {
        var fixture = new RetryFixture();
        var agent = CreateAgent(AgentStatus.RequiresManualIntervention);
        fixture.Arrange(agent, []);
        var handler = fixture.CreateHandler();

        var action = () => handler.Handle(
            new RetryProvisioningCommand(agent.Id, "caller-object-id"),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<InvalidStateTransitionException>();
        exception.Which.AttemptedAction.Should().Be("RetryUnsafeProvisioningFailure");
        await fixture.JobRepository.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_Should_RejectRetryWhenAnActiveJobAlreadyExists()
    {
        var fixture = new RetryFixture();
        var agent = CreateAgent(AgentStatus.Failed);
        var activeJob = CreateCurrentJob(agent.Id, JobStatus.Running);
        activeJob.Steps.ElementAt(0).Status = StepStatus.Running;
        fixture.Arrange(agent, [activeJob]);
        var handler = fixture.CreateHandler();

        var action = () => handler.Handle(
            new RetryProvisioningCommand(agent.Id, "caller-object-id"),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<InvalidStateTransitionException>();
        exception.Which.AttemptedAction.Should().Be("RetryProvisioningActiveJob");
        agent.Status.Should().Be(AgentStatus.Failed);
        await fixture.JobRepository.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_Should_RejectRetryWithoutAPriorProvisioningSource()
    {
        var fixture = new RetryFixture();
        var agent = CreateAgent(AgentStatus.Failed);
        fixture.Arrange(agent, []);
        var handler = fixture.CreateHandler();

        var action = () => handler.Handle(
            new RetryProvisioningCommand(agent.Id, "caller-object-id"),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<InvalidStateTransitionException>();
        exception.Which.AttemptedAction.Should().Be("RetryUnsafeProvisioningFailure");
        await fixture.JobRepository.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_Should_RejectRunningStageInFailedPriorJob()
    {
        var fixture = new RetryFixture();
        var agent = CreateAgent(AgentStatus.Failed);
        var priorJob = CreateCurrentJob(agent.Id, JobStatus.Failed);
        priorJob.ErrorCode = ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE;
        priorJob.Steps.ElementAt(0).Status = StepStatus.Running;
        fixture.Arrange(agent, [priorJob]);
        var handler = fixture.CreateHandler();

        var action = () => handler.Handle(
            new RetryProvisioningCommand(agent.Id, "caller-object-id"),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<InvalidStateTransitionException>();
        exception.Which.AttemptedAction.Should().Be("RetryUnsafeProvisioningFailure");
        await fixture.JobRepository.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_Should_RejectReachedButUnverifiedRegistryFailure()
    {
        var fixture = new RetryFixture();
        var agent = CreateAgent(AgentStatus.Failed);
        var priorJob = CreateCurrentJob(agent.Id, JobStatus.Failed);
        priorJob.ErrorCode = ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE;
        priorJob.Steps.ElementAt(5).Status = StepStatus.Failed;
        fixture.Arrange(agent, [priorJob]);
        var handler = fixture.CreateHandler();

        var action = () => handler.Handle(
            new RetryProvisioningCommand(agent.Id, "caller-object-id"),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<InvalidStateTransitionException>();
        exception.Which.AttemptedAction.Should().Be("RetryUnsafeProvisioningFailure");
        await fixture.JobRepository.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_Should_RejectMalformedCompletedPrefixState()
    {
        var fixture = new RetryFixture();
        var agent = CreateAgent(AgentStatus.Failed);
        var priorJob = CreateCurrentJob(agent.Id, JobStatus.Failed);
        priorJob.ErrorCode = ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE;
        priorJob.Steps.ElementAt(0).Status = StepStatus.Completed;
        priorJob.Steps.ElementAt(0).ResultData = "{";
        priorJob.Steps.ElementAt(1).Status = StepStatus.Failed;
        fixture.Arrange(agent, [priorJob]);
        var handler = fixture.CreateHandler();

        var action = () => handler.Handle(
            new RetryProvisioningCommand(agent.Id, "caller-object-id"),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<InvalidStateTransitionException>();
        exception.Which.AttemptedAction.Should().Be("RetryUnsafeProvisioningFailure");
        await fixture.JobRepository.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_Should_RejectNoncontiguousCompletedPrefix()
    {
        var fixture = new RetryFixture();
        var agent = CreateAgent(AgentStatus.Failed);
        var priorJob = CreateCurrentJob(agent.Id, JobStatus.Failed);
        priorJob.ErrorCode = ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE;
        var secondStep = priorJob.Steps.ElementAt(1);
        secondStep.Status = StepStatus.Completed;
        secondStep.ResultData = JsonSerializer.Serialize(new Agent365ProvisioningStepResult(
            secondStep.StepType,
            new Agent365ProvisioningState
            {
                BlueprintPrincipalObjectId = Guid.NewGuid().ToString("D")
            },
            "verified_EnsureBlueprintPrincipal"));
        priorJob.Steps.ElementAt(2).Status = StepStatus.Failed;
        fixture.Arrange(agent, [priorJob]);
        var handler = fixture.CreateHandler();

        var action = () => handler.Handle(
            new RetryProvisioningCommand(agent.Id, "caller-object-id"),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<InvalidStateTransitionException>();
        exception.Which.AttemptedAction.Should().Be("RetryUnsafeProvisioningFailure");
        await fixture.JobRepository.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_Should_RejectNonmonotonicCompletedPrefixState()
    {
        var fixture = new RetryFixture();
        var agent = CreateAgent(AgentStatus.Failed);
        var priorJob = CreateCurrentJob(agent.Id, JobStatus.Failed);
        priorJob.ErrorCode = ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE;
        var firstState = new Agent365ProvisioningState
        {
            BlueprintObjectId = Guid.NewGuid().ToString("D"),
            BlueprintClientId = Guid.NewGuid().ToString("D"),
            PlannedAgent365RegistrationId = Guid.NewGuid().ToString("D")
        };
        var firstStep = priorJob.Steps.ElementAt(0);
        firstStep.Status = StepStatus.Completed;
        firstStep.ResultData = JsonSerializer.Serialize(new Agent365ProvisioningStepResult(
            firstStep.StepType,
            firstState,
            "verified_ResolveBlueprint"));
        var secondStep = priorJob.Steps.ElementAt(1);
        secondStep.Status = StepStatus.Completed;
        secondStep.ResultData = JsonSerializer.Serialize(new Agent365ProvisioningStepResult(
            secondStep.StepType,
            firstState with
            {
                BlueprintObjectId = Guid.NewGuid().ToString("D"),
                BlueprintPrincipalObjectId = Guid.NewGuid().ToString("D")
            },
            "verified_EnsureBlueprintPrincipal"));
        priorJob.Steps.ElementAt(2).Status = StepStatus.Failed;
        fixture.Arrange(agent, [priorJob]);
        var handler = fixture.CreateHandler();

        var action = () => handler.Handle(
            new RetryProvisioningCommand(agent.Id, "caller-object-id"),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<InvalidStateTransitionException>();
        exception.Which.AttemptedAction.Should().Be("RetryUnsafeProvisioningFailure");
        await fixture.JobRepository.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_Should_RejectAmbiguousRegistryFailureEvenWhenAgentStateIsInconsistent()
    {
        var fixture = new RetryFixture();
        var agent = CreateAgent(AgentStatus.Failed);
        var priorJob = CreateCurrentJob(agent.Id, JobStatus.RequiresManualIntervention);
        priorJob.ErrorCode = ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT;
        priorJob.Steps.ElementAt(5).Status = StepStatus.Failed;
        fixture.Arrange(agent, [priorJob]);
        var handler = fixture.CreateHandler();

        var action = () => handler.Handle(
            new RetryProvisioningCommand(agent.Id, "caller-object-id"),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<InvalidStateTransitionException>();
        exception.Which.AttemptedAction.Should().Be("RetryUnsafeProvisioningFailure");
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_Should_RejectRetryWhenAnyPriorJobUsesLegacyWorkflow()
    {
        var agentRepository = Substitute.For<IAgentRepository>();
        var jobRepository = Substitute.For<IProvisioningJobRepository>();
        var outboxRepository = Substitute.For<IOutboxRepository>();
        var auditRepository = Substitute.For<IAuditEventRepository>();
        var unitOfWork = Substitute.For<IUnitOfWork>();
        var agent = new AgentRegistration
        {
            Id = Guid.NewGuid(),
            Status = AgentStatus.Failed
        };
        agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(agent);
        jobRepository.GetByAgentIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(
            new List<ProvisioningJob>
            {
                new()
                {
                    Id = Guid.NewGuid(),
                    AgentRegistrationId = agent.Id,
                    WorkflowVersion = ProvisioningWorkflow.LegacyVersion
                }
            });
        var handler = new RetryProvisioningHandler(
            agentRepository,
            jobRepository,
            outboxRepository,
            auditRepository,
            unitOfWork);

        var action = () => handler.Handle(
            new RetryProvisioningCommand(agent.Id, "caller-object-id"),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<InvalidStateTransitionException>();
        exception.Which.AttemptedAction.Should().Be("RetryLegacyProvisioning");
        await jobRepository.DidNotReceive().AddAsync(
            Arg.Any<ProvisioningJob>(),
            Arg.Any<CancellationToken>());
        await outboxRepository.DidNotReceive().AddAsync(
            Arg.Any<OutboxMessage>(),
            Arg.Any<CancellationToken>());
        await unitOfWork.DidNotReceive().SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_RejectCompletedRegistryStateWithoutDelegatedVerificationEvidence()
    {
        var fixture = new RetryFixture();
        var agent = CreateAgent(AgentStatus.Failed);
        var priorJob = CreateCurrentJob(agent.Id, JobStatus.Failed);
        CompleteThroughRegistry(priorJob, includeDelegatedEvidence: false);
        priorJob.ErrorCode = ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE;
        priorJob.Steps.ElementAt(6).Status = StepStatus.Failed;
        fixture.Arrange(agent, [priorJob]);
        var handler = fixture.CreateHandler();

        var action = () => handler.Handle(
            new RetryProvisioningCommand(agent.Id, "caller-object-id"),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<InvalidStateTransitionException>();
        exception.Which.AttemptedAction.Should().Be("RetryUnsafeProvisioningFailure");
        await fixture.JobRepository.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_Should_AllowFinalVerificationRetryAfterAcceptedRegistryCompletionEvenWhenManual()
    {
        var fixture = new RetryFixture();
        var agent = CreateAgent(AgentStatus.RequiresManualIntervention);
        var priorJob = CreateCurrentJob(agent.Id, JobStatus.RequiresManualIntervention);
        CompleteThroughRegistry(priorJob, includeDelegatedEvidence: true);
        priorJob.ErrorCode = ErrorCodes.PROVISIONING_CONFIGURATION_INVALID;
        priorJob.Steps.ElementAt(6).Status = StepStatus.Failed;
        fixture.Arrange(agent, [priorJob]);
        ProvisioningJob? addedJob = null;
        OutboxMessage? addedMessage = null;
        fixture.JobRepository.AddAsync(
                Arg.Do<ProvisioningJob>(job => addedJob = job),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);
        fixture.OutboxRepository.AddAsync(
                Arg.Do<OutboxMessage>(message => addedMessage = message),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);
        var handler = fixture.CreateHandler();

        var result = await handler.Handle(
            new RetryProvisioningCommand(agent.Id, "caller-object-id"),
            CancellationToken.None);

        result.Status.Should().Be(AgentStatus.Provisioning.ToString());
        agent.Status.Should().Be(AgentStatus.Provisioning);
        addedJob.Should().NotBeNull();
        addedJob!.Status.Should().Be(JobStatus.Pending);
        addedJob.PercentComplete.Should().Be(85);
        var orderedRetrySteps = addedJob.Steps.OrderBy(step => step.OrderIndex).ToArray();
        orderedRetrySteps.Take(6).Should().OnlyContain(step => step.Status == StepStatus.Completed);
        orderedRetrySteps.Take(6).Select(step => step.ResultData).Should().Equal(
            priorJob.Steps.OrderBy(step => step.OrderIndex).Take(6).Select(step => step.ResultData));
        orderedRetrySteps[6].Status.Should().Be(StepStatus.Pending);
        addedMessage.Should().NotBeNull();
        var payload = JsonSerializer.Deserialize<ProvisionAgentMessage>(addedMessage!.Payload);
        payload.Should().NotBeNull();
        payload!.AgentRegistrationId.Should().Be(agent.Id);
        payload.JobId.Should().Be(addedJob.Id);
        payload.ExpectedStepIndex.Should().Be(6);
        await fixture.JobRepository.Received(1).AddAsync(
            Arg.Is<ProvisioningJob>(job => job.Type == OperationType.RetryProvisioning),
            Arg.Any<CancellationToken>());
        await fixture.UnitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    private static AgentRegistration CreateAgent(AgentStatus status) => new()
    {
        Id = Guid.NewGuid(),
        Status = status,
        UpdatedAtUtc = DateTime.UtcNow.AddMinutes(-1),
        UpdatedByObjectId = "previous-caller"
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

    private static void CompleteThroughRegistry(
        ProvisioningJob job,
        bool includeDelegatedEvidence)
    {
        var registryId = Guid.NewGuid().ToString("D");
        var state = new Agent365ProvisioningState
        {
            BlueprintObjectId = Guid.NewGuid().ToString("D"),
            BlueprintClientId = Guid.NewGuid().ToString("D"),
            BlueprintPrincipalObjectId = Guid.NewGuid().ToString("D"),
            GatewayManagedIdentityPrincipalId = Guid.NewGuid().ToString("D"),
            GatewayFederatedCredentialId = Guid.NewGuid().ToString("D"),
            AgentIdentityObjectId = Guid.NewGuid().ToString("D"),
            AgentIdentityClientId = Guid.NewGuid().ToString("D"),
            ObservabilityAppRoleAssignmentId = Guid.NewGuid().ToString("D"),
            Agent365RegistrationId = registryId,
            RegistryProvider = "DirectRegistryPreview",
            RegistryAuthenticationMode = includeDelegatedEvidence
                ? "DelegatedAdministrator"
                : null,
            RegistryCreatedByObjectId = includeDelegatedEvidence
                ? Guid.NewGuid().ToString("D")
                : null,
            Agent365RegistrationVerifiedAtUtc = includeDelegatedEvidence
                ? DateTimeOffset.UtcNow.AddMinutes(-1)
                : null
        };

        foreach (var step in job.Steps.OrderBy(step => step.OrderIndex).Take(6))
        {
            step.Status = StepStatus.Completed;
            step.CompletedAtUtc = DateTime.UtcNow.AddMinutes(-1);
            step.ResultData = JsonSerializer.Serialize(new Agent365ProvisioningStepResult(
                step.StepType,
                state,
                $"verified_{step.StepType}"));
        }
    }

    private sealed class RetryFixture
    {
        public IAgentRepository AgentRepository { get; } = Substitute.For<IAgentRepository>();
        public IProvisioningJobRepository JobRepository { get; } =
            Substitute.For<IProvisioningJobRepository>();
        public IOutboxRepository OutboxRepository { get; } = Substitute.For<IOutboxRepository>();
        public IAuditEventRepository AuditRepository { get; } =
            Substitute.For<IAuditEventRepository>();
        public IUnitOfWork UnitOfWork { get; } = Substitute.For<IUnitOfWork>();

        public void Arrange(AgentRegistration agent, List<ProvisioningJob> jobs)
        {
            AgentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(agent);
            JobRepository.GetByAgentIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(jobs);
        }

        public RetryProvisioningHandler CreateHandler() => new(
            AgentRepository,
            JobRepository,
            OutboxRepository,
            AuditRepository,
            UnitOfWork);
    }
}
