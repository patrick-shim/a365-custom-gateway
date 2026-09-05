using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Services;
using Gateway.Purview;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Provisioning.Worker;

internal sealed class ProtectionAdminMessageHandler
{
    private static readonly JsonSerializerOptions MessageJsonOptions = new(
        JsonSerializerDefaults.Web)
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    private readonly IProtectionAdminOperationRepository _operationRepository;
    private readonly IProtectionCapabilityRepository _capabilityRepository;
    private readonly IPurviewTenantConnectionRepository _connectionRepository;
    private readonly IPurviewSensitiveInformationTypeSnapshotRepository _inventoryRepository;
    private readonly IPurviewKnowYourDataConfigurationRepository _knowYourDataRepository;
    private readonly IPurviewDlpProfileRepository _dlpProfileRepository;
    private readonly IPurviewConnectionVerificationProvider _connectionVerifier;
    private readonly IPurviewSettingsProvider _settingsProvider;
    private readonly IPurviewTokenRoleAttestor _tokenRoleAttestor;
    private readonly IPurviewRuntimeReadinessValidator _runtimeValidator;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IUnitOfWork _unitOfWork;
    private readonly IProtectionAdminOperationLockProvider _lockProvider;
    private readonly ProtectionAdminWorkerOptions _options;
    private readonly PurviewOptions _purviewOptions;
    private readonly IConfiguration _configuration;
    private readonly ILogger<ProtectionAdminMessageHandler> _logger;
    private readonly TimeProvider _timeProvider;

    public ProtectionAdminMessageHandler(
        IProtectionAdminOperationRepository operationRepository,
        IProtectionCapabilityRepository capabilityRepository,
        IPurviewTenantConnectionRepository connectionRepository,
        IPurviewSensitiveInformationTypeSnapshotRepository inventoryRepository,
        IPurviewKnowYourDataConfigurationRepository knowYourDataRepository,
        IPurviewDlpProfileRepository dlpProfileRepository,
        IPurviewConnectionVerificationProvider connectionVerifier,
        IPurviewSettingsProvider settingsProvider,
        IPurviewTokenRoleAttestor tokenRoleAttestor,
        IPurviewRuntimeReadinessValidator runtimeValidator,
        IOutboxRepository outboxRepository,
        IUnitOfWork unitOfWork,
        IProtectionAdminOperationLockProvider lockProvider,
        IOptions<ProtectionAdminWorkerOptions> options,
        IOptions<PurviewOptions> purviewOptions,
        IConfiguration configuration,
        ILogger<ProtectionAdminMessageHandler> logger)
        : this(
            operationRepository,
            capabilityRepository,
            connectionRepository,
            inventoryRepository,
            knowYourDataRepository,
            dlpProfileRepository,
            connectionVerifier,
            settingsProvider,
            tokenRoleAttestor,
            runtimeValidator,
            outboxRepository,
            unitOfWork,
            lockProvider,
            options,
            purviewOptions,
            configuration,
            logger,
            TimeProvider.System)
    {
    }

    internal ProtectionAdminMessageHandler(
        IProtectionAdminOperationRepository operationRepository,
        IProtectionCapabilityRepository capabilityRepository,
        IPurviewTenantConnectionRepository connectionRepository,
        IPurviewSensitiveInformationTypeSnapshotRepository inventoryRepository,
        IPurviewKnowYourDataConfigurationRepository knowYourDataRepository,
        IPurviewDlpProfileRepository dlpProfileRepository,
        IPurviewConnectionVerificationProvider connectionVerifier,
        IPurviewSettingsProvider settingsProvider,
        IPurviewTokenRoleAttestor tokenRoleAttestor,
        IPurviewRuntimeReadinessValidator runtimeValidator,
        IOutboxRepository outboxRepository,
        IUnitOfWork unitOfWork,
        IProtectionAdminOperationLockProvider lockProvider,
        IOptions<ProtectionAdminWorkerOptions> options,
        IOptions<PurviewOptions> purviewOptions,
        IConfiguration configuration,
        ILogger<ProtectionAdminMessageHandler> logger,
        TimeProvider timeProvider)
    {
        _operationRepository = operationRepository;
        _capabilityRepository = capabilityRepository;
        _connectionRepository = connectionRepository;
        _inventoryRepository = inventoryRepository;
        _knowYourDataRepository = knowYourDataRepository;
        _dlpProfileRepository = dlpProfileRepository;
        _connectionVerifier = connectionVerifier;
        _settingsProvider = settingsProvider;
        _tokenRoleAttestor = tokenRoleAttestor;
        _runtimeValidator = runtimeValidator;
        _outboxRepository = outboxRepository;
        _unitOfWork = unitOfWork;
        _lockProvider = lockProvider;
        _options = options.Value;
        _purviewOptions = purviewOptions.Value;
        _configuration = configuration;
        _logger = logger;
        _timeProvider = timeProvider;
    }

    public async Task<MessageHandlingResult> HandleAsync(
        string messageType,
        string payload,
        CancellationToken ct)
    {
        if (!string.Equals(
                messageType,
                nameof(ProtectionAdminOperationMessage),
                StringComparison.Ordinal))
        {
            return MessageHandlingResult.DeadLetter(
                "PROTECTION_ADMIN_MESSAGE_TYPE_INVALID",
                "The message subject is not the exact protection administration v1 contract.");
        }

        if (!TryDeserialize(payload, out var message))
        {
            return MessageHandlingResult.DeadLetter(
                "PROTECTION_ADMIN_MESSAGE_INVALID",
                "The protection administration message is invalid.");
        }

        await using var executionLease =
            await _lockProvider.AcquireExecutionAsync(message!.OperationId, ct);
        var operation = await _operationRepository.GetByIdAsync(message.OperationId, ct);
        if (operation is null)
        {
            return MessageHandlingResult.DeadLetter(
                "PROTECTION_ADMIN_OPERATION_NOT_FOUND",
                "The referenced protection administration operation does not exist.");
        }

        var bindingFailure = ValidateMessageBinding(operation, message);
        if (bindingFailure is not null)
            return MessageHandlingResult.DeadLetter(bindingFailure, SafeFailureSummary);

        if (IsTerminal(operation.Status))
            return MessageHandlingResult.Complete();

        var workflowFailure = ValidateWorkflow(operation);
        if (workflowFailure is not null)
        {
            await MarkFailedAsync(
                operation,
                step: null,
                workflowFailure,
                requiresManualIntervention: true,
                ct);
            return MessageHandlingResult.DeadLetter(workflowFailure, SafeFailureSummary);
        }

        var acceptanceFailure = ValidateAcceptedOperation(operation);
        if (acceptanceFailure is not null)
        {
            await MarkFailedAsync(
                operation,
                step: null,
                acceptanceFailure,
                requiresManualIntervention: true,
                ct);
            return MessageHandlingResult.DeadLetter(
                acceptanceFailure,
                SafeFailureSummary);
        }

        if (!TryParseCanonicalGuid(operation.TargetIdentifier, out var targetLockId))
        {
            await MarkFailedAsync(
                operation,
                step: null,
                "PROTECTION_ADMIN_TARGET_INVALID",
                requiresManualIntervention: true,
                ct);
            return MessageHandlingResult.DeadLetter(
                "PROTECTION_ADMIN_TARGET_INVALID",
                SafeFailureSummary);
        }

        await using var targetLease =
            await _lockProvider.AcquireExecutionAsync(targetLockId, ct);
        var step = operation.OrderedSteps.FirstOrDefault(candidate =>
            candidate.Status is not ProtectionAdminStepStatus.Completed and
                not ProtectionAdminStepStatus.Skipped);
        if (step is null)
        {
            await MarkFailedAsync(
                operation,
                step: null,
                "PROTECTION_ADMIN_WORKFLOW_INCOMPLETE",
                requiresManualIntervention: true,
                ct);
            return MessageHandlingResult.DeadLetter(
                "PROTECTION_ADMIN_WORKFLOW_INCOMPLETE",
                SafeFailureSummary);
        }

        if (message.ExpectedStepIndex < step.OrderIndex)
            return MessageHandlingResult.Complete();
        if (message.ExpectedStepIndex > step.OrderIndex)
        {
            return MessageHandlingResult.DeadLetter(
                "PROTECTION_ADMIN_MESSAGE_OUT_OF_ORDER",
                SafeFailureSummary);
        }

        var now = UtcNow;
        if (step.NextAttemptAtUtc is not null && step.NextAttemptAtUtc > now)
            return MessageHandlingResult.Complete();

        var wasAlreadyRunning = step.Status == ProtectionAdminStepStatus.Running;
        if (!wasAlreadyRunning)
        {
            if (step.AttemptCount >= operation.MaximumAttempts)
            {
                await MarkFailedAsync(
                    operation,
                    step,
                    "PROTECTION_ADMIN_ATTEMPTS_EXHAUSTED",
                    requiresManualIntervention: true,
                    ct);
                return MessageHandlingResult.DeadLetter(
                    "PROTECTION_ADMIN_ATTEMPTS_EXHAUSTED",
                    SafeFailureSummary);
            }

            MarkRunning(operation, step, now);
            await _unitOfWork.SaveChangesAsync(ct);
        }

        ProtectionAdminExecutionContext? context = null;
        try
        {
            context = await LoadExecutionContextAsync(operation, now, ct);
            var skipped = ShouldSkip(operation.Type, step.StepType);
            if (!skipped)
            {
                await ExecuteStepAsync(
                    operation,
                    step,
                    context,
                    wasAlreadyRunning,
                    ct);
            }

            await CompleteStepAsync(operation, step, context, skipped, ct);
            return MessageHandlingResult.Complete();
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (PurviewConnectionVerificationException exception)
            when (exception.IsTransient)
        {
            var failureCode = NormalizeFailureCode(
                exception.FailureCode,
                "PURVIEW_CONNECTION_READ_RETRY");
            if (step.AttemptCount >= operation.MaximumAttempts)
            {
                await MarkFailedAsync(
                    operation,
                    step,
                    "PURVIEW_CONNECTION_READ_RETRIES_EXHAUSTED",
                    requiresManualIntervention: true,
                    ct,
                    context);
                return MessageHandlingResult.DeadLetter(
                    "PURVIEW_CONNECTION_READ_RETRIES_EXHAUSTED",
                    SafeFailureSummary);
            }

            if (context is not null)
            {
                context.Connection.Status =
                    PurviewTenantConnectionStatus.PendingVerification;
                context.Connection.LastFailureCode = failureCode;
                context.Connection.UpdatedAtUtc = UtcNow;
            }
            await MarkPendingRetryAsync(
                operation,
                step,
                failureCode,
                RequiredActionRetry,
                ct);
            return MessageHandlingResult.Complete();
        }
        catch (PurviewConnectionVerificationException exception)
        {
            var failureCode = NormalizeFailureCode(
                exception.FailureCode,
                "PURVIEW_CONNECTION_PROVIDER_UNVERIFIED");
            await MarkFailedAsync(
                operation,
                step,
                failureCode,
                requiresManualIntervention: true,
                ct,
                context);
            return MessageHandlingResult.DeadLetter(
                failureCode,
                SafeFailureSummary);
        }
        catch (ProtectionAdminStepDeferredException)
        {
            return MessageHandlingResult.Complete();
        }
        catch (ProtectionAdminFailureException exception)
        {
            await MarkFailedAsync(
                operation,
                step,
                exception.FailureCode,
                exception.RequiresManualIntervention,
                ct,
                context);
            return MessageHandlingResult.DeadLetter(
                exception.FailureCode,
                SafeFailureSummary);
        }
        catch (PurviewPolicyException exception)
        {
            var failureCode = NormalizeFailureCode(
                exception.FailureCode,
                "PROTECTION_ADMIN_PROVIDER_UNVERIFIED");
            await MarkFailedAsync(
                operation,
                step,
                failureCode,
                requiresManualIntervention: true,
                ct,
                context);
            return MessageHandlingResult.DeadLetter(failureCode, SafeFailureSummary);
        }
        catch (Exception)
        {
            await MarkFailedAsync(
                operation,
                step,
                "PROTECTION_ADMIN_OUTCOME_UNKNOWN",
                requiresManualIntervention: true,
                ct,
                context);
            return MessageHandlingResult.DeadLetter(
                "PROTECTION_ADMIN_OUTCOME_UNKNOWN",
                SafeFailureSummary);
        }
    }

    public async Task<MessageHandlingResult?> HandleRetryExhaustedAsync(
        string messageType,
        string payload,
        string lastFailureCode,
        CancellationToken ct)
    {
        if (!string.Equals(
                messageType,
                nameof(ProtectionAdminOperationMessage),
                StringComparison.Ordinal) ||
            !TryDeserialize(payload, out var message))
        {
            return null;
        }

        await using var executionLease =
            await _lockProvider.AcquireExecutionAsync(message!.OperationId, ct);
        var operation = await _operationRepository.GetByIdAsync(message.OperationId, ct);
        if (operation is null)
            return null;

        var bindingFailure = ValidateMessageBinding(operation, message);
        var workflowFailure = ValidateWorkflow(operation);
        if (bindingFailure is not null ||
            workflowFailure is not null)
        {
            return MessageHandlingResult.DeadLetter(
                bindingFailure ??
                workflowFailure!,
                SafeFailureSummary);
        }

        if (IsTerminal(operation.Status))
            return MessageHandlingResult.Complete();

        var acceptanceFailure = ValidateAcceptedOperation(operation);
        if (acceptanceFailure is not null)
        {
            return MessageHandlingResult.DeadLetter(
                acceptanceFailure,
                SafeFailureSummary);
        }

        var step = operation.OrderedSteps.FirstOrDefault(candidate =>
            candidate.Status is not ProtectionAdminStepStatus.Completed and
                not ProtectionAdminStepStatus.Skipped);
        var failureCode = NormalizeFailureCode(
            lastFailureCode,
            "PROTECTION_ADMIN_RETRIES_EXHAUSTED");
        await MarkFailedAsync(
            operation,
            step,
            failureCode,
            requiresManualIntervention: true,
            ct);
        return MessageHandlingResult.DeadLetter(failureCode, SafeFailureSummary);
    }

    private async Task ExecuteStepAsync(
        ProtectionAdminOperation operation,
        ProtectionAdminOperationStep step,
        ProtectionAdminExecutionContext context,
        bool wasAlreadyRunning,
        CancellationToken ct)
    {
        switch (step.StepType)
        {
            case ProtectionAdminStepType.ValidateReviewedIntent:
                return;
            case ProtectionAdminStepType.DiscoverProviderState:
                await DiscoverProviderStateAsync(operation, step, context, ct);
                return;
            case ProtectionAdminStepType.ApplyReviewedMutation:
                await ApplyReviewedMutationAsync(
                    operation,
                    context,
                    wasAlreadyRunning,
                    ct);
                return;
            case ProtectionAdminStepType.RecordExactReadback:
                await RecordExactReadbackAsync(operation, context, ct);
                return;
            case ProtectionAdminStepType.VerifyPropagation:
                await VerifyPropagationAsync(
                    operation,
                    step,
                    context,
                    wasAlreadyRunning,
                    ct);
                return;
            case ProtectionAdminStepType.AttestTokenRoles:
                await AttestTokenRolesAsync(operation, step, context, ct);
                return;
            case ProtectionAdminStepType.ValidateRuntimeVerdict:
                await ValidateRuntimeVerdictAsync(
                    operation,
                    context,
                    wasAlreadyRunning,
                    ct);
                return;
            case ProtectionAdminStepType.Complete:
                ValidateCompletion(operation, context);
                return;
            default:
                throw Failure("PROTECTION_ADMIN_STEP_UNSUPPORTED");
        }
    }

    private async Task DiscoverProviderStateAsync(
        ProtectionAdminOperation operation,
        ProtectionAdminOperationStep step,
        ProtectionAdminExecutionContext context,
        CancellationToken ct)
    {
        switch (operation.Type)
        {
            case ProtectionAdminOperationType.ConnectPurviewTenant:
                await DiscoverConnectionProviderStateAsync(
                    operation,
                    step,
                    context,
                    ct);
                break;
            case ProtectionAdminOperationType.RefreshSensitiveInformationTypes:
                VerifyConnectionEvidence(context, activate: false);
                break;
            case ProtectionAdminOperationType.CreateOrUpdateKnowYourData:
                try
                {
                    var result = await _settingsProvider.VerifyKnowYourDataAsync(
                        CreateKnowYourDataIntent(operation, context, priorOutcomeUnknown: false),
                        ct);
                    PersistKnowYourDataReadback(context, RequireReadback(result), ready: false);
                }
                catch (PurviewPolicyException exception) when (
                    exception.FailureCode == "PURVIEW_KYD_READBACK_MISSING")
                {
                    context.KnowYourData!.ReadbackStatus = ProtectionReadbackStatus.Pending;
                }
                break;
            case ProtectionAdminOperationType.CreateOrUpdateDlpProfile:
                try
                {
                    var result = await _settingsProvider.VerifyDlpProfileAsync(
                        CreateDlpIntent(
                            operation,
                            context,
                            PurviewDlpMutationRecoveryPoint.None),
                        ct);
                    PersistDlpReadback(context, RequireReadback(result), resetReadiness: false);
                }
                catch (PurviewPolicyException exception) when (
                    exception.FailureCode == "PURVIEW_DLP_READBACK_MISSING")
                {
                    context.DlpProfile!.Readiness = context.DlpProfile.Readiness with
                    {
                        Readback = ProtectionReadbackStatus.Pending
                    };
                }
                break;
            case ProtectionAdminOperationType.ReconcileDlpProfile:
            case ProtectionAdminOperationType.ValidateDlpRuntime:
                {
                    var result = await _settingsProvider.VerifyDlpProfileAsync(
                        CreateDlpIntent(
                            operation,
                            context,
                            PurviewDlpMutationRecoveryPoint.None),
                        ct);
                    PersistDlpReadback(context, RequireReadback(result), resetReadiness: false);
                    break;
                }
            default:
                throw Failure("PROTECTION_ADMIN_OPERATION_UNSUPPORTED");
        }
    }

    private async Task ApplyReviewedMutationAsync(
        ProtectionAdminOperation operation,
        ProtectionAdminExecutionContext context,
        bool priorOutcomeUnknown,
        CancellationToken ct)
    {
        switch (operation.Type)
        {
            case ProtectionAdminOperationType.CreateOrUpdateKnowYourData:
                {
                    var result = await _settingsProvider.EnsureKnowYourDataAsync(
                        CreateKnowYourDataIntent(operation, context, priorOutcomeUnknown),
                        ct);
                    EnsureProviderDisposition(result.Disposition, result.FailureCode);
                    PersistKnowYourDataReadback(context, RequireReadback(result), ready: false);
                    break;
                }
            case ProtectionAdminOperationType.CreateOrUpdateDlpProfile:
                {
                    var recoveryPoint = priorOutcomeUnknown
                        ? PurviewDlpMutationRecoveryPoint.RuleCreationOutcomeUnknown
                        : PurviewDlpMutationRecoveryPoint.None;
                    var result = await _settingsProvider.EnsureDlpProfileAsync(
                        CreateDlpIntent(operation, context, recoveryPoint),
                        ct);
                    EnsureProviderDisposition(result.Disposition, result.FailureCode);
                    PersistDlpReadback(context, RequireReadback(result), resetReadiness: true);
                    break;
                }
            default:
                throw Failure("PROTECTION_ADMIN_MUTATION_UNSUPPORTED");
        }
    }

    private async Task RecordExactReadbackAsync(
        ProtectionAdminOperation operation,
        ProtectionAdminExecutionContext context,
        CancellationToken ct)
    {
        switch (operation.Type)
        {
            case ProtectionAdminOperationType.ConnectPurviewTenant:
                await RecordConnectionProviderReadbackAsync(
                    operation,
                    context,
                    ct);
                break;
            case ProtectionAdminOperationType.RefreshSensitiveInformationTypes:
                VerifyConnectionEvidence(context, activate: true);
                operation.ReadbackReferenceId = context.Inventory!.Id.Value;
                break;
            case ProtectionAdminOperationType.CreateOrUpdateKnowYourData:
                {
                    var result = await _settingsProvider.VerifyKnowYourDataAsync(
                        CreateKnowYourDataIntent(operation, context, priorOutcomeUnknown: false),
                        ct);
                    PersistKnowYourDataReadback(context, RequireReadback(result), ready: true);
                    operation.ReadbackReferenceId = context.KnowYourData!.Id;
                    break;
                }
            case ProtectionAdminOperationType.CreateOrUpdateDlpProfile:
            case ProtectionAdminOperationType.ValidateDlpRuntime:
                {
                    var result = await _settingsProvider.VerifyDlpProfileAsync(
                        CreateDlpIntent(
                            operation,
                            context,
                            PurviewDlpMutationRecoveryPoint.None),
                        ct);
                    PersistDlpReadback(context, RequireReadback(result), resetReadiness: false);
                    operation.ReadbackReferenceId = context.DlpProfile!.Id.Value;
                    break;
                }
            case ProtectionAdminOperationType.ReconcileDlpProfile:
                {
                    var result = await _settingsProvider.ReconcileDlpProfileAsync(
                        CreateDlpIntent(
                            operation,
                            context,
                            PurviewDlpMutationRecoveryPoint.None),
                        ct);
                    PersistDlpReadback(context, RequireReadback(result), resetReadiness: false);
                    operation.ReadbackReferenceId = context.DlpProfile!.Id.Value;
                    break;
                }
            default:
                throw Failure("PROTECTION_ADMIN_OPERATION_UNSUPPORTED");
        }
    }

    private async Task DiscoverConnectionProviderStateAsync(
        ProtectionAdminOperation operation,
        ProtectionAdminOperationStep step,
        ProtectionAdminExecutionContext context,
        CancellationToken ct)
    {
        var evidence = await ReadConnectionProviderEvidenceAsync(
            operation,
            context,
            ct);
        var generation = await EnsureConnectionGenerationAsync(
            operation,
            context.Connection,
            evidence,
            ct);
        context.Inventory = generation;
        operation.ReadbackReferenceId = evidence.InventoryGenerationId;
        step.ReadbackReferenceId = evidence.InventoryGenerationId;
        context.Connection.Status = PurviewTenantConnectionStatus.PendingVerification;
        context.Connection.LastFailureCode = null;
        context.Connection.UpdatedAtUtc = UtcNow;
    }

    private async Task RecordConnectionProviderReadbackAsync(
        ProtectionAdminOperation operation,
        ProtectionAdminExecutionContext context,
        CancellationToken ct)
    {
        var evidence = await ReadConnectionProviderEvidenceAsync(
            operation,
            context,
            ct);
        if (operation.ReadbackReferenceId != evidence.InventoryGenerationId)
        {
            throw new PurviewConnectionVerificationException(
                "PURVIEW_CONNECTION_GENERATION_CHANGED");
        }

        var generation = await EnsureConnectionGenerationAsync(
            operation,
            context.Connection,
            evidence,
            ct);
        if (context.Inventory is null ||
            context.Inventory.Id != generation.Id)
        {
            throw new PurviewConnectionVerificationException(
                "PURVIEW_CONNECTION_STAGED_INVENTORY_MISMATCH");
        }

        context.Inventory = generation;
        context.Connection.AuthorityApplicationId =
            new ApplicationClientId(evidence.AuthorityApplicationId);
        context.Connection.AuthorityServicePrincipalObjectId =
            new ServicePrincipalObjectId(
                evidence.AuthorityServicePrincipalObjectId);
        context.Connection.AuthorityKind = "CertificateApplicationVerified";
        context.Connection.ActiveInventoryGenerationId = generation.Id;
        context.Connection.AuthorizedAtUtc = evidence.ObservedAtUtc.UtcDateTime;
        context.Connection.LastVerifiedAtUtc = evidence.ObservedAtUtc.UtcDateTime;
        context.Connection.ExpiresAtUtc = evidence.ExpiresAtUtc.UtcDateTime;
        context.Connection.LastFailureCode = null;
        context.Connection.Status = PurviewTenantConnectionStatus.PendingVerification;
        context.Connection.UpdatedAtUtc = UtcNow;
        operation.ReadbackReferenceId = generation.Id.Value;
    }

    private async Task<PurviewConnectionVerificationEvidence>
        ReadConnectionProviderEvidenceAsync(
            ProtectionAdminOperation operation,
            ProtectionAdminExecutionContext context,
            CancellationToken ct)
    {
        var connection = context.Connection;
        if (connection.Status !=
                PurviewTenantConnectionStatus.PendingVerification ||
            !string.Equals(
                connection.AuthorityKind,
                "InteractiveSubmissionUnverified",
                StringComparison.Ordinal) ||
            !string.Equals(
                connection.CreatedByObjectId,
                operation.ActorObjectId,
                StringComparison.Ordinal))
        {
            throw new PurviewConnectionVerificationException(
                "PURVIEW_CONNECTION_SUBMISSION_MISMATCH");
        }
        var administratorObjectId = ParseCanonicalGuid(
            operation.ActorObjectId,
            "PURVIEW_CONNECTION_ADMINISTRATOR_INVALID");
        var binding = RequireExactPurviewCapabilityBinding(context.Capability);
        var evidence = await _connectionVerifier.VerifyAsync(
            new PurviewConnectionVerificationRequest(
                operation.Id,
                operation.TenantId.Value,
                administratorObjectId,
                binding.ApplicationId.Value,
                binding.ServicePrincipalObjectId.Value,
                binding.KeyVaultResourceId,
                binding.KeyVaultHost,
                binding.CertificateName,
                binding.CertificateSecretUri),
            ct);
        if (evidence.OperationId != operation.Id)
        {
            throw new PurviewConnectionVerificationException(
                "PURVIEW_CONNECTION_OPERATION_MISMATCH");
        }
        if (evidence.TenantId != operation.TenantId.Value)
        {
            throw new PurviewConnectionVerificationException(
                "PURVIEW_CONNECTION_TENANT_MISMATCH");
        }
        if (evidence.AdministratorObjectId != administratorObjectId ||
            !string.Equals(
                connection.CreatedByObjectId,
                operation.ActorObjectId,
                StringComparison.Ordinal))
        {
            throw new PurviewConnectionVerificationException(
                "PURVIEW_CONNECTION_ADMINISTRATOR_MISMATCH");
        }
        if (evidence.AuthorityApplicationId != binding.ApplicationId.Value ||
            evidence.AuthorityServicePrincipalObjectId !=
                binding.ServicePrincipalObjectId.Value ||
            !string.Equals(
                evidence.KeyVaultResourceId,
                binding.KeyVaultResourceId,
                StringComparison.Ordinal) ||
            !string.Equals(
                evidence.KeyVaultHost,
                binding.KeyVaultHost,
                StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(
                evidence.CertificateName,
                binding.CertificateName,
                StringComparison.Ordinal) ||
            !string.Equals(
                evidence.CertificateSecretUri.AbsoluteUri,
                binding.CertificateSecretUri.AbsoluteUri,
                StringComparison.Ordinal) ||
            !IsExactProviderCertificateReadback(
                evidence.ProviderCertificateSecretId,
                binding))
        {
            throw new PurviewConnectionVerificationException(
                "PURVIEW_CONNECTION_CAPABILITY_BINDING_MISMATCH");
        }
        if (!evidence.HasValidDigestAndGeneration())
        {
            throw new PurviewConnectionVerificationException(
                "PURVIEW_CONNECTION_EVIDENCE_DIGEST_MISMATCH");
        }

        RequireCurrentUtcEvidence(
            evidence.ObservedAtUtc,
            "PURVIEW_CONNECTION_EVIDENCE_STALE");
        var now = new DateTimeOffset(UtcNow, TimeSpan.Zero);
        if (evidence.ExpiresAtUtc.Offset != TimeSpan.Zero ||
            evidence.ExpiresAtUtc <= now ||
            evidence.ExpiresAtUtc > evidence.ObservedAtUtc.AddMinutes(15))
        {
            throw new PurviewConnectionVerificationException(
                "PURVIEW_CONNECTION_EVIDENCE_STALE");
        }

        return evidence;
    }

    private static bool IsExactProviderCertificateReadback(
        Uri providerSecretId,
        PurviewAutomationCapabilityBinding binding)
    {
        if (providerSecretId is null ||
            !providerSecretId.IsAbsoluteUri ||
            !string.Equals(
                providerSecretId.Scheme,
                Uri.UriSchemeHttps,
                StringComparison.OrdinalIgnoreCase) ||
            !providerSecretId.IsDefaultPort ||
            !string.Equals(
                providerSecretId.Host,
                binding.KeyVaultHost,
                StringComparison.OrdinalIgnoreCase) ||
            !string.IsNullOrEmpty(providerSecretId.UserInfo) ||
            !string.IsNullOrEmpty(providerSecretId.Query) ||
            !string.IsNullOrEmpty(providerSecretId.Fragment))
        {
            return false;
        }

        var segments = providerSecretId.AbsolutePath.Split(
            '/',
            StringSplitOptions.RemoveEmptyEntries);
        return segments is ["secrets", var certificateName, var version] &&
            string.Equals(
                certificateName,
                binding.CertificateName,
                StringComparison.Ordinal) &&
            IsBoundedResourceName(version, 128);
    }

    private static bool IsBoundedResourceName(string value, int maximumLength) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length <= maximumLength &&
        value.All(character =>
            char.IsAsciiLetterOrDigit(character) || character == '-');

    private async Task<PurviewSensitiveInformationTypeSnapshotGeneration>
        EnsureConnectionGenerationAsync(
            ProtectionAdminOperation operation,
            PurviewTenantConnection connection,
            PurviewConnectionVerificationEvidence evidence,
            CancellationToken ct)
    {
        var generationId = new SensitiveInformationTypeSnapshotGenerationId(
            evidence.InventoryGenerationId);
        var existing = await _inventoryRepository.GetGenerationAsync(
            generationId,
            ct);
        if (existing is not null)
        {
            ValidateConnectionGeneration(
                existing,
                operation,
                connection,
                evidence);
            return existing;
        }

        var generation = new PurviewSensitiveInformationTypeSnapshotGeneration
        {
            Id = generationId,
            PurviewTenantConnectionId = connection.Id,
            TenantId = operation.TenantId,
            RetrievedAtUtc = evidence.ObservedAtUtc.UtcDateTime,
            ExpiresAtUtc = evidence.ExpiresAtUtc.UtcDateTime,
            ItemCount = evidence.Items.Count,
            CreatedAtUtc = UtcNow
        };
        foreach (var item in evidence.Items)
        {
            generation.Items.Add(new PurviewSensitiveInformationTypeSnapshot
            {
                Id = CreateSnapshotId(evidence.InventoryGenerationId, item.Id),
                GenerationId = generationId,
                SensitiveInformationTypeId = new SensitiveInformationTypeId(item.Id),
                ExactName = item.ExactName,
                Publisher = item.Publisher,
                SortOrder = item.SortOrder
            });
        }

        await _inventoryRepository.AddGenerationAsync(generation, ct);
        return generation;
    }

    private static void ValidateConnectionGeneration(
        PurviewSensitiveInformationTypeSnapshotGeneration generation,
        ProtectionAdminOperation operation,
        PurviewTenantConnection connection,
        PurviewConnectionVerificationEvidence evidence)
    {
        if (generation.PurviewTenantConnectionId != connection.Id ||
            generation.TenantId != operation.TenantId ||
            generation.ItemCount != evidence.Items.Count)
        {
            throw new PurviewConnectionVerificationException(
                "PURVIEW_CONNECTION_STAGED_INVENTORY_MISMATCH");
        }

        var stored = generation.Items.OrderBy(item => item.SortOrder).ToArray();
        if (stored.Length != evidence.Items.Count)
        {
            throw new PurviewConnectionVerificationException(
                "PURVIEW_CONNECTION_STAGED_INVENTORY_MISMATCH");
        }
        for (var index = 0; index < stored.Length; index++)
        {
            if (stored[index].GenerationId != generation.Id ||
                stored[index].SensitiveInformationTypeId.Value !=
                    evidence.Items[index].Id ||
                !string.Equals(
                    stored[index].ExactName,
                    evidence.Items[index].ExactName,
                    StringComparison.Ordinal) ||
                !string.Equals(
                    stored[index].Publisher,
                    evidence.Items[index].Publisher,
                    StringComparison.Ordinal) ||
                stored[index].SortOrder != evidence.Items[index].SortOrder)
            {
                throw new PurviewConnectionVerificationException(
                    "PURVIEW_CONNECTION_STAGED_INVENTORY_MISMATCH");
            }
        }
    }

    private static Guid CreateSnapshotId(Guid generationId, Guid informationTypeId)
    {
        Span<byte> input = stackalloc byte[32];
        generationId.TryWriteBytes(input[..16]);
        informationTypeId.TryWriteBytes(input[16..]);
        var digest = SHA256.HashData(input);
        try
        {
            return new Guid(digest.AsSpan(0, 16));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(digest);
        }
    }

    private async Task VerifyPropagationAsync(
        ProtectionAdminOperation operation,
        ProtectionAdminOperationStep step,
        ProtectionAdminExecutionContext context,
        bool wasAlreadyRunning,
        CancellationToken ct)
    {
        if (wasAlreadyRunning)
            throw Failure("PURVIEW_PROPAGATION_OUTCOME_UNKNOWN");

        var result = await _runtimeValidator.ProbePropagationAsync(
            operation.Id,
            operation.ActorObjectId,
            context.DlpProfile!,
            ct);
        switch (result.Status)
        {
            case PurviewRuntimeValidationStatus.Ready:
                RequireCurrentUtcEvidence(
                    result.ObservedAtUtc,
                    "PURVIEW_PROPAGATION_EVIDENCE_INVALID");
                context.DlpProfile!.PropagationVerifiedAtUtc =
                    result.ObservedAtUtc.UtcDateTime;
                context.DlpProfile.Readiness = context.DlpProfile.Readiness with
                {
                    Propagation = ProtectionPropagationStatus.Ready
                };
                context.DlpProfile.Status = PurviewDlpProfileStatus.PendingPropagation;
                context.DlpProfile.LastFailureCode = null;
                context.DlpProfile.UpdatedAtUtc = UtcNow;
                return;
            case PurviewRuntimeValidationStatus.Pending:
                if (step.AttemptCount >= Math.Min(
                        operation.MaximumAttempts,
                        _options.MaximumPropagationAttempts))
                {
                    throw Failure(
                        "PURVIEW_PROPAGATION_TIMEOUT",
                        requiresManualIntervention: true);
                }

                context.DlpProfile!.Readiness = context.DlpProfile.Readiness with
                {
                    Propagation = ProtectionPropagationStatus.Pending
                };
                context.DlpProfile.Status = PurviewDlpProfileStatus.PendingPropagation;
                context.DlpProfile.LastFailureCode = NormalizeFailureCode(
                    result.FailureCode,
                    "PURVIEW_PROPAGATION_PENDING");
                context.DlpProfile.UpdatedAtUtc = UtcNow;
                await MarkPendingRetryAsync(
                    operation,
                    step,
                    NormalizeFailureCode(
                        result.FailureCode,
                        "PURVIEW_PROPAGATION_PENDING"),
                    RequiredActionWaitForPropagation,
                    ct);
                throw new ProtectionAdminStepDeferredException();
            case PurviewRuntimeValidationStatus.Unsupported:
                throw Failure(
                    NormalizeFailureCode(
                        result.FailureCode,
                        "PURVIEW_PROPAGATION_UNSUPPORTED"));
            case PurviewRuntimeValidationStatus.Failed:
            case PurviewRuntimeValidationStatus.OutcomeUnknown:
                throw Failure(
                    NormalizeFailureCode(
                        result.FailureCode,
                        "PURVIEW_PROPAGATION_UNVERIFIED"));
            default:
                throw Failure("PURVIEW_PROPAGATION_UNVERIFIED");
        }
    }

    private async Task AttestTokenRolesAsync(
        ProtectionAdminOperation operation,
        ProtectionAdminOperationStep step,
        ProtectionAdminExecutionContext context,
        CancellationToken ct)
    {
        var attestation = await _tokenRoleAttestor.AttestAsync(
            operation.TenantId.Value,
            ct);
        switch (attestation.Status)
        {
            case ProtectionTokenRoleStatus.Ready:
                RequireCurrentUtcEvidence(
                    attestation.ObservedAtUtc,
                    "PURVIEW_TOKEN_ROLE_EVIDENCE_INVALID");
                context.DlpProfile!.TokenRolesVerifiedAtUtc =
                    attestation.ObservedAtUtc.UtcDateTime;
                context.DlpProfile.Readiness = context.DlpProfile.Readiness with
                {
                    TokenRoles = ProtectionTokenRoleStatus.Ready
                };
                context.DlpProfile.Status = PurviewDlpProfileStatus.PendingPropagation;
                context.DlpProfile.LastFailureCode = null;
                context.DlpProfile.UpdatedAtUtc = UtcNow;
                return;
            case ProtectionTokenRoleStatus.PendingRefresh:
            case ProtectionTokenRoleStatus.MissingRequiredRoles:
                context.DlpProfile!.Readiness = context.DlpProfile.Readiness with
                {
                    TokenRoles = attestation.Status
                };
                context.DlpProfile.Status = PurviewDlpProfileStatus.PendingPropagation;
                context.DlpProfile.LastFailureCode = NormalizeFailureCode(
                    attestation.FailureCode,
                    "PURVIEW_TOKEN_ROLES_PENDING");
                context.DlpProfile.UpdatedAtUtc = UtcNow;
                await MarkPendingRetryAsync(
                    operation,
                    step,
                    NormalizeFailureCode(
                        attestation.FailureCode,
                        "PURVIEW_TOKEN_ROLES_PENDING"),
                    RequiredActionWaitForPropagation,
                    ct);
                throw new ProtectionAdminStepDeferredException();
            case ProtectionTokenRoleStatus.Failed:
                throw Failure(
                    NormalizeFailureCode(
                        attestation.FailureCode,
                        "PURVIEW_TOKEN_ROLE_ATTESTATION_FAILED"));
            default:
                throw Failure("PURVIEW_TOKEN_ROLE_ATTESTATION_FAILED");
        }
    }

    private async Task ValidateRuntimeVerdictAsync(
        ProtectionAdminOperation operation,
        ProtectionAdminExecutionContext context,
        bool wasAlreadyRunning,
        CancellationToken ct)
    {
        var profile = context.DlpProfile!;
        if (profile.Mode != PurviewMode.Enforce)
            throw Failure("PURVIEW_RUNTIME_ENFORCEMENT_REQUIRED");
        if (profile.Readiness.Readback != ProtectionReadbackStatus.Ready ||
            profile.Readiness.Propagation != ProtectionPropagationStatus.Ready ||
            profile.Readiness.TokenRoles != ProtectionTokenRoleStatus.Ready)
        {
            throw Failure("PURVIEW_RUNTIME_PREREQUISITES_NOT_READY");
        }

        if (wasAlreadyRunning &&
            (profile.RuntimeAllowVerifiedAtUtc is null ||
             profile.RuntimeBlockVerifiedAtUtc is null))
        {
            throw Failure("PURVIEW_RUNTIME_OUTCOME_UNKNOWN");
        }

        if (profile.RuntimeAllowVerifiedAtUtc is null)
        {
            var allow = await _runtimeValidator.ValidateAllowAsync(
                operation.Id,
                operation.ActorObjectId,
                profile,
                ct);
            EnsureRuntimeReady(allow, "PURVIEW_RUNTIME_ALLOW_NOT_OBSERVED");
            profile.RuntimeAllowVerifiedAtUtc = allow.ObservedAtUtc.UtcDateTime;
            profile.Readiness = profile.Readiness with
            {
                RuntimeVerdict = ProtectionRuntimeVerdictStatus.Pending
            };
            profile.UpdatedAtUtc = UtcNow;
            await _unitOfWork.SaveChangesAsync(ct);
        }

        if (profile.RuntimeBlockVerifiedAtUtc is null)
        {
            var block = await _runtimeValidator.ValidateBlockAsync(
                operation.Id,
                operation.ActorObjectId,
                profile,
                ct);
            EnsureRuntimeReady(block, "PURVIEW_RUNTIME_BLOCK_NOT_OBSERVED");
            profile.RuntimeBlockVerifiedAtUtc = block.ObservedAtUtc.UtcDateTime;
        }

        UpdateDlpReadiness(context, ProtectionRuntimeVerdictStatus.Ready);
        if (!profile.Readiness.IsReady)
            throw Failure("PURVIEW_RUNTIME_READINESS_INCOMPLETE");
    }

    private async Task<ProtectionAdminExecutionContext> LoadExecutionContextAsync(
        ProtectionAdminOperation operation,
        DateTime utcNow,
        CancellationToken ct)
    {
        ValidateReviewedOperation(operation);
        var capability = await _capabilityRepository.GetByKindAsync(
            ProtectionCapabilityKind.Purview,
            ct);
        if (capability is null ||
            capability.Status != ProtectionCapabilityStatus.Installed ||
            capability.LastReadbackAtUtc is null)
        {
            throw Failure("PURVIEW_CAPABILITY_NOT_READY");
        }

        var targetId = ParseCanonicalGuid(
            operation.TargetIdentifier,
            "PROTECTION_ADMIN_TARGET_INVALID");
        PurviewTenantConnection? connection;
        PurviewKnowYourDataConfiguration? knowYourData = null;
        PurviewDlpProfile? profile = null;
        switch (operation.Type)
        {
            case ProtectionAdminOperationType.ConnectPurviewTenant:
            case ProtectionAdminOperationType.RefreshSensitiveInformationTypes:
                connection = await _connectionRepository.GetByIdAsync(targetId, ct);
                break;
            case ProtectionAdminOperationType.CreateOrUpdateKnowYourData:
                knowYourData = await _knowYourDataRepository.GetByTenantIdAsync(
                    operation.TenantId,
                    ct);
                if (knowYourData is null || knowYourData.Id != targetId)
                    throw Failure("PURVIEW_KYD_TARGET_MISMATCH");
                connection = await _connectionRepository.GetByIdAsync(
                    knowYourData.PurviewTenantConnectionId,
                    ct);
                break;
            case ProtectionAdminOperationType.CreateOrUpdateDlpProfile:
            case ProtectionAdminOperationType.ReconcileDlpProfile:
            case ProtectionAdminOperationType.ValidateDlpRuntime:
                profile = await _dlpProfileRepository.GetByIdAsync(
                    new PurviewDlpProfileId(targetId),
                    ct);
                if (profile is null)
                    throw Failure("PURVIEW_DLP_TARGET_NOT_FOUND");
                connection = await _connectionRepository.GetByIdAsync(
                    profile.PurviewTenantConnectionId,
                    ct);
                break;
            default:
                throw Failure("PROTECTION_ADMIN_OPERATION_UNSUPPORTED");
        }

        if (connection is null || connection.TenantId != operation.TenantId)
            throw Failure("PURVIEW_CONNECTION_TARGET_MISMATCH");
        var capabilityBinding = RequireExactPurviewCapabilityBinding(capability);
        if (operation.Type != ProtectionAdminOperationType.ConnectPurviewTenant)
            EnsureConnectionAuthorityBinding(connection, capabilityBinding);
        if (operation.Type == ProtectionAdminOperationType.ConnectPurviewTenant)
        {
            var stagedInventoryId = connection.ActiveInventoryGenerationId ??
                (operation.ReadbackReferenceId is { } readbackReference
                    ? new SensitiveInformationTypeSnapshotGenerationId(
                        readbackReference)
                    : null);
            PurviewSensitiveInformationTypeSnapshotGeneration? stagedInventory = null;
            if (stagedInventoryId is not null)
            {
                stagedInventory = await _inventoryRepository.GetGenerationAsync(
                    stagedInventoryId.Value,
                    ct);
                if (stagedInventory is null ||
                    stagedInventory.PurviewTenantConnectionId != connection.Id ||
                    stagedInventory.TenantId != operation.TenantId ||
                    stagedInventory.IsExpired(utcNow))
                {
                    throw Failure("PURVIEW_CONNECTION_STAGED_INVENTORY_INVALID");
                }
                ValidateInventory(stagedInventory);
            }

            VerifyReviewedPayloadHash(operation, knowYourData, profile);
            return new(
                capability,
                connection,
                stagedInventory,
                null,
                knowYourData,
                profile);
        }

        if (connection.ActiveInventoryGenerationId is null)
            throw Failure("PURVIEW_INVENTORY_NOT_AVAILABLE");
        if (operation.Type is not ProtectionAdminOperationType.ConnectPurviewTenant and
                not ProtectionAdminOperationType.RefreshSensitiveInformationTypes &&
            !connection.IsUsableAt(utcNow))
        {
            throw Failure("PURVIEW_CONNECTION_NOT_USABLE");
        }

        var inventoryId = connection.ActiveInventoryGenerationId.Value;
        if (knowYourData is not null && knowYourData.InventoryGenerationId != inventoryId)
            throw Failure("PURVIEW_KYD_INVENTORY_MISMATCH");
        if (profile is not null && profile.InventoryGenerationId != inventoryId)
            throw Failure("PURVIEW_DLP_INVENTORY_MISMATCH");

        var inventory = await _inventoryRepository.GetGenerationAsync(inventoryId, ct);
        if (inventory is null ||
            inventory.PurviewTenantConnectionId != connection.Id ||
            inventory.TenantId != operation.TenantId ||
            inventory.IsExpired(utcNow))
        {
            throw Failure("PURVIEW_INVENTORY_STALE");
        }
        ValidateInventory(inventory);

        PurviewSensitiveInformationTypeSnapshot? selected = null;
        if (knowYourData is not null)
        {
            selected = RequireSelectedInformationType(
                inventory,
                knowYourData.SensitiveInformationTypeId,
                knowYourData.SensitiveInformationTypeName);
        }
        else if (profile is not null)
        {
            if (profile.SensitiveInformationTypeSnapshotExpiresAtUtc != inventory.ExpiresAtUtc)
                throw Failure("PURVIEW_DLP_INVENTORY_MISMATCH");
            selected = RequireSelectedInformationType(
                inventory,
                profile.SensitiveInformationTypeId,
                profile.SensitiveInformationTypeName);
        }

        VerifyReviewedPayloadHash(operation, knowYourData, profile);
        return new(
            capability,
            connection,
            inventory,
            selected,
            knowYourData,
            profile);
    }

    private static void VerifyReviewedPayloadHash(
        ProtectionAdminOperation operation,
        PurviewKnowYourDataConfiguration? knowYourData,
        PurviewDlpProfile? profile)
    {
        var actual = operation.Type switch
        {
            ProtectionAdminOperationType.ConnectPurviewTenant or
            ProtectionAdminOperationType.RefreshSensitiveInformationTypes =>
                ProtectionAdminIntentFingerprint.ForConnection(
                    operation.TenantId.Value),
            ProtectionAdminOperationType.CreateOrUpdateKnowYourData =>
                ProtectionAdminIntentFingerprint.ForKnowYourData(
                    knowYourData!),
            ProtectionAdminOperationType.CreateOrUpdateDlpProfile or
            ProtectionAdminOperationType.ReconcileDlpProfile or
            ProtectionAdminOperationType.ValidateDlpRuntime =>
                ProtectionAdminIntentFingerprint.ForDlpProfile(profile!),
            _ => throw Failure("PROTECTION_ADMIN_OPERATION_UNSUPPORTED")
        };
        if (!string.Equals(
                actual,
                operation.ReviewedPayloadHash,
                StringComparison.Ordinal))
        {
            throw Failure("PROTECTION_ADMIN_REVIEWED_INTENT_CHANGED");
        }
    }

    private async Task CompleteStepAsync(
        ProtectionAdminOperation operation,
        ProtectionAdminOperationStep step,
        ProtectionAdminExecutionContext context,
        bool skipped,
        CancellationToken ct)
    {
        var now = UtcNow;
        step.Status = skipped
            ? ProtectionAdminStepStatus.Skipped
            : ProtectionAdminStepStatus.Completed;
        step.CompletedAtUtc = now;
        step.NextAttemptAtUtc = null;
        step.FailureCode = null;
        step.RetryDisposition = ProtectionRetryDisposition.NotApplicable;
        if (step.StepType is ProtectionAdminStepType.DiscoverProviderState or
            ProtectionAdminStepType.RecordExactReadback)
        {
            step.ReadbackReferenceId = operation.ReadbackReferenceId;
        }

        if (step.StepType == ProtectionAdminStepType.Complete)
        {
            operation.Status = ProtectionAdminOperationStatus.Completed;
            operation.CompletedAtUtc = now;
            operation.NextAttemptAtUtc = null;
            operation.LastFailureCode = null;
            operation.RequiredAction = ResolveCompletionRequiredAction(
                operation,
                context);
            operation.RetryDisposition = ProtectionRetryDisposition.NotApplicable;
        }
        else
        {
            var nextStep = operation.OrderedSteps.Single(candidate =>
                candidate.OrderIndex == step.OrderIndex + 1);
            await _outboxRepository.AddAsync(new OutboxMessage
            {
                Id = Guid.NewGuid(),
                MessageType = nameof(ProtectionAdminOperationMessage),
                Payload = JsonSerializer.Serialize(
                    new ProtectionAdminOperationMessage(
                        operation.Id,
                        ProtectionAdminQueueContract.WorkflowVersion,
                        nextStep.OrderIndex,
                        operation.CorrelationId),
                    MessageJsonOptions),
                Status = OutboxMessageStatus.Pending,
                CreatedAtUtc = now
            }, ct);
            operation.Status = ProtectionAdminOperationStatus.Pending;
        }

        operation.UpdatedAtUtc = now;
        context.Connection.UpdatedAtUtc = now;
        await _unitOfWork.SaveChangesAsync(ct);
        _logger.LogInformation(
            "Protection administration operation {OperationId} completed step {Step}",
            operation.Id,
            step.StepType);
    }

    private async Task MarkPendingRetryAsync(
        ProtectionAdminOperation operation,
        ProtectionAdminOperationStep step,
        string failureCode,
        string requiredAction,
        CancellationToken ct)
    {
        var now = UtcNow;
        var nextAttempt = now.AddSeconds(_options.PropagationRetryDelaySeconds);
        step.Status = ProtectionAdminStepStatus.PendingPropagation;
        step.FailureCode = failureCode;
        step.RetryDisposition = ProtectionRetryDisposition.Retryable;
        step.NextAttemptAtUtc = nextAttempt;
        operation.Status = ProtectionAdminOperationStatus.PendingPropagation;
        operation.LastFailureCode = failureCode;
        operation.RequiredAction = requiredAction;
        operation.RetryDisposition = ProtectionRetryDisposition.Retryable;
        operation.NextAttemptAtUtc = nextAttempt;
        operation.UpdatedAtUtc = now;
        await _outboxRepository.AddAsync(new OutboxMessage
        {
            Id = Guid.NewGuid(),
            MessageType = nameof(ProtectionAdminOperationMessage),
            Payload = JsonSerializer.Serialize(
                new ProtectionAdminOperationMessage(
                    operation.Id,
                    ProtectionAdminQueueContract.WorkflowVersion,
                    step.OrderIndex,
                    operation.CorrelationId),
                MessageJsonOptions),
            Status = OutboxMessageStatus.Pending,
            CreatedAtUtc = now,
            NextRetryAtUtc = nextAttempt
        }, ct);
        await _unitOfWork.SaveChangesAsync(ct);
    }

    private async Task MarkFailedAsync(
        ProtectionAdminOperation operation,
        ProtectionAdminOperationStep? step,
        string failureCode,
        bool requiresManualIntervention,
        CancellationToken ct,
        ProtectionAdminExecutionContext? context = null)
    {
        var safeCode = NormalizeFailureCode(
            failureCode,
            "PROTECTION_ADMIN_UNVERIFIED");
        var now = UtcNow;
        operation.Status = requiresManualIntervention
            ? ProtectionAdminOperationStatus.RequiresManualIntervention
            : ProtectionAdminOperationStatus.Failed;
        operation.RetryDisposition = requiresManualIntervention
            ? ProtectionRetryDisposition.RequiresManualIntervention
            : ProtectionRetryDisposition.Exhausted;
        operation.LastFailureCode = safeCode;
        operation.RequiredAction = operation.Type ==
            ProtectionAdminOperationType.ConnectPurviewTenant
                ? RequiredActionRetry
                : requiresManualIntervention
                    ? RequiredActionReconcile
                    : RequiredActionRetry;
        operation.NextAttemptAtUtc = null;
        operation.UpdatedAtUtc = now;
        if (step is not null)
        {
            step.Status = requiresManualIntervention
                ? ProtectionAdminStepStatus.RequiresManualIntervention
                : ProtectionAdminStepStatus.Failed;
            step.RetryDisposition = operation.RetryDisposition;
            step.FailureCode = safeCode;
            step.NextAttemptAtUtc = null;
        }

        if (context?.DlpProfile is not null)
        {
            context.DlpProfile.Status = PurviewDlpProfileStatus.VerificationFailed;
            context.DlpProfile.LastFailureCode = safeCode;
            context.DlpProfile.Readiness = step?.StepType switch
            {
                ProtectionAdminStepType.DiscoverProviderState or
                ProtectionAdminStepType.RecordExactReadback =>
                    context.DlpProfile.Readiness with
                    {
                        Readback = ProtectionReadbackStatus.Failed
                    },
                ProtectionAdminStepType.VerifyPropagation =>
                    context.DlpProfile.Readiness with
                    {
                        Propagation = ProtectionPropagationStatus.Failed
                    },
                ProtectionAdminStepType.AttestTokenRoles =>
                    context.DlpProfile.Readiness with
                    {
                        TokenRoles = ProtectionTokenRoleStatus.Failed
                    },
                ProtectionAdminStepType.ValidateRuntimeVerdict =>
                    context.DlpProfile.Readiness with
                    {
                        RuntimeVerdict = ProtectionRuntimeVerdictStatus.Failed
                    },
                _ => context.DlpProfile.Readiness
            };
            context.DlpProfile.UpdatedAtUtc = now;
        }
        if (context?.KnowYourData is not null)
        {
            context.KnowYourData.Status = PurviewKnowYourDataStatus.VerificationFailed;
            context.KnowYourData.ReadbackStatus =
                step?.StepType is ProtectionAdminStepType.DiscoverProviderState or
                    ProtectionAdminStepType.RecordExactReadback
                    ? ProtectionReadbackStatus.Failed
                    : context.KnowYourData.ReadbackStatus;
            context.KnowYourData.LastFailureCode = safeCode;
            context.KnowYourData.UpdatedAtUtc = now;
        }
        if (context is not null &&
            operation.Type == ProtectionAdminOperationType.ConnectPurviewTenant)
        {
            context.Connection.Status =
                PurviewTenantConnectionStatus.VerificationFailed;
            context.Connection.ActiveInventoryGenerationId = null;
            context.Connection.AuthorityApplicationId = null;
            context.Connection.AuthorityServicePrincipalObjectId = null;
            context.Connection.AuthorityKind = "VerificationFailed";
            context.Connection.AuthorizedAtUtc = null;
            context.Connection.LastVerifiedAtUtc = null;
            context.Connection.ExpiresAtUtc = null;
            context.Connection.LastFailureCode = safeCode;
            context.Connection.UpdatedAtUtc = now;
        }

        await _unitOfWork.SaveChangesAsync(ct);
    }

    private void PersistKnowYourDataReadback(
        ProtectionAdminExecutionContext context,
        PurviewKnowYourDataReadback readback,
        bool ready)
    {
        var configuration = context.KnowYourData!;
        configuration.CollectionPolicyProviderId = readback.PolicyProviderId;
        configuration.LastReadbackAtUtc = readback.ObservedAtUtc.UtcDateTime;
        configuration.ReadbackStatus = ready
            ? ProtectionReadbackStatus.Ready
            : ProtectionReadbackStatus.Pending;
        configuration.Status = ready
            ? PurviewKnowYourDataStatus.Ready
            : PurviewKnowYourDataStatus.Pending;
        configuration.LastFailureCode = null;
        configuration.UpdatedAtUtc = UtcNow;
    }

    private void PersistDlpReadback(
        ProtectionAdminExecutionContext context,
        PurviewDlpProfileReadback readback,
        bool resetReadiness)
    {
        var profile = context.DlpProfile!;
        profile.DlpPolicyProviderId = readback.PolicyProviderId;
        profile.DlpRuleProviderId = readback.RuleProviderId;
        profile.LastReadbackAtUtc = readback.ObservedAtUtc.UtcDateTime;
        profile.LastFailureCode = null;
        if (resetReadiness)
        {
            profile.PropagationVerifiedAtUtc = null;
            profile.TokenRolesVerifiedAtUtc = null;
            profile.RuntimeAllowVerifiedAtUtc = null;
            profile.RuntimeBlockVerifiedAtUtc = null;
        }

        profile.Readiness = resetReadiness
            ? new ProtectionReadiness(
                context.Capability.Status,
                ProtectionReadbackStatus.Ready,
                ProtectionPropagationStatus.NotChecked,
                ProtectionTokenRoleStatus.NotChecked,
                ProtectionRuntimeVerdictStatus.NotChecked)
            : EvaluateDlpReadiness(
                context,
                ProtectionReadbackStatus.Ready,
                profile.Readiness.RuntimeVerdict);
        profile.Status = ResolveDlpStatus(profile.Readiness);
        profile.UpdatedAtUtc = UtcNow;
    }

    private void UpdateDlpReadiness(
        ProtectionAdminExecutionContext context,
        ProtectionRuntimeVerdictStatus runtimeStatus)
    {
        var profile = context.DlpProfile!;
        profile.Readiness = EvaluateDlpReadiness(
            context,
            profile.Readiness.Readback,
            runtimeStatus);
        profile.Status = profile.Readiness.IsReady
            ? PurviewDlpProfileStatus.Ready
            : PurviewDlpProfileStatus.VerificationFailed;
        profile.LastFailureCode = profile.Readiness.IsReady
            ? null
            : "PURVIEW_RUNTIME_READINESS_INCOMPLETE";
        profile.UpdatedAtUtc = UtcNow;
    }

    private ProtectionReadiness EvaluateDlpReadiness(
        ProtectionAdminExecutionContext context,
        ProtectionReadbackStatus readbackStatus,
        ProtectionRuntimeVerdictStatus runtimeStatus)
    {
        var profile = context.DlpProfile!;
        return PurviewReadinessEvaluator.Evaluate(
            new PurviewReadinessEvidence(
                context.Capability.Status,
                readbackStatus,
                profile.Readiness.Propagation,
                profile.Readiness.TokenRoles,
                runtimeStatus,
                ToOffset(profile.LastReadbackAtUtc),
                ToOffset(profile.PropagationVerifiedAtUtc),
                ToOffset(profile.TokenRolesVerifiedAtUtc),
                ToOffset(profile.RuntimeAllowVerifiedAtUtc),
                ToOffset(profile.RuntimeBlockVerifiedAtUtc)),
            new DateTimeOffset(UtcNow, TimeSpan.Zero));
    }

    private static PurviewDlpProfileStatus ResolveDlpStatus(
        ProtectionReadiness readiness)
    {
        if (readiness.IsReady)
            return PurviewDlpProfileStatus.Ready;
        if (readiness.Readback is ProtectionReadbackStatus.Failed or
                ProtectionReadbackStatus.Mismatch or
                ProtectionReadbackStatus.Stale ||
            readiness.Propagation == ProtectionPropagationStatus.Failed ||
            readiness.TokenRoles is ProtectionTokenRoleStatus.Failed or
                ProtectionTokenRoleStatus.MissingRequiredRoles ||
            readiness.RuntimeVerdict is ProtectionRuntimeVerdictStatus.Failed or
                ProtectionRuntimeVerdictStatus.Unsupported)
        {
            return PurviewDlpProfileStatus.VerificationFailed;
        }

        return PurviewDlpProfileStatus.PendingPropagation;
    }

    private static PurviewKnowYourDataIntent CreateKnowYourDataIntent(
        ProtectionAdminOperation operation,
        ProtectionAdminExecutionContext context,
        bool priorOutcomeUnknown) =>
        new(
            operation.Id,
            operation.TenantId.Value,
            context.Inventory!.Id.Value,
            ToOffset(context.Inventory.ExpiresAtUtc)!.Value,
            context.KnowYourData!.SensitiveInformationTypeId.Value,
            context.KnowYourData.SensitiveInformationTypeName,
            context.SelectedInformationType!.Publisher,
            $"A365 Gateway Know Your Data {context.KnowYourData.Id:D}",
            context.KnowYourData.Mode,
            context.KnowYourData.Activities.ToArray(),
            context.KnowYourData.IngestionEnabled,
            context.KnowYourData.CollectionPolicyProviderId,
            priorOutcomeUnknown);

    private static PurviewDlpProfileIntent CreateDlpIntent(
        ProtectionAdminOperation operation,
        ProtectionAdminExecutionContext context,
        PurviewDlpMutationRecoveryPoint recoveryPoint) =>
        new(
            operation.Id,
            operation.TenantId.Value,
            context.Inventory!.Id.Value,
            ToOffset(context.Inventory.ExpiresAtUtc)!.Value,
            context.DlpProfile!.SensitiveInformationTypeId.Value,
            context.DlpProfile.SensitiveInformationTypeName,
            context.SelectedInformationType!.Publisher,
            context.DlpProfile.BlueprintApplicationId.Value,
            $"A365 Gateway DLP {context.DlpProfile.Id.Value:D}",
            $"A365 Gateway DLP Rule {context.DlpProfile.Id.Value:D}",
            context.DlpProfile.Mode,
            context.DlpProfile.Activities.ToArray(),
            context.DlpProfile.Actions.ToArray(),
            context.DlpProfile.DlpPolicyProviderId,
            context.DlpProfile.DlpRuleProviderId,
            recoveryPoint);

    private void VerifyConnectionEvidence(
        ProtectionAdminExecutionContext context,
        bool activate)
    {
        var connection = context.Connection;
        if (connection.AuthorizedAtUtc is null ||
            connection.ExpiresAtUtc is null ||
            connection.ExpiresAtUtc <= UtcNow ||
            connection.ActiveInventoryGenerationId != context.Inventory!.Id)
        {
            throw Failure("PURVIEW_CONNECTION_EVIDENCE_UNVERIFIED");
        }

        if (!activate)
            return;

        connection.Status = PurviewTenantConnectionStatus.Connected;
        connection.LastVerifiedAtUtc = UtcNow;
        connection.LastFailureCode = null;
        connection.UpdatedAtUtc = UtcNow;
    }

    private void ValidateCompletion(
        ProtectionAdminOperation operation,
        ProtectionAdminExecutionContext context)
    {
        switch (operation.Type)
        {
            case ProtectionAdminOperationType.ConnectPurviewTenant:
                FinalizeConnectionVerification(operation, context);
                break;
            case ProtectionAdminOperationType.RefreshSensitiveInformationTypes:
                if (!context.Connection.IsUsableAt(UtcNow))
                    throw Failure("PURVIEW_CONNECTION_NOT_USABLE");
                break;
            case ProtectionAdminOperationType.CreateOrUpdateKnowYourData:
                if (!context.KnowYourData!.HasExactReadyReadback)
                    throw Failure("PURVIEW_KYD_READBACK_NOT_READY");
                break;
            case ProtectionAdminOperationType.CreateOrUpdateDlpProfile:
            case ProtectionAdminOperationType.ReconcileDlpProfile:
                if (context.DlpProfile!.Readiness.Readback !=
                        ProtectionReadbackStatus.Ready ||
                    string.IsNullOrWhiteSpace(context.DlpProfile.DlpPolicyProviderId) ||
                    string.IsNullOrWhiteSpace(context.DlpProfile.DlpRuleProviderId))
                {
                    throw Failure("PURVIEW_DLP_READBACK_NOT_READY");
                }
                break;
            case ProtectionAdminOperationType.ValidateDlpRuntime:
                if (!context.DlpProfile!.Readiness.IsReady ||
                    context.DlpProfile.Status != PurviewDlpProfileStatus.Ready)
                {
                    throw Failure("PURVIEW_RUNTIME_READINESS_INCOMPLETE");
                }
                break;
            default:
                throw Failure("PROTECTION_ADMIN_OPERATION_UNSUPPORTED");
        }
    }

    private void FinalizeConnectionVerification(
        ProtectionAdminOperation operation,
        ProtectionAdminExecutionContext context)
    {
        var connection = context.Connection;
        var binding = RequireExactPurviewCapabilityBinding(context.Capability);
        if (connection.Status != PurviewTenantConnectionStatus.PendingVerification ||
            connection.AuthorityApplicationId != binding.ApplicationId ||
            connection.AuthorityServicePrincipalObjectId !=
                binding.ServicePrincipalObjectId ||
            !string.Equals(
                connection.AuthorityKind,
                "CertificateApplicationVerified",
                StringComparison.Ordinal) ||
            connection.ActiveInventoryGenerationId is null ||
            context.Inventory is null ||
            connection.ActiveInventoryGenerationId != context.Inventory.Id ||
            connection.AuthorizedAtUtc is null ||
            connection.LastVerifiedAtUtc is null ||
            connection.ExpiresAtUtc is null ||
            connection.ExpiresAtUtc <= UtcNow)
        {
            throw Failure("PURVIEW_CONNECTION_FINAL_READBACK_INVALID");
        }

        ValidateInventory(context.Inventory);
        var expectedGenerationId =
            PurviewConnectionVerificationEvidence.DeriveInventoryGenerationId(
                operation.Id,
                operation.TenantId.Value,
                ParseCanonicalGuid(
                    operation.ActorObjectId,
                    "PURVIEW_CONNECTION_ADMINISTRATOR_INVALID"),
                binding.ApplicationId.Value,
                binding.ServicePrincipalObjectId.Value,
                binding.KeyVaultResourceId,
                binding.KeyVaultHost,
                binding.CertificateName,
                binding.CertificateSecretUri,
                context.Inventory.Items
                    .OrderBy(item => item.SortOrder)
                    .Select(item => new PurviewConnectionInventoryItem(
                        item.SensitiveInformationTypeId.Value,
                        item.ExactName,
                        item.Publisher,
                        item.SortOrder))
                    .ToArray());
        if (expectedGenerationId != context.Inventory.Id.Value)
            throw Failure("PURVIEW_CONNECTION_CAPABILITY_DRIFT");

        connection.Status = PurviewTenantConnectionStatus.Connected;
        connection.LastFailureCode = null;
        connection.UpdatedAtUtc = UtcNow;
    }

    private static bool ShouldSkip(
        ProtectionAdminOperationType operationType,
        ProtectionAdminStepType stepType) =>
        operationType switch
        {
            ProtectionAdminOperationType.ConnectPurviewTenant or
            ProtectionAdminOperationType.RefreshSensitiveInformationTypes =>
                stepType is ProtectionAdminStepType.ApplyReviewedMutation or
                    ProtectionAdminStepType.VerifyPropagation or
                    ProtectionAdminStepType.AttestTokenRoles or
                    ProtectionAdminStepType.ValidateRuntimeVerdict,
            ProtectionAdminOperationType.CreateOrUpdateKnowYourData =>
                stepType is ProtectionAdminStepType.VerifyPropagation or
                    ProtectionAdminStepType.AttestTokenRoles or
                    ProtectionAdminStepType.ValidateRuntimeVerdict,
            ProtectionAdminOperationType.CreateOrUpdateDlpProfile =>
                stepType == ProtectionAdminStepType.ValidateRuntimeVerdict,
            ProtectionAdminOperationType.ReconcileDlpProfile =>
                stepType is ProtectionAdminStepType.ApplyReviewedMutation or
                    ProtectionAdminStepType.VerifyPropagation or
                    ProtectionAdminStepType.AttestTokenRoles or
                    ProtectionAdminStepType.ValidateRuntimeVerdict,
            ProtectionAdminOperationType.ValidateDlpRuntime =>
                stepType == ProtectionAdminStepType.ApplyReviewedMutation,
            _ => false
        };

    private static string? ResolveCompletionRequiredAction(
        ProtectionAdminOperation operation,
        ProtectionAdminExecutionContext context) =>
        (operation.Type is ProtectionAdminOperationType.CreateOrUpdateDlpProfile or
            ProtectionAdminOperationType.ReconcileDlpProfile) &&
        context.DlpProfile?.Readiness.IsReady != true
            ? RequiredActionValidateRuntime
            : null;

    private static void ValidateReviewedOperation(ProtectionAdminOperation operation)
    {
        if (operation.WorkflowVersion != ProtectionAdminQueueContract.WorkflowVersion ||
            operation.MaximumAttempts < 1 ||
            !IsCanonicalGuid(operation.ActorObjectId) ||
            !IsReviewedHash(operation.ReviewedPayloadHash) ||
            !IsReviewedHash(operation.AcceptedRequestHash) ||
            operation.CorrelationId == Guid.Empty)
        {
            throw Failure("PROTECTION_ADMIN_REVIEWED_INTENT_INVALID");
        }

        var expectedTarget = operation.Type switch
        {
            ProtectionAdminOperationType.ConnectPurviewTenant =>
                ProtectionAdminTargetType.PurviewTenantConnection,
            ProtectionAdminOperationType.RefreshSensitiveInformationTypes =>
                ProtectionAdminTargetType.SensitiveInformationTypeInventory,
            ProtectionAdminOperationType.CreateOrUpdateKnowYourData =>
                ProtectionAdminTargetType.KnowYourDataConfiguration,
            ProtectionAdminOperationType.CreateOrUpdateDlpProfile or
            ProtectionAdminOperationType.ReconcileDlpProfile or
            ProtectionAdminOperationType.ValidateDlpRuntime =>
                ProtectionAdminTargetType.DlpProfile,
            _ => throw Failure("PROTECTION_ADMIN_OPERATION_UNSUPPORTED")
        };
        if (operation.TargetType != expectedTarget)
            throw Failure("PROTECTION_ADMIN_TARGET_TYPE_MISMATCH");
    }

    private static string? ValidateAcceptedOperation(
        ProtectionAdminOperation operation)
    {
        if (operation.Status is not ProtectionAdminOperationStatus.Pending and
                not ProtectionAdminOperationStatus.Running and
                not ProtectionAdminOperationStatus.PendingPropagation ||
            operation.ConfirmationVerifier?.ConsumedAtUtc is null)
        {
            return "PROTECTION_ADMIN_CONFIRMATION_NOT_CONSUMED";
        }

        return null;
    }

    private static void ValidateInventory(
        PurviewSensitiveInformationTypeSnapshotGeneration inventory)
    {
        if (inventory.ItemCount != inventory.Items.Count ||
            inventory.Items.Count is < 1 or > 2048)
        {
            throw Failure("PURVIEW_SIT_INVENTORY_INVALID");
        }

        var ids = new HashSet<Guid>();
        var names = new HashSet<string>(StringComparer.Ordinal);
        var ordered = inventory.Items.OrderBy(item => item.SortOrder).ToArray();
        for (var index = 0; index < ordered.Length; index++)
        {
            var item = ordered[index];
            if (item.GenerationId != inventory.Id ||
                item.SortOrder != index ||
                !ids.Add(item.SensitiveInformationTypeId.Value) ||
                !names.Add(item.ExactName) ||
                !IsBoundedText(item.ExactName, 255) ||
                !IsBoundedText(item.Publisher, 200))
            {
                throw Failure("PURVIEW_SIT_INVENTORY_INVALID");
            }
        }
    }

    private static PurviewSensitiveInformationTypeSnapshot RequireSelectedInformationType(
        PurviewSensitiveInformationTypeSnapshotGeneration inventory,
        SensitiveInformationTypeId sensitiveInformationTypeId,
        string exactName)
    {
        var matches = inventory.Items.Where(item =>
            item.SensitiveInformationTypeId == sensitiveInformationTypeId &&
            string.Equals(item.ExactName, exactName, StringComparison.Ordinal)).ToArray();
        return matches.Length == 1
            ? matches[0]
            : throw Failure("PURVIEW_SIT_SELECTION_STALE");
    }

    private static void EnsureProviderDisposition(
        PurviewSettingsOperationDisposition disposition,
        string? failureCode)
    {
        if (disposition == PurviewSettingsOperationDisposition.RequiresManualIntervention)
        {
            throw Failure(NormalizeFailureCode(
                failureCode,
                "PURVIEW_MUTATION_OUTCOME_UNRESOLVED"));
        }
    }

    private static T RequireReadback<T>(PurviewSettingsOperationResult<T> result)
        where T : class =>
        result.Readback ?? throw Failure(NormalizeFailureCode(
            result.FailureCode,
            "PURVIEW_EXACT_READBACK_MISSING"));

    private void EnsureRuntimeReady(
        PurviewRuntimeValidationResult result,
        string defaultFailureCode)
    {
        if (result.Status != PurviewRuntimeValidationStatus.Ready)
        {
            throw Failure(
                NormalizeFailureCode(result.FailureCode, defaultFailureCode));
        }

        RequireCurrentUtcEvidence(result.ObservedAtUtc, defaultFailureCode);
    }

    private static string? ValidateMessageBinding(
        ProtectionAdminOperation operation,
        ProtectionAdminOperationMessage message)
    {
        if (message.WorkflowVersion != ProtectionAdminQueueContract.WorkflowVersion ||
            operation.WorkflowVersion != message.WorkflowVersion)
        {
            return "PROTECTION_ADMIN_WORKFLOW_VERSION_UNSUPPORTED";
        }
        if (operation.CorrelationId != message.CorrelationId ||
            message.ExpectedStepIndex < 0 ||
            message.ExpectedStepIndex >= ProtectionAdminWorkflow.CurrentSteps.Count)
        {
            return "PROTECTION_ADMIN_MESSAGE_BINDING_MISMATCH";
        }

        return null;
    }

    private static string? ValidateWorkflow(ProtectionAdminOperation operation)
    {
        var steps = operation.OrderedSteps;
        if (steps.Count != ProtectionAdminWorkflow.CurrentSteps.Count)
            return "PROTECTION_ADMIN_WORKFLOW_INVALID";
        for (var index = 0; index < steps.Count; index++)
        {
            if (steps[index].Operation != operation ||
                steps[index].ProtectionAdminOperationId != operation.Id ||
                steps[index].OrderIndex != index ||
                steps[index].StepType != ProtectionAdminWorkflow.CurrentSteps[index])
            {
                return "PROTECTION_ADMIN_WORKFLOW_INVALID";
            }
        }

        return null;
    }

    private static void MarkRunning(
        ProtectionAdminOperation operation,
        ProtectionAdminOperationStep step,
        DateTime utcNow)
    {
        operation.Status = ProtectionAdminOperationStatus.Running;
        operation.StartedAtUtc ??= utcNow;
        operation.UpdatedAtUtc = utcNow;
        operation.NextAttemptAtUtc = null;
        operation.LastFailureCode = null;
        operation.RequiredAction = null;
        operation.RetryDisposition = ProtectionRetryDisposition.NotApplicable;
        step.Status = ProtectionAdminStepStatus.Running;
        step.StartedAtUtc ??= utcNow;
        step.AttemptCount++;
        operation.AttemptCount = Math.Max(operation.AttemptCount, step.AttemptCount);
        step.NextAttemptAtUtc = null;
        step.FailureCode = null;
        step.RetryDisposition = ProtectionRetryDisposition.NotApplicable;
    }

    private static bool TryDeserialize(
        string payload,
        out ProtectionAdminOperationMessage? message)
    {
        try
        {
            message = JsonSerializer.Deserialize<ProtectionAdminOperationMessage>(
                payload,
                MessageJsonOptions);
            return message is not null &&
                message.OperationId != Guid.Empty &&
                message.CorrelationId != Guid.Empty;
        }
        catch (JsonException)
        {
            message = null;
            return false;
        }
    }

    private DateTime UtcNow => _timeProvider.GetUtcNow().UtcDateTime;

    private static DateTimeOffset? ToOffset(DateTime? value) =>
        value is null
            ? null
            : new DateTimeOffset(
                DateTime.SpecifyKind(value.Value, DateTimeKind.Utc),
                TimeSpan.Zero);

    private static Guid ParseCanonicalGuid(string value, string failureCode)
    {
        if (!Guid.TryParse(value, out var parsed) ||
            parsed == Guid.Empty ||
            !string.Equals(value, parsed.ToString("D"), StringComparison.Ordinal))
        {
            throw Failure(failureCode);
        }

        return parsed;
    }

    private static bool TryParseCanonicalGuid(string value, out Guid parsed) =>
        Guid.TryParse(value, out parsed) &&
        parsed != Guid.Empty &&
        string.Equals(value, parsed.ToString("D"), StringComparison.Ordinal);

    private static bool IsCanonicalGuid(string value) =>
        TryParseCanonicalGuid(value, out _);

    private static bool IsReviewedHash(string? value) =>
        value is not null &&
        value.Length == 71 &&
        value.StartsWith("sha256:", StringComparison.Ordinal) &&
        value[7..].All(character =>
            character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static bool IsBoundedText(string? value, int maximumLength) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length <= maximumLength &&
        value.All(character => character > '\u001f' && character != '\u007f');

    private void RequireCurrentUtcEvidence(
        DateTimeOffset value,
        string failureCode)
    {
        var utcNow = new DateTimeOffset(UtcNow, TimeSpan.Zero);
        if (value.Offset != TimeSpan.Zero ||
            value > utcNow.AddMinutes(2) ||
            value < utcNow.Subtract(PurviewReadinessEvaluator.MaximumEvidenceAge))
        {
            throw Failure(failureCode);
        }
    }

    private static bool IsTerminal(ProtectionAdminOperationStatus status) =>
        status is ProtectionAdminOperationStatus.Completed or
            ProtectionAdminOperationStatus.Failed or
            ProtectionAdminOperationStatus.RequiresManualIntervention or
            ProtectionAdminOperationStatus.Cancelled;

    private static string NormalizeFailureCode(string? value, string fallback) =>
        IsSafeFailureCode(value)
            ? value!
            : fallback;

    private static bool IsSafeFailureCode(string? value) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length <= 64 &&
        value.All(character =>
            character is >= 'A' and <= 'Z' or >= '0' and <= '9' or '_');

    private static ProtectionAdminFailureException Failure(
        string failureCode,
        bool requiresManualIntervention = true) =>
        new(failureCode, requiresManualIntervention);

    private PurviewAutomationCapabilityBinding
        RequireExactPurviewCapabilityBinding(
            ProtectionCapability capability)
    {
        var identifiers = capability.ResourceIdentifiers;
        if (!_purviewOptions.Enabled ||
            !_purviewOptions.PolicyProvisioningEnabled ||
            capability.Kind != ProtectionCapabilityKind.Purview ||
            capability.Status != ProtectionCapabilityStatus.Installed ||
            capability.LastReadbackAtUtc is null ||
            capability.LastFailureCode is not null ||
            identifiers.Agent365RegistryApiApplicationId is not null ||
            identifiers.ContentSafetyAccountResourceId is not null ||
            identifiers.ContentSafetyEndpoint is not null ||
            identifiers.GatewayApiManagedIdentityPrincipalObjectId is null ||
            identifiers.PurviewRuntimeManagedIdentityPrincipalObjectId is null ||
            identifiers.PurviewAutomationApplicationId is null ||
            identifiers.PurviewAutomationServicePrincipalObjectId is null ||
            string.IsNullOrWhiteSpace(identifiers.KeyVaultResourceId) ||
            string.IsNullOrWhiteSpace(identifiers.KeyVaultHost) ||
            string.IsNullOrWhiteSpace(identifiers.CertificateName) ||
            string.IsNullOrWhiteSpace(identifiers.CertificateSecretUri) ||
            identifiers.BootstrapDeploymentOwnershipId is not { } ownershipId ||
            ownershipId == Guid.Empty ||
            !IsSourceFingerprint(identifiers.BootstrapSourceFingerprint) ||
            !TryParseCanonicalGuid(
                _configuration[
                    "PurviewRuntimeIdentity:ManagedIdentityPrincipalObjectId"] ??
                    string.Empty,
                out var configuredRuntimePrincipalId) ||
            identifiers.PurviewRuntimeManagedIdentityPrincipalObjectId.Value.Value !=
                configuredRuntimePrincipalId)
        {
            throw Failure("PURVIEW_CAPABILITY_BINDING_INVALID");
        }

        try
        {
            var binding = PurviewAutomationCapabilityBindingValidator.Bind(
                identifiers,
                _purviewOptions);
            if (!string.Equals(
                    identifiers.KeyVaultHost,
                    binding.KeyVaultHost,
                    StringComparison.Ordinal) ||
                !string.Equals(
                    identifiers.CertificateSecretUri,
                    binding.CertificateSecretUri.AbsoluteUri,
                    StringComparison.Ordinal))
            {
                throw Failure("PURVIEW_CAPABILITY_BINDING_INVALID");
            }

            return binding;
        }
        catch (PurviewPolicyException)
        {
            throw Failure("PURVIEW_CAPABILITY_BINDING_INVALID");
        }
    }

    private static void EnsureConnectionAuthorityBinding(
        PurviewTenantConnection connection,
        PurviewAutomationCapabilityBinding binding)
    {
        if (connection.AuthorityApplicationId != binding.ApplicationId ||
            connection.AuthorityServicePrincipalObjectId !=
                binding.ServicePrincipalObjectId ||
            !string.Equals(
                connection.AuthorityKind,
                "CertificateApplicationVerified",
                StringComparison.Ordinal))
        {
            throw Failure("PURVIEW_CAPABILITY_BINDING_INVALID");
        }
    }

    private static bool IsSourceFingerprint(string? value) =>
        value is { Length: 71 } &&
        value.StartsWith("sha256:", StringComparison.Ordinal) &&
        value.AsSpan(7).IndexOfAnyExcept(
            "0123456789abcdef") < 0;

    private const string SafeFailureSummary =
        "Protection administration could not prove safe completion.";
    private const string RequiredActionWaitForPropagation = "WaitForPropagation";
    private const string RequiredActionReconcile = "Reconcile";
    private const string RequiredActionValidateRuntime = "ValidateRuntime";
    private const string RequiredActionRetry = "Retry";

    private sealed class ProtectionAdminExecutionContext
    {
        public ProtectionAdminExecutionContext(
            ProtectionCapability capability,
            PurviewTenantConnection connection,
            PurviewSensitiveInformationTypeSnapshotGeneration? inventory,
            PurviewSensitiveInformationTypeSnapshot? selectedInformationType,
            PurviewKnowYourDataConfiguration? knowYourData,
            PurviewDlpProfile? dlpProfile)
        {
            Capability = capability;
            Connection = connection;
            Inventory = inventory;
            SelectedInformationType = selectedInformationType;
            KnowYourData = knowYourData;
            DlpProfile = dlpProfile;
        }

        public ProtectionCapability Capability { get; }
        public PurviewTenantConnection Connection { get; }
        public PurviewSensitiveInformationTypeSnapshotGeneration? Inventory { get; set; }
        public PurviewSensitiveInformationTypeSnapshot? SelectedInformationType { get; }
        public PurviewKnowYourDataConfiguration? KnowYourData { get; }
        public PurviewDlpProfile? DlpProfile { get; }
    }
}

internal sealed class ProtectionAdminFailureException : Exception
{
    public ProtectionAdminFailureException(
        string failureCode,
        bool requiresManualIntervention)
        : base("Protection administration failed closed.")
    {
        FailureCode = failureCode;
        RequiresManualIntervention = requiresManualIntervention;
    }

    public string FailureCode { get; }
    public bool RequiresManualIntervention { get; }
}

internal sealed class ProtectionAdminStepDeferredException : Exception;
