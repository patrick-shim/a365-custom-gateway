using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Messages;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using MediatR;

namespace Gateway.Application.Agents.Commands;

internal sealed class CompleteAgent365RegistrationHandler :
    IRequestHandler<CompleteAgent365RegistrationCommand, CompleteAgent365RegistrationResponse>
{
    private const string DelegatedAuthenticationMode = "DelegatedAdministrator";
    private const string DirectRegistryPreviewProvider = "DirectRegistryPreview";
    private const string AcceptedEvidence = "DelegatedRegistryCreateAccepted";
    private static readonly TimeSpan DependencyTimeout = TimeSpan.FromSeconds(60);

    private readonly IAgentRepository _agentRepository;
    private readonly IProvisioningJobRepository _jobRepository;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditRepository;
    private readonly IAgent365DelegatedRegistryClient _registryClient;
    private readonly IAgent365DelegatedTokenProvider _delegatedTokenProvider;
    private readonly IProvisioningExecutionLockProvider _lockProvider;
    private readonly IUnitOfWork _unitOfWork;

    public CompleteAgent365RegistrationHandler(
        IAgentRepository agentRepository,
        IProvisioningJobRepository jobRepository,
        IOutboxRepository outboxRepository,
        IAuditEventRepository auditRepository,
        IAgent365DelegatedRegistryClient registryClient,
        IAgent365DelegatedTokenProvider delegatedTokenProvider,
        IProvisioningExecutionLockProvider lockProvider,
        IUnitOfWork unitOfWork)
    {
        _agentRepository = agentRepository;
        _jobRepository = jobRepository;
        _outboxRepository = outboxRepository;
        _auditRepository = auditRepository;
        _registryClient = registryClient;
        _delegatedTokenProvider = delegatedTokenProvider;
        _lockProvider = lockProvider;
        _unitOfWork = unitOfWork;
    }

    public async Task<CompleteAgent365RegistrationResponse> Handle(
        CompleteAgent365RegistrationCommand request,
        CancellationToken cancellationToken)
    {
        if (!TryParseNonEmptyGuid(request.CallerObjectId, out var callerObjectId))
        {
            throw new DomainException(
                "The signed-in administrator identity is invalid.",
                ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED);
        }

        await using var lease = await _lockProvider.AcquireAsync(
            request.OperationId,
            cancellationToken);

        var job = await _jobRepository.GetByIdAsync(request.OperationId, cancellationToken)
            ?? throw new NotFoundException("ProvisioningJob", request.OperationId);
        var agent = await _agentRepository.GetByIdAsync(job.AgentRegistrationId, cancellationToken)
            ?? throw new NotFoundException("AgentRegistration", job.AgentRegistrationId);
        var orderedSteps = job.Steps.OrderBy(step => step.OrderIndex).ToArray();

        EnsureCurrentWorkflow(job, orderedSteps);

        var registerStep = orderedSteps[5];
        if (registerStep.Status == StepStatus.Completed)
        {
            var completed = ReadCompletedStep(registerStep, ProvisioningStepType.RegisterAgent);
            var existingId = RequireSafeRegistryId(completed.State.Agent365RegistrationId);
            return BuildResponse(job, agent, existingId, "VerificationQueued");
        }

        EnsureReadyForDelegatedAction(job, agent, orderedSteps, registerStep);
        var state = ReadCompletedPrefix(orderedSteps, completedCount: 5);

        Agent365RegistryAttemptState attempt;
        if (registerStep.Status == StepStatus.Running)
        {
            attempt = ReadAttempt(registerStep, callerObjectId);
            var returnedId = IsSafeRegistryId(attempt.ReturnedAgent365RegistrationId)
                ? attempt.ReturnedAgent365RegistrationId
                : null;
            var recoveryId = returnedId ?? RequireSafeRegistryId(attempt.PlannedAgent365RegistrationId);
            var recoveryRequest = BuildRegistryRequest(
                job,
                agent,
                state,
                callerObjectId,
                RequireSafeRegistryGuid(attempt.PlannedAgent365RegistrationId));

            // Token acquisition happens only after the exact v3 state and
            // GET-only recovery identifier have been validated. Interactive
            // consent/Conditional Access exceptions can therefore surface to
            // the API without any persisted mutation.
            _ = await _delegatedTokenProvider.GetTokenAsync(cancellationToken);

            // A returned ID is persisted only after Graph accepted the create
            // with a successful response (or returned the existing ID on a
            // conflict). This matches the A365 CLI boundary: do not require an
            // immediate GET after a documented 201 Created response.
            if (returnedId is not null)
            {
                return await AcceptAndContinueAsync(
                    job,
                    agent,
                    registerStep,
                    state,
                    attempt,
                    returnedId,
                    CancellationToken.None);
            }

            return await VerifyAndContinueAsync(
                job,
                agent,
                registerStep,
                state,
                recoveryRequest,
                attempt,
                recoveryId,
                CancellationToken.None);
        }

        if (registerStep.Status != StepStatus.Pending)
            throw InvalidAction(job, registerStep);

        // Pre-acquire before persisting POST intent. The client reacquires from
        // the OBO cache after the marker is durable.
        _ = await _delegatedTokenProvider.GetTokenAsync(cancellationToken);

        var now = DateTimeOffset.UtcNow;
        var plannedRegistrationId = Guid.NewGuid();
        attempt = new Agent365RegistryAttemptState(
            Agent365RegistryAttemptState.CurrentSchemaVersion,
            DelegatedAuthenticationMode,
            callerObjectId.ToString("D"),
            now,
            plannedRegistrationId.ToString("D"),
            ReturnedAgent365RegistrationId: null);

        registerStep.Status = StepStatus.Running;
        registerStep.StartedAtUtc ??= now.UtcDateTime;
        registerStep.ErrorCode = null;
        registerStep.ErrorMessage = null;
        registerStep.ResultData = JsonSerializer.Serialize(attempt);
        job.Status = JobStatus.Running;
        job.ErrorCode = null;
        job.ErrorSummary = null;
        await _unitOfWork.SaveChangesAsync(cancellationToken);

        var registryRequest = BuildRegistryRequest(
            job,
            agent,
            state,
            callerObjectId,
            plannedRegistrationId);

        using var dependencyCts = new CancellationTokenSource(DependencyTimeout);
        string registryId;
        try
        {
            registryId = await _registryClient.CreateAsync(registryRequest, dependencyCts.Token);
        }
        catch (Agent365DelegatedRegistryException exception)
        {
            if (!exception.MutationMayHaveOccurred)
            {
                await ResetToAwaitingAsync(
                    job,
                    agent,
                    registerStep,
                    exception.ErrorCode,
                    exception.SafeSummary,
                    cancellationToken);
                throw new DomainException(
                    exception.SafeSummary,
                    ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED);
            }

            // The planned ID was committed before the first POST. Any ambiguous
            // response can therefore be reconciled safely by exact-ID GET without
            // repeating or guessing the mutation.
            return await VerifyAndContinueAsync(
                job,
                agent,
                registerStep,
                state,
                registryRequest,
                attempt,
                plannedRegistrationId.ToString("D"),
                CancellationToken.None);
        }

        if (!IsSafeRegistryId(registryId))
        {
            await MarkManualAsync(
                job,
                agent,
                registerStep,
                "Microsoft Graph returned an invalid Registry identifier after create.",
                cancellationToken);
            throw UnsafeRegistryBoundary();
        }

        attempt = attempt with
        {
            ReturnedAgent365RegistrationId = registryId
        };
        registerStep.ResultData = JsonSerializer.Serialize(attempt);
        await _unitOfWork.SaveChangesAsync(CancellationToken.None);

        return await AcceptAndContinueAsync(
            job,
            agent,
            registerStep,
            state,
            attempt,
            registryId,
            CancellationToken.None);
    }

    private Task<CompleteAgent365RegistrationResponse> AcceptAndContinueAsync(
        ProvisioningJob job,
        AgentRegistration agent,
        ProvisioningJobStep registerStep,
        Agent365ProvisioningState previousState,
        Agent365RegistryAttemptState attempt,
        string registryId,
        CancellationToken cancellationToken) =>
        CompleteAndContinueAsync(
            job,
            agent,
            registerStep,
            previousState,
            attempt,
            registryId,
            DateTimeOffset.UtcNow,
            cancellationToken);

    private async Task<CompleteAgent365RegistrationResponse> VerifyAndContinueAsync(
        ProvisioningJob job,
        AgentRegistration agent,
        ProvisioningJobStep registerStep,
        Agent365ProvisioningState previousState,
        Agent365DelegatedRegistryRequest registryRequest,
        Agent365RegistryAttemptState attempt,
        string registryId,
        CancellationToken cancellationToken)
    {
        using var dependencyCts = new CancellationTokenSource(DependencyTimeout);
        try
        {
            await _registryClient.VerifyAsync(registryId, registryRequest, dependencyCts.Token);
        }
        catch (Agent365DelegatedRegistryException exception) when (exception.IsTransient)
        {
            registerStep.ResultData = JsonSerializer.Serialize(attempt);
            registerStep.ErrorCode = exception.ErrorCode;
            registerStep.ErrorMessage = exception.SafeSummary;
            job.Status = JobStatus.AwaitingAdministratorAction;
            job.ErrorCode = exception.ErrorCode;
            job.ErrorSummary = exception.SafeSummary;
            agent.Status = AgentStatus.AwaitingAdminApproval;
            agent.LastProvisioningErrorCode = exception.ErrorCode;
            agent.LastProvisioningErrorSummary = exception.SafeSummary;
            agent.UpdatedAtUtc = DateTime.UtcNow;
            await _unitOfWork.SaveChangesAsync(cancellationToken);

            throw new DomainException(
                "The Registry record was created, but exact verification is temporarily unavailable. Repeat this action to perform a GET-only verification; the create will not be repeated.",
                ErrorCodes.AGENT365_DEPENDENCY_UNAVAILABLE);
        }
        catch (Agent365DelegatedRegistryException exception)
        {
            await MarkManualAsync(
                job,
                agent,
                registerStep,
                exception.SafeSummary,
                cancellationToken);
            throw UnsafeRegistryBoundary(exception);
        }

        return await CompleteAndContinueAsync(
            job,
            agent,
            registerStep,
            previousState,
            attempt,
            registryId,
            DateTimeOffset.UtcNow,
            cancellationToken);
    }

    private async Task<CompleteAgent365RegistrationResponse> CompleteAndContinueAsync(
        ProvisioningJob job,
        AgentRegistration agent,
        ProvisioningJobStep registerStep,
        Agent365ProvisioningState previousState,
        Agent365RegistryAttemptState attempt,
        string registryId,
        DateTimeOffset acceptedAt,
        CancellationToken cancellationToken)
    {
        var completedState = previousState with
        {
            Agent365RegistrationId = registryId,
            RegistryProvider = DirectRegistryPreviewProvider,
            RegistryAuthenticationMode = DelegatedAuthenticationMode,
            RegistryCreatedByObjectId = attempt.CreatedByObjectId,
            Agent365RegistrationAcceptedAtUtc = acceptedAt
        };

        registerStep.ResultData = JsonSerializer.Serialize(new Agent365ProvisioningStepResult(
            ProvisioningStepType.RegisterAgent,
            completedState,
            AcceptedEvidence));
        registerStep.Status = StepStatus.Completed;
        registerStep.ErrorCode = null;
        registerStep.ErrorMessage = null;
        registerStep.CompletedAtUtc = acceptedAt.UtcDateTime;

        job.Status = JobStatus.Running;
        job.PercentComplete = 85;
        job.ErrorCode = null;
        job.ErrorSummary = null;
        agent.Status = AgentStatus.Provisioning;
        agent.Agent365InstanceId = registryId;
        agent.LastProvisioningErrorCode = null;
        agent.LastProvisioningErrorSummary = null;
        agent.UpdatedAtUtc = acceptedAt.UtcDateTime;
        agent.UpdatedByObjectId = attempt.CreatedByObjectId;

        await _outboxRepository.AddAsync(new OutboxMessage
        {
            Id = Guid.NewGuid(),
            MessageType = "ProvisionAgent",
            Payload = JsonSerializer.Serialize(new ProvisionAgentMessage(
                agent.Id,
                job.Id,
                ExpectedStepIndex: 6,
                CorrelationId: job.Id.ToString("D"))),
            Status = OutboxMessageStatus.Pending,
            RetryCount = 0,
            CreatedAtUtc = acceptedAt.UtcDateTime
        }, cancellationToken);

        await _auditRepository.AddAsync(new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "Agent365RegistryAcceptedByAdministrator",
            PerformedByObjectId = attempt.CreatedByObjectId,
            Details = JsonSerializer.Serialize(new
            {
                operationId = job.Id,
                agent365RegistrationId = registryId,
                evidence = AcceptedEvidence
            }),
            OccurredAtUtc = acceptedAt.UtcDateTime
        }, cancellationToken);

        await _unitOfWork.SaveChangesAsync(cancellationToken);
        return BuildResponse(job, agent, registryId, "VerificationQueued");
    }

    private async Task ResetToAwaitingAsync(
        ProvisioningJob job,
        AgentRegistration agent,
        ProvisioningJobStep registerStep,
        string errorCode,
        string safeSummary,
        CancellationToken cancellationToken)
    {
        registerStep.Status = StepStatus.Pending;
        registerStep.StartedAtUtc = null;
        registerStep.ResultData = null;
        registerStep.ErrorCode = errorCode;
        registerStep.ErrorMessage = safeSummary;
        job.Status = JobStatus.AwaitingAdministratorAction;
        job.ErrorCode = errorCode;
        job.ErrorSummary = safeSummary;
        agent.Status = AgentStatus.AwaitingAdminApproval;
        agent.LastProvisioningErrorCode = errorCode;
        agent.LastProvisioningErrorSummary = safeSummary;
        agent.UpdatedAtUtc = DateTime.UtcNow;
        await _unitOfWork.SaveChangesAsync(cancellationToken);
    }

    private async Task MarkManualAsync(
        ProvisioningJob job,
        AgentRegistration agent,
        ProvisioningJobStep registerStep,
        string safeSummary,
        CancellationToken cancellationToken)
    {
        registerStep.Status = StepStatus.Failed;
        registerStep.ErrorCode = ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT;
        registerStep.ErrorMessage = safeSummary;
        registerStep.CompletedAtUtc = DateTime.UtcNow;
        job.Status = JobStatus.RequiresManualIntervention;
        job.ErrorCode = ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT;
        job.ErrorSummary = safeSummary;
        job.CompletedAtUtc = DateTime.UtcNow;
        agent.Status = AgentStatus.RequiresManualIntervention;
        agent.LastProvisioningErrorCode = ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT;
        agent.LastProvisioningErrorSummary = safeSummary;
        agent.UpdatedAtUtc = DateTime.UtcNow;
        await _unitOfWork.SaveChangesAsync(cancellationToken);
    }

    private static Agent365DelegatedRegistryRequest BuildRegistryRequest(
        ProvisioningJob job,
        AgentRegistration agent,
        Agent365ProvisioningState state,
        Guid callerObjectId,
        Guid plannedRegistrationId)
    {
        var ownerId = ParseRequiredGuid(
            agent.OwnerObjectId,
            "The accountable owner does not have a valid Microsoft Entra object identifier.");
        var childId = ParseRequiredGuid(
            state.AgentIdentityObjectId,
            "The child Agent Identity has not been durably verified.");
        var blueprintClientId = ParseRequiredGuid(
            state.BlueprintClientId,
            "The selected blueprint client identifier has not been durably verified.");

        return new Agent365DelegatedRegistryRequest(
            job.Id,
            plannedRegistrationId,
            agent.Name,
            agent.Description,
            childId.ToString("D"),
            ownerId,
            callerObjectId,
            childId,
            blueprintClientId,
            new DateTimeOffset(DateTime.SpecifyKind(agent.CreatedAtUtc, DateTimeKind.Utc)),
            new DateTimeOffset(DateTime.SpecifyKind(agent.UpdatedAtUtc, DateTimeKind.Utc)));
    }

    private static void EnsureCurrentWorkflow(
        ProvisioningJob job,
        IReadOnlyList<ProvisioningJobStep> steps)
    {
        if (!ProvisioningWorkflow.IsCurrent(
                job.WorkflowVersion,
                steps.Select(step => step.StepType).ToArray()) ||
            steps.Count != ProvisioningWorkflow.CurrentSteps.Count ||
            steps.Where((step, index) => step.OrderIndex != index).Any())
        {
            throw new ConflictException(
                "Only the current delegated-administrator provisioning workflow can perform this action. Historical jobs remain read-only.",
                ErrorCodes.PROVISIONING_LEGACY_JOB);
        }
    }

    private static void EnsureReadyForDelegatedAction(
        ProvisioningJob job,
        AgentRegistration agent,
        IReadOnlyList<ProvisioningJobStep> steps,
        ProvisioningJobStep registerStep)
    {
        if (job.Status is JobStatus.RequiresManualIntervention or JobStatus.Completed or JobStatus.Failed ||
            agent.Status == AgentStatus.RequiresManualIntervention ||
            steps.Take(5).Any(step => step.Status != StepStatus.Completed) ||
            steps.Skip(6).Any(step => step.Status != StepStatus.Pending) ||
            registerStep.Status is not (StepStatus.Pending or StepStatus.Running))
        {
            throw InvalidAction(job, registerStep);
        }

        if (registerStep.Status == StepStatus.Pending &&
            job.Status != JobStatus.AwaitingAdministratorAction)
        {
            throw InvalidAction(job, registerStep);
        }
    }

    private static Agent365ProvisioningState ReadCompletedPrefix(
        IReadOnlyList<ProvisioningJobStep> steps,
        int completedCount)
    {
        var state = new Agent365ProvisioningState();
        for (var index = 0; index < completedCount; index++)
        {
            var result = ReadCompletedStep(steps[index], ProvisioningWorkflow.CurrentSteps[index]);
            if (!StatePreserves(state, result.State))
            {
                throw new ConflictException(
                    "The provisioning history is not a monotonic, verified completed prefix.",
                    ErrorCodes.PROVISIONING_STATE_INVALID);
            }

            state = result.State;
        }

        if (!TryParseNonEmptyGuid(state.BlueprintObjectId, out _) ||
            !TryParseNonEmptyGuid(state.BlueprintClientId, out _) ||
            !TryParseNonEmptyGuid(state.BlueprintPrincipalObjectId, out _) ||
            !TryParseNonEmptyGuid(state.GatewayManagedIdentityPrincipalId, out _) ||
            !IsSafeDependencyIdentifier(state.GatewayFederatedCredentialId) ||
            !TryParseNonEmptyGuid(state.AgentIdentityObjectId, out _) ||
            !TryParseNonEmptyGuid(state.AgentIdentityClientId, out _) ||
            !IsSafeDependencyIdentifier(state.ObservabilityAppRoleAssignmentId))
        {
            throw new ConflictException(
                "The provisioning history does not contain all verified prerequisites for Registry creation.",
                ErrorCodes.PROVISIONING_STATE_INVALID);
        }

        return state;
    }

    private static Agent365ProvisioningStepResult ReadCompletedStep(
        ProvisioningJobStep step,
        ProvisioningStepType expectedStep)
    {
        if (step.Status != StepStatus.Completed || string.IsNullOrWhiteSpace(step.ResultData))
            throw InvalidStepState();

        try
        {
            var result = JsonSerializer.Deserialize<Agent365ProvisioningStepResult>(step.ResultData);
            if (result is null ||
                result.State is null ||
                result.StepType != expectedStep ||
                !IsSafeCompletionEvidence(result.CompletionEvidence))
            {
                throw InvalidStepState();
            }

            return result;
        }
        catch (JsonException exception)
        {
            throw new ConflictException(
                "The provisioning history contains invalid durable step evidence.",
                ErrorCodes.PROVISIONING_STATE_INVALID,
                exception);
        }
    }

    private static Agent365RegistryAttemptState ReadAttempt(
        ProvisioningJobStep registerStep,
        Guid callerObjectId)
    {
        try
        {
            var attempt = JsonSerializer.Deserialize<Agent365RegistryAttemptState>(
                registerStep.ResultData ?? string.Empty);
            if (attempt is null ||
                attempt.SchemaVersion != Agent365RegistryAttemptState.CurrentSchemaVersion ||
                !string.Equals(
                    attempt.AuthenticationMode,
                    DelegatedAuthenticationMode,
                    StringComparison.Ordinal) ||
                !TryParseNonEmptyGuid(attempt.CreatedByObjectId, out var createdBy) ||
                createdBy != callerObjectId ||
                !IsSafeRegistryId(attempt.PlannedAgent365RegistrationId))
            {
                throw InvalidStepState();
            }

            return attempt;
        }
        catch (JsonException exception)
        {
            throw new ConflictException(
                "The Registry attempt has invalid durable recovery evidence.",
                ErrorCodes.PROVISIONING_STATE_INVALID,
                exception);
        }
    }

    private static bool StatePreserves(
        Agent365ProvisioningState previous,
        Agent365ProvisioningState current) =>
        Preserves(previous.BlueprintObjectId, current.BlueprintObjectId) &&
        Preserves(previous.BlueprintClientId, current.BlueprintClientId) &&
        Preserves(previous.BlueprintPrincipalObjectId, current.BlueprintPrincipalObjectId) &&
        Preserves(previous.AgentIdentityObjectId, current.AgentIdentityObjectId) &&
        Preserves(previous.AgentIdentityClientId, current.AgentIdentityClientId) &&
        Preserves(previous.ObservabilityAppRoleAssignmentId, current.ObservabilityAppRoleAssignmentId) &&
        Preserves(previous.GatewayManagedIdentityPrincipalId, current.GatewayManagedIdentityPrincipalId) &&
        Preserves(previous.GatewayFederatedCredentialId, current.GatewayFederatedCredentialId) &&
        Preserves(previous.Agent365RegistrationId, current.Agent365RegistrationId);

    private static bool Preserves(string? previous, string? current) =>
        previous is null || string.Equals(previous, current, StringComparison.Ordinal);

    private static bool IsSafeCompletionEvidence(string? evidence) =>
        !string.IsNullOrWhiteSpace(evidence) &&
        evidence.Length <= 64 &&
        evidence.All(character =>
            char.IsLetterOrDigit(character) || character is '-' or '_');

    private static bool TryParseNonEmptyGuid(string? value, out Guid parsed) =>
        Guid.TryParse(value, out parsed) && parsed != Guid.Empty;

    private static Guid ParseRequiredGuid(string? value, string message)
    {
        if (TryParseNonEmptyGuid(value, out var parsed))
            return parsed;

        throw new ConflictException(message, ErrorCodes.PROVISIONING_STATE_INVALID);
    }

    private static Guid RequireSafeRegistryGuid(string? value)
    {
        if (TryParseNonEmptyGuid(value, out var parsed))
            return parsed;

        throw InvalidStepState();
    }

    private static ConflictException InvalidStepState() => new(
        "The provisioning history contains invalid durable step evidence.",
        ErrorCodes.PROVISIONING_STATE_INVALID);

    private static ConflictException InvalidAction(
        ProvisioningJob job,
        ProvisioningJobStep registerStep) => new(
            $"Agent 365 Registry completion is unavailable while operation '{job.Status}' and Registry step '{registerStep.Status}' are in their current state.",
            ErrorCodes.INVALID_STATE_TRANSITION);

    private static ConflictException UnsafeRegistryBoundary(Exception? inner = null) => new(
        "The Registry create outcome is ambiguous. This operation requires manual reconciliation and will never repeat the create request.",
        ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
        inner);

    private static CompleteAgent365RegistrationResponse BuildResponse(
        ProvisioningJob job,
        AgentRegistration agent,
        string registryId,
        string status) => new(
            job.Id,
            agent.Id,
            registryId,
            status);

    private static string RequireSafeRegistryId(string? value)
    {
        if (IsSafeRegistryId(value))
            return value!;

        throw new ConflictException(
            "The completed Registry step has no valid service-generated identifier.",
            ErrorCodes.PROVISIONING_STATE_INVALID);
    }

    private static bool IsSafeRegistryId(string? value) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length <= 128 &&
        IsSafeIdentifierCharacters(value);

    private static bool IsSafeDependencyIdentifier(string? value) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length <= 256 &&
        IsSafeIdentifierCharacters(value);

    private static bool IsSafeIdentifierCharacters(string value) =>
        value.All(character =>
            char.IsLetterOrDigit(character) || character is '-' or '_' or '.');
}
