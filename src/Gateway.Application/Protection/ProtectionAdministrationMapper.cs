using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;

namespace Gateway.Application.Protection;

internal static class ProtectionAdministrationMapper
{
    public static ProtectionCapabilityDto ToDto(ProtectionCapability capability) => new(
        capability.Id,
        capability.Kind.ToString(),
        capability.Status.ToString(),
        new ProtectionCapabilityResourceIdentifiersDto(
            capability.ResourceIdentifiers.Agent365RegistryApiApplicationId?.Value,
            capability.ResourceIdentifiers.ContentSafetyAccountResourceId,
            capability.ResourceIdentifiers.ContentSafetyEndpoint,
            capability.ResourceIdentifiers.GatewayApiManagedIdentityPrincipalObjectId?.Value,
            capability.ResourceIdentifiers.PurviewRuntimeManagedIdentityPrincipalObjectId?.Value,
            capability.ResourceIdentifiers.PurviewAutomationApplicationId?.Value,
            capability.ResourceIdentifiers.PurviewAutomationServicePrincipalObjectId?.Value,
            capability.ResourceIdentifiers.KeyVaultResourceId,
            capability.ResourceIdentifiers.CertificateName),
        capability.LastReadbackAtUtc,
        capability.LastFailureCode,
        ProtectionRowVersion.Encode(
            capability.RowVersion,
            capability.Id,
            capability.UpdatedAtUtc));

    public static PurviewTenantConnectionDto ToDto(PurviewTenantConnection connection) => new(
        connection.Id,
        connection.TenantId.Value,
        connection.Status.ToString(),
        connection.AuthorityKind,
        connection.AuthorityApplicationId?.Value,
        connection.AuthorityServicePrincipalObjectId?.Value,
        connection.ActiveInventoryGenerationId?.Value,
        connection.AuthorizedAtUtc,
        connection.ExpiresAtUtc,
        connection.LastVerifiedAtUtc,
        connection.LastFailureCode,
        ProtectionRowVersion.Encode(
            connection.RowVersion,
            connection.Id,
            connection.UpdatedAtUtc));

    public static PurviewKnowYourDataConfigurationDto ToDto(
        PurviewKnowYourDataConfiguration configuration) => new(
        configuration.Id,
        configuration.PurviewTenantConnectionId,
        configuration.GroupId,
        configuration.ScopeType.ToString(),
        configuration.EnforcementPlane.ToString(),
        configuration.InventoryGenerationId.Value,
        configuration.SensitiveInformationTypeId.Value,
        configuration.SensitiveInformationTypeName,
        configuration.Mode.ToString(),
        configuration.Activities
            .OrderBy(activity => activity)
            .Select(activity => activity.ToString())
            .ToArray(),
        configuration.IngestionEnabled,
        configuration.Status.ToString(),
        configuration.ReadbackStatus.ToString(),
        configuration.CollectionPolicyProviderId,
        configuration.LastReadbackAtUtc,
        configuration.LastFailureCode,
        ProtectionRowVersion.Encode(
            configuration.RowVersion,
            configuration.Id,
            configuration.UpdatedAtUtc));

    public static PurviewDlpProfileDto ToDto(
        PurviewDlpProfile profile,
        DateTime? evaluationTimeUtc = null)
    {
        var utcNow = evaluationTimeUtc ?? DateTime.UtcNow;
        var blockers = GetReadinessBlockers(profile, utcNow).ToArray();
        var evaluatedAtUtc = new[]
            {
                profile.LastReadbackAtUtc,
                profile.PropagationVerifiedAtUtc,
                profile.TokenRolesVerifiedAtUtc,
                profile.RuntimeAllowVerifiedAtUtc,
                profile.RuntimeBlockVerifiedAtUtc
            }
            .Where(value => value is not null)
            .Max();

        return new PurviewDlpProfileDto(
            profile.Id.Value,
            profile.BlueprintApplicationId.Value,
            profile.DisplayName,
            profile.SensitiveInformationTypeId.Value,
            profile.SensitiveInformationTypeName,
            profile.Mode.ToString(),
            profile.Activities
                .OrderBy(activity => activity)
                .Select(activity => activity.ToString())
                .ToArray(),
            profile.Actions
                .OrderBy(action => action.Activity)
                .ThenBy(action => action.Action)
                .Select(action => new PurviewDlpRuleActionDto(
                    action.Activity.ToString(),
                    action.Action.ToString()))
                .ToArray(),
            profile.Status.ToString(),
            new ProtectionReadinessDto(
                profile.Readiness.Capability.ToString(),
                profile.Readiness.Readback.ToString(),
                profile.Readiness.Propagation.ToString(),
                profile.Readiness.TokenRoles.ToString(),
                profile.Readiness.RuntimeVerdict.ToString(),
                profile.IsExactlyReadyFor(
                    profile.BlueprintApplicationId,
                    utcNow),
                blockers,
                evaluatedAtUtc,
                CapabilityReadbackAtUtc: null,
                PolicyReadbackAtUtc: profile.LastReadbackAtUtc,
                PropagationVerifiedAtUtc: profile.PropagationVerifiedAtUtc,
                TokenRolesVerifiedAtUtc: profile.TokenRolesVerifiedAtUtc,
                RuntimeAllowVerifiedAtUtc: profile.RuntimeAllowVerifiedAtUtc,
                RuntimeBlockVerifiedAtUtc: profile.RuntimeBlockVerifiedAtUtc),
            profile.DlpPolicyProviderId,
            profile.DlpRuleProviderId,
            profile.LastReadbackAtUtc,
            ProtectionRowVersion.Encode(
                profile.RowVersion,
                profile.Id.Value,
                profile.UpdatedAtUtc));
    }

    public static ProtectionAdminOperationDto ToDto(
        ProtectionAdminOperation operation,
        DateTime utcNow)
    {
        var blockers = operation.LastFailureCode is null
            ? Array.Empty<string>()
            : new[] { operation.LastFailureCode };
        return new ProtectionAdminOperationDto(
            operation.Id,
            operation.WorkflowVersion,
            operation.Type.ToString(),
            operation.Status.ToString(),
            operation.TenantId.Value,
            operation.ActorObjectId,
            operation.TargetType.ToString(),
            operation.TargetIdentifier,
            operation.ReviewedPayloadHash,
            operation.IdempotencyKey.Value,
            ProtectionRowVersion.EncodeExpected(operation.ExpectedRowVersion),
            operation.RetryDisposition.ToString(),
            operation.AttemptCount,
            operation.MaximumAttempts,
            operation.NextAttemptAtUtc,
            operation.CanRetryAt(utcNow),
            operation.RequiresManualIntervention,
            operation.CorrelationId,
            operation.ReadbackReferenceId,
            operation.LastFailureCode,
            operation.RequiredAction,
            blockers,
            operation.CreatedAtUtc,
            operation.StartedAtUtc,
            operation.CompletedAtUtc,
            operation.UpdatedAtUtc,
            operation.OrderedSteps.Select(step => new ProtectionAdminOperationStepDto(
                step.Id,
                step.OrderIndex,
                step.StepType.ToString(),
                step.Status.ToString(),
                step.AttemptCount,
                step.RetryDisposition.ToString(),
                step.NextAttemptAtUtc,
                step.CanRetryAt(utcNow, operation.MaximumAttempts),
                step.RequiresManualIntervention,
                step.ReadbackReferenceId,
                step.FailureCode,
                step.StartedAtUtc,
                step.CompletedAtUtc)).ToArray(),
            ProtectionRowVersion.Encode(
                operation.RowVersion,
                operation.Id,
                operation.UpdatedAtUtc));
    }

    private static IEnumerable<string> GetReadinessBlockers(
        PurviewDlpProfile profile,
        DateTime utcNow)
    {
        if (profile.Readiness.Capability != ProtectionCapabilityStatus.Installed)
            yield return ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE;
        if (profile.Readiness.Readback != ProtectionReadbackStatus.Ready)
            yield return "PURVIEW_POLICY_READBACK_NOT_READY";
        if (profile.Readiness.Propagation != ProtectionPropagationStatus.Ready)
            yield return "PURVIEW_POLICY_PROPAGATION_NOT_READY";
        if (profile.Readiness.TokenRoles != ProtectionTokenRoleStatus.Ready)
            yield return "PURVIEW_TOKEN_ROLES_NOT_READY";
        if (profile.Readiness.RuntimeVerdict != ProtectionRuntimeVerdictStatus.Ready)
            yield return "PURVIEW_RUNTIME_VERDICT_NOT_READY";
        if (utcNow >= profile.SensitiveInformationTypeSnapshotExpiresAtUtc)
            yield return ErrorCodes.PURVIEW_INVENTORY_STALE;
    }
}
