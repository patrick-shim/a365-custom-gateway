using Gateway.Contracts.Dtos;

namespace Gateway.AdminUi.Models;

public sealed record ProtectionStateView(
    string Capability,
    string Requested,
    string Current,
    string Explanation);

public static class ProtectionStateProjection
{
    public static ProtectionStateView PromptShields(AgentFeaturesDto? features, string? registrationStatus)
    {
        var capability = Capability(features?.PromptShieldCapabilityStatus);
        if (features?.PromptShieldEnabled is not { } requested)
            return new(capability, "Unknown", "Unknown", "Refresh the saved protection choices. Unknown is not Off.");
        if (!requested)
            return new(capability, "Off", "Off", "Prompt Shields is intentionally off. This is not an incomplete registration.");
        if (registrationStatus is not null && registrationStatus != "Active")
            return new(capability, "On", "Registration not active", "The saved choice is unchanged; this registration is not accepting active Gateway traffic.");
        return features.PromptShieldEffectivelyEnabled && features.PromptShieldCapabilityStatus == "Installed"
            ? new(capability, "On", "Ready for evaluation", "Evaluate each prompt before the model. Readiness does not mean every prompt will be allowed.")
            : new(capability, "On", "Unavailable", "Administrator: check the installed Prompt Shields binding. The requested On choice has not been changed.");
    }

    public static ProtectionStateView Purview(AgentFeaturesDto? features, string? registrationStatus, DateTime utcNow) =>
        Purview(features?.PurviewEnabled, features?.PurviewPolicyMode, features?.PurviewMode,
            features?.PurviewProfileStatus, features?.PurviewReadiness,
            features?.PurviewEffectivelyEnabled == true, features?.PurviewConfigurationStatus,
            registrationStatus, utcNow);

    public static ProtectionStateView Profile(PurviewDlpProfileDto profile, DateTime utcNow) =>
        Purview(true, profile.PolicyMode, profile.Mode, profile.Status, profile.Readiness,
            profile.Readiness.IsReady, null, null, utcNow);

    public static ProtectionStateView Readiness(
        ProtectionReadinessDto readiness, string? policyMode, string? profileStatus, DateTime utcNow) =>
        Purview(true, policyMode, null, profileStatus, readiness, readiness.IsReady, null, null, utcNow);

    private static ProtectionStateView Purview(
        bool? enabled, string? policyMode, string? legacyMode, string? profileStatus,
        ProtectionReadinessDto? readiness, bool effectivelyEnabled, string? operationStatus,
        string? registrationStatus, DateTime utcNow)
    {
        var capability = Capability(readiness?.Capability);
        if (enabled is null)
            return new(capability, "Unknown", "Unknown", "Refresh the saved protection choices. Unknown is not Off.");
        if (!enabled.Value)
            return new(capability, "Off", "Off", "Microsoft Purview is intentionally off for this agent. Core registration can be complete.");

        var mode = policyMode ?? (legacyMode switch
        {
            "Enforce" => "Enforce",
            "AuditOnly" => "SimulationWithoutTips",
            _ => null
        });
        if (mode is not ("Enforce" or "SimulationWithTips" or "SimulationWithoutTips" or "Disabled"))
            return new(capability, "On; mode unknown", "Unknown", "Administrator: refresh the exact saved shared policy. No mode is inferred.");

        var requested = AgentProtectionUiMapping.PolicyLabel(mode, legacyMode);
        if (mode == "Disabled")
            return new(capability, requested, "Off", "The shared policy is saved Off. It cannot run a new behavior test; Prompt Shields remains independent.");
        if (operationStatus == "AwaitingBlueprint")
            return new(capability, requested, "Waiting for blueprint", "This registration's reviewed intent is not yet a configured shared policy.");
        if (registrationStatus is not null && registrationStatus != "Active")
            return new(capability, requested, "Registration not active", "The saved policy choice is unchanged; this registration is not accepting active Gateway traffic.");
        if (readiness is null)
            return new(capability, requested, "Action required", "Administrator: review the matching shared blueprint profile. No current readiness was returned.");
        if (readiness.ValidUntilUtc is { } until && utcNow >= until)
            return new(capability, requested, "Verification expired", "Administrator: refresh connection, inventory and current readiness before approving another test. Earlier reports remain historical.");
        if (readiness.Capability != "Installed")
            return new(capability, requested, "Unavailable", "Administrator: check the shared Purview capability. The saved mode has not been silently changed.");
        if (operationStatus is "OutcomeUnknown" or "RequiresManualIntervention" or "Failed" ||
            profileStatus == "VerificationFailed")
            return new(capability, requested, "Action required", "Administrator: read the existing operation and its required action. Do not repeat an uncertain mutation.");
        if (AgentProtectionUiMapping.IsSimulation(mode))
        {
            return AgentProtectionUiMapping.ConfiguredSimulationFacts(readiness, profileStatus, mode) &&
                readiness.ValidUntilUtc is { } expiry && expiry > utcNow
                ? new(capability, requested, "Simulation", "The current saved simulation is non-enforcing. It does not certify blocking or promise a provider policy tip.")
                : new(capability, requested, "Simulation unavailable", "Administrator: refresh the exact policy and inventory. Simulation remains selected and does not require enforcement certification.");
        }
        if (effectivelyEnabled && readiness.IsReady && profileStatus == "Ready" &&
            readiness.ValidUntilUtc is { } validUntil && validUntil > utcNow)
            return new(capability, requested, "Enforcing", "Current server-checked evidence applies only to this binding and approved samples. Each request is still revalidated.");
        if (operationStatus is "Pending" or "Running" or "WaitingForPropagation" ||
            profileStatus is "Pending" or "PendingPropagation")
            return new(capability, requested, "Verifying", "Follow the existing operation. Saved Enforce settings do not yet establish enforcement.");
        return new(capability, requested, "Configured", "Administrator: review current readiness and approve the required behavior test. Saved Enforce is not proof of enforcement.");
    }

    public static string Capability(string? status) => status switch
    {
        "Installed" => "Installed",
        "NotInstalled" => "Not installed",
        "PendingPropagation" => "Verifying installation",
        "Unavailable" => "Unavailable",
        _ => "Not reported"
    };
}
