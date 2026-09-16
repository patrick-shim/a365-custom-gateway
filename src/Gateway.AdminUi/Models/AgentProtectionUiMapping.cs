using Gateway.Contracts.Dtos;

namespace Gateway.AdminUi.Models;

public static class AgentProtectionUiMapping
{
    public static string ServerPolicyMode(PurviewPolicyMode mode) => mode switch
    {
        PurviewPolicyMode.Enforce => "Enforce",
        PurviewPolicyMode.SimulationWithPolicyTips => "SimulationWithTips",
        PurviewPolicyMode.SilentSimulation => "SimulationWithoutTips",
        PurviewPolicyMode.CreateButLeaveOff => "Disabled",
        _ => throw new ArgumentOutOfRangeException(nameof(mode))
    };

    public static PurviewPolicyMode? PolicyMode(string? policyMode, string? legacyMode) => policyMode switch
    {
        "Enforce" => PurviewPolicyMode.Enforce,
        "SimulationWithTips" => PurviewPolicyMode.SimulationWithPolicyTips,
        "SimulationWithoutTips" => PurviewPolicyMode.SilentSimulation,
        "Disabled" => PurviewPolicyMode.CreateButLeaveOff,
        null or "" => legacyMode == "Enforce" ? PurviewPolicyMode.Enforce : PurviewPolicyMode.SilentSimulation,
        _ => null
    };

    public static string LegacyMode(PurviewPolicyMode? mode) => mode == PurviewPolicyMode.Enforce ? "Enforce" : "AuditOnly";

    public static bool IsSimulation(string? mode, string? legacyMode = null) =>
        (!string.IsNullOrWhiteSpace(mode) || !string.IsNullOrWhiteSpace(legacyMode)) &&
        PolicyMode(mode, legacyMode) is PurviewPolicyMode.SimulationWithPolicyTips or PurviewPolicyMode.SilentSimulation;

    public static bool VerifiedNonEnforcingConfiguration(PurviewDlpProfileDto profile) =>
        PolicyMode(profile.PolicyMode, profile.Mode) is PurviewPolicyMode.SimulationWithPolicyTips or PurviewPolicyMode.SilentSimulation or PurviewPolicyMode.CreateButLeaveOff &&
        profile.Status is "SimulationReady" or "Disabled" &&
        profile.Readiness.Readback == "Ready" && profile.LastReadbackAtUtc is not null &&
        !string.IsNullOrWhiteSpace(profile.DlpPolicyProviderId) && !string.IsNullOrWhiteSpace(profile.DlpRuleProviderId);

    public static IReadOnlyList<string> ActionableReadinessBlockers(ProtectionReadinessDto readiness, string? policyMode) =>
        readiness.Blockers.Where(blocker => !((IsSimulation(policyMode) || policyMode == "Disabled") &&
            (blocker is "PURVIEW_POLICY_SIMULATION" or "PURVIEW_POLICY_DISABLED" or "PURVIEW_RUNTIME_VERDICT_NOT_READY" or
                "PURVIEW_RUNTIME_SAMPLES_REQUIRED" or "RuntimeValidationRequired" or "RuntimeNotTested" ||
             blocker == "PURVIEW_POLICY_PROPAGATION_NOT_READY" && readiness.Propagation == "NotChecked" ||
             blocker == "PURVIEW_TOKEN_ROLES_NOT_READY" && readiness.TokenRoles == "NotChecked"))).ToArray();

    public static bool ConfiguredSimulationFacts(ProtectionReadinessDto readiness, string? status, string? policyMode) =>
        IsSimulation(policyMode) && status == "SimulationReady" && readiness.Capability == "Installed" &&
        readiness.Readback == "Ready" && ActionableReadinessBlockers(readiness, policyMode).Count == 0;

    public static bool SimulationCapabilityUnavailable(ProtectionReadinessDto readiness) =>
        readiness.Capability is "Unavailable" or "NotInstalled" ||
        readiness.Blockers.Any(blocker => blocker is "PROTECTION_CAPABILITY_UNAVAILABLE" or
            "CapabilityUnavailable" or "CapabilityNotInstalled");

    public static IReadOnlyList<PurviewSensitiveInformationTypeSelectionDto> Types(PurviewDlpProfileDto profile) =>
        profile.SensitiveInformationTypes is { Count: > 0 } types ? types :
        [new(Guid.Empty, profile.SensitiveInformationTypeId, profile.SensitiveInformationTypeName)];

    public static bool HasExplicitThresholds(PurviewSensitiveInformationTypeSelectionDto item) =>
        HasExplicitThresholds(new AgentProtectionSitThresholds(item.MinCount, item.MaxCount, item.MinConfidence, item.MaxConfidence));

    public static bool HasExplicitThresholds(AgentProtectionSitThresholds? item) =>
        item is not null && item.MinCount is > 0 &&
        item.MaxCount is { } maxCount && (maxCount == -1 || maxCount >= item.MinCount) &&
        item.MinConfidence is >= 1 and <= 100 && item.MaxConfidence is >= 1 and <= 100 &&
        item.MaxConfidence >= item.MinConfidence;

    public static bool HasValidSuppliedThresholds(AgentProtectionSitThresholds? item) =>
        item is null ||
        (item.MinCount is null or > 0 && item.MaxCount is null or -1 or > 0 &&
         item.MinConfidence is null or (>= 1 and <= 100) && item.MaxConfidence is null or (>= 1 and <= 100) &&
         (item.MinCount is null || item.MaxCount is null or -1 || item.MaxCount >= item.MinCount) &&
         (item.MinConfidence is null || item.MaxConfidence is null || item.MaxConfidence >= item.MinConfidence));

    public static AgentProtectionSelection Selection(Guid? blueprintId, AgentFeaturesDto? features, PurviewDlpProfileDto? profile) => new()
    {
        BlueprintId = blueprintId,
        PromptShieldsEnabled = features?.PromptShieldEnabled == true,
        PurviewEnabled = features?.PurviewEnabled == true,
        PolicyMode = profile is null && features?.PurviewPolicyMode is null && features?.PurviewMode is null
            ? null : PolicyMode(profile?.PolicyMode ?? features?.PurviewPolicyMode, profile?.Mode ?? features?.PurviewMode),
        SensitiveInformationTypeIds = profile is null ? [] : Types(profile).Select(item => item.SensitiveInformationTypeId.ToString("D")).ToArray(),
        SensitiveInformationTypeThresholds = profile is null ? new Dictionary<string, AgentProtectionSitThresholds>() :
            Types(profile).ToDictionary(item => item.SensitiveInformationTypeId.ToString("D"),
                item => new AgentProtectionSitThresholds(item.MinCount, item.MaxCount, item.MinConfidence, item.MaxConfidence))
    };

    public static AgentProtectionReadinessState ReadinessState(string? status, bool ready) => status switch
    {
        "Disabled" => AgentProtectionReadinessState.ConfiguredOff,
        "SimulationReady" => AgentProtectionReadinessState.ConfiguredSimulation,
        "Failed" or "VerificationFailed" or "RequiresManualIntervention" => AgentProtectionReadinessState.Error,
        "AwaitingBlueprint" or "Pending" or "PendingPropagation" or "WaitingForPropagation" or "Queued" or "Running" => AgentProtectionReadinessState.Pending,
        _ => ready ? AgentProtectionReadinessState.Ready : AgentProtectionReadinessState.Unverified
    };

    public static bool CurrentReadiness(PurviewDlpProfileDto profile) =>
        profile.Readiness.IsReady &&
        (profile.RuntimeBehaviorVerifiedUntilUtc is null || profile.RuntimeBehaviorVerifiedUntilUtc > DateTime.UtcNow);

    public static string PolicyLabel(string? mode, string? legacy = null) => PolicyMode(mode, legacy) switch
    {
        PurviewPolicyMode.Enforce => "Enforce",
        PurviewPolicyMode.SimulationWithPolicyTips => "Simulation with policy tips where supported",
        PurviewPolicyMode.SilentSimulation => "Silent simulation",
        PurviewPolicyMode.CreateButLeaveOff => "Configured off",
        _ => "Unknown policy mode — review required"
    };
}
