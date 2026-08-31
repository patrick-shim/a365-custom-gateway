using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Gateway.Agent365;
using Gateway.Contracts;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Observability;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Provisioning.Worker;

internal sealed class ProvisioningMessageHandler
{
    private readonly IAgent365ProvisioningClient _provisioningClient;
    private readonly IAgentRepository _agentRepository;
    private readonly IProvisioningJobRepository _jobRepository;
    private readonly IActivityReceiptRepository _activityReceiptRepository;
    private readonly IAiInteractionRepository _aiInteractionRepository;
    private readonly IObservabilityExporter _observabilityExporter;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IUnitOfWork _unitOfWork;
    private readonly IProvisioningExecutionLockProvider _provisioningExecutionLockProvider;
    private readonly IPurviewPolicyProfileRepository _purviewPolicyProfileRepository;
    private readonly IPurviewPolicyProvisioningClient _purviewPolicyProvisioningClient;
    private readonly ProvisioningWorkerOptions _options;
    private readonly ILogger<ProvisioningMessageHandler> _logger;

    public ProvisioningMessageHandler(
        IAgent365ProvisioningClient provisioningClient,
        IAgentRepository agentRepository,
        IProvisioningJobRepository jobRepository,
        IActivityReceiptRepository activityReceiptRepository,
        IAiInteractionRepository aiInteractionRepository,
        IObservabilityExporter observabilityExporter,
        IAuditEventRepository auditEventRepository,
        IOutboxRepository outboxRepository,
        IUnitOfWork unitOfWork,
        IProvisioningExecutionLockProvider provisioningExecutionLockProvider,
        IPurviewPolicyProfileRepository purviewPolicyProfileRepository,
        IPurviewPolicyProvisioningClient purviewPolicyProvisioningClient,
        IOptions<ProvisioningWorkerOptions> options,
        ILogger<ProvisioningMessageHandler> logger)
    {
        _provisioningClient = provisioningClient;
        _agentRepository = agentRepository;
        _jobRepository = jobRepository;
        _activityReceiptRepository = activityReceiptRepository;
        _aiInteractionRepository = aiInteractionRepository;
        _observabilityExporter = observabilityExporter;
        _auditEventRepository = auditEventRepository;
        _outboxRepository = outboxRepository;
        _unitOfWork = unitOfWork;
        _provisioningExecutionLockProvider = provisioningExecutionLockProvider;
        _purviewPolicyProfileRepository = purviewPolicyProfileRepository;
        _purviewPolicyProvisioningClient = purviewPolicyProvisioningClient;
        _options = options.Value;
        _logger = logger;
    }

    public async Task<MessageHandlingResult> HandleAsync(
        string messageType,
        string payload,
        CancellationToken ct)
    {
        _logger.LogInformation("Processing provisioning message of type {MessageType}", messageType);

        switch (messageType)
        {
            case "ProvisionAgent":
            case "RetryProvisioning":
                return await HandleProvisionAsync(messageType, payload, ct);
            case "DeleteAgent":
                return await HandleDeleteAsync(payload, ct);
            case "ExportInteraction":
                return await HandleExportInteractionAsync(payload, ct);
            case "ProcessActivity":
                return await HandleProcessActivityAsync(payload, ct);
            default:
                _logger.LogWarning("Unknown message type: {MessageType}", messageType);
                return MessageHandlingResult.DeadLetter(
                    "UnknownMessageType",
                    "The message subject is not supported by this worker.");
        }
    }

    public async Task<MessageHandlingResult?> HandleRetryExhaustedAsync(
        string messageType,
        string payload,
        string lastFailureCode,
        CancellationToken ct)
    {
        return messageType switch
        {
            "ProvisionAgent" or "RetryProvisioning" =>
                await FailProvisioningAfterRetryExhaustionAsync(
                    payload,
                    lastFailureCode,
                    ct),
            "ExportInteraction" => await FailInteractionAfterRetryExhaustionAsync(
                payload,
                lastFailureCode,
                ct),
            "ProcessActivity" => await FailActivityAfterRetryExhaustionAsync(
                payload,
                lastFailureCode,
                ct),
            _ => null
        };
    }

    private async Task<MessageHandlingResult> HandleExportInteractionAsync(
        string payload,
        CancellationToken ct)
    {
        ExportInteractionMessage? message;
        try
        {
            message = JsonSerializer.Deserialize<ExportInteractionMessage>(payload);
        }
        catch (JsonException)
        {
            return MessageHandlingResult.DeadLetter(
                "InvalidPayload",
                "The interaction export payload is not valid JSON.");
        }

        if (message is null || message.AgentId == Guid.Empty || message.RecordId == Guid.Empty)
        {
            return MessageHandlingResult.DeadLetter(
                "InvalidPayload",
                "The interaction export payload is missing required identifiers.");
        }

        var agent = await _agentRepository.GetByIdAsync(message.AgentId, ct);
        if (agent is null)
        {
            return MessageHandlingResult.DeadLetter(
                "AgentNotFound",
                "The referenced agent registration does not exist.");
        }

        var record = await _aiInteractionRepository.GetByIdAsync(message.RecordId, ct);
        if (record is null || record.AgentRegistrationId != agent.Id)
        {
            return MessageHandlingResult.DeadLetter(
                "InteractionNotFound",
                "The referenced interaction does not exist for this agent.");
        }

        if (IsTerminalInteractionStatus(record.ObservabilityStatus))
            return MessageHandlingResult.Complete();

        var destinations = ResolveDestinations(
            agent.FeatureConfiguration.ObservabilityMode,
            message.Agent365ObservabilityEnabled,
            message.AzureMonitorExportEnabled);
        if (destinations == ObservabilityDestinations.None)
        {
            record.ObservabilityStatus = "Disabled";
            record.ProcessingStatus = ProcessingStatus.Processed;
            record.ProcessedAtUtc = DateTime.UtcNow;
            await _unitOfWork.SaveChangesAsync(ct);
            return MessageHandlingResult.Complete();
        }

        var shouldEmitAzureMonitorMirror = await TryClaimAzureMonitorMirrorAsync(
            destinations,
            agent.Id,
            record.Id,
            "interaction",
            record.CorrelationId,
            ct);

        record.ObservabilityStatus = "Processing";
        record.ProcessingStatus = ProcessingStatus.Processing;
        await _unitOfWork.SaveChangesAsync(ct);

        string? terminalErrorCode = null;
        try
        {
            if (shouldEmitAzureMonitorMirror)
            {
                SanitizedTelemetryEmitter.EmitAzureMonitorMirror(
                    agent.Id,
                    record.Id,
                    "interaction",
                    "chat",
                    record.OccurredAtUtc,
                    record.ReceivedAtUtc);
            }

            if (destinations.HasFlag(ObservabilityDestinations.Agent365))
            {
                await _observabilityExporter.ExportActivityAsync(
                    new ObservabilityExportRequest(
                        agent.Id,
                        record.Id,
                        agent.ExternalAgentId.Value,
                        agent.Name,
                        "chat",
                        record.CorrelationId,
                        record.SessionId,
                        record.TenantUserObjectId,
                        record.OccurredAtUtc,
                        record.ReceivedAtUtc,
                        record.ModelProvider,
                        record.ModelName,
                        AgentIdentityClientId: agent.Agent365AgentId,
                        BlueprintClientId: agent.BlueprintId),
                    ct);
            }
        }
        catch (Agent365ObservabilityConfigurationException exception)
        {
            terminalErrorCode = exception.Code;
        }
        catch (Agent365ObservabilityTransientException)
        {
            await ResetInteractionForRetryAsync(record, ct);
            throw;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            await ResetInteractionForRetryAsync(record, ct);
            throw;
        }

        record.ProcessedAtUtc = DateTime.UtcNow;
        if (terminalErrorCode is null)
        {
            record.ObservabilityStatus = "Completed";
            record.ProcessingStatus = ProcessingStatus.Processed;
        }
        else
        {
            record.ObservabilityStatus = ToPersistedFailureStatus(terminalErrorCode);
            record.ProcessingStatus = ProcessingStatus.Failed;
            await AddObservabilityFailureAuditAsync(
                agent.Id,
                "interaction",
                terminalErrorCode,
                record.CorrelationId,
                ct);
        }

        await _unitOfWork.SaveChangesAsync(ct);
        return MessageHandlingResult.Complete();
    }

    private async Task<MessageHandlingResult> HandleProcessActivityAsync(
        string payload,
        CancellationToken ct)
    {
        ProcessActivityMessage? message;
        try
        {
            message = JsonSerializer.Deserialize<ProcessActivityMessage>(payload);
        }
        catch (JsonException)
        {
            return MessageHandlingResult.DeadLetter(
                "InvalidPayload",
                "The activity processing payload is not valid JSON.");
        }

        if (message is null || message.AgentId == Guid.Empty || message.ReceiptId == Guid.Empty)
        {
            return MessageHandlingResult.DeadLetter(
                "InvalidPayload",
                "The activity processing payload is missing required identifiers.");
        }

        var agent = await _agentRepository.GetByIdAsync(message.AgentId, ct);
        if (agent is null)
        {
            return MessageHandlingResult.DeadLetter(
                "AgentNotFound",
                "The referenced agent registration does not exist.");
        }

        var receipt = await _activityReceiptRepository.GetByIdAsync(message.ReceiptId, ct);
        if (receipt is null || receipt.AgentRegistrationId != agent.Id)
        {
            return MessageHandlingResult.DeadLetter(
                "ActivityNotFound",
                "The referenced activity receipt does not exist for this agent.");
        }

        if (receipt.ProcessingStatus is ProcessingStatus.Processed or ProcessingStatus.Failed)
            return MessageHandlingResult.Complete();

        var destinations = ResolveDestinations(
            agent.FeatureConfiguration.ObservabilityMode,
            message.Agent365ObservabilityEnabled,
            message.AzureMonitorExportEnabled);
        var operation = MapActivityOperation(receipt.ActivityType);
        if (destinations == ObservabilityDestinations.None)
        {
            receipt.ProcessingStatus = ProcessingStatus.Processed;
            receipt.ProcessedAtUtc = DateTime.UtcNow;
            await _unitOfWork.SaveChangesAsync(ct);
            return MessageHandlingResult.Complete();
        }

        var shouldEmitAzureMonitorMirror = await TryClaimAzureMonitorMirrorAsync(
            destinations,
            agent.Id,
            receipt.Id,
            "activity",
            receipt.CorrelationId,
            ct);

        receipt.ProcessingStatus = ProcessingStatus.Processing;
        await _unitOfWork.SaveChangesAsync(ct);

        string? terminalErrorCode = null;
        try
        {
            if (shouldEmitAzureMonitorMirror)
            {
                SanitizedTelemetryEmitter.EmitAzureMonitorMirror(
                    agent.Id,
                    receipt.Id,
                    "activity",
                    operation,
                    receipt.OccurredAtUtc,
                    receipt.ReceivedAtUtc);
            }

            if (destinations.HasFlag(ObservabilityDestinations.Agent365))
            {
                await _observabilityExporter.ExportActivityAsync(
                    new ObservabilityExportRequest(
                        agent.Id,
                        receipt.Id,
                        agent.ExternalAgentId.Value,
                        agent.Name,
                        operation,
                        receipt.CorrelationId,
                        receipt.SessionId,
                        message.ActorTenantUserObjectId,
                        receipt.OccurredAtUtc,
                        receipt.ReceivedAtUtc,
                        AgentIdentityClientId: agent.Agent365AgentId,
                        BlueprintClientId: agent.BlueprintId),
                    ct);
            }
        }
        catch (Agent365ObservabilityConfigurationException exception)
        {
            terminalErrorCode = exception.Code;
        }
        catch (Agent365ObservabilityTransientException)
        {
            await ResetActivityForRetryAsync(receipt, ct);
            throw;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            await ResetActivityForRetryAsync(receipt, ct);
            throw;
        }

        receipt.ProcessedAtUtc = DateTime.UtcNow;
        if (terminalErrorCode is null)
        {
            receipt.ProcessingStatus = ProcessingStatus.Processed;
        }
        else
        {
            receipt.ProcessingStatus = ProcessingStatus.Failed;
            await AddObservabilityFailureAuditAsync(
                agent.Id,
                "activity",
                terminalErrorCode,
                receipt.CorrelationId,
                ct);
        }

        await _unitOfWork.SaveChangesAsync(ct);
        return MessageHandlingResult.Complete();
    }

    private async Task<MessageHandlingResult> FailInteractionAfterRetryExhaustionAsync(
        string payload,
        string lastFailureCode,
        CancellationToken ct)
    {
        ExportInteractionMessage? message;
        try
        {
            message = JsonSerializer.Deserialize<ExportInteractionMessage>(payload);
        }
        catch (JsonException)
        {
            return InvalidRetryExhaustionPayload("interaction");
        }

        if (message is null || message.AgentId == Guid.Empty || message.RecordId == Guid.Empty)
            return InvalidRetryExhaustionPayload("interaction");

        var record = await _aiInteractionRepository.GetByIdAsync(message.RecordId, ct);
        if (record is null || record.AgentRegistrationId != message.AgentId)
            return RetryExhaustedResult();

        if (!IsTerminalInteractionStatus(record.ObservabilityStatus))
        {
            record.ObservabilityStatus = "Failed";
            record.ProcessingStatus = ProcessingStatus.Failed;
            record.ProcessedAtUtc = DateTime.UtcNow;
            await AddObservabilityFailureAuditAsync(
                message.AgentId,
                "interaction",
                "RetriesExhausted",
                record.CorrelationId,
                ct,
                lastFailureCode);
            await _unitOfWork.SaveChangesAsync(ct);
        }

        return RetryExhaustedResult();
    }

    private async Task<MessageHandlingResult> FailActivityAfterRetryExhaustionAsync(
        string payload,
        string lastFailureCode,
        CancellationToken ct)
    {
        ProcessActivityMessage? message;
        try
        {
            message = JsonSerializer.Deserialize<ProcessActivityMessage>(payload);
        }
        catch (JsonException)
        {
            return InvalidRetryExhaustionPayload("activity");
        }

        if (message is null || message.AgentId == Guid.Empty || message.ReceiptId == Guid.Empty)
            return InvalidRetryExhaustionPayload("activity");

        var receipt = await _activityReceiptRepository.GetByIdAsync(message.ReceiptId, ct);
        if (receipt is null || receipt.AgentRegistrationId != message.AgentId)
            return RetryExhaustedResult();

        if (receipt.ProcessingStatus is not ProcessingStatus.Processed and not ProcessingStatus.Failed)
        {
            receipt.ProcessingStatus = ProcessingStatus.Failed;
            receipt.ProcessedAtUtc = DateTime.UtcNow;
            await AddObservabilityFailureAuditAsync(
                message.AgentId,
                "activity",
                "RetriesExhausted",
                receipt.CorrelationId,
                ct,
                lastFailureCode);
            await _unitOfWork.SaveChangesAsync(ct);
        }

        return RetryExhaustedResult();
    }

    private async Task<bool> TryClaimAzureMonitorMirrorAsync(
        ObservabilityDestinations destinations,
        Guid agentId,
        Guid recordId,
        string recordType,
        string correlationId,
        CancellationToken ct)
    {
        if (!destinations.HasFlag(ObservabilityDestinations.AzureMonitor))
            return false;

        var markerId = CreateAzureMonitorMirrorMarkerId(recordType, recordId);
        if (await _auditEventRepository.ExistsAsync(markerId, ct))
            return false;

        await _auditEventRepository.AddAsync(new AuditEvent
        {
            Id = markerId,
            AgentRegistrationId = agentId,
            EventType = "AzureMonitorMirrorScheduled",
            Details = JsonSerializer.Serialize(new { RecordType = recordType }),
            CorrelationId = correlationId,
            OccurredAtUtc = DateTime.UtcNow
        }, ct);

        return true;
    }

    private static Guid CreateAzureMonitorMirrorMarkerId(string recordType, Guid recordId)
    {
        var markerSource = Encoding.UTF8.GetBytes(
            $"azure-monitor-mirror:{recordType}:{recordId:D}");
        return new Guid(SHA256.HashData(markerSource).AsSpan(0, 16));
    }

    private static MessageHandlingResult InvalidRetryExhaustionPayload(string recordType)
    {
        return MessageHandlingResult.DeadLetter(
            "InvalidPayload",
            $"The {recordType} payload could not be finalized after retry exhaustion.");
    }

    private static MessageHandlingResult RetryExhaustedResult()
    {
        return MessageHandlingResult.DeadLetter(
            "ObservabilityRetriesExhausted",
            "Observability processing exhausted its delivery attempts.");
    }

    private async Task ResetInteractionForRetryAsync(
        AiInteractionRecord record,
        CancellationToken ct)
    {
        record.ObservabilityStatus = "Queued";
        record.ProcessingStatus = ProcessingStatus.Accepted;
        record.ProcessedAtUtc = null;
        await _unitOfWork.SaveChangesAsync(ct);
    }

    private async Task ResetActivityForRetryAsync(ActivityReceipt receipt, CancellationToken ct)
    {
        receipt.ProcessingStatus = ProcessingStatus.Accepted;
        receipt.ProcessedAtUtc = null;
        await _unitOfWork.SaveChangesAsync(ct);
    }

    private async Task AddObservabilityFailureAuditAsync(
        Guid agentId,
        string recordType,
        string errorCode,
        string correlationId,
        CancellationToken ct,
        string? lastFailureCode = null)
    {
        var details = lastFailureCode is null
            ? JsonSerializer.Serialize(new { RecordType = recordType, ErrorCode = errorCode })
            : JsonSerializer.Serialize(new
            {
                RecordType = recordType,
                ErrorCode = errorCode,
                LastFailureCode = lastFailureCode
            });

        await _auditEventRepository.AddAsync(new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agentId,
            EventType = "ObservabilityExportFailed",
            Details = details,
            CorrelationId = correlationId,
            OccurredAtUtc = DateTime.UtcNow
        }, ct);
    }

    private static bool IsTerminalInteractionStatus(string status)
    {
        return status is "Completed" or "Disabled" or "Failed"
            or "MissingUserContext" or "UnsupportedActivity";
    }

    private static string ToPersistedFailureStatus(string errorCode)
    {
        return errorCode switch
        {
            "MissingUserContext" => "MissingUserContext",
            "UnsupportedOperation" => "UnsupportedActivity",
            _ => "Failed"
        };
    }

    private static string MapActivityOperation(ActivityType activityType)
    {
        return activityType switch
        {
            ActivityType.ToolInvocation => "execute_tool",
            ActivityType.Chat => "chat",
            ActivityType.InvokeAgent => "invoke_agent",
            ActivityType.OutputMessages => "output_messages",
            ActivityType.Custom => "custom",
            _ => throw new Agent365ObservabilityConfigurationException("UnsupportedOperation")
        };
    }

    private static ObservabilityDestinations ResolveDestinations(ObservabilityMode mode)
    {
        return mode switch
        {
            ObservabilityMode.Disabled => ObservabilityDestinations.None,
            ObservabilityMode.GatewayOnly => ObservabilityDestinations.AzureMonitor,
            ObservabilityMode.Agent365 => ObservabilityDestinations.Agent365,
            ObservabilityMode.Agent365AzureMonitor =>
                ObservabilityDestinations.Agent365 | ObservabilityDestinations.AzureMonitor,
            _ => throw new Agent365ObservabilityConfigurationException("UnsupportedObservabilityMode")
        };
    }

    private static ObservabilityDestinations ResolveDestinations(
        ObservabilityMode fallbackMode,
        bool? agent365ObservabilityEnabled,
        bool? azureMonitorExportEnabled)
    {
        if (!agent365ObservabilityEnabled.HasValue || !azureMonitorExportEnabled.HasValue)
            return ResolveDestinations(fallbackMode);

        var destinations = ObservabilityDestinations.None;

        if (agent365ObservabilityEnabled.Value)
            destinations |= ObservabilityDestinations.Agent365;

        if (azureMonitorExportEnabled.Value)
            destinations |= ObservabilityDestinations.AzureMonitor;

        return destinations;
    }

    private async Task<MessageHandlingResult> HandleProvisionAsync(
        string messageType,
        string payload,
        CancellationToken ct)
    {
        ProvisionAgentMessage? message;
        try
        {
            message = JsonSerializer.Deserialize<ProvisionAgentMessage>(payload);
        }
        catch (JsonException)
        {
            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_INVALID_MESSAGE,
                "The provisioning payload is not valid JSON.");
        }

        if (message is null ||
            message.AgentRegistrationId == Guid.Empty ||
            message.JobId == Guid.Empty ||
            message.ExpectedStepIndex < 0)
        {
            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_INVALID_MESSAGE,
                "The provisioning payload is missing required identifiers.");
        }

        await using var executionLease =
            await _provisioningExecutionLockProvider.AcquireAsync(message.JobId, ct);

        var agent = await _agentRepository.GetByIdAsync(message.AgentRegistrationId, ct);
        if (agent is null)
        {
            return MessageHandlingResult.DeadLetter(
                ErrorCodes.AGENT_NOT_FOUND,
                "The referenced agent registration does not exist.");
        }

        var job = await _jobRepository.GetByIdAsync(message.JobId, ct);
        if (job is null)
        {
            return MessageHandlingResult.DeadLetter(
                ErrorCodes.OPERATION_NOT_FOUND,
                "The referenced provisioning job does not exist.");
        }

        if (job.AgentRegistrationId != agent.Id ||
            job.Type is not OperationType.ProvisionAgent and not OperationType.RetryProvisioning)
        {
            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_JOB_MISMATCH,
                "The provisioning job does not belong to the referenced agent.");
        }

        var steps = job.Steps.OrderBy(step => step.OrderIndex).ToList();
        if (!HasCurrentProvisioningSequence(job, steps))
        {
            await PersistProvisioningFailureAsync(
                agent,
                job,
                steps.FirstOrDefault(step => step.Status != StepStatus.Completed),
                ErrorCodes.PROVISIONING_LEGACY_JOB,
                "This job uses a legacy provisioning sequence and requires explicit review.",
                requiresManualIntervention: true,
                message.CorrelationId,
                ct);

            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_LEGACY_JOB,
                "This job uses a legacy provisioning sequence and requires explicit review.");
        }

        var stateResolution = await ResolveProvisioningStateAsync(job, steps, ct);
        if (!stateResolution.Succeeded)
        {
            await PersistProvisioningFailureAsync(
                agent,
                job,
                steps.FirstOrDefault(step => step.Status != StepStatus.Completed),
                stateResolution.ErrorCode!,
                stateResolution.ErrorSummary!,
                requiresManualIntervention: true,
                message.CorrelationId,
                ct);

            return MessageHandlingResult.DeadLetter(
                stateResolution.ErrorCode!,
                stateResolution.ErrorSummary!);
        }

        var persistedPurviewError = ValidatePersistedPurviewState(
            agent,
            steps,
            stateResolution.State);
        if (persistedPurviewError is not null)
        {
            await PersistProvisioningFailureAsync(
                agent,
                job,
                steps.FirstOrDefault(step => step.Status != StepStatus.Completed),
                ErrorCodes.PROVISIONING_STATE_INVALID,
                persistedPurviewError,
                requiresManualIntervention: true,
                message.CorrelationId,
                ct);

            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                persistedPurviewError);
        }

        if (job.Status == JobStatus.Completed)
        {
            if (steps.All(step => step.Status == StepStatus.Completed) &&
                IsStepComplete(ProvisioningStepType.VerifyAgent365Connection, stateResolution.State))
            {
                ApplyProvisioningState(agent, stateResolution.State);
                if (agent.Status == AgentStatus.Provisioning)
                {
                    agent.Status = AgentStatus.Active;
                    agent.LastProvisioningErrorCode = null;
                    agent.LastProvisioningErrorSummary = null;
                }
                await _unitOfWork.SaveChangesAsync(ct);
                return MessageHandlingResult.Complete();
            }

            await PersistProvisioningFailureAsync(
                agent,
                job,
                steps.FirstOrDefault(step => step.Status != StepStatus.Completed),
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The completed job does not contain verified final provisioning state.",
                requiresManualIntervention: true,
                message.CorrelationId,
                ct);

            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The completed job does not contain verified final provisioning state.");
        }

        if (job.Status is JobStatus.Failed or JobStatus.RequiresManualIntervention)
            return MessageHandlingResult.Complete();

        if (job.Status == JobStatus.AwaitingAdministratorAction)
            return MessageHandlingResult.Complete();

        var currentStep = steps.FirstOrDefault(step => step.Status != StepStatus.Completed);
        if (currentStep is null)
        {
            await FinalizeProvisioningAsync(agent, job, stateResolution.State, message.CorrelationId, ct);
            return MessageHandlingResult.Complete();
        }

        if (message.ExpectedStepIndex < currentStep.OrderIndex)
            return MessageHandlingResult.Complete();

        if (message.ExpectedStepIndex > currentStep.OrderIndex)
        {
            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The provisioning message is out of order for the persisted job state.");
        }

        // Workflow v3 reserves Registry creation for the signed-in administrator.
        // A queued RegisterAgent message is stale or invalid and must never cause a
        // worker-side Registry mutation.
        if (currentStep.StepType == ProvisioningStepType.RegisterAgent)
            return MessageHandlingResult.Complete();

        if (!_options.ProvisioningExecutionEnabled)
        {
            await PersistProvisioningFailureAsync(
                agent,
                job,
                currentStep,
                ErrorCodes.PROVISIONING_DISABLED,
                "Real provisioning execution is disabled for this worker.",
                requiresManualIntervention: false,
                message.CorrelationId,
                ct);

            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_DISABLED,
                "Real provisioning execution is disabled for this worker.");
        }

        agent.Status = AgentStatus.Provisioning;
        job.Status = JobStatus.Running;
        job.ErrorCode = null;
        job.ErrorSummary = null;
        job.CompletedAtUtc = null;
        currentStep.Status = StepStatus.Running;
        currentStep.ErrorCode = null;
        currentStep.ErrorMessage = null;
        currentStep.StartedAtUtc ??= DateTime.UtcNow;
        await _unitOfWork.SaveChangesAsync(ct);

        var request = new Agent365ProvisioningStepRequest(
            currentStep.StepType,
            new AgentProvisioningRequest(
                agent.Id,
                agent.ExternalAgentId.Value,
                agent.Name,
                agent.Description,
                agent.OwnerObjectId,
                agent.Environment.ToString(),
                agent.BlueprintSelectionMode,
                agent.RequestedBlueprintObjectId,
                agent.RequestedBlueprintDisplayName),
            stateResolution.State,
            message.CorrelationId);

        Agent365ProvisioningStepResult result;
        try
        {
            result = await _provisioningClient.ExecuteStepAsync(request, ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Agent365ProvisioningException exception) when (exception.IsTransient)
        {

            currentStep.Status = StepStatus.Pending;
            currentStep.ErrorCode = exception.ErrorCode;
            currentStep.ErrorMessage = exception.SafeSummary;
            job.ErrorCode = exception.ErrorCode;
            job.ErrorSummary = exception.SafeSummary;
            await _unitOfWork.SaveChangesAsync(ct);
            throw;
        }
        catch (Agent365ProvisioningException exception)
        {
            await PersistProvisioningFailureAsync(
                agent,
                job,
                currentStep,
                exception.ErrorCode,
                exception.SafeSummary,
                exception.RequiresManualIntervention,
                message.CorrelationId,
                ct);

            return MessageHandlingResult.DeadLetter(
                exception.ErrorCode,
                exception.SafeSummary);
        }
        catch (NotImplementedException)
        {
            const string summary = "The selected provisioning step is not implemented.";
            await PersistProvisioningFailureAsync(
                agent,
                job,
                currentStep,
                ErrorCodes.PROVISIONING_STEP_NOT_IMPLEMENTED,
                summary,
                requiresManualIntervention: false,
                message.CorrelationId,
                ct);

            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_STEP_NOT_IMPLEMENTED,
                summary);
        }
        catch (Exception)
        {
            const string summary = "The provisioning step failed without a safe dependency result.";
            await PersistProvisioningFailureAsync(
                agent,
                job,
                currentStep,
                ErrorCodes.PROVISIONING_FAILED,
                summary,
                requiresManualIntervention: false,
                message.CorrelationId,
                ct);

            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_FAILED,
                summary);
        }

        var validationError = ValidateStepResult(currentStep.StepType, stateResolution.State, result, agent);
        if (validationError is not null)
        {
            await PersistProvisioningFailureAsync(
                agent,
                job,
                currentStep,
                ErrorCodes.PROVISIONING_STATE_INVALID,
                validationError,
                requiresManualIntervention: true,
                message.CorrelationId,
                ct);

            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                validationError);
        }

        if (agent.PurviewPolicyProfileId is not null &&
            currentStep.StepType is ProvisioningStepType.ResolveBlueprint or
                ProvisioningStepType.VerifyAgent365Connection)
        {
            try
            {
                result = currentStep.StepType == ProvisioningStepType.ResolveBlueprint
                    ? await EnsurePurviewPolicyAssignmentAsync(agent, result, ct)
                    : await VerifyPurviewPolicyAssignmentAsync(agent, result, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch (PurviewPolicyException exception) when (exception.IsTransient)
            {
                currentStep.Status = StepStatus.Pending;
                currentStep.ErrorCode = exception.FailureCode;
                currentStep.ErrorMessage = exception.Message;
                job.ErrorCode = exception.FailureCode;
                job.ErrorSummary = exception.Message;
                await _unitOfWork.SaveChangesAsync(ct);
                throw;
            }
            catch (PurviewPolicyException exception)
            {
                await PersistProvisioningFailureAsync(
                    agent,
                    job,
                    currentStep,
                    exception.FailureCode,
                    exception.Message,
                    requiresManualIntervention: false,
                    message.CorrelationId,
                    ct);
                return MessageHandlingResult.DeadLetter(exception.FailureCode, exception.Message);
            }
        }

        var resultData = JsonSerializer.Serialize(result);
        if (resultData.Length > 4000)
        {
            const string summary = "The safe provisioning state exceeds the persistence limit.";
            await PersistProvisioningFailureAsync(
                agent,
                job,
                currentStep,
                ErrorCodes.PROVISIONING_STATE_INVALID,
                summary,
                requiresManualIntervention: true,
                message.CorrelationId,
                ct);

            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                summary);
        }

        currentStep.ResultData = resultData;
        currentStep.Status = StepStatus.Completed;
        currentStep.CompletedAtUtc = DateTime.UtcNow;
        currentStep.ErrorCode = null;
        currentStep.ErrorMessage = null;
        ApplyProvisioningState(agent, result.State);

        var completedCount = steps.Count(step => step.Status == StepStatus.Completed);
        job.PercentComplete = (completedCount * 100) / steps.Count;

        await _auditEventRepository.AddAsync(new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "ProvisioningStepCompleted",
            Details = JsonSerializer.Serialize(new
            {
                job.Id,
                Step = currentStep.StepType.ToString(),
                result.CompletionEvidence
            }),
            CorrelationId = message.CorrelationId,
            OccurredAtUtc = DateTime.UtcNow
        }, ct);

        if (currentStep.StepType == ProvisioningStepType.AssignAgent365Access)
        {
            const string actionSummary =
                "A signed-in administrator must complete Agent 365 Registry registration.";
            job.Status = JobStatus.AwaitingAdministratorAction;
            job.ErrorCode = ErrorCodes.AGENT365_REGISTRY_ACTION_REQUIRED;
            job.ErrorSummary = actionSummary;
            job.CompletedAtUtc = null;
            agent.Status = AgentStatus.AwaitingAdminApproval;
            agent.LastProvisioningErrorCode = ErrorCodes.AGENT365_REGISTRY_ACTION_REQUIRED;
            agent.LastProvisioningErrorSummary = actionSummary;

            await _auditEventRepository.AddAsync(new AuditEvent
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agent.Id,
                EventType = "Agent365RegistryAdministratorActionRequired",
                Details = JsonSerializer.Serialize(new { job.Id }),
                CorrelationId = message.CorrelationId,
                OccurredAtUtc = DateTime.UtcNow
            }, ct);

            await _unitOfWork.SaveChangesAsync(ct);
            return MessageHandlingResult.Complete();
        }

        if (completedCount == steps.Count)
        {
            await FinalizeProvisioningAsync(
                agent,
                job,
                result.State,
                message.CorrelationId,
                ct,
                saveChanges: false);
        }
        else
        {
            await _outboxRepository.AddAsync(new OutboxMessage
            {
                Id = Guid.NewGuid(),
                MessageType = messageType,
                Payload = JsonSerializer.Serialize(message with
                {
                    ExpectedStepIndex = currentStep.OrderIndex + 1
                }),
                Status = OutboxMessageStatus.Pending,
                RetryCount = 0,
                CreatedAtUtc = DateTime.UtcNow
            }, ct);
        }

        await _unitOfWork.SaveChangesAsync(ct);
        return MessageHandlingResult.Complete();
    }

    private async Task<ProvisioningStateResolution> ResolveProvisioningStateAsync(
        ProvisioningJob job,
        IReadOnlyList<ProvisioningJobStep> steps,
        CancellationToken ct)
    {
        var state = new Agent365ProvisioningState();
        var hasPersistedState = false;
        var sawIncompleteStep = false;

        foreach (var step in steps)
        {
            if (step.Status != StepStatus.Completed)
            {
                sawIncompleteStep = true;
                continue;
            }

            if (sawIncompleteStep)
            {
                return ProvisioningStateResolution.Failed(
                    "Completed provisioning steps are not a contiguous verified prefix.");
            }

            if (!TryDeserializeStepResult(step, out var persistedResult) ||
                !StatePreserves(state, persistedResult.State) ||
                !IsStepComplete(step.StepType, persistedResult.State))
            {
                return ProvisioningStateResolution.Failed(
                    "A completed provisioning step is missing valid resumable state.");
            }

            state = persistedResult.State;
            hasPersistedState = true;
        }

        if (job.Type != OperationType.RetryProvisioning)
            return ProvisioningStateResolution.Success(state);

        var priorJobs = await _jobRepository.GetByAgentIdAsync(job.AgentRegistrationId, ct);
        var priorProvisioningJobs = priorJobs
            .Where(candidate =>
                candidate.Id != job.Id &&
                candidate.Type is OperationType.ProvisionAgent or OperationType.RetryProvisioning)
            .ToArray();
        if (priorProvisioningJobs.Any(candidate =>
                candidate.WorkflowVersion != job.WorkflowVersion ||
                !HasCurrentProvisioningSequence(
                    candidate,
                    candidate.Steps.OrderBy(step => step.OrderIndex).ToList())))
        {
            return ProvisioningStateResolution.Failed(
                "A prior provisioning job uses a legacy workflow and cannot seed this retry.",
                ErrorCodes.PROVISIONING_LEGACY_JOB);
        }

        if (priorProvisioningJobs.Length == 0)
        {
            return ProvisioningStateResolution.Failed(
                "No prior provisioning job can safely seed this retry.");
        }

        if (priorProvisioningJobs.Any(candidate =>
                candidate.Status is JobStatus.Pending or JobStatus.Running or
                    JobStatus.AwaitingAdministratorAction))
        {
            return ProvisioningStateResolution.Failed(
                "An earlier provisioning job is still active and prevents a safe retry.");
        }

        if (priorProvisioningJobs.Any(candidate =>
                candidate.Steps.Any(step => step.Status == StepStatus.Running)))
        {
            return ProvisioningStateResolution.Failed(
                "A prior provisioning stage may have mutated external state and cannot be retried safely.",
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        }

        // Current workflow-v3 retries carry their verified completed prefix in the
        // new job. Once that prefix has passed the monotonic state checks above and
        // no other job or step is active, it is the authoritative retry boundary.
        // Re-evaluating every older terminal job here can incorrectly reject a
        // final-only retry merely because an earlier attempt required manual
        // intervention. No external mutation is repeated: the next pending step is
        // the only step the worker can execute.
        if (hasPersistedState)
            return ProvisioningStateResolution.Success(state);

        if (priorProvisioningJobs.Any(candidate =>
                candidate.Status == JobStatus.RequiresManualIntervention ||
                string.Equals(
                    candidate.ErrorCode,
                    ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                    StringComparison.Ordinal) ||
                candidate.Steps.Any(step => string.Equals(
                    step.ErrorCode,
                    ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                    StringComparison.Ordinal))))
        {
            return ProvisioningStateResolution.Failed(
                "A prior provisioning result is ambiguous or requires manual reconciliation.",
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        }

        var retrySources = priorProvisioningJobs
            .OrderByDescending(candidate => candidate.CreatedAtUtc)
            .ThenByDescending(candidate => candidate.Id)
            .ToArray();
        if (retrySources.Any(HasUnsafeRegistryRetryBoundary))
        {
            return ProvisioningStateResolution.Failed(
                "A prior Agent 365 Registry create may have completed and cannot be retried safely.",
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        }

        var retrySource = retrySources[0];
        if (retrySource.Status != JobStatus.Failed ||
            string.IsNullOrWhiteSpace(retrySource.ErrorCode) ||
            string.Equals(
                retrySource.ErrorCode,
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                StringComparison.Ordinal) ||
            !retrySource.Steps.Any(step => step.Status == StepStatus.Failed))
        {
            return ProvisioningStateResolution.Failed(
                "The latest provisioning result lacks durable retry-safe failure evidence.");
        }

        if (!TryResolvePriorCompletedPrefix(
                retrySource.Steps.OrderBy(step => step.OrderIndex).ToArray(),
                out var priorState,
                out _))
        {
            return ProvisioningStateResolution.Failed(
                "The retry source does not contain a valid monotonic completed prefix.");
        }

        return ProvisioningStateResolution.Success(priorState);
    }

    private static bool HasUnsafeRegistryRetryBoundary(ProvisioningJob priorJob)
    {
        var registryStep = priorJob.Steps.Single(step =>
            step.StepType == ProvisioningStepType.RegisterAgent);
        if (registryStep.Status == StepStatus.Pending)
            return priorJob.Status != JobStatus.Failed;

        // A delegated Registry POST is never repeated by retry. Once the boundary
        // was reached, the existing job must be resumed or reconciled by exact ID.
        return true;
    }

    private static bool TryResolvePriorCompletedPrefix(
        IReadOnlyList<ProvisioningJobStep> steps,
        out Agent365ProvisioningState state,
        out bool hasPersistedState)
    {
        state = new Agent365ProvisioningState();
        hasPersistedState = false;
        var sawIncompleteStep = false;

        foreach (var step in steps)
        {
            if (step.Status != StepStatus.Completed)
            {
                sawIncompleteStep = true;
                continue;
            }

            if (sawIncompleteStep ||
                !TryDeserializeStepResult(step, out var persistedResult) ||
                !StatePreserves(state, persistedResult.State) ||
                !IsStepComplete(step.StepType, persistedResult.State))
            {
                return false;
            }

            state = persistedResult.State;
            hasPersistedState = true;
        }

        return true;
    }

    private static bool TryDeserializeStepResult(
        ProvisioningJobStep step,
        out Agent365ProvisioningStepResult result)
    {
        result = null!;
        if (string.IsNullOrWhiteSpace(step.ResultData))
            return false;

        try
        {
            var parsed = JsonSerializer.Deserialize<Agent365ProvisioningStepResult>(step.ResultData);
            if (parsed is null ||
                parsed.State is null ||
                parsed.StepType != step.StepType ||
                !IsSafeCompletionEvidence(parsed.CompletionEvidence))
            {
                return false;
            }

            result = parsed;
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static string? ValidateStepResult(
        ProvisioningStepType expectedStep,
        Agent365ProvisioningState previousState,
        Agent365ProvisioningStepResult result,
        AgentRegistration agent)
    {
        if (result.StepType != expectedStep ||
            result.State is null ||
            !IsSafeCompletionEvidence(result.CompletionEvidence))
        {
            return "The provisioning adapter returned an invalid step result.";
        }

        if (!StatePreserves(previousState, result.State) ||
            !IsStepComplete(expectedStep, result.State) ||
            !HasValidNewStepIdentifiers(expectedStep, result.State))
        {
            return "The provisioning adapter did not return verified monotonic state for this step.";
        }

        if (agent.CredentialReference is not null &&
            result.State.KeyVaultSecretUri is not null &&
            !string.Equals(
                agent.CredentialReference.KeyVaultSecretUri,
                result.State.KeyVaultSecretUri,
                StringComparison.Ordinal))
        {
            return "The provisioning result conflicts with the persisted credential reference.";
        }

        return null;
    }

    private static bool HasValidNewStepIdentifiers(
        ProvisioningStepType stepType,
        Agent365ProvisioningState state)
    {
        return stepType != ProvisioningStepType.RegisterAgent ||
               TryParseNonEmptyGuid(state.Agent365RegistrationId, out _);
    }

    private static bool TryParseNonEmptyGuid(string? value, out Guid parsed) =>
        Guid.TryParse(value, out parsed) && parsed != Guid.Empty;

    private static bool HasCurrentProvisioningSequence(
        ProvisioningJob job,
        IReadOnlyList<ProvisioningJobStep> steps)
    {
        if (job.WorkflowVersion != ProvisioningWorkflow.CurrentVersion ||
            steps.Count != ProvisioningWorkflow.CurrentSteps.Count)
            return false;

        for (var index = 0; index < steps.Count; index++)
        {
            if (steps[index].OrderIndex != index ||
                steps[index].StepType != ProvisioningWorkflow.CurrentSteps[index])
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsStepComplete(
        ProvisioningStepType stepType,
        Agent365ProvisioningState state)
    {
        return stepType switch
        {
            ProvisioningStepType.CreateAppRegistration =>
                HasValue(state.ApplicationObjectId) && HasValue(state.ApplicationClientId),
            ProvisioningStepType.CreateServicePrincipal =>
                HasValue(state.ServicePrincipalObjectId),
            ProvisioningStepType.AssignRoles =>
                HasValue(state.AppRoleAssignmentId),
            ProvisioningStepType.StoreCredentials =>
                HasValue(state.PasswordCredentialKeyId) && HasValue(state.KeyVaultSecretUri),
            ProvisioningStepType.CreateBlueprint =>
                HasValue(state.BlueprintObjectId) && HasValue(state.BlueprintClientId),
            ProvisioningStepType.CreateBlueprintPrincipal =>
                HasValue(state.BlueprintPrincipalObjectId),
            ProvisioningStepType.CreateAgentIdentity =>
                HasValue(state.AgentIdentityObjectId) &&
                HasValue(state.AgentIdentityClientId) &&
                HasValue(state.BlueprintClientId),
            ProvisioningStepType.RegisterAgent =>
                TryParseNonEmptyGuid(state.Agent365RegistrationId, out _) &&
                string.Equals(
                    state.RegistryAuthenticationMode,
                    Agent365Options.DelegatedAdministratorAuthenticationMode,
                    StringComparison.Ordinal) &&
                TryParseNonEmptyGuid(state.RegistryCreatedByObjectId, out _) &&
                (state.Agent365RegistrationAcceptedAtUtc is not null ||
                 state.Agent365RegistrationVerifiedAtUtc is not null),
            ProvisioningStepType.ResolveBlueprint =>
                HasValue(state.BlueprintObjectId) &&
                HasValue(state.BlueprintClientId),
            ProvisioningStepType.EnsureBlueprintPrincipal =>
                HasValue(state.BlueprintPrincipalObjectId),
            ProvisioningStepType.ConfigureGatewayFederation =>
                HasValue(state.GatewayManagedIdentityPrincipalId) &&
                HasValue(state.GatewayFederatedCredentialId),
            ProvisioningStepType.AssignAgent365Access =>
                HasValue(state.ObservabilityAppRoleAssignmentId) &&
                HasValue(state.AgentIdentityClientId),
            ProvisioningStepType.VerifyAgent365Connection =>
                state.Agent365ConnectionVerifiedAtUtc is not null &&
                IsStepComplete(ProvisioningStepType.RegisterAgent, state) &&
                HasValue(state.BlueprintPrincipalObjectId) &&
                HasValue(state.GatewayManagedIdentityPrincipalId) &&
                HasValue(state.GatewayFederatedCredentialId) &&
                HasValue(state.AgentIdentityClientId) &&
                HasValue(state.BlueprintClientId) &&
                HasValue(state.ObservabilityAppRoleAssignmentId) &&
                HasValue(state.Agent365RegistrationId),
            _ => false
        };
    }

    private static bool StatePreserves(
        Agent365ProvisioningState previous,
        Agent365ProvisioningState current)
    {
        return Preserves(previous.ApplicationObjectId, current.ApplicationObjectId) &&
               Preserves(previous.ApplicationClientId, current.ApplicationClientId) &&
               Preserves(previous.ServicePrincipalObjectId, current.ServicePrincipalObjectId) &&
               Preserves(previous.AppRoleAssignmentId, current.AppRoleAssignmentId) &&
               Preserves(previous.PasswordCredentialKeyId, current.PasswordCredentialKeyId) &&
               Preserves(previous.KeyVaultSecretUri, current.KeyVaultSecretUri) &&
               Preserves(previous.CredentialExpiresAtUtc, current.CredentialExpiresAtUtc) &&
               Preserves(previous.BlueprintObjectId, current.BlueprintObjectId) &&
               Preserves(previous.BlueprintClientId, current.BlueprintClientId) &&
               Preserves(previous.BlueprintPrincipalObjectId, current.BlueprintPrincipalObjectId) &&
               Preserves(previous.AgentIdentityObjectId, current.AgentIdentityObjectId) &&
               Preserves(previous.AgentIdentityClientId, current.AgentIdentityClientId) &&
               Preserves(previous.ObservabilityAppRoleAssignmentId, current.ObservabilityAppRoleAssignmentId) &&
               Preserves(previous.GatewayManagedIdentityPrincipalId, current.GatewayManagedIdentityPrincipalId) &&
               Preserves(previous.GatewayFederatedCredentialId, current.GatewayFederatedCredentialId) &&
               Preserves(previous.PurviewPolicyProfileId, current.PurviewPolicyProfileId) &&
               Preserves(previous.PurviewCollectionPolicyId, current.PurviewCollectionPolicyId) &&
               Preserves(previous.PurviewDlpPolicyId, current.PurviewDlpPolicyId) &&
               Preserves(previous.PurviewDlpRuleId, current.PurviewDlpRuleId) &&
               Preserves(
                   previous.PurviewPolicyAssignmentVerifiedAtUtc,
                   current.PurviewPolicyAssignmentVerifiedAtUtc) &&
               Preserves(
                   previous.PurviewPolicyFinalVerifiedAtUtc,
                   current.PurviewPolicyFinalVerifiedAtUtc) &&
               Preserves(previous.PlannedAgent365RegistrationId, current.PlannedAgent365RegistrationId) &&
               Preserves(previous.Agent365RegistrationId, current.Agent365RegistrationId) &&
               Preserves(previous.RegistryProvider, current.RegistryProvider) &&
               Preserves(previous.RegistryAuthenticationMode, current.RegistryAuthenticationMode) &&
               Preserves(previous.RegistryCreatedByObjectId, current.RegistryCreatedByObjectId) &&
               Preserves(
                   previous.Agent365RegistrationAcceptedAtUtc,
                   current.Agent365RegistrationAcceptedAtUtc) &&
               Preserves(
                   previous.Agent365RegistrationVerifiedAtUtc,
                   current.Agent365RegistrationVerifiedAtUtc) &&
               Preserves(
                   previous.Agent365ConnectionVerifiedAtUtc,
                   current.Agent365ConnectionVerifiedAtUtc);
    }

    private static bool Preserves(string? previous, string? current) =>
        previous is null || string.Equals(previous, current, StringComparison.Ordinal);

    private static bool Preserves(DateTimeOffset? previous, DateTimeOffset? current) =>
        previous is null || previous == current;

    private static bool Preserves(Guid? previous, Guid? current) =>
        previous is null || previous == current;

    private static bool HasValue(string? value) => !string.IsNullOrWhiteSpace(value);

    private static string? ValidatePersistedPurviewState(
        AgentRegistration agent,
        IReadOnlyList<ProvisioningJobStep> steps,
        Agent365ProvisioningState state)
    {
        if (agent.PurviewPolicyProfileId is null)
            return null;

        var resolveStep = steps.Single(step =>
            step.StepType == ProvisioningStepType.ResolveBlueprint);
        if (resolveStep.Status != StepStatus.Completed)
            return null;

        if (state.PurviewPolicyProfileId != agent.PurviewPolicyProfileId ||
            !HasValue(state.PurviewCollectionPolicyId) ||
            !HasValue(state.PurviewDlpPolicyId) ||
            !HasValue(state.PurviewDlpRuleId) ||
            state.PurviewPolicyAssignmentVerifiedAtUtc is null)
        {
            return "The protected blueprint prefix is missing exact Purview profile readback evidence.";
        }

        var finalStep = steps.Single(step =>
            step.StepType == ProvisioningStepType.VerifyAgent365Connection);
        if (finalStep.Status == StepStatus.Completed &&
            state.PurviewPolicyFinalVerifiedAtUtc is null)
        {
            return "The protected registration is missing final Purview revalidation evidence.";
        }

        return null;
    }

    private static bool IsSafeCompletionEvidence(string? evidence) =>
        !string.IsNullOrWhiteSpace(evidence) &&
        evidence.Length <= 64 &&
        evidence.All(character =>
            char.IsLetterOrDigit(character) || character is '-' or '_');

    private static void ApplyProvisioningState(
        AgentRegistration agent,
        Agent365ProvisioningState state)
    {
        agent.ExternalClientId = state.AgentIdentityClientId ?? agent.ExternalClientId;
        agent.AgentIdentityObjectId = state.AgentIdentityObjectId ?? agent.AgentIdentityObjectId;
        agent.BlueprintObjectId = state.BlueprintObjectId ?? agent.BlueprintObjectId;
        agent.BlueprintId = state.BlueprintClientId ?? agent.BlueprintId;
        agent.Agent365AgentId = state.AgentIdentityClientId ?? agent.Agent365AgentId;
        agent.Agent365InstanceId = state.Agent365RegistrationId ?? agent.Agent365InstanceId;
        agent.PurviewPolicyProfileId = state.PurviewPolicyProfileId ?? agent.PurviewPolicyProfileId;
        agent.PurviewPolicyAssignmentVerifiedAtUtc =
            state.PurviewPolicyFinalVerifiedAtUtc?.UtcDateTime ??
            state.PurviewPolicyAssignmentVerifiedAtUtc?.UtcDateTime ??
            agent.PurviewPolicyAssignmentVerifiedAtUtc;

        if (state.KeyVaultSecretUri is null)
            return;

        if (agent.CredentialReference is null)
        {
            agent.CredentialReference = new AgentCredentialReference
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agent.Id,
                CredentialType = CredentialType.ClientSecret,
                KeyVaultSecretUri = state.KeyVaultSecretUri,
                ExpiresAtUtc = state.CredentialExpiresAtUtc?.UtcDateTime,
                CreatedAtUtc = DateTime.UtcNow
            };
            return;
        }

        agent.CredentialReference.ExpiresAtUtc = state.CredentialExpiresAtUtc?.UtcDateTime;
    }

    private async Task<Agent365ProvisioningStepResult> EnsurePurviewPolicyAssignmentAsync(
        AgentRegistration agent,
        Agent365ProvisioningStepResult result,
        CancellationToken ct)
    {
        if (!_purviewPolicyProvisioningClient.IsEnabled)
        {
            throw new PurviewPolicyException(
                "PURVIEW_POLICY_PROVISIONING_DISABLED",
                "Automated Purview policy assignment is not configured for this worker.");
        }

        var profileId = agent.PurviewPolicyProfileId!.Value;
        await using var profileLease = await _provisioningExecutionLockProvider.AcquireAsync(
            profileId,
            ct);
        var profile = await _purviewPolicyProfileRepository.GetByIdAsync(
            profileId,
            ct) ?? throw new PurviewPolicyException(
                "PURVIEW_POLICY_PROFILE_NOT_FOUND",
                "The selected Purview policy profile no longer exists.");
        var blueprintApplicationId = result.State.BlueprintClientId;
        if (!TryParseNonEmptyGuid(blueprintApplicationId, out _))
        {
            throw new PurviewPolicyException(
                "PURVIEW_POLICY_BLUEPRINT_INVALID",
                "The resolved blueprint did not provide a valid Application ID.");
        }

        if (!TryResolveAuthorizedPurviewDlpScope(profile, out var priorDlpApplicationIds, out var scopeError))
        {
            MarkPurviewProfileFailed(profile, "PURVIEW_POLICY_PERSISTED_SCOPE_INVALID");
            throw new PurviewPolicyException(
                "PURVIEW_POLICY_PERSISTED_SCOPE_INVALID",
                scopeError!);
        }
        var expectedDlpApplicationIds = AddBlueprintToAuthorizedDlpScope(
            priorDlpApplicationIds,
            blueprintApplicationId!);

        PurviewPolicyProvisioningResult provisioned;
        try
        {
            provisioned = await _purviewPolicyProvisioningClient.EnsureProfileAssignmentAsync(
                new PurviewPolicyProvisioningRequest(
                    profile.Id,
                    profile.DisplayName,
                    profile.Template,
                    profile.Mode,
                    profile.CollectionPolicyName,
                    profile.DlpPolicyName,
                    profile.DlpRuleName,
                    blueprintApplicationId!,
                    agent.RequestedBlueprintDisplayName ?? agent.Name,
                    profile.CollectionPolicyId,
                    profile.DlpPolicyId,
                    profile.DlpRuleId,
                    priorDlpApplicationIds,
                    expectedDlpApplicationIds),
                ct);
        }
        catch (PurviewPolicyException exception) when (!exception.IsTransient)
        {
            MarkPurviewProfileFailed(profile, exception.FailureCode);
            throw;
        }
        var readbackError = ValidatePurviewReadback(
            profile,
            provisioned,
            blueprintApplicationId!,
            expectedDlpApplicationIds,
            expectedState: null);
        if (readbackError is not null)
        {
            MarkPurviewProfileFailed(profile, "PURVIEW_POLICY_READBACK_MISMATCH");
            throw new PurviewPolicyException(
                "PURVIEW_POLICY_READBACK_MISMATCH",
                readbackError);
        }

        profile.CollectionPolicyId = provisioned.CollectionPolicyId;
        profile.DlpPolicyId = provisioned.DlpPolicyId;
        profile.DlpRuleId = provisioned.DlpRuleId;
        profile.BlueprintApplicationIdsJson = JsonSerializer.Serialize(expectedDlpApplicationIds);
        profile.Status = "Ready";
        profile.VerifiedAtUtc = provisioned.VerifiedAtUtc.UtcDateTime;
        profile.LastErrorCode = null;
        profile.UpdatedAtUtc = DateTime.UtcNow;
        agent.PurviewPolicyAssignmentVerifiedAtUtc = provisioned.VerifiedAtUtc.UtcDateTime;

        return result with
        {
            State = result.State with
            {
                PurviewPolicyProfileId = profile.Id,
                PurviewCollectionPolicyId = provisioned.CollectionPolicyId,
                PurviewDlpPolicyId = provisioned.DlpPolicyId,
                PurviewDlpRuleId = provisioned.DlpRuleId,
                PurviewPolicyAssignmentVerifiedAtUtc = provisioned.VerifiedAtUtc
            },
            CompletionEvidence = "BlueprintAndPurviewProfileVerified"
        };
    }

    private async Task<Agent365ProvisioningStepResult> VerifyPurviewPolicyAssignmentAsync(
        AgentRegistration agent,
        Agent365ProvisioningStepResult result,
        CancellationToken ct)
    {
        if (!_purviewPolicyProvisioningClient.IsEnabled)
        {
            throw new PurviewPolicyException(
                "PURVIEW_POLICY_PROVISIONING_DISABLED",
                "Automated Purview policy verification is not configured for this worker.");
        }

        var profileId = agent.PurviewPolicyProfileId!.Value;
        await using var profileLease = await _provisioningExecutionLockProvider.AcquireAsync(
            profileId,
            ct);
        var profile = await _purviewPolicyProfileRepository.GetByIdAsync(
            profileId,
            ct) ?? throw new PurviewPolicyException(
                "PURVIEW_POLICY_PROFILE_NOT_FOUND",
                "The selected Purview policy profile no longer exists.");
        if (!string.Equals(profile.Status, "Ready", StringComparison.Ordinal) ||
            result.State.PurviewPolicyProfileId != profile.Id ||
            !HasValue(profile.CollectionPolicyId) ||
            !HasValue(profile.DlpPolicyId) ||
            !HasValue(profile.DlpRuleId) ||
            !HasValue(result.State.PurviewCollectionPolicyId) ||
            !HasValue(result.State.PurviewDlpPolicyId) ||
            !HasValue(result.State.PurviewDlpRuleId) ||
            result.State.PurviewPolicyAssignmentVerifiedAtUtc is null)
        {
            throw new PurviewPolicyException(
                "PURVIEW_POLICY_STATE_INVALID",
                "The selected Purview profile lacks a complete verified assignment state.");
        }

        var blueprintApplicationId = result.State.BlueprintClientId;
        if (!TryParseNonEmptyGuid(blueprintApplicationId, out _))
        {
            throw new PurviewPolicyException(
                "PURVIEW_POLICY_BLUEPRINT_INVALID",
                "The final provisioning state did not contain a valid blueprint Application ID.");
        }
        if (!TryResolveAuthorizedPurviewDlpScope(profile, out var priorDlpApplicationIds, out var scopeError))
        {
            MarkPurviewProfileFailed(profile, "PURVIEW_POLICY_PERSISTED_SCOPE_INVALID");
            throw new PurviewPolicyException(
                "PURVIEW_POLICY_PERSISTED_SCOPE_INVALID",
                scopeError!);
        }
        var expectedDlpApplicationIds = AddBlueprintToAuthorizedDlpScope(
            priorDlpApplicationIds,
            blueprintApplicationId!);

        PurviewPolicyProvisioningResult provisioned;
        try
        {
            provisioned = await _purviewPolicyProvisioningClient.VerifyProfileAssignmentAsync(
                new PurviewPolicyProvisioningRequest(
                    profile.Id,
                    profile.DisplayName,
                    profile.Template,
                    profile.Mode,
                    profile.CollectionPolicyName,
                    profile.DlpPolicyName,
                    profile.DlpRuleName,
                    blueprintApplicationId!,
                    agent.RequestedBlueprintDisplayName ?? agent.Name,
                    result.State.PurviewCollectionPolicyId,
                    result.State.PurviewDlpPolicyId,
                    result.State.PurviewDlpRuleId,
                    priorDlpApplicationIds,
                    expectedDlpApplicationIds),
                ct);
        }
        catch (PurviewPolicyException exception) when (!exception.IsTransient)
        {
            MarkPurviewProfileFailed(profile, exception.FailureCode);
            throw;
        }
        var readbackError = ValidatePurviewReadback(
            profile,
            provisioned,
            blueprintApplicationId!,
            expectedDlpApplicationIds,
            result.State);
        if (readbackError is not null)
        {
            MarkPurviewProfileFailed(profile, "PURVIEW_POLICY_READBACK_MISMATCH");
            throw new PurviewPolicyException(
                "PURVIEW_POLICY_READBACK_MISMATCH",
                readbackError);
        }

        profile.BlueprintApplicationIdsJson = JsonSerializer.Serialize(expectedDlpApplicationIds);
        profile.VerifiedAtUtc = provisioned.VerifiedAtUtc.UtcDateTime;
        profile.LastErrorCode = null;
        profile.UpdatedAtUtc = DateTime.UtcNow;
        agent.PurviewPolicyAssignmentVerifiedAtUtc = provisioned.VerifiedAtUtc.UtcDateTime;

        return result with
        {
            State = result.State with
            {
                PurviewPolicyFinalVerifiedAtUtc = provisioned.VerifiedAtUtc
            },
            CompletionEvidence = "Agent365ConnectionAndPurviewVerified"
        };
    }

    private static string? ValidatePurviewReadback(
        PurviewPolicyProfile profile,
        PurviewPolicyProvisioningResult provisioned,
        string blueprintApplicationId,
        IReadOnlyList<string> expectedDlpApplicationIds,
        Agent365ProvisioningState? expectedState)
    {
        if (string.IsNullOrWhiteSpace(provisioned.CollectionPolicyId) ||
            string.IsNullOrWhiteSpace(provisioned.DlpPolicyId) ||
            string.IsNullOrWhiteSpace(provisioned.DlpRuleId) ||
            provisioned.VerifiedAtUtc == default ||
            provisioned.DlpBlueprintApplicationIds.Count(applicationId => string.Equals(
                applicationId,
                blueprintApplicationId,
                StringComparison.OrdinalIgnoreCase)) != 1 ||
            provisioned.DlpBlueprintApplicationIds.Count !=
                provisioned.DlpBlueprintApplicationIds.Distinct(
                    StringComparer.OrdinalIgnoreCase).Count() ||
            !HasExactGuidSet(provisioned.DlpBlueprintApplicationIds, expectedDlpApplicationIds))
        {
            return "Purview did not return complete exact blueprint and provider-ID readback evidence.";
        }

        if (!MatchesPersistedIdentifier(profile.CollectionPolicyId, provisioned.CollectionPolicyId) ||
            !MatchesPersistedIdentifier(profile.DlpPolicyId, provisioned.DlpPolicyId) ||
            !MatchesPersistedIdentifier(profile.DlpRuleId, provisioned.DlpRuleId) ||
            (expectedState is not null &&
             (!string.Equals(
                  expectedState.PurviewCollectionPolicyId,
                  provisioned.CollectionPolicyId,
                  StringComparison.Ordinal) ||
              !string.Equals(
                  expectedState.PurviewDlpPolicyId,
                  provisioned.DlpPolicyId,
                  StringComparison.Ordinal) ||
              !string.Equals(
                  expectedState.PurviewDlpRuleId,
                  provisioned.DlpRuleId,
                  StringComparison.Ordinal) ||
              provisioned.VerifiedAtUtc < expectedState.PurviewPolicyAssignmentVerifiedAtUtc)))
        {
            return "Purview provider identifiers or verification time do not match the persisted profile state.";
        }

        var expectedDlpMode = profile.Mode switch
        {
            "Enforce" => "Enable",
            "AuditOnly" => "TestWithoutNotifications",
            _ => null
        };
        var evidence = provisioned.Evidence;
        if (expectedDlpMode is null ||
            evidence is null ||
            !string.Equals(evidence.CollectionMode, "Enable", StringComparison.Ordinal) ||
            !HasExactSet(evidence.CollectionActivities, "UploadText", "DownloadText") ||
            !HasExactSet(
                evidence.CollectionEnforcementPlanes,
                PurviewPolicyLocationContract.ApplicationEnforcementPlane) ||
            !HasExactSet(evidence.CollectionSensitiveTypeIds, "All") ||
            !evidence.CollectionIngestionEnabled ||
            !HasExactPurviewLocation(
                evidence.CollectionLocation,
                PurviewPolicyLocationContract.CollectionLocationType,
                [PurviewPolicyLocationContract.EnterpriseAiAppsCollectionLocationId]) ||
            !string.Equals(evidence.DlpMode, expectedDlpMode, StringComparison.Ordinal) ||
            !HasExactSet(
                evidence.DlpEnforcementPlanes,
                PurviewPolicyLocationContract.ApplicationEnforcementPlane) ||
            !HasExactPurviewLocation(
                evidence.DlpLocation,
                PurviewPolicyLocationContract.DlpLocationType,
                expectedDlpApplicationIds) ||
            evidence.ClassifierNames.Count != 1 ||
            evidence.ClassifierNames.Any(string.IsNullOrWhiteSpace) ||
            evidence.RuleActions.Count != 1 ||
            !string.Equals(evidence.RuleActions[0].Setting, "UploadText", StringComparison.Ordinal) ||
            !string.Equals(evidence.RuleActions[0].Value, "Block", StringComparison.Ordinal) ||
            evidence.HasExclusions ||
            evidence.HasBypass ||
            evidence.HasExtraConditions ||
            evidence.HasExtraActions)
        {
            return "Purview typed readback does not match the reviewed Gateway protection template.";
        }

        return null;
    }

    private static bool MatchesPersistedIdentifier(string? expected, string actual) =>
        string.IsNullOrWhiteSpace(expected) ||
        string.Equals(expected, actual, StringComparison.Ordinal);

    private static bool HasExactSet(IReadOnlyList<string> actual, params string[] expected) =>
        actual.Count == expected.Length &&
        actual.OrderBy(value => value, StringComparer.Ordinal).SequenceEqual(
            expected.OrderBy(value => value, StringComparer.Ordinal),
            StringComparer.Ordinal);

    private static bool HasExactPurviewLocation(
        PurviewPolicyLocationReadbackEvidence? actual,
        string expectedLocationType,
        IReadOnlyList<string> expectedLocationIds) =>
        actual is not null &&
        string.Equals(
            actual.Workload,
            PurviewPolicyLocationContract.ApplicationWorkload,
            StringComparison.Ordinal) &&
        string.Equals(
            actual.LocationSource,
            PurviewPolicyLocationContract.EntraLocationSource,
            StringComparison.Ordinal) &&
        string.Equals(actual.LocationType, expectedLocationType, StringComparison.Ordinal) &&
        actual.LocationIds is not null &&
        HasExactGuidSet(actual.LocationIds, expectedLocationIds);

    private static bool HasExactGuidSet(
        IReadOnlyList<string> actual,
        IReadOnlyList<string> expected)
    {
        var normalizedActual = new List<string>(actual.Count);
        foreach (var value in actual)
        {
            if (!TryParseNonEmptyGuid(value, out var parsed))
                return false;
            normalizedActual.Add(parsed.ToString("D"));
        }

        return normalizedActual.Count == expected.Count &&
               normalizedActual.OrderBy(value => value, StringComparer.Ordinal).SequenceEqual(
                   expected.OrderBy(value => value, StringComparer.Ordinal),
                   StringComparer.Ordinal);
    }

    private static bool TryResolveAuthorizedPurviewDlpScope(
        PurviewPolicyProfile profile,
        out string[] applicationIds,
        out string? error)
    {
        applicationIds = [];
        error = null;
        if (string.IsNullOrWhiteSpace(profile.BlueprintApplicationIdsJson) ||
            profile.BlueprintApplicationIdsJson.Length > 65536)
        {
            error = "The persisted Purview application scope is missing or exceeds the safe limit.";
            return false;
        }

        try
        {
            using var document = JsonDocument.Parse(profile.BlueprintApplicationIdsJson);
            if (document.RootElement.ValueKind != JsonValueKind.Array ||
                document.RootElement.GetArrayLength() > 512)
            {
                error = "The persisted Purview application scope is not a bounded JSON array.";
                return false;
            }

            var values = new List<string>(document.RootElement.GetArrayLength());
            foreach (var element in document.RootElement.EnumerateArray())
            {
                if (element.ValueKind != JsonValueKind.String ||
                    !TryParseNonEmptyGuid(element.GetString(), out var parsed))
                {
                    error = "The persisted Purview application scope contains an invalid Application ID.";
                    return false;
                }
                var canonical = parsed.ToString("D");
                if (values.Contains(canonical, StringComparer.Ordinal))
                {
                    error = "The persisted Purview application scope contains a duplicate Application ID.";
                    return false;
                }
                values.Add(canonical);
            }
            applicationIds = values.OrderBy(value => value, StringComparer.Ordinal).ToArray();
        }
        catch (JsonException)
        {
            error = "The persisted Purview application scope is not valid JSON.";
            return false;
        }

        if (string.Equals(profile.Status, "Pending", StringComparison.Ordinal))
        {
            if (applicationIds.Length != 0 ||
                HasValue(profile.CollectionPolicyId) ||
                HasValue(profile.DlpPolicyId) ||
                HasValue(profile.DlpRuleId) ||
                profile.VerifiedAtUtc is not null)
            {
                error = "A pending Purview profile contains provider authority that cannot be adopted automatically.";
                return false;
            }
            return true;
        }

        if (!string.Equals(profile.Status, "Ready", StringComparison.Ordinal) ||
            applicationIds.Length == 0 ||
            !HasValue(profile.CollectionPolicyId) ||
            !HasValue(profile.DlpPolicyId) ||
            !HasValue(profile.DlpRuleId) ||
            profile.VerifiedAtUtc is null)
        {
            error = "The Purview profile is not a complete Ready profile with persisted scope authority.";
            return false;
        }
        return true;
    }

    private static string[] AddBlueprintToAuthorizedDlpScope(
        IReadOnlyList<string> priorDlpApplicationIds,
        string blueprintApplicationId)
    {
        _ = TryParseNonEmptyGuid(blueprintApplicationId, out var parsed);
        return priorDlpApplicationIds
            .Append(parsed.ToString("D"))
            .Distinct(StringComparer.Ordinal)
            .OrderBy(value => value, StringComparer.Ordinal)
            .ToArray();
    }

    private static void MarkPurviewProfileFailed(
        PurviewPolicyProfile profile,
        string errorCode)
    {
        profile.Status = "Failed";
        profile.LastErrorCode = errorCode;
        profile.UpdatedAtUtc = DateTime.UtcNow;
    }

    private async Task FinalizeProvisioningAsync(
        AgentRegistration agent,
        ProvisioningJob job,
        Agent365ProvisioningState state,
        string? correlationId,
        CancellationToken ct,
        bool saveChanges = true)
    {
        ApplyProvisioningState(agent, state);
        job.Status = JobStatus.Completed;
        job.PercentComplete = 100;
        job.ErrorCode = null;
        job.ErrorSummary = null;
        job.CompletedAtUtc = DateTime.UtcNow;
        if (agent.Status == AgentStatus.Provisioning)
        {
            agent.Status = AgentStatus.Active;
            agent.LastProvisioningErrorCode = null;
            agent.LastProvisioningErrorSummary = null;
        }

        await _auditEventRepository.AddAsync(new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "ProvisioningCompleted",
            Details = JsonSerializer.Serialize(new { job.Id }),
            CorrelationId = correlationId,
            OccurredAtUtc = DateTime.UtcNow
        }, ct);

        if (saveChanges)
            await _unitOfWork.SaveChangesAsync(ct);
    }

    private async Task PersistProvisioningFailureAsync(
        AgentRegistration agent,
        ProvisioningJob job,
        ProvisioningJobStep? step,
        string errorCode,
        string safeSummary,
        bool requiresManualIntervention,
        string? correlationId,
        CancellationToken ct,
        string? lastFailureCode = null)
    {
        if (step is not null && step.Status != StepStatus.Completed)
        {
            step.Status = StepStatus.Failed;
            step.ErrorCode = errorCode;
            step.ErrorMessage = safeSummary;
            step.CompletedAtUtc = DateTime.UtcNow;
        }

        job.Status = requiresManualIntervention
            ? JobStatus.RequiresManualIntervention
            : JobStatus.Failed;
        job.ErrorCode = errorCode;
        job.ErrorSummary = safeSummary;
        job.CompletedAtUtc = DateTime.UtcNow;
        agent.Status = requiresManualIntervention
            ? AgentStatus.RequiresManualIntervention
            : AgentStatus.Failed;
        agent.LastProvisioningErrorCode = errorCode;
        agent.LastProvisioningErrorSummary = safeSummary;

        await _auditEventRepository.AddAsync(new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "ProvisioningFailed",
            Details = JsonSerializer.Serialize(new
            {
                job.Id,
                ErrorCode = errorCode,
                Step = step?.StepType.ToString(),
                LastFailureCode = lastFailureCode
            }),
            CorrelationId = correlationId,
            OccurredAtUtc = DateTime.UtcNow
        }, ct);

        await _unitOfWork.SaveChangesAsync(ct);
    }

    private async Task<MessageHandlingResult> FailProvisioningAfterRetryExhaustionAsync(
        string payload,
        string lastFailureCode,
        CancellationToken ct)
    {
        ProvisionAgentMessage? message;
        try
        {
            message = JsonSerializer.Deserialize<ProvisionAgentMessage>(payload);
        }
        catch (JsonException)
        {
            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_INVALID_MESSAGE,
                "The provisioning payload could not be finalized after retry exhaustion.");
        }

        if (message is null ||
            message.AgentRegistrationId == Guid.Empty ||
            message.JobId == Guid.Empty ||
            message.ExpectedStepIndex < 0)
        {
            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_INVALID_MESSAGE,
                "The provisioning payload could not be finalized after retry exhaustion.");
        }

        var agent = await _agentRepository.GetByIdAsync(message.AgentRegistrationId, ct);
        var job = await _jobRepository.GetByIdAsync(message.JobId, ct);
        if (agent is null || job is null || job.AgentRegistrationId != agent.Id)
        {
            return MessageHandlingResult.DeadLetter(
                ErrorCodes.PROVISIONING_JOB_MISMATCH,
                "The exhausted provisioning message could not be correlated safely.");
        }

        if (job.Status is not JobStatus.Completed and not JobStatus.Failed and
            not JobStatus.RequiresManualIntervention and
            not JobStatus.AwaitingAdministratorAction)
        {
            var step = job.Steps
                .OrderBy(candidate => candidate.OrderIndex)
                .FirstOrDefault(candidate => candidate.Status != StepStatus.Completed);

            await PersistProvisioningFailureAsync(
                agent,
                job,
                step,
                ErrorCodes.PROVISIONING_RETRIES_EXHAUSTED,
                "Provisioning dependency retries were exhausted.",
                requiresManualIntervention: false,
                message.CorrelationId,
                ct,
                lastFailureCode);
        }

        return MessageHandlingResult.DeadLetter(
            ErrorCodes.PROVISIONING_RETRIES_EXHAUSTED,
            "Provisioning dependency retries were exhausted.");
    }

    private sealed record ProvisioningStateResolution(
        bool Succeeded,
        Agent365ProvisioningState State,
        string? ErrorSummary,
        string? ErrorCode)
    {
        public static ProvisioningStateResolution Success(Agent365ProvisioningState state) =>
            new(true, state, null, null);

        public static ProvisioningStateResolution Failed(
            string errorSummary,
            string errorCode = ErrorCodes.PROVISIONING_STATE_INVALID) =>
            new(false, new Agent365ProvisioningState(), errorSummary, errorCode);
    }

    private async Task<MessageHandlingResult> HandleDeleteAsync(
        string payload,
        CancellationToken ct)
    {
        DeleteAgentMessage? message;
        try
        {
            message = JsonSerializer.Deserialize<DeleteAgentMessage>(payload);
        }
        catch (JsonException)
        {
            return MessageHandlingResult.DeadLetter(
                "DELETE_INVALID_MESSAGE",
                "The deletion payload is not valid JSON.");
        }

        if (message is null ||
            message.AgentRegistrationId == Guid.Empty ||
            message.JobId == Guid.Empty)
        {
            return MessageHandlingResult.DeadLetter(
                "DELETE_INVALID_MESSAGE",
                "The deletion payload is missing required identifiers.");
        }

        var agent = await _agentRepository.GetByIdAsync(message.AgentRegistrationId, ct);
        var job = await _jobRepository.GetByIdAsync(message.JobId, ct);
        if (agent is null || job is null ||
            job.AgentRegistrationId != message.AgentRegistrationId ||
            job.Type != OperationType.DeleteAgent)
        {
            return MessageHandlingResult.DeadLetter(
                "DELETE_JOB_MISMATCH",
                "The deletion job could not be correlated safely.");
        }

        if (job.Status == JobStatus.Completed && agent.Status == AgentStatus.Deleted)
            return MessageHandlingResult.Complete();

        job.Status = JobStatus.Running;
        agent.Status = AgentStatus.Deleting;
        await _unitOfWork.SaveChangesAsync(ct);

        job.Status = JobStatus.Completed;
        job.PercentComplete = 100;
        job.ErrorCode = null;
        job.ErrorSummary = null;
        job.CompletedAtUtc = DateTime.UtcNow;
        agent.Status = AgentStatus.Deleted;
        agent.IsDeleted = true;
        agent.DeletedAtUtc = DateTime.UtcNow;

        await _auditEventRepository.AddAsync(new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "GatewayRegistrationDeletedResourcesPreserved",
            Details = JsonSerializer.Serialize(new { Scope = "GatewayRegistrationOnly" }),
            CorrelationId = message.CorrelationId,
            OccurredAtUtc = DateTime.UtcNow
        }, ct);

        await _unitOfWork.SaveChangesAsync(ct);
        return MessageHandlingResult.Complete();
    }

    private sealed record ExportInteractionMessage(
        Guid AgentId,
        Guid RecordId,
        string? CorrelationId,
        bool? Agent365ObservabilityEnabled = null,
        bool? AzureMonitorExportEnabled = null);

    private sealed record ProcessActivityMessage(
        Guid AgentId,
        Guid ReceiptId,
        string? CorrelationId,
        string? ActorTenantUserObjectId = null,
        bool? Agent365ObservabilityEnabled = null,
        bool? AzureMonitorExportEnabled = null);

    [Flags]
    private enum ObservabilityDestinations
    {
        None = 0,
        Agent365 = 1,
        AzureMonitor = 2
    }
}
