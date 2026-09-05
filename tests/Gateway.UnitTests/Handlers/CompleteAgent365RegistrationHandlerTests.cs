using System.Text.Json;
using FluentAssertions;
using Gateway.Application.Agents.Commands;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public sealed class CompleteAgent365RegistrationHandlerTests
{
    [Fact]
    public async Task Handle_ShouldPersistIntentCreateOnceAcceptAndQueueFinalStep()
    {
        var fixture = new Fixture();
        var scenario = CreateAwaitingScenario();
        var registryId = Guid.NewGuid().ToString("D");
        var snapshots = new List<string?>();
        var callOrder = new List<string>();
        fixture.Arrange(scenario);
        fixture.TokenProvider.GetTokenAsync(Arg.Any<CancellationToken>())
            .Returns(_ =>
            {
                callOrder.Add("token");
                return "opaque-test-value";
            });
        fixture.UnitOfWork
            .When(unitOfWork => unitOfWork.SaveChangesAsync(Arg.Any<CancellationToken>()))
            .Do(_ =>
            {
                callOrder.Add("save");
                snapshots.Add(scenario.RegisterStep.ResultData);
            });
        Agent365DelegatedRegistryRequest? createRequest = null;
        fixture.RegistryClient.CreateAsync(
                Arg.Do<Agent365DelegatedRegistryRequest>(request =>
                {
                    callOrder.Add("create");
                    createRequest = request;
                }),
                Arg.Any<CancellationToken>())
            .Returns(registryId);

        var response = await fixture.CreateHandler().Handle(
            new CompleteAgent365RegistrationCommand(scenario.Job.Id, scenario.CallerObjectId),
            CancellationToken.None);

        response.OperationId.Should().Be(scenario.Job.Id);
        response.AgentId.Should().Be(scenario.Agent.Id);
        response.Agent365RegistrationId.Should().Be(registryId);
        response.Status.Should().Be("VerificationQueued");
        createRequest.Should().NotBeNull();
        createRequest!.RequestCorrelationId.Should().Be(scenario.Job.Id);
        createRequest.SourceAgentId.Should().Be(scenario.State.AgentIdentityObjectId);
        createRequest.PlannedRegistrationId.Should().NotBeEmpty();
        createRequest.DisplayName.Should().Be(scenario.Agent.Name);
        createRequest.Description.Should().Be(scenario.Agent.Description);
        createRequest.OwnerObjectId.Should().Be(Guid.Parse(scenario.Agent.OwnerObjectId));
        createRequest.CreatedByObjectId.Should().Be(Guid.Parse(scenario.CallerObjectId));
        createRequest.AgentIdentityObjectId.Should().Be(
            Guid.Parse(scenario.State.AgentIdentityObjectId!));
        createRequest.BlueprintClientId.Should().Be(
            Guid.Parse(scenario.State.BlueprintClientId!));

        await fixture.RegistryClient.Received(1).CreateAsync(
            Arg.Any<Agent365DelegatedRegistryRequest>(),
            Arg.Any<CancellationToken>());
        await fixture.RegistryClient.DidNotReceiveWithAnyArgs().VerifyAsync(default!, default!, default);
        await fixture.LockProvider.Received(1).AcquireAsync(
            scenario.Job.Id,
            Arg.Any<CancellationToken>());
        await fixture.TokenProvider.Received(1).GetTokenAsync(Arg.Any<CancellationToken>());
        callOrder.Take(3).Should().Equal("token", "save", "create");

        snapshots.Should().HaveCount(3);
        var intent = JsonSerializer.Deserialize<Agent365RegistryAttemptState>(snapshots[0]!);
        intent.Should().NotBeNull();
        intent!.ReturnedAgent365RegistrationId.Should().BeNull();
        intent.PlannedAgent365RegistrationId.Should().Be(
            createRequest.PlannedRegistrationId.ToString("D"));
        var returnedId = JsonSerializer.Deserialize<Agent365RegistryAttemptState>(snapshots[1]!);
        returnedId!.ReturnedAgent365RegistrationId.Should().Be(registryId);

        scenario.RegisterStep.Status.Should().Be(StepStatus.Completed);
        scenario.Job.Status.Should().Be(JobStatus.Running);
        scenario.Job.PercentComplete.Should().Be(85);
        scenario.Agent.Status.Should().Be(AgentStatus.Provisioning);
        scenario.Agent.Agent365InstanceId.Should().Be(registryId);
        var finalResult = JsonSerializer.Deserialize<Agent365ProvisioningStepResult>(
            scenario.RegisterStep.ResultData!);
        finalResult!.State.Agent365RegistrationId.Should().Be(registryId);
        finalResult.State.RegistryAuthenticationMode.Should().Be("DelegatedAdministrator");
        finalResult.State.RegistryCreatedByObjectId.Should().Be(scenario.CallerObjectId);
        finalResult.State.Agent365RegistrationAcceptedAtUtc.Should().NotBeNull();
        finalResult.State.Agent365RegistrationVerifiedAtUtc.Should().BeNull();
        finalResult.CompletionEvidence.Should().Be("DelegatedRegistryCreateAccepted");

        await fixture.OutboxRepository.Received(1).AddAsync(
            Arg.Is<OutboxMessage>(message => IsFinalVerificationMessage(
                message,
                scenario.Agent.Id,
                scenario.Job.Id)),
            Arg.Any<CancellationToken>());
        await fixture.AuditRepository.Received(1).AddAsync(
            Arg.Is<AuditEvent>(audit =>
                audit.EventType == "Agent365RegistryAcceptedByAdministrator" &&
                audit.PerformedByObjectId == scenario.CallerObjectId &&
                audit.Details != null &&
                audit.Details.Contains(registryId, StringComparison.Ordinal) &&
                !audit.Details.Contains("token", StringComparison.OrdinalIgnoreCase) &&
                !audit.Details.Contains("authorization", StringComparison.OrdinalIgnoreCase)),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ShouldBeIdempotentAfterCompletedRegistryStep()
    {
        var fixture = new Fixture();
        var scenario = CreateAwaitingScenario();
        var registryId = Guid.NewGuid().ToString("D");
        CompleteRegistryStep(scenario, registryId);
        fixture.Arrange(scenario);

        var response = await fixture.CreateHandler().Handle(
            new CompleteAgent365RegistrationCommand(scenario.Job.Id, scenario.CallerObjectId),
            CancellationToken.None);

        response.Agent365RegistrationId.Should().Be(registryId);
        await fixture.RegistryClient.DidNotReceiveWithAnyArgs().CreateAsync(default!, default);
        await fixture.RegistryClient.DidNotReceiveWithAnyArgs().VerifyAsync(default!, default!, default);
        await fixture.TokenProvider.DidNotReceiveWithAnyArgs().GetTokenAsync(default);
        await fixture.OutboxRepository.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
        await fixture.AuditRepository.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_ShouldVerifyPlannedIdWhenRunningAttemptContainsReturnedId()
    {
        var fixture = new Fixture();
        var scenario = CreateAwaitingScenario();
        var registryId = Guid.NewGuid().ToString("D");
        MarkRunningAttempt(scenario, registryId);
        var attempt = JsonSerializer.Deserialize<Agent365RegistryAttemptState>(
            scenario.RegisterStep.ResultData!)!;
        fixture.Arrange(scenario);

        await fixture.CreateHandler().Handle(
            new CompleteAgent365RegistrationCommand(scenario.Job.Id, scenario.CallerObjectId),
            CancellationToken.None);

        await fixture.RegistryClient.DidNotReceiveWithAnyArgs().CreateAsync(default!, default);
        await fixture.RegistryClient.Received(1).VerifyAsync(
            attempt.PlannedAgent365RegistrationId,
            Arg.Any<Agent365DelegatedRegistryRequest>(),
            Arg.Any<CancellationToken>());
        await fixture.TokenProvider.Received(1).GetTokenAsync(Arg.Any<CancellationToken>());
        scenario.RegisterStep.Status.Should().Be(StepStatus.Completed);
    }

    [Fact]
    public async Task Handle_ShouldFinishAcceptedRecoveryAfterCallerCancellation()
    {
        var fixture = new Fixture();
        var scenario = CreateAwaitingScenario();
        var registryId = Guid.NewGuid().ToString("D");
        MarkRunningAttempt(scenario, registryId);
        var attempt = JsonSerializer.Deserialize<Agent365RegistryAttemptState>(
            scenario.RegisterStep.ResultData!)!;
        fixture.Arrange(scenario);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var response = await fixture.CreateHandler().Handle(
            new CompleteAgent365RegistrationCommand(scenario.Job.Id, scenario.CallerObjectId),
            cancellation.Token);

        response.Agent365RegistrationId.Should().Be(attempt.PlannedAgent365RegistrationId);
        await fixture.RegistryClient.DidNotReceiveWithAnyArgs().CreateAsync(default!, default);
        await fixture.RegistryClient.Received(1).VerifyAsync(
            attempt.PlannedAgent365RegistrationId,
            Arg.Any<Agent365DelegatedRegistryRequest>(),
            Arg.Any<CancellationToken>());
        await fixture.UnitOfWork.Received(1).SaveChangesAsync(
            Arg.Is<CancellationToken>(token => !token.IsCancellationRequested));
        scenario.RegisterStep.Status.Should().Be(StepStatus.Completed);
    }

    [Fact]
    public async Task Handle_ShouldUsePlannedIdGetOnlyWhenRunningAttemptHasNoReturnedId()
    {
        var fixture = new Fixture();
        var scenario = CreateAwaitingScenario();
        MarkRunningAttempt(scenario, returnedRegistryId: null);
        var attempt = JsonSerializer.Deserialize<Agent365RegistryAttemptState>(
            scenario.RegisterStep.ResultData!)!;
        fixture.Arrange(scenario);

        var response = await fixture.CreateHandler().Handle(
            new CompleteAgent365RegistrationCommand(scenario.Job.Id, scenario.CallerObjectId),
            CancellationToken.None);

        response.Agent365RegistrationId.Should().Be(attempt.PlannedAgent365RegistrationId);
        scenario.Job.Status.Should().Be(JobStatus.Running);
        scenario.Agent.Status.Should().Be(AgentStatus.Provisioning);
        scenario.RegisterStep.Status.Should().Be(StepStatus.Completed);
        await fixture.RegistryClient.DidNotReceiveWithAnyArgs().CreateAsync(default!, default);
        await fixture.RegistryClient.Received(1).VerifyAsync(
            attempt.PlannedAgent365RegistrationId,
            Arg.Any<Agent365DelegatedRegistryRequest>(),
            Arg.Any<CancellationToken>());
        await fixture.TokenProvider.Received(1).GetTokenAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ShouldResetToAwaitingWhenDelegatedAccessFailsBeforeDispatch()
    {
        var fixture = new Fixture();
        var scenario = CreateAwaitingScenario();
        fixture.Arrange(scenario);
        fixture.RegistryClient.CreateAsync(
                Arg.Any<Agent365DelegatedRegistryRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(Task.FromException<string>(new Agent365DelegatedRegistryException(
                ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED,
                "Administrator consent is required.",
                mutationMayHaveOccurred: false)));

        var action = () => fixture.CreateHandler().Handle(
            new CompleteAgent365RegistrationCommand(scenario.Job.Id, scenario.CallerObjectId),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(
            ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED);
        scenario.Job.Status.Should().Be(JobStatus.AwaitingAdministratorAction);
        scenario.Agent.Status.Should().Be(AgentStatus.AwaitingAdminApproval);
        scenario.RegisterStep.Status.Should().Be(StepStatus.Pending);
        scenario.RegisterStep.ResultData.Should().BeNull();
        await fixture.RegistryClient.Received(1).CreateAsync(
            Arg.Any<Agent365DelegatedRegistryRequest>(),
            Arg.Any<CancellationToken>());
        await fixture.RegistryClient.DidNotReceiveWithAnyArgs().VerifyAsync(default!, default!, default);
        await fixture.OutboxRepository.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
    }

    [Fact]
    public async Task Handle_ShouldPersistResetAfterCallerCancelsFollowingDurableIntent()
    {
        var fixture = new Fixture();
        var scenario = CreateAwaitingScenario();
        fixture.Arrange(scenario);
        using var cancellation = new CancellationTokenSource();
        Func<NSubstitute.Core.CallInfo, Task<string>> failAfterCancellation = _ =>
        {
            cancellation.Cancel();
            return Task.FromException<string>(new Agent365DelegatedRegistryException(
                ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED,
                "Administrator consent is required.",
                mutationMayHaveOccurred: false));
        };
        fixture.RegistryClient.CreateAsync(
                Arg.Any<Agent365DelegatedRegistryRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(failAfterCancellation);

        var action = () => fixture.CreateHandler().Handle(
            new CompleteAgent365RegistrationCommand(scenario.Job.Id, scenario.CallerObjectId),
            cancellation.Token);

        await action.Should().ThrowAsync<DomainException>();
        scenario.RegisterStep.Status.Should().Be(StepStatus.Pending);
        scenario.RegisterStep.ResultData.Should().BeNull();
        await fixture.UnitOfWork.Received().SaveChangesAsync(
            Arg.Is<CancellationToken>(token => !token.IsCancellationRequested));
    }

    [Fact]
    public async Task Handle_ShouldLeaveNoIntentWhenOboConsentFailsBeforeDispatch()
    {
        var fixture = new Fixture();
        var scenario = CreateAwaitingScenario();
        fixture.Arrange(scenario);
        fixture.TokenProvider.GetTokenAsync(Arg.Any<CancellationToken>())
            .Returns(Task.FromException<string>(new Agent365DelegatedRegistryException(
                ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED,
                "Administrator consent is required.",
                mutationMayHaveOccurred: false)));

        var action = () => fixture.CreateHandler().Handle(
            new CompleteAgent365RegistrationCommand(scenario.Job.Id, scenario.CallerObjectId),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365DelegatedRegistryException>();
        exception.Which.MutationMayHaveOccurred.Should().BeFalse();
        scenario.Job.Status.Should().Be(JobStatus.AwaitingAdministratorAction);
        scenario.Agent.Status.Should().Be(AgentStatus.AwaitingAdminApproval);
        scenario.RegisterStep.Status.Should().Be(StepStatus.Pending);
        scenario.RegisterStep.ResultData.Should().BeNull();
        await fixture.TokenProvider.Received(1).GetTokenAsync(Arg.Any<CancellationToken>());
        await fixture.RegistryClient.DidNotReceiveWithAnyArgs().CreateAsync(default!, default);
        await fixture.RegistryClient.DidNotReceiveWithAnyArgs().VerifyAsync(default!, default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_ShouldNotRequireImmediateGetAfterAcceptedCreate()
    {
        var fixture = new Fixture();
        var scenario = CreateAwaitingScenario();
        var registryId = Guid.NewGuid().ToString("D");
        fixture.Arrange(scenario);
        fixture.RegistryClient.CreateAsync(
                Arg.Any<Agent365DelegatedRegistryRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(registryId);
        fixture.RegistryClient.VerifyAsync(
                registryId,
                Arg.Any<Agent365DelegatedRegistryRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(
                Task.FromException(new Agent365DelegatedRegistryException(
                    ErrorCodes.AGENT365_DEPENDENCY_UNAVAILABLE,
                    "Exact verification is temporarily unavailable.",
                    mutationMayHaveOccurred: true,
                    isTransient: true)),
                Task.CompletedTask);
        var response = await fixture.CreateHandler().Handle(
            new CompleteAgent365RegistrationCommand(scenario.Job.Id, scenario.CallerObjectId),
            CancellationToken.None);

        response.Agent365RegistrationId.Should().Be(registryId);
        await fixture.RegistryClient.Received(1).CreateAsync(
            Arg.Any<Agent365DelegatedRegistryRequest>(),
            Arg.Any<CancellationToken>());
        await fixture.RegistryClient.DidNotReceiveWithAnyArgs().VerifyAsync(default!, default!, default);
        await fixture.OutboxRepository.Received(1).AddAsync(
            Arg.Any<OutboxMessage>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ShouldReconcileAmbiguousCreateByPlannedIdGetOnly()
    {
        var fixture = new Fixture();
        var scenario = CreateAwaitingScenario();
        fixture.Arrange(scenario);
        fixture.RegistryClient.CreateAsync(
                Arg.Any<Agent365DelegatedRegistryRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(Task.FromException<string>(new Agent365DelegatedRegistryException(
                ErrorCodes.AGENT365_REGISTRY_REQUEST_REJECTED,
                "The create result could not be determined.",
                mutationMayHaveOccurred: true)));

        var response = await fixture.CreateHandler().Handle(
            new CompleteAgent365RegistrationCommand(scenario.Job.Id, scenario.CallerObjectId),
            CancellationToken.None);

        response.Agent365RegistrationId.Should().NotBeNullOrWhiteSpace();
        scenario.Job.Status.Should().Be(JobStatus.Running);
        scenario.RegisterStep.Status.Should().Be(StepStatus.Completed);
        await fixture.RegistryClient.Received(1).CreateAsync(
            Arg.Any<Agent365DelegatedRegistryRequest>(),
            Arg.Any<CancellationToken>());
        await fixture.RegistryClient.Received(1).VerifyAsync(
            response.Agent365RegistrationId,
            Arg.Any<Agent365DelegatedRegistryRequest>(),
            Arg.Any<CancellationToken>());
        await fixture.OutboxRepository.Received(1).AddAsync(
            Arg.Any<OutboxMessage>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ShouldRejectHistoricalVersionTwoOperationBeforeAnyRegistrySideEffect()
    {
        var fixture = new Fixture();
        var scenario = CreateAwaitingScenario();
        scenario.Job.WorkflowVersion = 2;
        scenario.Job.Status = JobStatus.RequiresManualIntervention;
        scenario.Agent.Status = AgentStatus.RequiresManualIntervention;
        scenario.RegisterStep.Status = StepStatus.Failed;
        scenario.RegisterStep.ErrorCode = ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT;
        fixture.Arrange(scenario);

        var action = () => fixture.CreateHandler().Handle(
            new CompleteAgent365RegistrationCommand(scenario.Job.Id, scenario.CallerObjectId),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<ConflictException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_LEGACY_JOB);
        await fixture.RegistryClient.DidNotReceiveWithAnyArgs().CreateAsync(default!, default);
        await fixture.RegistryClient.DidNotReceiveWithAnyArgs().VerifyAsync(default!, default!, default);
        await fixture.TokenProvider.DidNotReceiveWithAnyArgs().GetTokenAsync(default);
        await fixture.OutboxRepository.DidNotReceiveWithAnyArgs().AddAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_ShouldRejectInvalidCallerBeforeAcquiringTheJobLock()
    {
        var fixture = new Fixture();

        var action = () => fixture.CreateHandler().Handle(
            new CompleteAgent365RegistrationCommand(Guid.NewGuid(), "not-an-object-id"),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(
            ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED);
        await fixture.LockProvider.DidNotReceiveWithAnyArgs().AcquireAsync(default, default);
        await fixture.TokenProvider.DidNotReceiveWithAnyArgs().GetTokenAsync(default);
        await fixture.RegistryClient.DidNotReceiveWithAnyArgs().CreateAsync(default!, default);
    }

    private static Scenario CreateAwaitingScenario()
    {
        var callerObjectId = Guid.NewGuid().ToString("D");
        var state = new Agent365ProvisioningState
        {
            BlueprintObjectId = Guid.NewGuid().ToString("D"),
            BlueprintClientId = Guid.NewGuid().ToString("D"),
            BlueprintPrincipalObjectId = Guid.NewGuid().ToString("D"),
            GatewayManagedIdentityPrincipalId = Guid.NewGuid().ToString("D"),
            GatewayFederatedCredentialId = "fic-resource-id_123",
            AgentIdentityObjectId = Guid.NewGuid().ToString("D"),
            AgentIdentityClientId = Guid.NewGuid().ToString("D"),
            ObservabilityAppRoleAssignmentId = "Lo6gEKI-4EyAy9X91LBepo6Aq0Rt6QxBjWRl76txk8I"
        };
        var agent = new AgentRegistration
        {
            Id = Guid.NewGuid(),
            ExternalAgentId = new ExternalAgentId($"agent-{Guid.NewGuid():N}"),
            Name = "Delegated Registry verification",
            Description = "Safe synthetic verification",
            OwnerObjectId = callerObjectId,
            Status = AgentStatus.AwaitingAdminApproval,
            CreatedAtUtc = DateTime.UtcNow.AddMinutes(-5),
            UpdatedAtUtc = DateTime.UtcNow.AddMinutes(-1),
            CreatedByObjectId = callerObjectId,
            UpdatedByObjectId = callerObjectId
        };
        var job = new ProvisioningJob
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            Type = OperationType.ProvisionAgent,
            Status = JobStatus.AwaitingAdministratorAction,
            PercentComplete = 71,
            WorkflowVersion = ProvisioningWorkflow.CurrentVersion,
            StartedAtUtc = DateTime.UtcNow.AddMinutes(-5),
            CreatedAtUtc = DateTime.UtcNow.AddMinutes(-5)
        };
        job.Steps = ProvisioningWorkflow.CurrentSteps
            .Select((stepType, index) => new ProvisioningJobStep
            {
                Id = Guid.NewGuid(),
                ProvisioningJobId = job.Id,
                StepType = stepType,
                OrderIndex = index,
                Status = index < 5 ? StepStatus.Completed : StepStatus.Pending,
                CompletedAtUtc = index < 5 ? DateTime.UtcNow.AddMinutes(-2) : null,
                ResultData = index < 5
                    ? JsonSerializer.Serialize(new Agent365ProvisioningStepResult(
                        stepType,
                        state,
                        $"verified_{stepType}"))
                    : null
            })
            .ToList();
        return new Scenario(
            callerObjectId,
            agent,
            job,
            job.Steps.Single(step => step.StepType == ProvisioningStepType.RegisterAgent),
            state);
    }

    private static void MarkRunningAttempt(Scenario scenario, string? returnedRegistryId)
    {
        scenario.Job.Status = JobStatus.AwaitingAdministratorAction;
        scenario.RegisterStep.Status = StepStatus.Running;
        scenario.RegisterStep.StartedAtUtc = DateTime.UtcNow.AddMinutes(-1);
        scenario.RegisterStep.ResultData = JsonSerializer.Serialize(new Agent365RegistryAttemptState(
            Agent365RegistryAttemptState.CurrentSchemaVersion,
            "DelegatedAdministrator",
            scenario.CallerObjectId,
            DateTimeOffset.UtcNow.AddMinutes(-1),
            Guid.NewGuid().ToString("D"),
            returnedRegistryId));
    }

    private static void CompleteRegistryStep(Scenario scenario, string registryId)
    {
        scenario.Job.Status = JobStatus.Running;
        scenario.Job.PercentComplete = 85;
        scenario.RegisterStep.Status = StepStatus.Completed;
        scenario.RegisterStep.CompletedAtUtc = DateTime.UtcNow;
        scenario.RegisterStep.ResultData = JsonSerializer.Serialize(new Agent365ProvisioningStepResult(
            ProvisioningStepType.RegisterAgent,
            scenario.State with
            {
                Agent365RegistrationId = registryId,
                RegistryProvider = "DirectRegistryPreview",
                RegistryAuthenticationMode = "DelegatedAdministrator",
                RegistryCreatedByObjectId = scenario.CallerObjectId,
                Agent365RegistrationVerifiedAtUtc = DateTimeOffset.UtcNow
            },
            "DelegatedRegistryRecordVerified"));
    }

    private static bool IsFinalVerificationMessage(
        OutboxMessage message,
        Guid agentId,
        Guid jobId)
    {
        if (message.MessageType != "ProvisionAgent" ||
            message.Status != OutboxMessageStatus.Pending)
        {
            return false;
        }

        var payload = JsonSerializer.Deserialize<ProvisionAgentMessage>(message.Payload);
        return payload is not null &&
               payload.AgentRegistrationId == agentId &&
               payload.JobId == jobId &&
               payload.ExpectedStepIndex == 6;
    }

    private sealed record Scenario(
        string CallerObjectId,
        AgentRegistration Agent,
        ProvisioningJob Job,
        ProvisioningJobStep RegisterStep,
        Agent365ProvisioningState State);

    private sealed class Fixture
    {
        public IAgentRepository AgentRepository { get; } = Substitute.For<IAgentRepository>();
        public IProvisioningJobRepository JobRepository { get; } =
            Substitute.For<IProvisioningJobRepository>();
        public IOutboxRepository OutboxRepository { get; } = Substitute.For<IOutboxRepository>();
        public IAuditEventRepository AuditRepository { get; } =
            Substitute.For<IAuditEventRepository>();
        public IAgent365DelegatedRegistryClient RegistryClient { get; } =
            Substitute.For<IAgent365DelegatedRegistryClient>();
        public IAgent365DelegatedTokenProvider TokenProvider { get; } =
            Substitute.For<IAgent365DelegatedTokenProvider>();
        public IProvisioningExecutionLockProvider LockProvider { get; } =
            Substitute.For<IProvisioningExecutionLockProvider>();
        public IUnitOfWork UnitOfWork { get; } = Substitute.For<IUnitOfWork>();

        public Fixture()
        {
            var lease = Substitute.For<IProvisioningExecutionLease>();
            LockProvider.AcquireAsync(Arg.Any<Guid>(), Arg.Any<CancellationToken>())
                .Returns(lease);
            TokenProvider.GetTokenAsync(Arg.Any<CancellationToken>())
                .Returns("opaque-test-value");
        }

        public void Arrange(Scenario scenario)
        {
            JobRepository.GetByIdAsync(scenario.Job.Id, Arg.Any<CancellationToken>())
                .Returns(scenario.Job);
            AgentRepository.GetByIdAsync(scenario.Agent.Id, Arg.Any<CancellationToken>())
                .Returns(scenario.Agent);
        }

        public CompleteAgent365RegistrationHandler CreateHandler() => new(
            AgentRepository,
            JobRepository,
            OutboxRepository,
            AuditRepository,
            RegistryClient,
            TokenProvider,
            LockProvider,
            UnitOfWork);
    }
}
