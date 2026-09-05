using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Messages;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using MediatR;

namespace Gateway.Application.Protection;

internal sealed class ProtectionMutationHandler :
    IRequestHandler<
        StartPurviewTenantConnectionCommand,
        ProtectionOperationAcceptedResponse>,
    IRequestHandler<
        CompletePurviewTenantConnectionCommand,
        ProtectionOperationAcceptedResponse>,
    IRequestHandler<
        StartPurviewKnowYourDataCommand,
        ProtectionOperationAcceptedResponse>,
    IRequestHandler<
        StartPurviewDlpProfileCommand,
        ProtectionOperationAcceptedResponse>,
    IRequestHandler<
        ReconcilePurviewDlpProfileCommand,
        ProtectionOperationAcceptedResponse>,
    IRequestHandler<
        ValidatePurviewDlpProfileRuntimeCommand,
        ProtectionOperationAcceptedResponse>
{
    private readonly IProtectionCapabilityRepository _capabilities;
    private readonly IPurviewTenantConnectionRepository _connections;
    private readonly IPurviewSensitiveInformationTypeSnapshotRepository _inventory;
    private readonly IPurviewKnowYourDataConfigurationRepository _knowYourData;
    private readonly IPurviewDlpProfileRepository _profiles;
    private readonly IProtectionAdminOperationRepository _operations;
    private readonly IOutboxRepository _outbox;
    private readonly IAuditEventRepository _auditEvents;
    private readonly IUnitOfWork _unitOfWork;
    private readonly ProtectionOperationTokenService _tokens;
    private readonly TimeProvider _timeProvider;

    public ProtectionMutationHandler(
        IProtectionCapabilityRepository capabilities,
        IPurviewTenantConnectionRepository connections,
        IPurviewSensitiveInformationTypeSnapshotRepository inventory,
        IPurviewKnowYourDataConfigurationRepository knowYourData,
        IPurviewDlpProfileRepository profiles,
        IProtectionAdminOperationRepository operations,
        IOutboxRepository outbox,
        IAuditEventRepository auditEvents,
        IUnitOfWork unitOfWork,
        ProtectionOperationTokenService tokens,
        TimeProvider timeProvider)
    {
        _capabilities = capabilities;
        _connections = connections;
        _inventory = inventory;
        _knowYourData = knowYourData;
        _profiles = profiles;
        _operations = operations;
        _outbox = outbox;
        _auditEvents = auditEvents;
        _unitOfWork = unitOfWork;
        _tokens = tokens;
        _timeProvider = timeProvider;
    }

    public async Task<ProtectionOperationAcceptedResponse> Handle(
        StartPurviewTenantConnectionCommand command,
        CancellationToken cancellationToken)
    {
        ProtectionAdministrationRules.EnsureTenant(
            command.Actor,
            command.Request.TenantId);
        var acceptedRequestHash =
            ProtectionAcceptedRequestHasher.Compute(command.Request);
        var idempotencyKey = new ProtectionIdempotencyKey(
            command.Request.IdempotencyKey);
        var replay = await GetReplayAsync(
            command.Actor,
            command.Request.ConfirmationTokenId,
            idempotencyKey,
            command.Request.ExpectedRowVersion,
            ProtectionAdminOperationType.ConnectPurviewTenant,
            acceptedRequestHash,
            cancellationToken);
        if (replay is not null)
            return ReplayResult(replay);

        var operation = await RequireConfirmationOperationAsync(
            command.Actor,
            command.Request.ConfirmationTokenId,
            cancellationToken);
        var validated = _tokens.ValidateConfirmation(
            operation,
            command.Actor,
            command.Request.ConfirmationToken,
            command.Request.ExpectedRowVersion);
        var reviewed =
            ProtectionAdministrationRules
                .DeserializePayload<PurviewTenantConnectionReviewPayload>(
                    validated.Payload);
        ProtectionAdministrationRules.EnsureTenant(
            command.Actor,
            reviewed.TenantId);
        await ProtectionAdministrationRules.RequirePurviewCapabilityAsync(
            _capabilities,
            cancellationToken);

        var connection = await _connections.GetByTenantIdAsync(
            new EntraTenantId(command.Actor.TenantId),
            cancellationToken);
        EnsureExpected(
            command.Request.ExpectedRowVersion,
            connection,
            connection?.Id ?? Guid.Empty,
            connection?.UpdatedAtUtc ?? default,
            connection?.RowVersion);

        var now = UtcNow();
        if (connection is null)
        {
            connection = new PurviewTenantConnection
            {
                Id = Guid.NewGuid(),
                TenantId = new EntraTenantId(command.Actor.TenantId),
                CreatedByObjectId = command.Actor.ObjectId,
                CreatedAtUtc = now
            };
            await _connections.AddAsync(connection, cancellationToken);
        }

        connection.Status = PurviewTenantConnectionStatus.AwaitingAdministrator;
        connection.AuthorityKind = "InteractiveDelegatedAdministrator";
        connection.AuthorizedAtUtc = null;
        var launchExpiry = _timeProvider.GetUtcNow().AddMinutes(15);
        connection.ExpiresAtUtc = launchExpiry.UtcDateTime;
        connection.LastFailureCode = null;
        connection.UpdatedAtUtc = now;

        ConsumeForAcceptance(
            operation,
            idempotencyKey,
            ProtectionAdminOperationType.ConnectPurviewTenant,
            ProtectionAdminOperationStatus.AwaitingAdministrator,
            command.Request.ExpectedRowVersion,
            acceptedRequestHash,
            now);
        operation.TargetIdentifier = connection.Id.ToString("D");
        operation.RequiredAction =
            ProtectionRequiredActionCodes.CompletePurviewTenantConnection;
        MarkConnectionAwaitingAdministrator(operation, now);
        var launch = PurviewCompanionLaunchContract.Create(
            operation.Id,
            command.Actor.TenantId,
            Guid.Parse(command.Actor.ObjectId),
            Guid.NewGuid(),
            launchExpiry);
        var accepted = Accepted(operation, launch);
        await AddAuditAsync(
            operation,
            "PurviewConnectionAwaitingAdministrator",
            cancellationToken);
        StoreResult(operation, accepted);
        await _unitOfWork.SaveChangesAsync(cancellationToken);
        return accepted;
    }

    public async Task<ProtectionOperationAcceptedResponse> Handle(
        CompletePurviewTenantConnectionCommand command,
        CancellationToken cancellationToken)
    {
        var nowOffset = _timeProvider.GetUtcNow();
        var now = nowOffset.UtcDateTime;
        ProtectionAdministrationRules.EnsureEvidence(
            command.Request.Evidence,
            command.Actor,
            nowOffset);
        if (command.Request.InventoryGenerationId == Guid.Empty)
        {
            throw new ValidationException(new Dictionary<string, string[]>
            {
                ["InventoryGenerationId"] =
                ["The completion inventory generation binding is required."]
            });
        }
        var evidenceDigest =
            PurviewTenantConnectionEvidenceDigest.Compute(
                command.OperationId,
                command.Request.InventoryGenerationId,
                command.Request.Evidence);
        if (!string.Equals(
                evidenceDigest,
                command.Request.EvidenceDigest,
                StringComparison.Ordinal))
        {
            throw new ValidationException(new Dictionary<string, string[]>
            {
                ["EvidenceDigest"] =
                ["The completion evidence digest does not match the canonical validated evidence."]
            });
        }
        var acceptedRequestHash =
            ProtectionAcceptedRequestHasher.Compute(
                command.OperationId,
                command.Request);
        var idempotencyKey = new ProtectionIdempotencyKey(
            command.Request.IdempotencyKey);
        var replay = await GetReplayAsync(
            command.Actor,
            command.Request.ConfirmationTokenId,
            idempotencyKey,
            command.Request.ExpectedRowVersion,
            ProtectionAdminOperationType.CompletePurviewTenantConnection,
            acceptedRequestHash,
            cancellationToken);
        if (replay is not null)
            return ReplayResult(replay);

        var authorizationOperation = await RequireConfirmationOperationAsync(
            command.Actor,
            command.Request.ConfirmationTokenId,
            cancellationToken);
        var validated = _tokens.ValidateConfirmation(
            authorizationOperation,
            command.Actor,
            command.Request.ConfirmationToken,
            command.Request.ExpectedRowVersion);
        var reviewed =
            ProtectionAdministrationRules
                .DeserializePayload<PurviewTenantConnectionCompletionReviewPayload>(
                    validated.Payload);
        if (reviewed.SourceOperationId != command.OperationId ||
            reviewed.InventoryGenerationId !=
                command.Request.InventoryGenerationId ||
            !string.Equals(
                reviewed.EvidenceDigest,
                evidenceDigest,
                StringComparison.Ordinal))
        {
            throw new DomainException(
                "The confirmation was not reviewed for this exact companion evidence.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }
        await ProtectionAdministrationRules.RequirePurviewCapabilityAsync(
            _capabilities,
            cancellationToken);

        var originalOperation = await _operations.GetByIdAsync(
            command.OperationId,
            cancellationToken);
        if (originalOperation is null ||
            originalOperation.TenantId.Value != command.Actor.TenantId ||
            !string.Equals(
                originalOperation.ActorObjectId,
                command.Actor.ObjectId,
                StringComparison.Ordinal) ||
            originalOperation.Type !=
                ProtectionAdminOperationType.ConnectPurviewTenant ||
            originalOperation.Status !=
                ProtectionAdminOperationStatus.AwaitingAdministrator)
        {
            throw new NotFoundException(
                "ProtectionAdminOperation",
                command.OperationId);
        }

        var launch = ReadCompanionLaunch(originalOperation);
        if (launch.InventoryGenerationId !=
                command.Request.InventoryGenerationId ||
            launch.ExpiresAtUtc <= nowOffset ||
            command.Request.Evidence.InventoryExpiresAtUtc !=
                launch.ExpiresAtUtc)
        {
            throw new DomainException(
                "The companion evidence does not match the active launch binding.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }

        var connection = await _connections.GetByTenantIdAsync(
            new EntraTenantId(command.Actor.TenantId),
            cancellationToken);
        if (connection is null ||
            connection.Status !=
                PurviewTenantConnectionStatus.AwaitingAdministrator)
        {
            throw new DomainException(
                "The Purview tenant connection is not awaiting companion evidence.",
                ErrorCodes.PURVIEW_TENANT_NOT_CONNECTED);
        }

        EnsureExpected(
            command.Request.ExpectedRowVersion,
            connection,
            connection.Id,
            connection.UpdatedAtUtc,
            connection.RowVersion);
        connection.Status =
            PurviewTenantConnectionStatus.PendingVerification;
        connection.AuthorityKind = "InteractiveSubmissionUnverified";
        connection.ActiveInventoryGenerationId = null;
        connection.AuthorizedAtUtc = null;
        connection.LastVerifiedAtUtc = null;
        connection.ExpiresAtUtc = null;
        connection.LastFailureCode = null;
        connection.UpdatedAtUtc = now;

        ConsumeForAcceptance(
            authorizationOperation,
            idempotencyKey,
            ProtectionAdminOperationType.CompletePurviewTenantConnection,
            ProtectionAdminOperationStatus.Submitted,
            command.Request.ExpectedRowVersion,
            acceptedRequestHash,
            now);
        authorizationOperation.ReadbackReferenceId = originalOperation.Id;
        authorizationOperation.CompletedAtUtc = null;
        authorizationOperation.RequiredAction = null;
        CompleteAllSteps(authorizationOperation, now);

        originalOperation.Status = ProtectionAdminOperationStatus.Pending;
        originalOperation.RetryDisposition =
            ProtectionRetryDisposition.Retryable;
        originalOperation.ReadbackReferenceId = null;
        originalOperation.CompletedAtUtc = null;
        originalOperation.RequiredAction = null;
        originalOperation.UpdatedAtUtc = now;
        var nextStep = originalOperation.OrderedSteps[1];
        nextStep.Status = ProtectionAdminStepStatus.Pending;
        nextStep.StartedAtUtc = null;
        nextStep.CompletedAtUtc = null;
        var submitted = Accepted(originalOperation);
        StoreResult(authorizationOperation, submitted);
        await AddOutboxAsync(
            originalOperation,
            expectedStepIndex: 1,
            cancellationToken);
        await AddAuditAsync(
            originalOperation,
            "PurviewConnectionEvidenceSubmitted",
            cancellationToken);
        await _unitOfWork.SaveChangesAsync(cancellationToken);
        return submitted;
    }

    public async Task<ProtectionOperationAcceptedResponse> Handle(
        StartPurviewKnowYourDataCommand command,
        CancellationToken cancellationToken)
    {
        var acceptedRequestHash =
            ProtectionAcceptedRequestHasher.Compute(command.Request);
        var accepted = await PrepareQueuedOperationAsync(
            command.Actor,
            command.Request.ConfirmationTokenId,
            command.Request.ConfirmationToken,
            command.Request.IdempotencyKey,
            command.Request.ExpectedRowVersion,
            ProtectionAdminOperationType.CreateOrUpdateKnowYourData,
            acceptedRequestHash,
            cancellationToken);
        if (accepted.IsReplay)
            return ReplayResult(accepted.Operation);

        var reviewed =
            ProtectionAdministrationRules
                .DeserializePayload<PurviewKnowYourDataReviewPayload>(
                    accepted.Payload!.Value);
        var now = UtcNow();
        var connection =
            await ProtectionAdministrationRules.RequireConnectionAsync(
                _connections,
                command.Actor,
                reviewed.TenantConnectionId,
                now,
                mustBeUsable: true,
                cancellationToken);
        var selection = await RequireReviewedInventoryAsync(
            connection,
            reviewed.InventoryGenerationId,
            reviewed.SensitiveInformationTypeId,
            reviewed.SensitiveInformationTypeName,
            now,
            cancellationToken);
        var configuration = await _knowYourData.GetByTenantIdAsync(
            connection.TenantId,
            cancellationToken);
        EnsureExpected(
            command.Request.ExpectedRowVersion,
            configuration,
            configuration?.Id ?? Guid.Empty,
            configuration?.UpdatedAtUtc ?? default,
            configuration?.RowVersion);
        var activities = ProtectionAdministrationRules.ParseActivities(
            reviewed.Activities);
        var mode = ProtectionAdministrationRules.ParseMode(reviewed.Mode);
        var targetId = Guid.Parse(accepted.Operation.TargetIdentifier);
        if (configuration is null)
        {
            configuration = new PurviewKnowYourDataConfiguration
            {
                Id = targetId,
                PurviewTenantConnectionId = connection.Id,
                CreatedAtUtc = now
            };
            await _knowYourData.AddAsync(configuration, cancellationToken);
        }
        else if (configuration.Id != targetId)
        {
            throw new DomainException(
                "The reviewed Know Your Data target no longer matches.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }

        configuration.InventoryGenerationId = selection.Generation.Id;
        configuration.SensitiveInformationTypeId =
            selection.Item.SensitiveInformationTypeId;
        configuration.SensitiveInformationTypeName =
            selection.Item.ExactName;
        configuration.Mode = mode;
        configuration.Activities = activities.ToList();
        configuration.IngestionEnabled = reviewed.IngestionEnabled;
        configuration.Status = PurviewKnowYourDataStatus.Pending;
        configuration.ReadbackStatus = ProtectionReadbackStatus.Pending;
        configuration.LastFailureCode = null;
        configuration.UpdatedAtUtc = now;

        await QueueAsync(
            accepted.Operation,
            "PurviewKnowYourDataOperationAccepted",
            cancellationToken);
        return Accepted(accepted.Operation);
    }

    public async Task<ProtectionOperationAcceptedResponse> Handle(
        StartPurviewDlpProfileCommand command,
        CancellationToken cancellationToken)
    {
        var acceptedRequestHash =
            ProtectionAcceptedRequestHasher.Compute(command.Request);
        var accepted = await PrepareQueuedOperationAsync(
            command.Actor,
            command.Request.ConfirmationTokenId,
            command.Request.ConfirmationToken,
            command.Request.IdempotencyKey,
            command.Request.ExpectedRowVersion,
            ProtectionAdminOperationType.CreateOrUpdateDlpProfile,
            acceptedRequestHash,
            cancellationToken);
        if (accepted.IsReplay)
            return ReplayResult(accepted.Operation);

        var reviewed =
            ProtectionAdministrationRules
                .DeserializePayload<PurviewDlpProfileReviewPayload>(
                    accepted.Payload!.Value);
        var now = UtcNow();
        var connection =
            await ProtectionAdministrationRules.RequireConnectionAsync(
                _connections,
                command.Actor,
                reviewed.TenantConnectionId,
                now,
                mustBeUsable: true,
                cancellationToken);
        var selection = await RequireReviewedInventoryAsync(
            connection,
            reviewed.InventoryGenerationId,
            reviewed.SensitiveInformationTypeId,
            reviewed.SensitiveInformationTypeName,
            now,
            cancellationToken);
        var profile = await _profiles.GetByIdAsync(
            new PurviewDlpProfileId(reviewed.ProfileId),
            cancellationToken);
        EnsureExpected(
            command.Request.ExpectedRowVersion,
            profile,
            profile?.Id.Value ?? Guid.Empty,
            profile?.UpdatedAtUtc ?? default,
            profile?.RowVersion);
        var byBlueprint = await _profiles.GetByBlueprintApplicationIdAsync(
            new BlueprintApplicationId(reviewed.BlueprintApplicationId),
            cancellationToken);
        if (byBlueprint is not null &&
            byBlueprint.Id.Value != reviewed.ProfileId)
        {
            throw new ConflictException(
                "This blueprint application already has a different DLP profile.",
                ErrorCodes.PURVIEW_POLICY_PROFILE_CONFLICT);
        }

        var activities = ProtectionAdministrationRules.ParseActivities(
            reviewed.Activities);
        var actions = ProtectionAdministrationRules.ParseActions(
            reviewed.Actions,
            activities);
        var mode = ProtectionAdministrationRules.ParseMode(reviewed.Mode);
        ProtectionAdministrationRules.EnsureBoundedDisplayName(
            reviewed.DisplayName);
        if (profile is null)
        {
            profile = new PurviewDlpProfile
            {
                Id = new PurviewDlpProfileId(reviewed.ProfileId),
                PurviewTenantConnectionId = connection.Id,
                BlueprintApplicationId =
                    new BlueprintApplicationId(
                        reviewed.BlueprintApplicationId),
                CreatedAtUtc = now
            };
            await _profiles.AddAsync(profile, cancellationToken);
        }
        else if (profile.PurviewTenantConnectionId != connection.Id ||
                 profile.BlueprintApplicationId.Value !=
                 reviewed.BlueprintApplicationId)
        {
            throw new DomainException(
                "The reviewed DLP profile target no longer matches.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }

        profile.DisplayName = reviewed.DisplayName;
        profile.InventoryGenerationId = selection.Generation.Id;
        profile.SensitiveInformationTypeSnapshotExpiresAtUtc =
            selection.Generation.ExpiresAtUtc;
        profile.SensitiveInformationTypeId =
            selection.Item.SensitiveInformationTypeId;
        profile.SensitiveInformationTypeName = selection.Item.ExactName;
        profile.Mode = mode;
        profile.Activities = activities.ToList();
        profile.Actions = actions.ToList();
        profile.Status = PurviewDlpProfileStatus.Pending;
        profile.Readiness = new ProtectionReadiness(
            ProtectionCapabilityStatus.Installed,
            ProtectionReadbackStatus.Pending,
            ProtectionPropagationStatus.NotChecked,
            ProtectionTokenRoleStatus.NotChecked,
            ProtectionRuntimeVerdictStatus.NotChecked);
        profile.PropagationVerifiedAtUtc = null;
        profile.TokenRolesVerifiedAtUtc = null;
        profile.RuntimeAllowVerifiedAtUtc = null;
        profile.RuntimeBlockVerifiedAtUtc = null;
        profile.LastFailureCode = null;
        profile.UpdatedAtUtc = now;

        await QueueAsync(
            accepted.Operation,
            "PurviewDlpProfileOperationAccepted",
            cancellationToken);
        return Accepted(accepted.Operation);
    }

    public async Task<ProtectionOperationAcceptedResponse> Handle(
        ReconcilePurviewDlpProfileCommand command,
        CancellationToken cancellationToken)
    {
        var acceptedRequestHash =
            ProtectionAcceptedRequestHasher.Compute(
                command.ProfileId,
                command.Request);
        var accepted = await PrepareQueuedOperationAsync(
            command.Actor,
            command.Request.ConfirmationTokenId,
            command.Request.ConfirmationToken,
            command.Request.IdempotencyKey,
            command.Request.ExpectedRowVersion,
            ProtectionAdminOperationType.ReconcileDlpProfile,
            acceptedRequestHash,
            cancellationToken,
            reviewedType:
                ProtectionAdminOperationType.ReconcileDlpProfile);
        if (accepted.IsReplay)
            return ReplayResult(accepted.Operation);

        await EnsureExactReviewedProfileAsync(
            command.Actor,
            command.ProfileId,
            command.Request.ExpectedRowVersion,
            accepted.Payload!.Value,
            requireRuntimePrerequisites: false,
            cancellationToken);
        await QueueAsync(
            accepted.Operation,
            "PurviewDlpProfileReconcileAccepted",
            cancellationToken);
        return Accepted(accepted.Operation);
    }

    public async Task<ProtectionOperationAcceptedResponse> Handle(
        ValidatePurviewDlpProfileRuntimeCommand command,
        CancellationToken cancellationToken)
    {
        var acceptedRequestHash =
            ProtectionAcceptedRequestHasher.Compute(
                command.ProfileId,
                command.Request);
        var accepted = await PrepareQueuedOperationAsync(
            command.Actor,
            command.Request.ConfirmationTokenId,
            command.Request.ConfirmationToken,
            command.Request.IdempotencyKey,
            command.Request.ExpectedRowVersion,
            ProtectionAdminOperationType.ValidateDlpRuntime,
            acceptedRequestHash,
            cancellationToken,
            reviewedType:
                ProtectionAdminOperationType.ValidateDlpRuntime);
        if (accepted.IsReplay)
            return ReplayResult(accepted.Operation);

        await EnsureExactReviewedProfileAsync(
            command.Actor,
            command.ProfileId,
            command.Request.ExpectedRowVersion,
            accepted.Payload!.Value,
            requireRuntimePrerequisites: true,
            cancellationToken);
        await QueueAsync(
            accepted.Operation,
            "PurviewDlpRuntimeValidationAccepted",
            cancellationToken);
        return Accepted(accepted.Operation);
    }

    private async Task<PreparedOperation> PrepareQueuedOperationAsync(
        ProtectionActor actor,
        Guid confirmationTokenId,
        string confirmationToken,
        Guid idempotencyKeyValue,
        string expectedRowVersion,
        ProtectionAdminOperationType acceptedType,
        string acceptedRequestHash,
        CancellationToken cancellationToken,
        ProtectionAdminOperationType? reviewedType = null)
    {
        var idempotencyKey = new ProtectionIdempotencyKey(
            idempotencyKeyValue);
        var replay = await GetReplayAsync(
            actor,
            confirmationTokenId,
            idempotencyKey,
            expectedRowVersion,
            acceptedType,
            acceptedRequestHash,
            cancellationToken);
        if (replay is not null)
            return new PreparedOperation(replay, null, IsReplay: true);

        var operation = await RequireConfirmationOperationAsync(
            actor,
            confirmationTokenId,
            cancellationToken);
        if (reviewedType is not null && operation.Type != reviewedType)
        {
            throw new DomainException(
                "The confirmation was not reviewed for this target.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }

        var validated = _tokens.ValidateConfirmation(
            operation,
            actor,
            confirmationToken,
            expectedRowVersion);
        await ProtectionAdministrationRules.RequirePurviewCapabilityAsync(
            _capabilities,
            cancellationToken);
        ConsumeForAcceptance(
            operation,
            idempotencyKey,
            acceptedType,
            ProtectionAdminOperationStatus.Pending,
            expectedRowVersion,
            acceptedRequestHash,
            UtcNow());
        return new PreparedOperation(
            operation,
            validated.Payload,
            IsReplay: false);
    }

    private async Task EnsureExactReviewedProfileAsync(
        ProtectionActor actor,
        Guid profileId,
        string expectedRowVersion,
        JsonElement payload,
        bool requireRuntimePrerequisites,
        CancellationToken cancellationToken)
    {
        var reviewed =
            ProtectionAdministrationRules
                .DeserializePayload<PurviewDlpProfileReviewPayload>(payload);
        if (profileId == Guid.Empty || reviewed.ProfileId != profileId)
        {
            throw new DomainException(
                "The confirmed DLP profile does not match the route target.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }

        var profile = await _profiles.GetByIdAsync(
            new PurviewDlpProfileId(profileId),
            cancellationToken);
        if (profile is null)
            throw new NotFoundException("PurviewDlpProfile", profileId);
        var connection =
            await ProtectionAdministrationRules.RequireConnectionAsync(
                _connections,
                actor,
                reviewed.TenantConnectionId,
                UtcNow(),
                mustBeUsable: true,
                cancellationToken);
        if (profile.PurviewTenantConnectionId != connection.Id)
            throw new NotFoundException("PurviewDlpProfile", profileId);
        EnsureExpected(
            expectedRowVersion,
            profile,
            profile.Id.Value,
            profile.UpdatedAtUtc,
            profile.RowVersion);
        EnsureProfileMatchesReview(profile, reviewed);
        ProtectionAdministrationRules.ParseActions(reviewed.Actions,
            ProtectionAdministrationRules.ParseActivities(reviewed.Activities));
        await RequireReviewedInventoryAsync(
            connection,
            reviewed.InventoryGenerationId,
            reviewed.SensitiveInformationTypeId,
            reviewed.SensitiveInformationTypeName,
            UtcNow(),
            cancellationToken);

        if (requireRuntimePrerequisites &&
            (profile.Mode != PurviewMode.Enforce ||
             profile.Readiness.Readback != ProtectionReadbackStatus.Ready ||
             profile.Readiness.Propagation !=
                 ProtectionPropagationStatus.Ready ||
             profile.Readiness.TokenRoles !=
                 ProtectionTokenRoleStatus.Ready))
        {
            throw new DomainException(
                "Enforce mode, exact policy readback, propagation, and token-role evidence are required before runtime validation.",
                ErrorCodes.PURVIEW_DLP_PROFILE_NOT_READY);
        }
    }

    private static void EnsureProfileMatchesReview(
        PurviewDlpProfile profile,
        PurviewDlpProfileReviewPayload reviewed)
    {
        var activities = profile.Activities
            .OrderBy(value => value)
            .Select(value => value.ToString());
        var actions = profile.Actions
            .OrderBy(value => value.Activity)
            .ThenBy(value => value.Action)
            .Select(value => (
                Activity: value.Activity.ToString(),
                Action: value.Action.ToString()));
        var reviewedActions = reviewed.Actions.Select(value => (
            value.Activity,
            value.Action));
        if (profile.BlueprintApplicationId.Value !=
                reviewed.BlueprintApplicationId ||
            !string.Equals(
                profile.DisplayName,
                reviewed.DisplayName,
                StringComparison.Ordinal) ||
            profile.InventoryGenerationId.Value !=
                reviewed.InventoryGenerationId ||
            profile.SensitiveInformationTypeId.Value !=
                reviewed.SensitiveInformationTypeId ||
            !string.Equals(
                profile.SensitiveInformationTypeName,
                reviewed.SensitiveInformationTypeName,
                StringComparison.Ordinal) ||
            !string.Equals(
                profile.Mode.ToString(),
                reviewed.Mode,
                StringComparison.Ordinal) ||
            !activities.SequenceEqual(reviewed.Activities) ||
            !actions.SequenceEqual(reviewedActions))
        {
            throw new DomainException(
                "Reconciliation and runtime validation require a review of the exact current DLP profile.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }
    }

    private async Task<ValidatedSensitiveInformationType>
        RequireReviewedInventoryAsync(
            PurviewTenantConnection connection,
            Guid generationId,
            Guid sensitiveInformationTypeId,
            string exactName,
            DateTime utcNow,
            CancellationToken cancellationToken) =>
        await ProtectionAdministrationRules.RequireInventorySelectionAsync(
            _inventory,
            connection,
            new Contracts.Dtos.PurviewSensitiveInformationTypeSelectionDto(
                generationId,
                sensitiveInformationTypeId,
                exactName),
            utcNow,
            cancellationToken);

    private async Task QueueAsync(
        ProtectionAdminOperation operation,
        string auditEventType,
        CancellationToken cancellationToken)
    {
        StoreResult(operation, Accepted(operation));
        await AddOutboxAsync(
            operation,
            expectedStepIndex: 0,
            cancellationToken);
        await AddAuditAsync(
            operation,
            auditEventType,
            cancellationToken);
        await _unitOfWork.SaveChangesAsync(cancellationToken);
    }

    private async Task<ProtectionAdminOperation?> GetReplayAsync(
        ProtectionActor actor,
        Guid confirmationTokenId,
        ProtectionIdempotencyKey idempotencyKey,
        string expectedRowVersion,
        ProtectionAdminOperationType acceptedType,
        string acceptedRequestHash,
        CancellationToken cancellationToken)
    {
        var existing = await _operations.GetByIdempotencyKeyAsync(
            new EntraTenantId(actor.TenantId),
            idempotencyKey,
            cancellationToken);
        if (existing is null)
            return null;

        if (existing.Id != confirmationTokenId ||
            !string.Equals(
                existing.ActorObjectId,
                actor.ObjectId,
                StringComparison.Ordinal) ||
            existing.Type != acceptedType ||
            !string.Equals(
                existing.AcceptedRequestHash,
                acceptedRequestHash,
                StringComparison.Ordinal) ||
            !string.Equals(
                ProtectionRowVersion.EncodeExpected(
                    existing.ExpectedRowVersion),
                expectedRowVersion,
                StringComparison.Ordinal) ||
            existing.ConfirmationVerifier?.ConsumedAtUtc is null ||
            existing.Status ==
                ProtectionAdminOperationStatus.AwaitingConfirmation)
        {
            throw IdempotencyConflict();
        }

        return existing;
    }

    private async Task<ProtectionAdminOperation>
        RequireConfirmationOperationAsync(
            ProtectionActor actor,
            Guid confirmationTokenId,
            CancellationToken cancellationToken)
    {
        var operation = await _operations.GetByIdAsync(
            confirmationTokenId,
            cancellationToken);
        if (operation is null ||
            operation.TenantId.Value != actor.TenantId ||
            !string.Equals(
                operation.ActorObjectId,
                actor.ObjectId,
                StringComparison.Ordinal))
        {
            throw new NotFoundException(
                "ProtectionAdminOperation",
                confirmationTokenId);
        }

        if (operation.Status !=
            ProtectionAdminOperationStatus.AwaitingConfirmation)
        {
            throw new DomainException(
                "The one-time confirmation is no longer usable.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }

        return operation;
    }

    private static void ConsumeForAcceptance(
        ProtectionAdminOperation operation,
        ProtectionIdempotencyKey idempotencyKey,
        ProtectionAdminOperationType acceptedType,
        ProtectionAdminOperationStatus status,
        string expectedRowVersion,
        string acceptedRequestHash,
        DateTime utcNow)
    {
        operation.ConfirmationVerifier!.MarkConsumed(utcNow);
        operation.IdempotencyKey = idempotencyKey;
        operation.Type = acceptedType;
        operation.Status = status;
        operation.ExpectedRowVersion =
            ProtectionRowVersion.DecodeExpected(expectedRowVersion);
        operation.AcceptedRequestHash = acceptedRequestHash;
        operation.RetryDisposition = ProtectionRetryDisposition.Retryable;
        operation.RequiredAction = null;
        operation.UpdatedAtUtc = utcNow;
        foreach (var step in operation.OrderedSteps)
        {
            if (step.Status ==
                ProtectionAdminStepStatus.AwaitingConfirmation)
            {
                step.Status = ProtectionAdminStepStatus.Pending;
            }
        }
    }

    private static void MarkConnectionAwaitingAdministrator(
        ProtectionAdminOperation operation,
        DateTime utcNow)
    {
        var steps = operation.OrderedSteps;
        steps[0].Status = ProtectionAdminStepStatus.Completed;
        steps[0].StartedAtUtc = utcNow;
        steps[0].CompletedAtUtc = utcNow;
        steps[1].Status =
            ProtectionAdminStepStatus.AwaitingAdministrator;
        operation.StartedAtUtc = utcNow;
    }

    private static void CompleteAllSteps(
        ProtectionAdminOperation operation,
        DateTime utcNow)
    {
        foreach (var step in operation.OrderedSteps)
        {
            step.Status = ProtectionAdminStepStatus.Completed;
            step.StartedAtUtc ??= utcNow;
            step.CompletedAtUtc = utcNow;
            step.RetryDisposition =
                ProtectionRetryDisposition.NotApplicable;
        }

        operation.RetryDisposition =
            ProtectionRetryDisposition.NotApplicable;
    }

    private static void EnsureExpected<T>(
        string expectedRowVersion,
        T? entity,
        Guid entityId,
        DateTime updatedAtUtc,
        byte[]? rowVersion)
        where T : class =>
        ProtectionRowVersion.EnsureMatches(
            expectedRowVersion,
            entity is not null,
            rowVersion,
            entityId,
            updatedAtUtc);

    private async Task AddAuditAsync(
        ProtectionAdminOperation operation,
        string eventType,
        CancellationToken cancellationToken)
    {
        await _auditEvents.AddAsync(new AuditEvent
        {
            Id = Guid.NewGuid(),
            EventType = eventType,
            PerformedByObjectId = operation.ActorObjectId,
            PerformedByRole = "Gateway.Administrator",
            CorrelationId = operation.CorrelationId.ToString("D"),
            Details = JsonSerializer.Serialize(new
            {
                operationId = operation.Id,
                operationType = operation.Type.ToString(),
                targetType = operation.TargetType.ToString()
            }),
            OccurredAtUtc = UtcNow()
        }, cancellationToken);
    }

    private static ProtectionOperationAcceptedResponse Accepted(
        ProtectionAdminOperation operation,
        PurviewCompanionLaunchDto? companionLaunch = null) =>
        new(
            operation.Id,
            operation.Status.ToString(),
            operation.CorrelationId,
            companionLaunch);

    private static PurviewCompanionLaunchDto ReadCompanionLaunch(
        ProtectionAdminOperation operation)
    {
        if (string.IsNullOrWhiteSpace(operation.ResultJson))
        {
            throw new DomainException(
                "The companion launch binding is unavailable.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }

        var launch =
            JsonSerializer.Deserialize<ProtectionOperationAcceptedResponse>(
                operation.ResultJson)?.CompanionLaunch;
        if (launch is null ||
            launch.OperationId != operation.Id ||
            launch.InventoryGenerationId == Guid.Empty ||
            launch.ExpiresAtUtc.Offset != TimeSpan.Zero)
        {
            throw new DomainException(
                "The companion launch binding is invalid.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }

        return launch;
    }

    private static ProtectionOperationAcceptedResponse ReplayResult(
        ProtectionAdminOperation operation)
    {
        if (string.IsNullOrWhiteSpace(operation.ResultJson))
            throw IdempotencyConflict();
        return JsonSerializer.Deserialize<ProtectionOperationAcceptedResponse>(
                   operation.ResultJson)
            ?? throw IdempotencyConflict();
    }

    private static void StoreResult(
        ProtectionAdminOperation operation,
        ProtectionOperationAcceptedResponse result)
    {
        operation.ResultJson = JsonSerializer.Serialize(result);
    }

    private async Task AddOutboxAsync(
        ProtectionAdminOperation operation,
        int expectedStepIndex,
        CancellationToken cancellationToken)
    {
        await _outbox.AddAsync(new OutboxMessage
        {
            Id = Guid.NewGuid(),
            MessageType = nameof(ProtectionAdminOperationMessage),
            Payload = JsonSerializer.Serialize(
                new ProtectionAdminOperationMessage(
                    operation.Id,
                    operation.WorkflowVersion,
                    expectedStepIndex,
                    operation.CorrelationId)),
            Status = OutboxMessageStatus.Pending,
            RetryCount = 0,
            CreatedAtUtc = UtcNow()
        }, cancellationToken);
    }

    private static ConflictException IdempotencyConflict() =>
        new(
            "The Idempotency-Key was already used for a different protection administration request.",
            ErrorCodes.IDEMPOTENCY_CONFLICT);

    private DateTime UtcNow() => _timeProvider.GetUtcNow().UtcDateTime;

    private sealed record PreparedOperation(
        ProtectionAdminOperation Operation,
        JsonElement? Payload,
        bool IsReplay);
}
