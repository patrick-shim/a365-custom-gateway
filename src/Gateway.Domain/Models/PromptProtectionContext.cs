using System.Security.Cryptography;
using System.Text.Json;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;

namespace Gateway.Domain.Models;

// Only immutable digests and scalar decisions escape the snapshot reader. No prompt or response is included.
public sealed record PromptProtectionContext(
    Guid AgentRegistrationId,
    Guid ProtectionRevision,
    string AgentConfigurationHash,
    string Hash,
    bool PromptShieldRequired,
    PurviewPolicyMode PurviewMode,
    DateTime? ValidUntilUtc,
    bool AgentActive)
{
    public PurviewRuntimeCertificationBinding? RuntimeCertificationBinding { get; init; }
    public Guid? PurviewBlueprintApplicationId { get; init; }
    public bool RequiresReceipt => PromptShieldRequired || PurviewMode == PurviewPolicyMode.Enforce;

    public bool MatchesAgent(AgentRegistration agent) =>
        AgentRegistrationId == agent.Id &&
        string.Equals(AgentConfigurationHash, ComputeAgentConfigurationHash(agent), StringComparison.Ordinal);

    public bool IsCurrentAt(DateTime utcNow) =>
        AgentActive && ProtectionRevision != Guid.Empty &&
        (ValidUntilUtc is null || utcNow < ValidUntilUtc);

    public bool MatchesReceipt(PromptEvaluationRecord receipt, DateTime utcNow) =>
        IsCurrentAt(utcNow) &&
        receipt.AgentRegistrationId == AgentRegistrationId &&
        receipt.ProtectionRevision == ProtectionRevision &&
        receipt.ProtectionContextHash == Hash &&
        receipt.PromptShieldRequired == PromptShieldRequired &&
        receipt.EvaluatedPurviewPolicyMode == PurviewMode &&
        receipt.Outcome == PromptEvaluationOutcome.Allowed &&
        (!PromptShieldRequired || receipt.PromptShieldDecision == PromptShieldDecisionType.Allowed) &&
        (PurviewMode != PurviewPolicyMode.Enforce || receipt.PurviewDecision == PurviewDecisionType.Allowed) &&
        receipt.ConsumedAtUtc is null && utcNow < receipt.ExpiresAtUtc;

    public static string ComputeAgentConfigurationHash(AgentRegistration agent) => Digest(new
    {
        agent.Id,
        ExternalAgentId = agent.ExternalAgentId.Value,
        agent.ProtectionRevision,
        agent.Status,
        agent.IsDeleted,
        agent.Agent365AgentId,
        agent.BlueprintId,
        agent.FeatureConfiguration.PromptShieldEnabled,
        agent.FeatureConfiguration.PurviewEnabled,
        agent.FeatureConfiguration.PurviewMode,
        agent.RequestedPurviewPolicyMode,
        agent.RequestedPurviewPolicyProfileId,
        agent.PurviewPolicyProfileId
    });

    public static PromptProtectionContext Capture(
        AgentRegistration agent,
        PurviewDlpProfile? profile = null,
        ProtectionCapability? promptShieldCapability = null,
        ProtectionCapability? purviewCapability = null,
        PurviewTenantConnection? connection = null,
        PurviewSensitiveInformationTypeSnapshotGeneration? inventory = null,
        ProtectionAdminOperation? certification = null,
        PurviewRuntimeCertificationBinding? runtimeCertification = null)
    {
        var mode = !agent.FeatureConfiguration.PurviewEnabled ? PurviewPolicyMode.Disabled
            : profile?.EffectivePolicyMode ?? agent.RequestedPurviewPolicyMode ??
                PurviewPolicyModeCompatibility.FromLegacy(agent.FeatureConfiguration.PurviewMode ?? Enums.PurviewMode.Enforce);
        var purviewActive = agent.FeatureConfiguration.PurviewEnabled && mode != PurviewPolicyMode.Disabled;
        var agentHash = ComputeAgentConfigurationHash(agent);
        var hash = Digest(new
        {
            Version = 1,
            Agent = agentHash,
            Mode = mode,
            RuntimeCertification = mode == PurviewPolicyMode.Enforce ? runtimeCertification : null,
            PromptShieldCapability = agent.FeatureConfiguration.PromptShieldEnabled ? CapabilityBinding(promptShieldCapability) : null,
            PurviewCapability = purviewActive ? CapabilityBinding(purviewCapability) : null,
            Profile = agent.FeatureConfiguration.PurviewEnabled && profile is not null ? new
            {
                profile.Id,
                profile.BlueprintApplicationId,
                profile.PurviewTenantConnectionId,
                profile.InventoryGenerationId,
                profile.SensitiveInformationTypeSnapshotExpiresAtUtc,
                profile.EffectivePolicyMode,
                SelectedTypes = profile.NormalizedSensitiveInformationTypes,
                Activities = profile.Activities.OrderBy(value => value).ToArray(),
                Actions = profile.Actions.OrderBy(value => value.Activity).ThenBy(value => value.Action).ToArray(),
                profile.Status,
                profile.Readiness,
                profile.DlpPolicyProviderId,
                profile.DlpRuleProviderId,
                profile.LastReadbackAtUtc,
                profile.PropagationVerifiedAtUtc,
                profile.TokenRolesVerifiedAtUtc,
                profile.RuntimeAllowVerifiedAtUtc,
                profile.RuntimeBlockVerifiedAtUtc,
                profile.RuntimeBehaviorSuiteHash,
                profile.RuntimeBehaviorVerifiedUntilUtc,
                profile.RuntimeBehaviorCertificationOperationId,
                profile.RowVersion
            } : null,
            Connection = purviewActive && connection is not null ? new
            {
                connection.Id,
                connection.TenantId,
                connection.Status,
                connection.AuthorityApplicationId,
                connection.AuthorityServicePrincipalObjectId,
                connection.AuthorityKind,
                connection.ActiveInventoryGenerationId,
                connection.AuthorizedAtUtc,
                connection.ExpiresAtUtc,
                connection.LastVerifiedAtUtc,
                connection.RowVersion
            } : null,
            Inventory = purviewActive && inventory is not null ? new
            {
                inventory.Id,
                inventory.PurviewTenantConnectionId,
                inventory.TenantId,
                inventory.RetrievedAtUtc,
                inventory.ExpiresAtUtc,
                inventory.ItemCount,
                Items = inventory.Items.OrderBy(item => item.Id).Select(item => new
                {
                    item.Id, item.GenerationId, item.SensitiveInformationTypeId, item.ExactName
                }).ToArray()
            } : null,
            Certification = purviewActive && certification is not null ? new
            {
                certification.Id,
                certification.Status,
                certification.TargetIdentifier,
                certification.RuntimeTestSuiteHash,
                certification.RuntimeTestConfigurationFingerprint,
                certification.CompletedAtUtc,
                certification.RowVersion
            } : null
        });
        var deadlines = mode == PurviewPolicyMode.Enforce
            ? new[] { profile?.SensitiveInformationTypeSnapshotExpiresAtUtc, profile?.RuntimeBehaviorVerifiedUntilUtc,
                connection?.ExpiresAtUtc, inventory?.ExpiresAtUtc, runtimeCertification?.ValidUntilUtc.UtcDateTime }
                .Where(value => value.HasValue).Select(value => value!.Value).ToArray()
            : [];
        return new(agent.Id, agent.ProtectionRevision, agentHash, hash,
            agent.FeatureConfiguration.PromptShieldEnabled, mode,
            deadlines.Length == 0 ? null : deadlines.Min(),
            agent.Status == AgentStatus.Active && !agent.IsDeleted)
        {
            RuntimeCertificationBinding = mode == PurviewPolicyMode.Enforce ? runtimeCertification : null,
            PurviewBlueprintApplicationId = agent.FeatureConfiguration.PurviewEnabled && Guid.TryParse(agent.BlueprintId, out var blueprint)
                ? blueprint : null
        };
    }

    private static object? CapabilityBinding(ProtectionCapability? capability) =>
        capability is null ? null : new
        {
            capability.Id, capability.Kind, capability.Status, capability.ResourceIdentifiers,
            capability.LastReadbackAtUtc, capability.RowVersion
        };

    private static string Digest<T>(T value) =>
        Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(value)));
}
