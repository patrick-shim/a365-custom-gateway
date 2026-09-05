using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using MediatR;

namespace Gateway.Application.Protection;

internal sealed class ProtectionReviewHandler :
    IRequestHandler<
        ReviewPurviewTenantConnectionCommand,
        ProtectionOperationReviewResponse>,
    IRequestHandler<
        ReviewPurviewTenantConnectionCompletionCommand,
        ProtectionOperationReviewResponse>,
    IRequestHandler<
        ReviewPurviewKnowYourDataCommand,
        ProtectionOperationReviewResponse>,
    IRequestHandler<
        ReviewPurviewDlpProfileCommand,
        ProtectionOperationReviewResponse>,
    IRequestHandler<
        ReviewReconcilePurviewDlpProfileCommand,
        ProtectionOperationReviewResponse>,
    IRequestHandler<
        ReviewValidatePurviewDlpRuntimeCommand,
        ProtectionOperationReviewResponse>,
    IRequestHandler<
        ConfirmProtectionOperationReviewCommand,
        ProtectionOperationConfirmationResponse>
{
    private readonly IProtectionCapabilityRepository _capabilities;
    private readonly IPurviewTenantConnectionRepository _connections;
    private readonly IPurviewSensitiveInformationTypeSnapshotRepository _inventory;
    private readonly IPurviewKnowYourDataConfigurationRepository _knowYourData;
    private readonly IPurviewDlpProfileRepository _profiles;
    private readonly IProtectionAdminOperationRepository _operations;
    private readonly IAgentIdentityBlueprintCatalog _blueprints;
    private readonly IAuditEventRepository _auditEvents;
    private readonly IUnitOfWork _unitOfWork;
    private readonly ProtectionOperationTokenService _tokens;
    private readonly TimeProvider _timeProvider;

    public ProtectionReviewHandler(
        IProtectionCapabilityRepository capabilities,
        IPurviewTenantConnectionRepository connections,
        IPurviewSensitiveInformationTypeSnapshotRepository inventory,
        IPurviewKnowYourDataConfigurationRepository knowYourData,
        IPurviewDlpProfileRepository profiles,
        IProtectionAdminOperationRepository operations,
        IAgentIdentityBlueprintCatalog blueprints,
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
        _blueprints = blueprints;
        _auditEvents = auditEvents;
        _unitOfWork = unitOfWork;
        _tokens = tokens;
        _timeProvider = timeProvider;
    }

    public async Task<ProtectionOperationReviewResponse> Handle(
        ReviewPurviewTenantConnectionCommand command,
        CancellationToken cancellationToken)
    {
        ProtectionAdministrationRules.EnsureTenant(
            command.Actor,
            command.Request.TenantId);
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

        var operation = CreateOperation(
            command.Actor,
            ProtectionAdminOperationType.ConnectPurviewTenant,
            ProtectionAdminTargetType.PurviewTenantConnection,
            command.Actor.TenantId.ToString("D"),
            command.Request.ExpectedRowVersion,
            command.CorrelationId);
        var payload = new PurviewTenantConnectionReviewPayload(
            command.Actor.TenantId);
        return await PersistReviewAsync(
            operation,
            command.Request.ExpectedRowVersion,
            payload,
            new ProtectionOperationReviewSummaryDto(
                command.Actor.TenantId,
                operation.Type.ToString(),
                operation.TargetType.ToString(),
                operation.TargetIdentifier,
                BlueprintApplicationId: null,
                SensitiveInformationTypeId: null,
                SensitiveInformationTypeName: null,
                Mode: null,
                Activities: [],
                Actions: [],
                ScopeType: "Tenant",
                EnforcementPlane: PurviewEnforcementPlane.Application.ToString(),
                ProtectionAdministrationRules.ReadinessDisclaimer),
            cancellationToken);
    }

    public async Task<ProtectionOperationReviewResponse> Handle(
        ReviewPurviewTenantConnectionCompletionCommand command,
        CancellationToken cancellationToken)
    {
        if (command.OperationId == Guid.Empty ||
            command.Request.OperationId != command.OperationId ||
            command.Request.InventoryGenerationId == Guid.Empty)
        {
            throw new ValidationException(new Dictionary<string, string[]>
            {
                ["OperationId"] =
                ["The active operation and inventory generation binding is invalid."]
            });
        }

        var now = _timeProvider.GetUtcNow();
        ProtectionAdministrationRules.EnsureEvidence(
            command.Request.Evidence,
            command.Actor,
            now);
        var digest = PurviewTenantConnectionEvidenceDigest.Compute(
            command.OperationId,
            command.Request.InventoryGenerationId,
            command.Request.Evidence);
        if (!string.Equals(
                digest,
                command.Request.EvidenceDigest,
                StringComparison.Ordinal))
        {
            throw new ValidationException(new Dictionary<string, string[]>
            {
                ["EvidenceDigest"] =
                ["The companion evidence digest does not match the canonical validated evidence."]
            });
        }

        var (sourceOperation, connection, launch) =
            await RequireActiveConnectionLaunchAsync(
                command.Actor,
                command.OperationId,
                cancellationToken);
        if (launch.InventoryGenerationId !=
                command.Request.InventoryGenerationId ||
            launch.ExpiresAtUtc <= now ||
            command.Request.Evidence.InventoryExpiresAtUtc !=
                launch.ExpiresAtUtc)
        {
            throw new DomainException(
                "The companion evidence does not match the active launch binding.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }

        EnsureExpected(
            command.Request.ExpectedRowVersion,
            connection,
            connection.Id,
            connection.UpdatedAtUtc,
            connection.RowVersion);
        var operation = CreateOperation(
            command.Actor,
            ProtectionAdminOperationType.CompletePurviewTenantConnection,
            ProtectionAdminTargetType.PurviewTenantConnection,
            connection.Id.ToString("D"),
            command.Request.ExpectedRowVersion,
            command.CorrelationId);
        var payload = new PurviewTenantConnectionCompletionReviewPayload(
            sourceOperation.Id,
            launch.InventoryGenerationId,
            digest);
        return await PersistReviewAsync(
            operation,
            command.Request.ExpectedRowVersion,
            payload,
            new ProtectionOperationReviewSummaryDto(
                command.Actor.TenantId,
                operation.Type.ToString(),
                operation.TargetType.ToString(),
                operation.TargetIdentifier,
                BlueprintApplicationId: null,
                SensitiveInformationTypeId: null,
                SensitiveInformationTypeName: null,
                Mode: null,
                Activities: [],
                Actions: [],
                ScopeType: "Tenant",
                EnforcementPlane:
                    PurviewEnforcementPlane.Application.ToString(),
                ProtectionAdministrationRules.ReadinessDisclaimer,
                SourceOperationId: sourceOperation.Id,
                InventoryGenerationId: launch.InventoryGenerationId,
                EvidenceDigest: digest),
            cancellationToken);
    }

    public async Task<ProtectionOperationReviewResponse> Handle(
        ReviewPurviewKnowYourDataCommand command,
        CancellationToken cancellationToken)
    {
        await ProtectionAdministrationRules.RequirePurviewCapabilityAsync(
            _capabilities,
            cancellationToken);
        var now = UtcNow();
        var connection = await ProtectionAdministrationRules.RequireConnectionAsync(
            _connections,
            command.Actor,
            command.Request.TenantConnectionId,
            now,
            mustBeUsable: true,
            cancellationToken);
        var selection =
            await ProtectionAdministrationRules.RequireInventorySelectionAsync(
                _inventory,
                connection,
                command.Request.SensitiveInformationType,
                now,
                cancellationToken);
        var mode = ProtectionAdministrationRules.ParseMode(command.Request.Mode);
        var activities = ProtectionAdministrationRules.ParseActivities(
            command.Request.Activities);
        var existing = await _knowYourData.GetByTenantIdAsync(
            connection.TenantId,
            cancellationToken);
        EnsureExpected(
            command.Request.ExpectedRowVersion,
            existing,
            existing?.Id ?? Guid.Empty,
            existing?.UpdatedAtUtc ?? default,
            existing?.RowVersion);

        var targetId = existing?.Id ?? Guid.NewGuid();
        var operation = CreateOperation(
            command.Actor,
            ProtectionAdminOperationType.CreateOrUpdateKnowYourData,
            ProtectionAdminTargetType.KnowYourDataConfiguration,
            targetId.ToString("D"),
            command.Request.ExpectedRowVersion,
            command.CorrelationId);
        var payload = new PurviewKnowYourDataReviewPayload(
            connection.Id,
            selection.Generation.Id.Value,
            selection.Item.SensitiveInformationTypeId.Value,
            selection.Item.ExactName,
            mode.ToString(),
            activities.Select(value => value.ToString()).ToArray(),
            command.Request.IngestionEnabled);
        return await PersistReviewAsync(
            operation,
            command.Request.ExpectedRowVersion,
            payload,
            new ProtectionOperationReviewSummaryDto(
                command.Actor.TenantId,
                operation.Type.ToString(),
                operation.TargetType.ToString(),
                operation.TargetIdentifier,
                BlueprintApplicationId: null,
                selection.Item.SensitiveInformationTypeId.Value,
                selection.Item.ExactName,
                mode.ToString(),
                payload.Activities,
                Actions: [],
                PurviewPolicyScopeType.Group.ToString(),
                PurviewEnforcementPlane.Application.ToString(),
                ProtectionAdministrationRules.ReadinessDisclaimer),
            cancellationToken);
    }

    public async Task<ProtectionOperationReviewResponse> Handle(
        ReviewPurviewDlpProfileCommand command,
        CancellationToken cancellationToken)
    {
        await ProtectionAdministrationRules.RequirePurviewCapabilityAsync(
            _capabilities,
            cancellationToken);
        var now = UtcNow();
        var connection = await ProtectionAdministrationRules.RequireConnectionAsync(
            _connections,
            command.Actor,
            command.Request.TenantConnectionId,
            now,
            mustBeUsable: true,
            cancellationToken);
        var selection =
            await ProtectionAdministrationRules.RequireInventorySelectionAsync(
                _inventory,
                connection,
                command.Request.SensitiveInformationType,
                now,
                cancellationToken);
        ProtectionAdministrationRules.EnsureBoundedDisplayName(
            command.Request.DisplayName);
        var mode = ProtectionAdministrationRules.ParseMode(command.Request.Mode);
        var activities = ProtectionAdministrationRules.ParseActivities(
            command.Request.Activities);
        var actions = ProtectionAdministrationRules.ParseActions(
            command.Request.Actions,
            activities);
        await EnsureBlueprintAsync(
            command.Request.BlueprintApplicationId,
            cancellationToken);

        PurviewDlpProfile? existing;
        if (command.Request.ProfileId is { } profileId)
        {
            if (profileId == Guid.Empty)
            {
                throw new ValidationException(new Dictionary<string, string[]>
                {
                    ["ProfileId"] = ["ProfileId must be a non-empty identifier."]
                });
            }

            existing = await _profiles.GetByIdAsync(
                new PurviewDlpProfileId(profileId),
                cancellationToken);
            if (existing is null ||
                existing.PurviewTenantConnectionId != connection.Id)
            {
                throw new NotFoundException("PurviewDlpProfile", profileId);
            }

            if (existing.BlueprintApplicationId.Value !=
                command.Request.BlueprintApplicationId)
            {
                throw new ConflictException(
                    "A DLP profile cannot be moved to a different blueprint application.",
                    ErrorCodes.PURVIEW_POLICY_PROFILE_CONFLICT);
            }
        }
        else
        {
            existing = await _profiles.GetByBlueprintApplicationIdAsync(
                new BlueprintApplicationId(
                    command.Request.BlueprintApplicationId),
                cancellationToken);
            if (existing is not null)
            {
                throw new ConflictException(
                    "This blueprint application already has a DLP profile.",
                    ErrorCodes.PURVIEW_POLICY_PROFILE_CONFLICT);
            }
        }

        EnsureExpected(
            command.Request.ExpectedRowVersion,
            existing,
            existing?.Id.Value ?? Guid.Empty,
            existing?.UpdatedAtUtc ?? default,
            existing?.RowVersion);

        var targetId = existing?.Id.Value ?? Guid.NewGuid();
        var operation = CreateOperation(
            command.Actor,
            ProtectionAdminOperationType.CreateOrUpdateDlpProfile,
            ProtectionAdminTargetType.DlpProfile,
            targetId.ToString("D"),
            command.Request.ExpectedRowVersion,
            command.CorrelationId);
        var payload = new PurviewDlpProfileReviewPayload(
            targetId,
            connection.Id,
            command.Request.BlueprintApplicationId,
            command.Request.DisplayName,
            selection.Generation.Id.Value,
            selection.Item.SensitiveInformationTypeId.Value,
            selection.Item.ExactName,
            mode.ToString(),
            activities.Select(value => value.ToString()).ToArray(),
            actions.Select(value => new PurviewDlpRuleActionDto(
                value.Activity.ToString(),
                value.Action.ToString())).ToArray());
        return await PersistReviewAsync(
            operation,
            command.Request.ExpectedRowVersion,
            payload,
            new ProtectionOperationReviewSummaryDto(
                command.Actor.TenantId,
                operation.Type.ToString(),
                operation.TargetType.ToString(),
                operation.TargetIdentifier,
                command.Request.BlueprintApplicationId,
                selection.Item.SensitiveInformationTypeId.Value,
                selection.Item.ExactName,
                mode.ToString(),
                payload.Activities,
                payload.Actions,
                PurviewPolicyScopeType.Individual.ToString(),
                PurviewEnforcementPlane.Application.ToString(),
                ProtectionAdministrationRules.ReadinessDisclaimer),
            cancellationToken);
    }

    public Task<ProtectionOperationReviewResponse> Handle(
        ReviewReconcilePurviewDlpProfileCommand command,
        CancellationToken cancellationToken) =>
        ReviewExistingDlpActionAsync(
            command.Actor,
            command.ProfileId,
            command.Request.ProfileId,
            command.Request.ExpectedRowVersion,
            ProtectionAdminOperationType.ReconcileDlpProfile,
            command.CorrelationId,
            cancellationToken);

    public Task<ProtectionOperationReviewResponse> Handle(
        ReviewValidatePurviewDlpRuntimeCommand command,
        CancellationToken cancellationToken) =>
        ReviewExistingDlpActionAsync(
            command.Actor,
            command.ProfileId,
            command.Request.ProfileId,
            command.Request.ExpectedRowVersion,
            ProtectionAdminOperationType.ValidateDlpRuntime,
            command.CorrelationId,
            cancellationToken);

    public async Task<ProtectionOperationConfirmationResponse> Handle(
        ConfirmProtectionOperationReviewCommand command,
        CancellationToken cancellationToken)
    {
        var operation = await _operations.GetByIdAsync(
            command.Request.ReviewTokenId,
            cancellationToken);
        EnsureOwnedAwaitingOperation(operation, command.Actor);
        await ProtectionAdministrationRules.RequirePurviewCapabilityAsync(
            _capabilities,
            cancellationToken);

        var confirmation = _tokens.ExchangeReview(
            operation!,
            command.Actor,
            command.Request.ReviewToken);
        await RecheckReviewAsync(
            operation!,
            command.Actor,
            confirmation.ExpectedRowVersion,
            confirmation.Payload,
            cancellationToken);

        operation!.ConfirmationVerifier = confirmation.Verifier;
        operation.UpdatedAtUtc = UtcNow();
        await AddAuditAsync(
            operation,
            "ProtectionOperationConfirmed",
            cancellationToken);
        await _unitOfWork.SaveChangesAsync(cancellationToken);

        return new ProtectionOperationConfirmationResponse(
            operation.Id,
            operation.Id,
            confirmation.Token,
            confirmation.ExpiresAtUtc);
    }

    private async Task<ProtectionOperationReviewResponse> PersistReviewAsync<T>(
        ProtectionAdminOperation operation,
        string expectedRowVersion,
        T payload,
        ProtectionOperationReviewSummaryDto summary,
        CancellationToken cancellationToken)
    {
        var issued = _tokens.IssueReview(
            operation,
            expectedRowVersion,
            payload);
        operation.ReviewedPayloadHash = issued.ReviewedPayloadHash;
        operation.ConfirmationVerifier = issued.Verifier;
        await _operations.AddAsync(operation, cancellationToken);
        await AddAuditAsync(
            operation,
            "ProtectionOperationReviewed",
            cancellationToken);
        await _unitOfWork.SaveChangesAsync(cancellationToken);
        return new ProtectionOperationReviewResponse(
            operation.Id,
            issued.Token,
            issued.ReviewedPayloadHash,
            issued.ExpiresAtUtc,
            summary);
    }

    private async Task RecheckReviewAsync(
        ProtectionAdminOperation operation,
        ProtectionActor actor,
        string expectedRowVersion,
        JsonElement payload,
        CancellationToken cancellationToken)
    {
        var now = UtcNow();
        switch (operation.Type)
        {
            case ProtectionAdminOperationType.ConnectPurviewTenant:
                {
                    var reviewed =
                        ProtectionAdministrationRules
                            .DeserializePayload<PurviewTenantConnectionReviewPayload>(
                                payload);
                    ProtectionAdministrationRules.EnsureTenant(actor, reviewed.TenantId);
                    var connection = await _connections.GetByTenantIdAsync(
                        new EntraTenantId(actor.TenantId),
                        cancellationToken);
                    EnsureExpected(
                        expectedRowVersion,
                        connection,
                        connection?.Id ?? Guid.Empty,
                        connection?.UpdatedAtUtc ?? default,
                        connection?.RowVersion);
                    break;
                }
            case ProtectionAdminOperationType.CompletePurviewTenantConnection:
                {
                    var reviewed =
                        ProtectionAdministrationRules
                            .DeserializePayload<PurviewTenantConnectionCompletionReviewPayload>(
                                payload);
                    var (_, connection, launch) =
                        await RequireActiveConnectionLaunchAsync(
                            actor,
                            reviewed.SourceOperationId,
                            cancellationToken);
                    if (launch.InventoryGenerationId !=
                            reviewed.InventoryGenerationId ||
                        launch.ExpiresAtUtc <= _timeProvider.GetUtcNow() ||
                        string.IsNullOrWhiteSpace(reviewed.EvidenceDigest))
                    {
                        throw new DomainException(
                            "The companion completion review binding changed.",
                            ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
                    }

                    EnsureExpected(
                        expectedRowVersion,
                        connection,
                        connection.Id,
                        connection.UpdatedAtUtc,
                        connection.RowVersion);
                    break;
                }
            case ProtectionAdminOperationType.CreateOrUpdateKnowYourData:
                {
                    var reviewed =
                        ProtectionAdministrationRules
                            .DeserializePayload<PurviewKnowYourDataReviewPayload>(
                                payload);
                    var connection =
                        await ProtectionAdministrationRules.RequireConnectionAsync(
                            _connections,
                            actor,
                            reviewed.TenantConnectionId,
                            now,
                            mustBeUsable: true,
                            cancellationToken);
                    await RecheckInventoryAsync(
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
                        expectedRowVersion,
                        configuration,
                        configuration?.Id ?? Guid.Empty,
                        configuration?.UpdatedAtUtc ?? default,
                        configuration?.RowVersion);
                    break;
                }
            case ProtectionAdminOperationType.CreateOrUpdateDlpProfile:
            case ProtectionAdminOperationType.ReconcileDlpProfile:
            case ProtectionAdminOperationType.ValidateDlpRuntime:
                {
                    var reviewed =
                        ProtectionAdministrationRules
                            .DeserializePayload<PurviewDlpProfileReviewPayload>(
                                payload);
                    var connection =
                        await ProtectionAdministrationRules.RequireConnectionAsync(
                            _connections,
                            actor,
                            reviewed.TenantConnectionId,
                            now,
                            mustBeUsable: true,
                            cancellationToken);
                    await RecheckInventoryAsync(
                        connection,
                        reviewed.InventoryGenerationId,
                        reviewed.SensitiveInformationTypeId,
                        reviewed.SensitiveInformationTypeName,
                        now,
                        cancellationToken);
                    await EnsureBlueprintAsync(
                        reviewed.BlueprintApplicationId,
                        cancellationToken);
                    var profile = await _profiles.GetByIdAsync(
                        new PurviewDlpProfileId(reviewed.ProfileId),
                        cancellationToken);
                    EnsureExpected(
                        expectedRowVersion,
                        profile,
                        profile?.Id.Value ?? Guid.Empty,
                        profile?.UpdatedAtUtc ?? default,
                        profile?.RowVersion);
                    break;
                }
            default:
                throw new DomainException(
                    "The protection operation review type is unsupported.",
                    ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }
    }

    private async Task RecheckInventoryAsync(
        PurviewTenantConnection connection,
        Guid generationId,
        Guid sensitiveInformationTypeId,
        string exactName,
        DateTime utcNow,
        CancellationToken cancellationToken)
    {
        await ProtectionAdministrationRules.RequireInventorySelectionAsync(
            _inventory,
            connection,
            new PurviewSensitiveInformationTypeSelectionDto(
                generationId,
                sensitiveInformationTypeId,
                exactName),
            utcNow,
            cancellationToken);
    }

    private async Task<ProtectionOperationReviewResponse>
        ReviewExistingDlpActionAsync(
            ProtectionActor actor,
            Guid routeProfileId,
            Guid requestProfileId,
            string expectedRowVersion,
            ProtectionAdminOperationType operationType,
            Guid correlationId,
            CancellationToken cancellationToken)
    {
        if (routeProfileId == Guid.Empty ||
            requestProfileId != routeProfileId)
        {
            throw new ValidationException(new Dictionary<string, string[]>
            {
                ["ProfileId"] =
                ["The request profile must match the exact route target."]
            });
        }

        await ProtectionAdministrationRules.RequirePurviewCapabilityAsync(
            _capabilities,
            cancellationToken);
        var profile = await _profiles.GetByIdAsync(
            new PurviewDlpProfileId(routeProfileId),
            cancellationToken)
            ?? throw new NotFoundException(
                "PurviewDlpProfile",
                routeProfileId);
        var now = UtcNow();
        var connection =
            await ProtectionAdministrationRules.RequireConnectionAsync(
                _connections,
                actor,
                profile.PurviewTenantConnectionId,
                now,
                mustBeUsable: true,
                cancellationToken);
        await RecheckInventoryAsync(
            connection,
            profile.InventoryGenerationId.Value,
            profile.SensitiveInformationTypeId.Value,
            profile.SensitiveInformationTypeName,
            now,
            cancellationToken);
        EnsureExpected(
            expectedRowVersion,
            profile,
            profile.Id.Value,
            profile.UpdatedAtUtc,
            profile.RowVersion);
        var payload = CreateDlpPayload(profile);
        ProtectionAdministrationRules.ParseActions(payload.Actions,
            ProtectionAdministrationRules.ParseActivities(payload.Activities));
        if (operationType == ProtectionAdminOperationType.ValidateDlpRuntime && profile.Mode != PurviewMode.Enforce)
        {
            throw new DomainException(
                "Enforce mode is required for the allow and block runtime check.",
                ErrorCodes.PURVIEW_DLP_PROFILE_NOT_READY);
        }
        var operation = CreateOperation(
            actor,
            operationType,
            ProtectionAdminTargetType.DlpProfile,
            profile.Id.Value.ToString("D"),
            expectedRowVersion,
            correlationId);
        return await PersistReviewAsync(
            operation,
            expectedRowVersion,
            payload,
            new ProtectionOperationReviewSummaryDto(
                actor.TenantId,
                operationType.ToString(),
                operation.TargetType.ToString(),
                operation.TargetIdentifier,
                profile.BlueprintApplicationId.Value,
                profile.SensitiveInformationTypeId.Value,
                profile.SensitiveInformationTypeName,
                profile.Mode.ToString(),
                payload.Activities,
                payload.Actions,
                PurviewPolicyScopeType.Individual.ToString(),
                PurviewEnforcementPlane.Application.ToString(),
                ProtectionAdministrationRules.ReadinessDisclaimer),
            cancellationToken);
    }

    private static PurviewDlpProfileReviewPayload CreateDlpPayload(
        PurviewDlpProfile profile) =>
        new(
            profile.Id.Value,
            profile.PurviewTenantConnectionId,
            profile.BlueprintApplicationId.Value,
            profile.DisplayName,
            profile.InventoryGenerationId.Value,
            profile.SensitiveInformationTypeId.Value,
            profile.SensitiveInformationTypeName,
            profile.Mode.ToString(),
            profile.Activities
                .OrderBy(value => value)
                .Select(value => value.ToString())
                .ToArray(),
            profile.Actions
                .OrderBy(value => value.Activity)
                .ThenBy(value => value.Action)
                .Select(value => new PurviewDlpRuleActionDto(
                    value.Activity.ToString(),
                    value.Action.ToString()))
                .ToArray());

    private async Task<(
        ProtectionAdminOperation Operation,
        PurviewTenantConnection Connection,
        PurviewCompanionLaunchDto Launch)>
        RequireActiveConnectionLaunchAsync(
            ProtectionActor actor,
            Guid sourceOperationId,
            CancellationToken cancellationToken)
    {
        var sourceOperation = await _operations.GetByIdAsync(
            sourceOperationId,
            cancellationToken);
        if (sourceOperation is null ||
            sourceOperation.Type !=
                ProtectionAdminOperationType.ConnectPurviewTenant ||
            sourceOperation.Status !=
                ProtectionAdminOperationStatus.AwaitingAdministrator ||
            sourceOperation.TenantId.Value != actor.TenantId ||
            !string.Equals(
                sourceOperation.ActorObjectId,
                actor.ObjectId,
                StringComparison.Ordinal) ||
            !string.Equals(
                sourceOperation.RequiredAction,
                ProtectionRequiredActionCodes.CompletePurviewTenantConnection,
                StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(sourceOperation.ResultJson))
        {
            throw new NotFoundException(
                "ProtectionAdminOperation",
                sourceOperationId);
        }

        var accepted =
            JsonSerializer.Deserialize<ProtectionOperationAcceptedResponse>(
                sourceOperation.ResultJson);
        var launch = accepted?.CompanionLaunch;
        if (launch is null ||
            launch.OperationId != sourceOperationId ||
            launch.InventoryGenerationId == Guid.Empty ||
            launch.ExpiresAtUtc.Offset != TimeSpan.Zero)
        {
            throw new DomainException(
                "The active companion launch binding is unavailable.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }

        if (!Guid.TryParse(
                sourceOperation.TargetIdentifier,
                out var connectionId) ||
            connectionId == Guid.Empty)
        {
            throw new DomainException(
                "The active companion connection target is invalid.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }

        var connection = await _connections.GetByIdAsync(
            connectionId,
            cancellationToken);
        if (connection is null ||
            connection.TenantId.Value != actor.TenantId ||
            connection.Status !=
                PurviewTenantConnectionStatus.AwaitingAdministrator)
        {
            throw new DomainException(
                "The Purview connection is not awaiting this companion.",
                ErrorCodes.PURVIEW_TENANT_NOT_CONNECTED);
        }

        return (sourceOperation, connection, launch);
    }

    private async Task EnsureBlueprintAsync(
        Guid blueprintApplicationId,
        CancellationToken cancellationToken)
    {
        if (blueprintApplicationId == Guid.Empty)
        {
            throw new ValidationException(new Dictionary<string, string[]>
            {
                ["BlueprintApplicationId"] =
                ["BlueprintApplicationId must be a non-empty identifier."]
            });
        }

        var blueprints = await _blueprints.ListAsync(cancellationToken);
        var matches = blueprints
            .Where(item => item.BlueprintClientId == blueprintApplicationId)
            .ToArray();
        if (matches.Length != 1 || !matches[0].IsAgent365Compatible)
        {
            throw new DomainException(
                "The selected blueprint application is absent or incompatible.",
                ErrorCodes.AGENT_IDENTITY_BLUEPRINT_INCOMPATIBLE);
        }
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

    private ProtectionAdminOperation CreateOperation(
        ProtectionActor actor,
        ProtectionAdminOperationType type,
        ProtectionAdminTargetType targetType,
        string targetIdentifier,
        string expectedRowVersion,
        Guid correlationId)
    {
        var now = UtcNow();
        var operation = new ProtectionAdminOperation
        {
            Id = Guid.NewGuid(),
            WorkflowVersion = ProtectionAdminWorkflow.CurrentVersion,
            Type = type,
            Status = ProtectionAdminOperationStatus.AwaitingConfirmation,
            TenantId = new EntraTenantId(actor.TenantId),
            ActorObjectId = actor.ObjectId,
            TargetType = targetType,
            TargetIdentifier = targetIdentifier,
            IdempotencyKey = new ProtectionIdempotencyKey(Guid.NewGuid()),
            ExpectedRowVersion =
                ProtectionRowVersion.DecodeExpected(expectedRowVersion),
            RetryDisposition = ProtectionRetryDisposition.NotApplicable,
            MaximumAttempts = 5,
            CorrelationId = correlationId == Guid.Empty
                ? Guid.NewGuid()
                : correlationId,
            CreatedAtUtc = now,
            UpdatedAtUtc = now
        };
        for (var index = 0;
             index < ProtectionAdminWorkflow.CurrentSteps.Count;
             index++)
        {
            operation.AddStep(new ProtectionAdminOperationStep
            {
                Id = Guid.NewGuid(),
                StepType = ProtectionAdminWorkflow.CurrentSteps[index],
                Status = index == 0
                    ? ProtectionAdminStepStatus.AwaitingConfirmation
                    : ProtectionAdminStepStatus.Pending,
                OrderIndex = index,
                RetryDisposition = ProtectionRetryDisposition.NotApplicable
            });
        }

        return operation;
    }

    private static void EnsureOwnedAwaitingOperation(
        ProtectionAdminOperation? operation,
        ProtectionActor actor)
    {
        if (operation is null ||
            operation.TenantId.Value != actor.TenantId ||
            !string.Equals(
                operation.ActorObjectId,
                actor.ObjectId,
                StringComparison.Ordinal))
        {
            throw new NotFoundException(
                "ProtectionAdminOperation",
                operation?.Id ?? Guid.Empty);
        }

        if (operation.Status != ProtectionAdminOperationStatus.AwaitingConfirmation)
        {
            throw new DomainException(
                "The protection operation is not awaiting confirmation.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }
    }

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

    private DateTime UtcNow() => _timeProvider.GetUtcNow().UtcDateTime;
}
