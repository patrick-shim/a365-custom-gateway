using System.Diagnostics;
using System.Text.Json;
using FluentAssertions;
using Gateway.Agent365;
using Gateway.Contracts;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Observability;
using Gateway.Provisioning.Worker;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using NSubstitute;

namespace Gateway.ObservabilityRuntime.Tests.Worker;

public sealed class ProvisioningMessageHandlerTests
{
    private const string PlannedRegistryId =
        "12121212-1212-4212-8212-121212121212";

    [Fact]
    public async Task HandleAsync_ProvisionAgentMalformedPayload_RequestsDeadLetter()
    {
        var fixture = new HandlerFixture();

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            "{not-json",
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_INVALID_MESSAGE);
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task HandleAsync_ProvisionAgentJobForDifferentAgent_RequestsDeadLetter()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var job = CreateProvisioningJob(Guid.NewGuid(), ProvisioningStepType.CreateAppRegistration);
        fixture.Arrange(agent, job);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_JOB_MISMATCH);
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task HandleAsync_ProvisionAgentOutOfOrderStepIndex_RequestsDeadLetter()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var job = CreateCurrentProvisioningJob(agent.Id);
        fixture.Arrange(agent, job);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id, expectedStepIndex: 1),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_STATE_INVALID);
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task HandleAsync_ProvisioningDisabled_FailsTruthfullyAndRequestsDeadLetter()
    {
        var fixture = new HandlerFixture(provisioningExecutionEnabled: false);
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var job = CreateCurrentProvisioningJob(agent.Id);
        var firstStep = job.Steps.OrderBy(step => step.OrderIndex).First();
        fixture.Arrange(agent, job);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_DISABLED);
        job.Status.Should().Be(JobStatus.Failed);
        job.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_DISABLED);
        agent.Status.Should().Be(AgentStatus.Failed);
        agent.LastProvisioningErrorCode.Should().Be(ErrorCodes.PROVISIONING_DISABLED);
        firstStep.Status.Should().Be(StepStatus.Failed);
        firstStep.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_DISABLED);
        job.Steps.Skip(1).Should().OnlyContain(step => step.Status == StepStatus.Pending);
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
    }

    [Fact]
    public async Task HandleAsync_ProvisioningNotImplemented_NeverCompletesStepOrJob()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var job = CreateCurrentProvisioningJob(agent.Id);
        var step = job.Steps.OrderBy(candidate => candidate.OrderIndex).First();
        fixture.Arrange(agent, job);
        fixture.ProvisioningClient.ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(Task.FromException<Agent365ProvisioningStepResult>(
                new NotImplementedException("raw dependency text must not persist")));

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_STEP_NOT_IMPLEMENTED);
        step.Status.Should().Be(StepStatus.Failed);
        job.Status.Should().Be(JobStatus.Failed);
        agent.Status.Should().Be(AgentStatus.Failed);
        step.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_STEP_NOT_IMPLEMENTED);
        job.PercentComplete.Should().Be(0);
        new[] { step.ErrorMessage, job.ErrorSummary, agent.LastProvisioningErrorSummary }
            .Should().NotContain("raw dependency text must not persist");
    }

    [Fact]
    public async Task HandleAsync_ProvisioningFailure_DoesNotPersistRawExceptionText()
    {
        const string rawDependencyText = "Bearer credential and dependency response must not persist";
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var job = CreateCurrentProvisioningJob(agent.Id);
        var step = job.Steps.OrderBy(candidate => candidate.OrderIndex).First();
        fixture.Arrange(agent, job);
        fixture.ProvisioningClient.ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(Task.FromException<Agent365ProvisioningStepResult>(
                new InvalidOperationException(rawDependencyText)));

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_FAILED);
        step.Status.Should().Be(StepStatus.Failed);
        job.Status.Should().Be(JobStatus.Failed);
        agent.Status.Should().Be(AgentStatus.Failed);
        new[]
        {
            step.ErrorMessage,
            job.ErrorSummary,
            agent.LastProvisioningErrorSummary,
            step.ResultData,
            string.Join("|", fixture.AddedAuditEvents.Select(auditEvent => auditEvent.Details))
        }.Should().NotContain(value =>
            value != null && value.Contains(rawDependencyText, StringComparison.Ordinal));
    }

    [Fact]
    public async Task HandleAsync_ProvisionAgent_SkipsCompletedStepAndResumesRemainingStep()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var job = CreateCurrentProvisioningJob(agent.Id);
        var steps = job.Steps.OrderBy(step => step.OrderIndex).ToArray();
        steps[0].Status = StepStatus.Completed;
        steps[0].CompletedAtUtc = DateTime.UtcNow.AddMinutes(-1);
        steps[0].ResultData = JsonSerializer.Serialize(new Agent365ProvisioningStepResult(
            steps[0].StepType,
            CreateSuccessfulState(steps[0].StepType),
            "verified_ResolveBlueprint"));
        fixture.Arrange(agent, job);
        fixture.ProvisioningClient.ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(call => CreateSuccessfulStepResult(
                call.Arg<Agent365ProvisioningStepRequest>()));

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id, expectedStepIndex: 1),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        await fixture.ProvisioningClient.Received(1).ExecuteStepAsync(
            Arg.Is<Agent365ProvisioningStepRequest>(request =>
                request.StepType == ProvisioningStepType.EnsureBlueprintPrincipal &&
                request.State.BlueprintObjectId == "blueprint-object-id" &&
                request.State.BlueprintClientId == "blueprint-client-id" &&
                request.State.PlannedAgent365RegistrationId == null),
            Arg.Any<CancellationToken>());
        steps.Take(2).Should().OnlyContain(step => step.Status == StepStatus.Completed);
        steps.Skip(2).Should().OnlyContain(step => step.Status == StepStatus.Pending);
        job.PercentComplete.Should().Be(28);
    }

    [Fact]
    public async Task HandleAsync_ProvisioningResultCannotDropDelegatedRegistryEvidence()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var job = CreateCurrentProvisioningJob(agent.Id);
        var steps = job.Steps.OrderBy(step => step.OrderIndex).ToArray();
        _ = CompletePrefix(steps, completedCount: 6);
        fixture.Arrange(agent, job);
        fixture.ProvisioningClient.ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(call =>
            {
                var request = call.Arg<Agent365ProvisioningStepRequest>();
                return new Agent365ProvisioningStepResult(
                    request.StepType,
                    request.State with
                    {
                        Agent365ConnectionVerifiedAtUtc = DateTimeOffset.UtcNow,
                        RegistryCreatedByObjectId = null
                    },
                    "verified_VerifyAgent365Connection");
            });

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id, expectedStepIndex: 6),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_STATE_INVALID);
        job.Status.Should().Be(JobStatus.RequiresManualIntervention);
        steps[6].Status.Should().Be(StepStatus.Failed);
    }

    [Fact]
    public async Task HandleAsync_NewResolveResultAllowsServiceGeneratedRegistryId()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var job = CreateCurrentProvisioningJob(agent.Id);
        var firstStep = job.Steps.OrderBy(step => step.OrderIndex).First();
        fixture.Arrange(agent, job);
        fixture.ProvisioningClient.ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(call =>
            {
                var request = call.Arg<Agent365ProvisioningStepRequest>();
                return new Agent365ProvisioningStepResult(
                    request.StepType,
                    request.State with
                    {
                        BlueprintObjectId = "blueprint-object-id",
                        BlueprintClientId = "blueprint-client-id"
                    },
                    "verified_ResolveBlueprint");
            });

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        job.Status.Should().Be(JobStatus.Running);
        firstStep.Status.Should().Be(StepStatus.Completed);
        fixture.AddedOutboxMessages.Should().ContainSingle();
    }

    // Workflow-v2 worker-owned Registry result validation is intentionally
    // unreachable in workflow v3.
#if false
    [Fact]
    public async Task HandleAsync_NewRegistryResultRequiresMatchingPlannedAndActualIds()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var job = CreateCurrentProvisioningJob(agent.Id);
        var steps = job.Steps.OrderBy(step => step.OrderIndex).ToArray();
        _ = CompletePrefix(steps, completedCount: 5);
        fixture.Arrange(agent, job);
        fixture.ProvisioningClient.ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(call =>
            {
                var request = call.Arg<Agent365ProvisioningStepRequest>();
                return new Agent365ProvisioningStepResult(
                    request.StepType,
                    request.State with
                    {
                        Agent365RegistrationId =
                            "34343434-3434-4434-8434-343434343434",
                        RegistryProvider = Agent365Options.DirectRegistryPreviewProvider
                    },
                    "DirectRegistryPreviewRecordVerified");
            });

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id, expectedStepIndex: 5),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_STATE_INVALID);
        job.Status.Should().Be(JobStatus.RequiresManualIntervention);
        steps[5].Status.Should().Be(StepStatus.Failed);
    }
#endif

    [Fact]
    public async Task HandleAsync_QueuedRegisterAgentMessageNeverInvokesWorkerAdapter()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        agent.Status = AgentStatus.AwaitingAdminApproval;
        var job = CreateCurrentProvisioningJob(agent.Id);
        var steps = job.Steps.OrderBy(step => step.OrderIndex).ToArray();
        _ = CompletePrefix(steps, completedCount: 5);
        job.Status = JobStatus.AwaitingAdministratorAction;
        job.PercentComplete = 71;
        fixture.Arrange(agent, job);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id, expectedStepIndex: 5),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        job.Status.Should().Be(JobStatus.AwaitingAdministratorAction);
        steps[5].Status.Should().Be(StepStatus.Pending);
        fixture.AddedOutboxMessages.Should().BeEmpty();
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
    }

#if false
    [Fact]
    public async Task HandleAsync_NewRegistryResultRejectsLegacyStateWithoutPlannedId()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var job = CreateCurrentProvisioningJob(agent.Id);
        var steps = job.Steps.OrderBy(step => step.OrderIndex).ToArray();
        _ = CompletePrefix(steps, completedCount: 5);
        foreach (var step in steps.Take(5))
        {
            var persisted = JsonSerializer.Deserialize<Agent365ProvisioningStepResult>(
                step.ResultData!);
            persisted.Should().NotBeNull();
            step.ResultData = JsonSerializer.Serialize(persisted! with
            {
                State = persisted.State with { PlannedAgent365RegistrationId = null }
            });
        }
        fixture.Arrange(agent, job);
        fixture.ProvisioningClient.ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(call =>
            {
                var request = call.Arg<Agent365ProvisioningStepRequest>();
                return new Agent365ProvisioningStepResult(
                    request.StepType,
                    request.State with
                    {
                        Agent365RegistrationId = PlannedRegistryId,
                        RegistryProvider = Agent365Options.DirectRegistryPreviewProvider
                    },
                    "DirectRegistryPreviewRecordVerified");
            });

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id, expectedStepIndex: 5),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_STATE_INVALID);
        job.Status.Should().Be(JobStatus.RequiresManualIntervention);
        steps[5].Status.Should().Be(StepStatus.Failed);
    }
#endif

    [Fact]
    public async Task HandleAsync_RetryRejectsPriorAmbiguousRegistryCreateWithPlannedId()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var prior = CreateAmbiguousRegistryPriorJob(agent.Id, preservePlannedId: true);
        var retry = CreateCurrentProvisioningJob(agent.Id);
        retry.Type = OperationType.RetryProvisioning;
        retry.CreatedAtUtc = prior.CreatedAtUtc.AddMinutes(1);
        fixture.Arrange(agent, retry);
        fixture.Jobs.GetByAgentIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns([prior, retry]);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, retry.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        retry.Status.Should().Be(JobStatus.RequiresManualIntervention);
        retry.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
    }

    [Fact]
    public async Task HandleAsync_RetryRejectsLegacyRegistryBoundaryWithoutPlannedId()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var prior = CreateAmbiguousRegistryPriorJob(agent.Id, preservePlannedId: false);
        var retry = CreateCurrentProvisioningJob(agent.Id);
        retry.Type = OperationType.RetryProvisioning;
        retry.CreatedAtUtc = prior.CreatedAtUtc.AddMinutes(1);
        fixture.Arrange(agent, retry);
        fixture.Jobs.GetByAgentIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns([retry, prior]);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, retry.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        retry.Status.Should().Be(JobStatus.RequiresManualIntervention);
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
    }

    [Fact]
    public async Task HandleAsync_RetryRejectsPriorLegacyProvisioningWorkflow()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var legacy = CreateProvisioningJob(
            agent.Id,
            ProvisioningStepType.CreateAppRegistration,
            ProvisioningStepType.CreateServicePrincipal);
        legacy.WorkflowVersion = ProvisioningWorkflow.CurrentVersion - 1;
        legacy.Status = JobStatus.Failed;
        legacy.CreatedAtUtc = DateTime.UtcNow.AddMinutes(-2);
        var retry = CreateCurrentProvisioningJob(agent.Id);
        retry.Type = OperationType.RetryProvisioning;
        retry.CreatedAtUtc = DateTime.UtcNow;
        fixture.Arrange(agent, retry);
        fixture.Jobs.GetByAgentIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns([retry, legacy]);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, retry.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_LEGACY_JOB);
        retry.Status.Should().Be(JobStatus.RequiresManualIntervention);
        retry.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_LEGACY_JOB);
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
    }

    [Fact]
    public async Task HandleAsync_RetryRejectsActivePriorJobBeforeAdapterExecution()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var prior = CreateCurrentProvisioningJob(agent.Id);
        _ = CompletePrefix(
            prior.Steps.OrderBy(step => step.OrderIndex).ToArray(),
            completedCount: 2);
        prior.Status = JobStatus.Running;
        prior.CreatedAtUtc = DateTime.UtcNow.AddMinutes(-2);
        var retry = CreateCurrentProvisioningJob(agent.Id);
        retry.Type = OperationType.RetryProvisioning;
        retry.CreatedAtUtc = DateTime.UtcNow;
        fixture.Arrange(agent, retry);
        fixture.Jobs.GetByAgentIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns([retry, prior]);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, retry.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_STATE_INVALID);
        retry.Status.Should().Be(JobStatus.RequiresManualIntervention);
        retry.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_STATE_INVALID);
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
    }

    [Fact]
    public async Task HandleAsync_RetryRejectsRunningStageInFailedPriorJob()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var prior = CreateCurrentProvisioningJob(agent.Id);
        _ = CompletePrefix(
            prior.Steps.OrderBy(step => step.OrderIndex).ToArray(),
            completedCount: 1);
        var unresolvedStep = prior.Steps.OrderBy(step => step.OrderIndex).ElementAt(1);
        unresolvedStep.Status = StepStatus.Running;
        unresolvedStep.StartedAtUtc = DateTime.UtcNow.AddMinutes(-2);
        prior.Status = JobStatus.Failed;
        prior.ErrorCode = ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE;
        prior.CreatedAtUtc = DateTime.UtcNow.AddMinutes(-2);
        var retry = CreateCurrentProvisioningJob(agent.Id);
        retry.Type = OperationType.RetryProvisioning;
        retry.CreatedAtUtc = DateTime.UtcNow;
        fixture.Arrange(agent, retry);
        fixture.Jobs.GetByAgentIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns([retry, prior]);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, retry.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        retry.Status.Should().Be(JobStatus.RequiresManualIntervention);
        retry.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
    }

    [Fact]
    public async Task HandleAsync_RetryRejectsMissingPriorProvisioningSource()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var retry = CreateCurrentProvisioningJob(agent.Id);
        retry.Type = OperationType.RetryProvisioning;
        fixture.Arrange(agent, retry);
        fixture.Jobs.GetByAgentIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns([retry]);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, retry.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_STATE_INVALID);
        retry.Status.Should().Be(JobStatus.RequiresManualIntervention);
        retry.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_STATE_INVALID);
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
    }

    [Fact]
    public async Task HandleAsync_RetryRejectsVerifiedRegistryHistoryWithoutPlannedId()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var prior = CreateCurrentProvisioningJob(agent.Id);
        var priorSteps = prior.Steps.OrderBy(step => step.OrderIndex).ToArray();
        _ = CompletePrefix(priorSteps, completedCount: 6);
        foreach (var step in priorSteps.Take(6))
        {
            var persisted = JsonSerializer.Deserialize<Agent365ProvisioningStepResult>(
                step.ResultData!);
            persisted.Should().NotBeNull();
            step.ResultData = JsonSerializer.Serialize(persisted! with
            {
                State = persisted.State with { PlannedAgent365RegistrationId = null }
            });
        }

        priorSteps[6].Status = StepStatus.Failed;
        prior.Status = JobStatus.Failed;
        prior.CreatedAtUtc = DateTime.UtcNow.AddMinutes(-2);
        var retry = CreateCurrentProvisioningJob(agent.Id);
        retry.Type = OperationType.RetryProvisioning;
        retry.CreatedAtUtc = DateTime.UtcNow;
        fixture.Arrange(agent, retry);
        fixture.Jobs.GetByAgentIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns([retry, prior]);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, retry.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        retry.Status.Should().Be(JobStatus.RequiresManualIntervention);
        retry.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
    }

    [Fact]
    public async Task HandleAsync_RetryUsesNewestTerminalRetrySafePrefix()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var prior = CreateCurrentProvisioningJob(agent.Id);
        var priorSteps = prior.Steps.OrderBy(step => step.OrderIndex).ToArray();
        var priorState = CompletePrefix(priorSteps, completedCount: 1);
        priorSteps[1].Status = StepStatus.Failed;
        priorSteps[1].ErrorCode = ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE;
        prior.Status = JobStatus.Failed;
        prior.ErrorCode = ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE;
        prior.CreatedAtUtc = DateTime.UtcNow.AddMinutes(-2);
        var retry = CreateCurrentProvisioningJob(agent.Id);
        retry.Type = OperationType.RetryProvisioning;
        retry.CreatedAtUtc = DateTime.UtcNow;
        fixture.Arrange(agent, retry);
        fixture.Jobs.GetByAgentIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns([retry, prior]);
        fixture.ProvisioningClient.ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(call => CreateSuccessfulStepResult(
                call.Arg<Agent365ProvisioningStepRequest>()));

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, retry.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        await fixture.ProvisioningClient.Received(1).ExecuteStepAsync(
            Arg.Is<Agent365ProvisioningStepRequest>(request =>
                request.StepType == ProvisioningStepType.ResolveBlueprint &&
                request.State.BlueprintObjectId == priorState.BlueprintObjectId &&
                request.State.PlannedAgent365RegistrationId ==
                priorState.PlannedAgent365RegistrationId),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task HandleAsync_RetryScansAllPriorJobsBeforeChoosingNewestSafePrefix()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var unsafePrior = CreateAmbiguousRegistryPriorJob(
            agent.Id,
            preservePlannedId: true);
        unsafePrior.CreatedAtUtc = DateTime.UtcNow.AddMinutes(-3);
        var safeNewer = CreateCurrentProvisioningJob(agent.Id);
        _ = CompletePrefix(
            safeNewer.Steps.OrderBy(step => step.OrderIndex).ToArray(),
            completedCount: 2);
        safeNewer.Steps.OrderBy(step => step.OrderIndex).ElementAt(2).Status =
            StepStatus.Failed;
        safeNewer.Status = JobStatus.Failed;
        safeNewer.CreatedAtUtc = DateTime.UtcNow.AddMinutes(-2);
        var retry = CreateCurrentProvisioningJob(agent.Id);
        retry.Type = OperationType.RetryProvisioning;
        retry.CreatedAtUtc = DateTime.UtcNow;
        fixture.Arrange(agent, retry);
        fixture.Jobs.GetByAgentIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns([safeNewer, retry, unsafePrior]);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, retry.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        retry.Status.Should().Be(JobStatus.RequiresManualIntervention);
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
    }

    [Fact]
    public async Task HandleAsync_ProvisionAgentDuplicateReplay_DoesNotExecuteCompletedStepAgain()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var job = CreateCurrentProvisioningJob(agent.Id);
        var firstStep = job.Steps.OrderBy(step => step.OrderIndex).First();
        firstStep.Status = StepStatus.Completed;
        firstStep.CompletedAtUtc = DateTime.UtcNow.AddMinutes(-1);
        firstStep.ResultData = JsonSerializer.Serialize(new Agent365ProvisioningStepResult(
            firstStep.StepType,
            CreateSuccessfulState(firstStep.StepType),
            "verified_ResolveBlueprint"));
        job.Status = JobStatus.Running;
        job.PercentComplete = 14;
        fixture.Arrange(agent, job);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id, expectedStepIndex: 0),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
        job.Steps.Skip(1).Should().OnlyContain(step => step.Status == StepStatus.Pending);
        job.PercentComplete.Should().Be(14);
    }

    [Theory]
    [InlineData(AgentStatus.Active)]
    [InlineData(AgentStatus.Disabled)]
    [InlineData(AgentStatus.Failed)]
    [InlineData(AgentStatus.Deleting)]
    [InlineData(AgentStatus.Deleted)]
    [InlineData(AgentStatus.RequiresManualIntervention)]
    public async Task HandleAsync_CompletedJobStaleDelivery_NeverOverridesNonProvisioningAgentState(
        AgentStatus persistedStatus)
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        agent.Status = persistedStatus;
        var job = CreateCurrentProvisioningJob(agent.Id);
        CompleteProvisioningJob(job);
        fixture.Arrange(agent, job);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(
                agent.Id,
                job.Id,
                ProvisioningWorkflow.CurrentSteps.Count - 1),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        agent.Status.Should().Be(persistedStatus);
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
    }

#if false
    [Fact]
    public async Task HandleAsync_RedeliveredRunningRegistryCreate_UsesPlannedIdForGetOnlyRecovery()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        agent.Status = AgentStatus.Provisioning;
        var job = CreateCurrentProvisioningJob(agent.Id);
        var steps = job.Steps.OrderBy(step => step.OrderIndex).ToArray();
        var state = CompletePrefix(steps, completedCount: 5);
        state.Agent365RegistrationId.Should().BeNull();
        var registryStep = steps[5];
        registryStep.Status = StepStatus.Running;
        registryStep.StartedAtUtc = DateTime.UtcNow.AddMinutes(-1);
        job.Status = JobStatus.Running;
        job.PercentComplete = 71;
        fixture.Arrange(agent, job);
        fixture.ProvisioningClient.ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(call =>
            {
                var request = call.Arg<Agent365ProvisioningStepRequest>();
                return new Agent365ProvisioningStepResult(
                    request.StepType,
                    request.State with
                    {
                        RegistryProvider = Agent365Options.DirectRegistryPreviewProvider
                    },
                    "DirectRegistryPreviewRecordVerified");
            });

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id, expectedStepIndex: 5),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        registryStep.Status.Should().Be(StepStatus.Completed);
        job.Status.Should().Be(JobStatus.Running);
        job.PercentComplete.Should().Be(85);
        await fixture.ProvisioningClient.Received(1).ExecuteStepAsync(
            Arg.Is<Agent365ProvisioningStepRequest>(request =>
                request.StepType == ProvisioningStepType.RegisterAgent &&
                request.State.PlannedAgent365RegistrationId ==
                    PlannedRegistryId &&
                request.State.Agent365RegistrationId ==
                    PlannedRegistryId),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task HandleAsync_RedeliveredRunningRegistryCreate_MissingKnownIdStaysManual()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        agent.Status = AgentStatus.Provisioning;
        var job = CreateCurrentProvisioningJob(agent.Id);
        var steps = job.Steps.OrderBy(step => step.OrderIndex).ToArray();
        _ = CompletePrefix(steps, completedCount: 5);
        var registryStep = steps[5];
        registryStep.Status = StepStatus.Running;
        registryStep.StartedAtUtc = DateTime.UtcNow.AddMinutes(-1);
        job.Status = JobStatus.Running;
        job.PercentComplete = 71;
        fixture.Arrange(agent, job);
        fixture.ProvisioningClient.ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(Task.FromException<Agent365ProvisioningStepResult>(
                new Agent365ProvisioningException(
                    ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                    "The planned Registry record was not found.",
                    requiresManualIntervention: true)));

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id, expectedStepIndex: 5),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        job.Status.Should().Be(JobStatus.RequiresManualIntervention);
        registryStep.Status.Should().Be(StepStatus.Failed);
        agent.Status.Should().Be(AgentStatus.RequiresManualIntervention);
        await fixture.ProvisioningClient.Received(1).ExecuteStepAsync(
            Arg.Is<Agent365ProvisioningStepRequest>(request =>
                request.State.Agent365RegistrationId ==
                    PlannedRegistryId),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task HandleAsync_RedeliveredRunningRegistryCreate_InconclusiveGetStaysManual()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        agent.Status = AgentStatus.Provisioning;
        var job = CreateCurrentProvisioningJob(agent.Id);
        var steps = job.Steps.OrderBy(step => step.OrderIndex).ToArray();
        _ = CompletePrefix(steps, completedCount: 5);
        var registryStep = steps[5];
        registryStep.Status = StepStatus.Running;
        registryStep.StartedAtUtc = DateTime.UtcNow.AddMinutes(-1);
        job.Status = JobStatus.Running;
        job.PercentComplete = 71;
        fixture.Arrange(agent, job);
        fixture.ProvisioningClient.ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(Task.FromException<Agent365ProvisioningStepResult>(
                new Agent365ProvisioningException(
                    "MICROSOFT_GRAPH_TRANSIENT",
                    "Microsoft Graph is temporarily unavailable.",
                    isTransient: true)));

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id, expectedStepIndex: 5),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        job.Status.Should().Be(JobStatus.RequiresManualIntervention);
        registryStep.Status.Should().Be(StepStatus.Failed);
        agent.Status.Should().Be(AgentStatus.RequiresManualIntervention);
    }

    [Theory]
    [InlineData("nontransient")]
    [InlineData("raw")]
    [InlineData("not-implemented")]
    public async Task HandleAsync_RedeliveredRunningRegistryCreate_AnyReadFailureStaysManual(
        string failureKind)
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        agent.Status = AgentStatus.Provisioning;
        var job = CreateCurrentProvisioningJob(agent.Id);
        var steps = job.Steps.OrderBy(step => step.OrderIndex).ToArray();
        _ = CompletePrefix(steps, completedCount: 5);
        var registryStep = steps[5];
        registryStep.Status = StepStatus.Running;
        registryStep.StartedAtUtc = DateTime.UtcNow.AddMinutes(-1);
        job.Status = JobStatus.Running;
        job.PercentComplete = 71;
        fixture.Arrange(agent, job);
        Exception failure = failureKind switch
        {
            "nontransient" => new Agent365ProvisioningException(
                ErrorCodes.PROVISIONING_DEPENDENCY_FORBIDDEN,
                "The Registry read was rejected."),
            "raw" => new InvalidOperationException("raw read failure"),
            "not-implemented" => new NotImplementedException("read unavailable"),
            _ => throw new ArgumentOutOfRangeException(nameof(failureKind))
        };
        fixture.ProvisioningClient.ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(Task.FromException<Agent365ProvisioningStepResult>(failure));

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id, expectedStepIndex: 5),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        job.Status.Should().Be(JobStatus.RequiresManualIntervention);
        job.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        registryStep.Status.Should().Be(StepStatus.Failed);
        registryStep.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        agent.Status.Should().Be(AgentStatus.RequiresManualIntervention);
    }
#endif

    [Fact]
    public async Task HandleAsync_StaleRunningRegisterMessageNeverInvokesWorkerAdapter()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        agent.Status = AgentStatus.Provisioning;
        var job = CreateCurrentProvisioningJob(agent.Id);
        var steps = job.Steps.OrderBy(step => step.OrderIndex).ToArray();
        _ = CompletePrefix(steps, completedCount: 5);
        var registryStep = steps[5];
        registryStep.Status = StepStatus.Running;
        registryStep.StartedAtUtc = DateTime.UtcNow.AddMinutes(-1);
        job.Status = JobStatus.Running;
        job.PercentComplete = 71;
        fixture.Arrange(agent, job);

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id, expectedStepIndex: 5),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        job.Status.Should().Be(JobStatus.Running);
        registryStep.Status.Should().Be(StepStatus.Running);
        fixture.AddedOutboxMessages.Should().BeEmpty();
        await fixture.ProvisioningClient.DidNotReceiveWithAnyArgs()
            .ExecuteStepAsync(default!, default);
    }

    [Fact]
    public async Task HandleAsync_ProvisionAgent_ExecutesExactlyOneExternalStepPerIteration()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var job = CreateCurrentProvisioningJob(agent.Id);
        var steps = job.Steps.OrderBy(step => step.OrderIndex).ToArray();
        fixture.Arrange(agent, job);
        fixture.ProvisioningClient.ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(call => CreateSuccessfulStepResult(
                call.Arg<Agent365ProvisioningStepRequest>()));

        var result = await fixture.Handler.HandleAsync(
            "ProvisionAgent",
            CreateProvisioningPayload(agent.Id, job.Id),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        await fixture.ProvisioningClient.Received(1).ExecuteStepAsync(
            Arg.Is<Agent365ProvisioningStepRequest>(request =>
                request.StepType == ProvisioningStepType.ResolveBlueprint),
            Arg.Any<CancellationToken>());
        fixture.AddedOutboxMessages.Should().ContainSingle();
        var continuation = JsonSerializer.Deserialize<ProvisionAgentMessage>(
            fixture.AddedOutboxMessages.Single().Payload);
        continuation.Should().NotBeNull();
        continuation!.AgentRegistrationId.Should().Be(agent.Id);
        continuation.JobId.Should().Be(job.Id);
        continuation.ExpectedStepIndex.Should().Be(1);
        steps[0].Status.Should().Be(StepStatus.Completed);
        steps.Skip(1).Should().OnlyContain(step => step.Status == StepStatus.Pending);
        job.Status.Should().Be(JobStatus.Running);
        job.PercentComplete.Should().Be(14);
    }

    [Fact]
    public async Task HandleAsync_ProvisionAgentSuccessfulWorkerPrefix_PausesForAdministrator()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var job = CreateCurrentProvisioningJob(agent.Id);
        fixture.Arrange(agent, job);
        fixture.ProvisioningClient.ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(call => CreateSuccessfulStepResult(
                call.Arg<Agent365ProvisioningStepRequest>()));

        MessageHandlingResult? result = null;
        for (var expectedStepIndex = 0;
             expectedStepIndex < 5;
             expectedStepIndex++)
        {
            result = await fixture.Handler.HandleAsync(
                "ProvisionAgent",
                CreateProvisioningPayload(agent.Id, job.Id, expectedStepIndex),
                CancellationToken.None);
            result.ShouldDeadLetter.Should().BeFalse();
        }

        result.Should().NotBeNull();
        agent.Status.Should().Be(AgentStatus.AwaitingAdminApproval);
        job.Status.Should().Be(JobStatus.AwaitingAdministratorAction);
        job.PercentComplete.Should().Be(71);
        job.Steps.OrderBy(step => step.OrderIndex).Take(5)
            .Should().OnlyContain(step => step.Status == StepStatus.Completed);
        job.Steps.OrderBy(step => step.OrderIndex).Skip(5)
            .Should().OnlyContain(step => step.Status == StepStatus.Pending);
        var stepRequests = fixture.ProvisioningClient.ReceivedCalls()
            .Where(call => call.GetMethodInfo().Name == nameof(IAgent365ProvisioningClient.ExecuteStepAsync))
            .Select(call => call.GetArguments()[0])
            .Cast<Agent365ProvisioningStepRequest>()
            .ToArray();
        stepRequests.Should().HaveCount(5);
        stepRequests.Select(request => request.StepType)
            .Should().Equal(ProvisioningWorkflow.CurrentSteps.Take(5));
        stepRequests.GroupBy(request => request.StepType)
            .Should().OnlyContain(group => group.Count() == 1);
        await fixture.ProvisioningClient.Received(5)
            .ExecuteStepAsync(
                Arg.Any<Agent365ProvisioningStepRequest>(),
                Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task HandleAsync_UnknownMessageType_RequestsDeadLetter()
    {
        var fixture = new HandlerFixture();

        var result = await fixture.Handler.HandleAsync(
            "NotSupported",
            "{}",
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be("UnknownMessageType");
        await fixture.UnitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task HandleAsync_LegacyActivityWithoutSnapshot_FallsBackToCurrentGatewayOnlyMode()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.GatewayOnly);
        var receipt = CreateReceipt(agent.Id, ActivityType.Chat);
        fixture.Arrange(agent, receipt);
        Activity? mirroredActivity = null;
        using var listener = CreateListener(activity => mirroredActivity = activity);

        var result = await fixture.Handler.HandleAsync(
            "ProcessActivity",
            CreateActivityPayload(agent.Id, receipt.Id, tenantUserObjectId: null),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        receipt.ProcessingStatus.Should().Be(ProcessingStatus.Processed);
        receipt.ProcessedAtUtc.Should().NotBeNull();
        await fixture.Exporter.DidNotReceiveWithAnyArgs()
            .ExportActivityAsync(default!, default);
        mirroredActivity.Should().NotBeNull();
        mirroredActivity!.OperationName.Should().Be(GatewayActivitySource.Operations.MirrorSanitizedTelemetry);
        mirroredActivity.GetTagItem("gateway.agent.registration_id").Should().Be(agent.Id.ToString("D"));
        mirroredActivity.GetTagItem("gateway.record.type").Should().Be("activity");
        mirroredActivity.GetTagItem("gateway.operation").Should().Be("chat");
        var allowedTags = new HashSet<string>(StringComparer.Ordinal)
        {
            "gateway.agent.registration_id",
            "gateway.event.id",
            "gateway.record.type",
            "gateway.operation",
            "gateway.export.destination"
        };
        mirroredActivity.TagObjects.Select(tag => tag.Key).Should().OnlyContain(tag =>
            allowedTags.Contains(tag));
    }

    [Fact]
    public async Task HandleAsync_ActivitySnapshot_TakesPrecedenceOverCurrentAgentMode()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.GatewayOnly);
        var receipt = CreateReceipt(agent.Id, ActivityType.Chat);
        fixture.Arrange(agent, receipt);
        Activity? mirroredActivity = null;
        using var listener = CreateListener(activity => mirroredActivity = activity);

        var result = await fixture.Handler.HandleAsync(
            "ProcessActivity",
            CreateActivityPayloadWithSnapshot(
                agent.Id,
                receipt.Id,
                UserObjectId.ToString("D"),
                agent365ObservabilityEnabled: true,
                azureMonitorExportEnabled: false),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        await fixture.Exporter.Received(1).ExportActivityAsync(
            Arg.Is<ObservabilityExportRequest>(request => request.EventId == receipt.Id),
            Arg.Any<CancellationToken>());
        mirroredActivity.Should().BeNull();
    }

    [Fact]
    public async Task HandleAsync_InteractionSnapshot_TakesPrecedenceOverCurrentAgentMode()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var interaction = CreateInteraction(agent.Id);
        fixture.Arrange(agent, interaction);
        Activity? mirroredActivity = null;
        using var listener = CreateListener(activity => mirroredActivity = activity);

        var result = await fixture.Handler.HandleAsync(
            "ExportInteraction",
            CreateInteractionPayloadWithSnapshot(
                agent.Id,
                interaction.Id,
                agent365ObservabilityEnabled: false,
                azureMonitorExportEnabled: true),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        await fixture.Exporter.DidNotReceiveWithAnyArgs()
            .ExportActivityAsync(default!, default);
        mirroredActivity.Should().NotBeNull();
        mirroredActivity!.GetTagItem("gateway.record.type").Should().Be("interaction");
    }

    [Fact]
    public async Task HandleAsync_PartialActivitySnapshot_FallsBackEntirelyToCurrentAgentMode()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.GatewayOnly);
        var receipt = CreateReceipt(agent.Id, ActivityType.Chat);
        fixture.Arrange(agent, receipt);
        Activity? mirroredActivity = null;
        using var listener = CreateListener(activity => mirroredActivity = activity);
        var payload = JsonSerializer.Serialize(new
        {
            AgentId = agent.Id,
            ReceiptId = receipt.Id,
            CorrelationId = receipt.CorrelationId,
            ActorTenantUserObjectId = UserObjectId.ToString("D"),
            Agent365ObservabilityEnabled = true
        });

        var result = await fixture.Handler.HandleAsync(
            "ProcessActivity",
            payload,
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        await fixture.Exporter.DidNotReceiveWithAnyArgs()
            .ExportActivityAsync(default!, default);
        mirroredActivity.Should().NotBeNull();
        mirroredActivity!.GetTagItem("gateway.export.destination").Should().Be("azure_monitor");
    }

    [Fact]
    public async Task HandleAsync_Agent365AndAzureWithoutUser_FailsAgent365AndStillMirrorsAzure()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365AzureMonitor);
        var receipt = CreateReceipt(agent.Id, ActivityType.OutputMessages);
        fixture.Arrange(agent, receipt);
        fixture.Exporter.ExportActivityAsync(Arg.Any<ObservabilityExportRequest>(), Arg.Any<CancellationToken>())
            .Returns(Task.FromException(
                new Agent365ObservabilityConfigurationException("MissingUserContext")));
        AuditEvent? auditEvent = null;
        fixture.AuditEvents.AddAsync(
                Arg.Do<AuditEvent>(value => auditEvent = value),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);
        Activity? mirroredActivity = null;
        using var listener = CreateListener(activity => mirroredActivity = activity);

        var result = await fixture.Handler.HandleAsync(
            "ProcessActivity",
            CreateActivityPayload(agent.Id, receipt.Id, tenantUserObjectId: null),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        receipt.ProcessingStatus.Should().Be(ProcessingStatus.Failed);
        receipt.ProcessedAtUtc.Should().NotBeNull();
        mirroredActivity.Should().NotBeNull();
        mirroredActivity!.GetTagItem("gateway.operation").Should().Be("output_messages");
        auditEvent.Should().NotBeNull();
        auditEvent!.EventType.Should().Be("ObservabilityExportFailed");
        auditEvent.Details.Should().Be(
            JsonSerializer.Serialize(new { RecordType = "activity", ErrorCode = "MissingUserContext" }));
    }

    [Fact]
    public async Task HandleAsync_TransientAgent365Failure_ResetsActivityForServiceBusRetry()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var receipt = CreateReceipt(agent.Id, ActivityType.Chat);
        fixture.Arrange(agent, receipt);
        fixture.Exporter.ExportActivityAsync(Arg.Any<ObservabilityExportRequest>(), Arg.Any<CancellationToken>())
            .Returns(Task.FromException(new Agent365ObservabilityTransientException("Http503")));

        var action = () => fixture.Handler.HandleAsync(
            "ProcessActivity",
            CreateActivityPayload(agent.Id, receipt.Id, UserObjectId.ToString("D")),
            CancellationToken.None);

        await action.Should().ThrowAsync<Agent365ObservabilityTransientException>();
        receipt.ProcessingStatus.Should().Be(ProcessingStatus.Accepted);
        receipt.ProcessedAtUtc.Should().BeNull();
        await fixture.UnitOfWork.Received(2).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task HandleAsync_CompositeTransientFailure_MirrorsAzureOnlyOnceAcrossRetries()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365AzureMonitor);
        var receipt = CreateReceipt(agent.Id, ActivityType.Chat);
        fixture.Arrange(agent, receipt);
        fixture.Exporter.ExportActivityAsync(
                Arg.Any<ObservabilityExportRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(Task.FromException(new Agent365ObservabilityTransientException("Http503")));
        int mirrorCount = 0;
        using var listener = CreateListener(_ => mirrorCount++);
        var payload = CreateActivityPayload(
            agent.Id,
            receipt.Id,
            UserObjectId.ToString("D"));

        for (int attempt = 0; attempt < 2; attempt++)
        {
            var action = () => fixture.Handler.HandleAsync(
                "ProcessActivity",
                payload,
                CancellationToken.None);

            await action.Should().ThrowAsync<Agent365ObservabilityTransientException>();
        }

        mirrorCount.Should().Be(1);
        receipt.ProcessingStatus.Should().Be(ProcessingStatus.Accepted);
        await fixture.Exporter.Received(2).ExportActivityAsync(
            Arg.Any<ObservabilityExportRequest>(),
            Arg.Any<CancellationToken>());
        await fixture.AuditEvents.Received(1).AddAsync(
            Arg.Is<AuditEvent>(auditEvent =>
                auditEvent.EventType == "AzureMonitorMirrorScheduled"),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task HandleRetryExhaustedAsync_Activity_PersistsFailureAndAuditBeforeDeadLetter()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var receipt = CreateReceipt(agent.Id, ActivityType.Chat);
        fixture.Arrange(agent, receipt);
        AuditEvent? failureAudit = null;
        fixture.AuditEvents.AddAsync(
                Arg.Do<AuditEvent>(auditEvent => failureAudit = auditEvent),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        var result = await fixture.Handler.HandleRetryExhaustedAsync(
            "ProcessActivity",
            CreateActivityPayload(agent.Id, receipt.Id, UserObjectId.ToString("D")),
            "Http503",
            CancellationToken.None);

        result.Should().NotBeNull();
        result!.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be("ObservabilityRetriesExhausted");
        receipt.ProcessingStatus.Should().Be(ProcessingStatus.Failed);
        receipt.ProcessedAtUtc.Should().NotBeNull();
        failureAudit.Should().NotBeNull();
        failureAudit!.EventType.Should().Be("ObservabilityExportFailed");
        failureAudit.Details.Should().Contain("RetriesExhausted");
        failureAudit.Details.Should().Contain("Http503");
        await fixture.UnitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task HandleRetryExhaustedAsync_Interaction_PersistsFailureAndAuditBeforeDeadLetter()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var interaction = CreateInteraction(agent.Id);
        fixture.Arrange(agent, interaction);
        AuditEvent? failureAudit = null;
        fixture.AuditEvents.AddAsync(
                Arg.Do<AuditEvent>(auditEvent => failureAudit = auditEvent),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        var result = await fixture.Handler.HandleRetryExhaustedAsync(
            "ExportInteraction",
            CreateInteractionPayloadWithSnapshot(
                agent.Id,
                interaction.Id,
                agent365ObservabilityEnabled: true,
                azureMonitorExportEnabled: false),
            "Http503",
            CancellationToken.None);

        result.Should().NotBeNull();
        result!.ShouldDeadLetter.Should().BeTrue();
        result.DeadLetterReason.Should().Be("ObservabilityRetriesExhausted");
        interaction.ObservabilityStatus.Should().Be("Failed");
        interaction.ProcessingStatus.Should().Be(ProcessingStatus.Failed);
        interaction.ProcessedAtUtc.Should().NotBeNull();
        failureAudit.Should().NotBeNull();
        failureAudit!.EventType.Should().Be("ObservabilityExportFailed");
        failureAudit.Details.Should().Contain("RetriesExhausted");
        failureAudit.Details.Should().Contain("Http503");
        await fixture.UnitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task HandleAsync_LegacyInteractionWithoutSnapshot_FallsBackToCurrentAgent365ModeAndExportsOnlyPersistedSafeMetadata()
    {
        var fixture = new HandlerFixture();
        var agent = CreateAgent(ObservabilityMode.Agent365);
        var interaction = CreateInteraction(agent.Id);
        fixture.Arrange(agent, interaction);
        ObservabilityExportRequest? exportRequest = null;
        fixture.Exporter.ExportActivityAsync(
                Arg.Do<ObservabilityExportRequest>(value => exportRequest = value),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        var result = await fixture.Handler.HandleAsync(
            "ExportInteraction",
            JsonSerializer.Serialize(new
            {
                AgentId = agent.Id,
                RecordId = interaction.Id,
                CorrelationId = interaction.CorrelationId
            }),
            CancellationToken.None);

        result.ShouldDeadLetter.Should().BeFalse();
        interaction.ObservabilityStatus.Should().Be("Completed");
        interaction.ProcessingStatus.Should().Be(ProcessingStatus.Processed);
        exportRequest.Should().NotBeNull();
        exportRequest!.TenantUserObjectId.Should().Be(interaction.TenantUserObjectId);
        exportRequest.ModelProvider.Should().Be(interaction.ModelProvider);
        exportRequest.ModelName.Should().Be(interaction.ModelName);
        typeof(ObservabilityExportRequest).GetProperties().Select(property => property.Name)
            .Should().NotContain(name =>
                name.Contains("Content", StringComparison.OrdinalIgnoreCase)
                || name.Contains("Prompt", StringComparison.OrdinalIgnoreCase)
                || name.Contains("Response", StringComparison.OrdinalIgnoreCase)
                || name.Contains("Token", StringComparison.OrdinalIgnoreCase)
                || name.Contains("Secret", StringComparison.OrdinalIgnoreCase));
    }

    private static readonly Guid UserObjectId =
        Guid.Parse("33333333-3333-4333-8333-333333333333");

    private static AgentRegistration CreateAgent(ObservabilityMode mode)
    {
        var id = Guid.NewGuid();
        return new AgentRegistration
        {
            Id = id,
            ExternalAgentId = new ExternalAgentId("external-agent-1"),
            Name = "Test agent",
            Description = "Provisioning regression test agent",
            OwnerObjectId = UserObjectId.ToString("D"),
            Environment = AgentEnvironment.Development,
            BlueprintSelectionMode = "CreateNew",
            RequestedBlueprintDisplayName = "Shared development blueprint",
            FeatureConfiguration = new AgentFeatureConfiguration
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = id,
                ObservabilityMode = mode
            }
        };
    }

    private static ProvisioningJob CreateProvisioningJob(
        Guid agentId,
        params ProvisioningStepType[] stepTypes)
    {
        var job = new ProvisioningJob
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agentId,
            Type = OperationType.ProvisionAgent,
            Status = JobStatus.Pending,
            WorkflowVersion = ProvisioningWorkflow.CurrentVersion,
            CreatedAtUtc = DateTime.UtcNow,
            StartedAtUtc = DateTime.UtcNow,
            PercentComplete = 0
        };

        job.Steps = stepTypes
            .Select((stepType, index) => new ProvisioningJobStep
            {
                Id = Guid.NewGuid(),
                ProvisioningJobId = job.Id,
                StepType = stepType,
                Status = StepStatus.Pending,
                OrderIndex = index,
                ProvisioningJob = job
            })
            .ToList();

        return job;
    }

    private static ProvisioningJob CreateCurrentProvisioningJob(Guid agentId) =>
        CreateProvisioningJob(agentId, ProvisioningWorkflow.CurrentSteps.ToArray());

    private static ProvisioningJob CreateAmbiguousRegistryPriorJob(
        Guid agentId,
        bool preservePlannedId)
    {
        var job = CreateCurrentProvisioningJob(agentId);
        var steps = job.Steps.OrderBy(step => step.OrderIndex).ToArray();
        _ = CompletePrefix(steps, completedCount: 5);
        if (!preservePlannedId)
        {
            foreach (var step in steps.Take(5))
            {
                var persisted = JsonSerializer.Deserialize<Agent365ProvisioningStepResult>(
                    step.ResultData!);
                persisted.Should().NotBeNull();
                step.ResultData = JsonSerializer.Serialize(persisted! with
                {
                    State = persisted.State with { PlannedAgent365RegistrationId = null }
                });
            }
        }

        var registryStep = steps[5];
        registryStep.Status = StepStatus.Failed;
        registryStep.StartedAtUtc = DateTime.UtcNow.AddMinutes(-2);
        registryStep.ErrorCode = ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT;
        registryStep.ErrorMessage = "The Registry create outcome is unknown.";
        job.Status = JobStatus.RequiresManualIntervention;
        job.ErrorCode = ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT;
        job.ErrorSummary = "The Registry create outcome is unknown.";
        job.PercentComplete = 71;
        job.CreatedAtUtc = DateTime.UtcNow.AddMinutes(-2);
        return job;
    }

    private static Agent365ProvisioningStepResult CreateSuccessfulStepResult(
        Agent365ProvisioningStepRequest request) =>
        new(
            request.StepType,
            CreateSuccessfulState(request.StepType, request.State),
            CompletionEvidence: $"verified_{request.StepType}");

    private static Agent365ProvisioningState CreateSuccessfulState(
        ProvisioningStepType stepType,
        Agent365ProvisioningState? current = null)
    {
        var state = current ?? new Agent365ProvisioningState();
        return stepType switch
        {
            ProvisioningStepType.CreateAppRegistration => state with
            {
                ApplicationObjectId = "application-object-id",
                ApplicationClientId = "application-client-id"
            },
            ProvisioningStepType.CreateServicePrincipal => state with
            {
                ServicePrincipalObjectId = "service-principal-object-id"
            },
            ProvisioningStepType.AssignRoles => state with
            {
                AppRoleAssignmentId = "app-role-assignment-id"
            },
            ProvisioningStepType.StoreCredentials => state with
            {
                PasswordCredentialKeyId = "password-credential-key-id",
                KeyVaultSecretUri = "https://test-vault.vault.azure.net/secrets/agent-credential"
            },
            ProvisioningStepType.CreateBlueprint => state with
            {
                BlueprintObjectId = "blueprint-object-id",
                BlueprintClientId = "blueprint-client-id"
            },
            ProvisioningStepType.CreateBlueprintPrincipal => state with
            {
                BlueprintPrincipalObjectId = "blueprint-principal-object-id"
            },
            ProvisioningStepType.CreateAgentIdentity => state with
            {
                AgentIdentityObjectId = "agent-identity-object-id",
                AgentIdentityClientId = "agent-identity-client-id"
            },
            ProvisioningStepType.RegisterAgent => state with
            {
                Agent365RegistrationId = PlannedRegistryId,
                RegistryProvider = Agent365Options.DirectRegistryPreviewProvider,
                RegistryAuthenticationMode =
                    Agent365Options.DelegatedAdministratorAuthenticationMode,
                RegistryCreatedByObjectId =
                    "23232323-2323-4323-8323-232323232323",
                Agent365RegistrationVerifiedAtUtc = DateTimeOffset.UtcNow
            },
            ProvisioningStepType.ResolveBlueprint => state with
            {
                BlueprintObjectId = "blueprint-object-id",
                BlueprintClientId = "blueprint-client-id"
            },
            ProvisioningStepType.EnsureBlueprintPrincipal => state with
            {
                BlueprintPrincipalObjectId = "blueprint-principal-object-id"
            },
            ProvisioningStepType.ConfigureGatewayFederation => state with
            {
                GatewayManagedIdentityPrincipalId =
                    "46464646-4646-4646-8646-464646464646",
                GatewayFederatedCredentialId = "gateway-federated-credential-id"
            },
            ProvisioningStepType.AssignAgent365Access => state with
            {
                AgentIdentityClientId = "agent-identity-client-id",
                ObservabilityAppRoleAssignmentId = "observability-app-role-assignment-id"
            },
            ProvisioningStepType.VerifyAgent365Connection => state with
            {
                Agent365ConnectionVerifiedAtUtc = DateTimeOffset.UtcNow
            },
            _ => throw new ArgumentOutOfRangeException(nameof(stepType), stepType, null)
        };
    }

    private static void CompleteProvisioningJob(ProvisioningJob job)
    {
        var steps = job.Steps.OrderBy(step => step.OrderIndex).ToArray();
        _ = CompletePrefix(steps, steps.Length);
        job.Status = JobStatus.Completed;
        job.PercentComplete = 100;
        job.CompletedAtUtc = DateTime.UtcNow;
    }

    private static Agent365ProvisioningState CompletePrefix(
        IReadOnlyList<ProvisioningJobStep> steps,
        int completedCount)
    {
        var state = new Agent365ProvisioningState();
        foreach (var step in steps.Take(completedCount))
        {
            state = CreateSuccessfulState(step.StepType, state);
            step.Status = StepStatus.Completed;
            step.CompletedAtUtc = DateTime.UtcNow.AddMinutes(-1);
            step.ResultData = JsonSerializer.Serialize(new Agent365ProvisioningStepResult(
                step.StepType,
                state,
                $"verified_{step.StepType}"));
        }

        return state;
    }

    private static string CreateProvisioningPayload(
        Guid agentId,
        Guid jobId,
        int expectedStepIndex = 0) =>
        JsonSerializer.Serialize(new ProvisionAgentMessage(
            agentId,
            jobId,
            expectedStepIndex,
            "correlation-1"));

    private static ActivityReceipt CreateReceipt(Guid agentId, ActivityType activityType)
    {
        var occurredAt = DateTime.UtcNow.AddSeconds(-1);
        return new ActivityReceipt
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agentId,
            ExternalActivityId = "activity-1",
            SessionId = "session-1",
            ActivityType = activityType,
            ActorType = ActorType.User,
            ProcessingStatus = ProcessingStatus.Accepted,
            CorrelationId = "correlation-1",
            OccurredAtUtc = occurredAt,
            ReceivedAtUtc = occurredAt.AddMilliseconds(100)
        };
    }

    private static AiInteractionRecord CreateInteraction(Guid agentId)
    {
        var occurredAt = DateTime.UtcNow.AddSeconds(-1);
        return new AiInteractionRecord
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agentId,
            ExternalInteractionId = "interaction-1",
            SessionId = "session-1",
            TenantUserObjectId = UserObjectId.ToString("D"),
            ContentBlobUri = "https://storage.example.test/private-content",
            ModelProvider = "test-provider",
            ModelName = "test-model",
            ProcessingStatus = ProcessingStatus.Accepted,
            ObservabilityStatus = "Queued",
            CorrelationId = "correlation-1",
            OccurredAtUtc = occurredAt,
            ReceivedAtUtc = occurredAt.AddMilliseconds(100)
        };
    }

    private static string CreateActivityPayload(
        Guid agentId,
        Guid receiptId,
        string? tenantUserObjectId)
    {
        return JsonSerializer.Serialize(new
        {
            AgentId = agentId,
            ReceiptId = receiptId,
            CorrelationId = "correlation-1",
            ActorTenantUserObjectId = tenantUserObjectId
        });
    }

    private static string CreateActivityPayloadWithSnapshot(
        Guid agentId,
        Guid receiptId,
        string? tenantUserObjectId,
        bool agent365ObservabilityEnabled,
        bool azureMonitorExportEnabled)
    {
        return JsonSerializer.Serialize(new
        {
            AgentId = agentId,
            ReceiptId = receiptId,
            CorrelationId = "correlation-1",
            ActorTenantUserObjectId = tenantUserObjectId,
            Agent365ObservabilityEnabled = agent365ObservabilityEnabled,
            AzureMonitorExportEnabled = azureMonitorExportEnabled
        });
    }

    private static string CreateInteractionPayloadWithSnapshot(
        Guid agentId,
        Guid recordId,
        bool agent365ObservabilityEnabled,
        bool azureMonitorExportEnabled)
    {
        return JsonSerializer.Serialize(new
        {
            AgentId = agentId,
            RecordId = recordId,
            CorrelationId = "correlation-1",
            Agent365ObservabilityEnabled = agent365ObservabilityEnabled,
            AzureMonitorExportEnabled = azureMonitorExportEnabled
        });
    }

    private static ActivityListener CreateListener(Action<Activity> onStopped)
    {
        var listener = new ActivityListener
        {
            ShouldListenTo = source => source.Name == GatewayActivitySource.Name,
            Sample = (ref ActivityCreationOptions<ActivityContext> _) =>
                ActivitySamplingResult.AllDataAndRecorded,
            ActivityStopped = onStopped
        };
        ActivitySource.AddActivityListener(listener);
        return listener;
    }

    private sealed class HandlerFixture
    {
        private readonly HashSet<Guid> _auditEventIds = [];

        public HandlerFixture(bool provisioningExecutionEnabled = true)
        {
            UnitOfWork.SaveChangesAsync(Arg.Any<CancellationToken>()).Returns(Task.FromResult(1));
            Exporter.ExportActivityAsync(
                    Arg.Any<ObservabilityExportRequest>(),
                    Arg.Any<CancellationToken>())
                .Returns(Task.CompletedTask);
            AuditEvents.ExistsAsync(Arg.Any<Guid>(), Arg.Any<CancellationToken>())
                .Returns(callInfo => Task.FromResult(_auditEventIds.Contains(callInfo.ArgAt<Guid>(0))));
            AuditEvents.AddAsync(Arg.Any<AuditEvent>(), Arg.Any<CancellationToken>())
                .Returns(callInfo =>
                {
                    var auditEvent = callInfo.ArgAt<AuditEvent>(0);
                    _auditEventIds.Add(auditEvent.Id);
                    AddedAuditEvents.Add(auditEvent);
                    return Task.CompletedTask;
                });
            Outbox.AddAsync(Arg.Any<OutboxMessage>(), Arg.Any<CancellationToken>())
                .Returns(callInfo =>
                {
                    AddedOutboxMessages.Add(callInfo.ArgAt<OutboxMessage>(0));
                    return Task.CompletedTask;
                });

            Handler = new ProvisioningMessageHandler(
                ProvisioningClient,
                Agents,
                Jobs,
                ActivityReceipts,
                Interactions,
                Exporter,
                AuditEvents,
                Outbox,
                UnitOfWork,
                ProvisioningExecutionLockProvider,
                Options.Create(new ProvisioningWorkerOptions
                {
                    ProvisioningExecutionEnabled = provisioningExecutionEnabled
                }),
                NullLogger<ProvisioningMessageHandler>.Instance);
        }

        public IAgent365ProvisioningClient ProvisioningClient { get; } =
            Substitute.For<IAgent365ProvisioningClient>();
        public IAgentRepository Agents { get; } = Substitute.For<IAgentRepository>();
        public IProvisioningJobRepository Jobs { get; } = Substitute.For<IProvisioningJobRepository>();
        public IActivityReceiptRepository ActivityReceipts { get; } =
            Substitute.For<IActivityReceiptRepository>();
        public IAiInteractionRepository Interactions { get; } =
            Substitute.For<IAiInteractionRepository>();
        public IObservabilityExporter Exporter { get; } = Substitute.For<IObservabilityExporter>();
        public IAuditEventRepository AuditEvents { get; } = Substitute.For<IAuditEventRepository>();
        public List<AuditEvent> AddedAuditEvents { get; } = [];
        public IOutboxRepository Outbox { get; } = Substitute.For<IOutboxRepository>();
        public List<OutboxMessage> AddedOutboxMessages { get; } = [];
        public IUnitOfWork UnitOfWork { get; } = Substitute.For<IUnitOfWork>();
        public IProvisioningExecutionLockProvider ProvisioningExecutionLockProvider { get; } =
            new NoOpProvisioningExecutionLockProvider();
        public ProvisioningMessageHandler Handler { get; }

        public void Arrange(AgentRegistration agent, ActivityReceipt receipt)
        {
            Agents.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(agent);
            ActivityReceipts.GetByIdAsync(receipt.Id, Arg.Any<CancellationToken>()).Returns(receipt);
        }

        public void Arrange(AgentRegistration agent, AiInteractionRecord interaction)
        {
            Agents.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(agent);
            Interactions.GetByIdAsync(interaction.Id, Arg.Any<CancellationToken>()).Returns(interaction);
        }

        public void Arrange(AgentRegistration agent, ProvisioningJob job)
        {
            Agents.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(agent);
            Jobs.GetByIdAsync(job.Id, Arg.Any<CancellationToken>()).Returns(job);
        }

        private sealed class NoOpProvisioningExecutionLockProvider :
            IProvisioningExecutionLockProvider
        {
            public Task<IProvisioningExecutionLease> AcquireAsync(Guid jobId, CancellationToken ct)
            {
                ct.ThrowIfCancellationRequested();
                return Task.FromResult<IProvisioningExecutionLease>(
                    new NoOpProvisioningExecutionLease());
            }
        }

        private sealed class NoOpProvisioningExecutionLease : IProvisioningExecutionLease
        {
            public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        }
    }
}
