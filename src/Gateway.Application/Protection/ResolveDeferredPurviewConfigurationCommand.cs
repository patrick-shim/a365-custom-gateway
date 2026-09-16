using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using MediatR;

namespace Gateway.Application.Protection;

/// <summary>Internal worker continuation; never exposed as a control-plane endpoint.</summary>
public sealed record ResolveDeferredPurviewConfigurationCommand(Guid AgentId) : IRequest;

internal sealed class ResolveDeferredPurviewConfigurationHandler(
    IAgentRepository agents,
    IProtectionAdminOperationRepository operations,
    IPurviewDlpProfileRepository profiles,
    IPurviewTenantConnectionRepository connections,
    IPurviewSensitiveInformationTypeSnapshotRepository inventory,
    IOutboxRepository outbox,
    IAuditEventRepository audit,
    TimeProvider timeProvider) : IRequestHandler<ResolveDeferredPurviewConfigurationCommand>
{
    public async Task Handle(ResolveDeferredPurviewConfigurationCommand request, CancellationToken ct)
    {
        var agent = await agents.GetByIdAsync(request.AgentId, ct)
            ?? throw new NotFoundException("AgentRegistration", request.AgentId);
        if (agent.PurviewConfigurationOperationId is not { } operationId)
            return;
        var operation = await operations.GetByIdAsync(operationId, ct)
            ?? throw new NotFoundException("ProtectionAdminOperation", operationId);
        if (operation.Status != ProtectionAdminOperationStatus.AwaitingBlueprint)
            return;
        var pending = operation.DeferredConfiguration;
        if (pending is null || pending.AgentRegistrationId != agent.Id ||
            operation.Type != ProtectionAdminOperationType.CreateOrUpdateDlpProfile ||
            operation.ConfirmationVerifier?.ConsumedAtUtc is null ||
            operation.TargetIdentifier != pending.ProfileId.ToString("D") ||
            agent.Status != AgentStatus.Active || agent.IsDeleted ||
            agent.BlueprintSelectionMode != "CreateNew" ||
            agent.ExternalAgentId.Value != pending.ExternalAgentId ||
            agent.RequestedBlueprintDisplayName != pending.BlueprintDisplayName ||
            agent.CreatedByObjectId != operation.ActorObjectId ||
            !Guid.TryParse(agent.BlueprintObjectId, out var blueprintObjectId) || blueprintObjectId == Guid.Empty ||
            !Guid.TryParse(agent.BlueprintId, out var blueprintId) || blueprintId == Guid.Empty)
            throw new DomainException("Deferred consent is not bound to a completed new blueprint registration.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);

        var selected = pending.SensitiveInformationTypes.OrderBy(value => value.Id).ToArray();
        var payload = new PurviewDlpProfileReviewPayload(pending.ProfileId, pending.TenantConnectionId,
            Guid.Empty, pending.DisplayName, pending.InventoryGenerationId, selected[0].Id, selected[0].ExactName,
            pending.PolicyMode.ToLegacy().ToString(), pending.Activities.Select(value => value.ToString()).ToArray(),
            pending.Actions.Select(value => new PurviewDlpRuleActionDto(value.Activity.ToString(), value.Action.ToString())).ToArray(),
            pending.PolicyMode.ToString(),
            selected.Select(value => new PurviewSensitiveInformationTypeSelectionDto(pending.InventoryGenerationId, value.Id, value.ExactName,
                value.MinCount, value.MaxCount, value.MinConfidence, value.MaxConfidence)).ToArray(),
            new PurviewDeferredBlueprintDto(pending.ExternalAgentId, pending.BlueprintDisplayName));
        var originalHash = ProtectionOperationTokenService.ComputePayloadHash(
            JsonSerializer.SerializeToElement(payload, ProtectionAdministrationRules.JsonOptions));
        if (originalHash != pending.SourceReviewedPayloadHash || originalHash != operation.ReviewedPayloadHash)
            throw new DomainException("Deferred reviewed intent changed.", ErrorCodes.PROTECTION_CONFIRMATION_INVALID);

        var now = timeProvider.GetUtcNow().UtcDateTime;
        var existing = await profiles.GetByBlueprintApplicationIdAsync(new BlueprintApplicationId(blueprintId), ct);
        if (existing is not null)
        {
            operation.Status = ProtectionAdminOperationStatus.RequiresManualIntervention;
            operation.RetryDisposition = ProtectionRetryDisposition.RequiresManualIntervention;
            operation.LastFailureCode = ErrorCodes.PURVIEW_POLICY_PROFILE_CONFLICT;
            operation.RequiredAction = ProtectionRequiredActionCodes.ReviewExistingSharedPolicy;
            operation.UpdatedAtUtc = now;
            return;
        }

        // Inventory/authority expiry is an explicit blocked state, never permission to call the provider.
        try
        {
            var connection = await ProtectionAdministrationRules.RequireConnectionAsync(connections,
                new ProtectionActor(operation.TenantId.Value, operation.ActorObjectId),
                pending.TenantConnectionId, now, true, ct);
            var validated = await ProtectionAdministrationRules.RequireInventorySelectionsAsync(inventory,
                connection, ProtectionAdministrationRules.DlpSelections(payload), now, ct);
            var profile = new PurviewDlpProfile
            {
                Id = new PurviewDlpProfileId(pending.ProfileId),
                PurviewTenantConnectionId = pending.TenantConnectionId,
                BlueprintApplicationId = new BlueprintApplicationId(blueprintId),
                DisplayName = pending.DisplayName,
                InventoryGenerationId = new SensitiveInformationTypeSnapshotGenerationId(pending.InventoryGenerationId),
                SensitiveInformationTypeSnapshotExpiresAtUtc = validated[0].Generation.ExpiresAtUtc,
                SensitiveInformationTypeId = new SensitiveInformationTypeId(selected[0].Id),
                SensitiveInformationTypeName = selected[0].ExactName,
                SensitiveInformationTypes = selected.ToList(),
                Mode = pending.PolicyMode.ToLegacy(),
                PolicyMode = pending.PolicyMode,
                Activities = pending.Activities.ToList(),
                Actions = pending.Actions.ToList(),
                Status = PurviewDlpProfileStatus.Pending,
                Readiness = new ProtectionReadiness(ProtectionCapabilityStatus.Installed, ProtectionReadbackStatus.Pending,
                    ProtectionPropagationStatus.NotChecked, ProtectionTokenRoleStatus.NotChecked, ProtectionRuntimeVerdictStatus.NotChecked),
                CreatedAtUtc = now,
                UpdatedAtUtc = now
            };
            await profiles.AddAsync(profile, ct);
            var boundPayload = payload with { BlueprintApplicationId = blueprintId, DeferredBlueprint = null };
            operation.ReviewedPayloadHash = ProtectionOperationTokenService.ComputePayloadHash(
                JsonSerializer.SerializeToElement(boundPayload, ProtectionAdministrationRules.JsonOptions));
            operation.Status = ProtectionAdminOperationStatus.Pending;
            operation.RequiredAction = null;
            operation.LastFailureCode = null;
            operation.UpdatedAtUtc = now;
            await outbox.AddAsync(new OutboxMessage
            {
                Id = Guid.NewGuid(),
                MessageType = nameof(ProtectionAdminOperationMessage),
                Payload = JsonSerializer.Serialize(new ProtectionAdminOperationMessage(operation.Id,
                    ProtectionAdminWorkflow.CurrentVersion, 0, operation.CorrelationId),
                    ProtectionAdministrationRules.JsonOptions),
                Status = OutboxMessageStatus.Pending,
                CreatedAtUtc = now
            }, ct);
            await audit.AddAsync(new AuditEvent
            {
                Id = Guid.NewGuid(), AgentRegistrationId = agent.Id, EventType = "DeferredPurviewConsentBound",
                PerformedByObjectId = operation.ActorObjectId, OccurredAtUtc = now,
                Details = JsonSerializer.Serialize(new DeferredBindingAudit(operation.Id, blueprintId, pending.SourceReviewedPayloadHash))
            }, ct);
        }
        catch (DomainException exception)
        {
            operation.Status = ProtectionAdminOperationStatus.RequiresManualIntervention;
            operation.RetryDisposition = ProtectionRetryDisposition.RequiresManualIntervention;
            operation.LastFailureCode = exception.ErrorCode;
            operation.RequiredAction = ProtectionRequiredActionCodes.RefreshInventoryAndReviewPolicyForResolvedBlueprint;
            operation.UpdatedAtUtc = now;
        }
        // The worker commits this continuation atomically with provisioning completion.
    }

    private sealed record DeferredBindingAudit(Guid OperationId, Guid BlueprintApplicationId, string SourceReviewedPayloadHash);
}
