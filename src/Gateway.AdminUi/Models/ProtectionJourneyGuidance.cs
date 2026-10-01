using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;

namespace Gateway.AdminUi.Models;

public enum ProtectionJourneyAction
{
    None,
    RefreshState,
    CheckOperation,
    ReviewConnection
}

public sealed record ProtectionJourneyGuidance(
    string Title,
    string Status,
    string Summary,
    string Purpose,
    string Remaining,
    string NextStep,
    string? ActionLabel = null,
    string? ActionHref = null,
    ProtectionJourneyAction Action = ProtectionJourneyAction.None)
{
    public static ProtectionJourneyGuidance ForRuntime(
        PurviewRuntimeTestResultResponse report, PurviewDlpProfileDto? currentProfile, DateTime utcNow)
    {
        const string purpose = "Approved examples test behavior in effective policy scope. The receipt is historical; current readiness is checked separately.";
        const string limits = "This does not identify which classifier matched, prove every future prompt, enable an agent or confirm downstream telemetry delivery.";
        if (report.Status == "Running" || report.Outcome == "OutcomeUnknown")
            return new("The runtime result is not confirmed", "Outcome unknown",
                "A saved reference exists, but no final provider result is confirmed.", purpose, limits,
                "Read this same safe report. Do not resubmit the previous samples or confirmation.",
                "Check existing report", Action: ProtectionJourneyAction.CheckOperation);
        if (currentProfile is null)
            return new("Report saved; current readiness is unavailable", "Action required",
                "The saved report can be inspected below, but the current exact profile has not been verified.",
                purpose, limits,
                "Refresh current readiness before drawing a conclusion from the report. No sample is sent by refreshing.",
                "Refresh current readiness", Action: ProtectionJourneyAction.RefreshState);
        var policyHref = $"/settings/policy?profile={currentProfile.Id:D}";
        var runtimeHref = $"/settings/runtime?profile={currentProfile.Id:D}";
        var state = ProtectionStateProjection.Profile(currentProfile, utcNow);
        if (state.Current is "Off" or "Simulation" or "Verification expired")
            return ForProfile(currentProfile, utcNow, true, false, policyHref, runtimeHref);
        if (report.Outcome == "EnforcementBehaviorVerified" && report.EnforcementBehaviorVerified &&
            state.Current == "Enforcing" && report.ProfileRowVersion == currentProfile.RowVersion)
            return new("Approved behavior is currently verified", "Enforcing",
                "The approved suite completed and the matching saved profile has current server-checked enforcement readiness.",
                purpose, limits,
                "Continue to agents. Open an agent using this blueprint, review its own Purview choice, and verify evaluated traffic and downstream activity separately.",
                "Continue to agents", "/agents");
        if (report.Status == "Failed" || report.Outcome == "Failed")
            return new("The approved behavior test did not verify protection", "Failed",
                "The report records an unsuccessful test; no enforcement readiness is inferred from it.",
                purpose, limits,
                "Inspect the recorded failure and current profile blockers. Resolve them before approving a fresh test; previous samples are not replayed.",
                "Review this shared policy", policyHref);
        if (report.Outcome == "Partial")
            return new("More approved examples are needed", "Partially verified",
                "This report covers only part of the intended suite. It does not establish complete enforcement readiness.",
                purpose, limits,
                "If this tab still holds the reviewed suite, use Prepare next batch below. Otherwise reopen this exact profile and explicitly review a fresh full suite.",
                "Continue to behavior tests", runtimeHref);
        return new("Report saved; current protection still needs review", state.Current,
            "The report records the completed test outcome below. Current policy evidence is shown separately.",
            purpose, limits,
            "Review this exact saved profile and its current blockers before approving further tests. Earlier results are not applied to a changed or expired binding.",
            "Review this shared policy", policyHref);
    }

    public static ProtectionJourneyGuidance ForProfile(
        PurviewDlpProfileDto profile,
        DateTime utcNow,
        bool isAdministrator,
        bool runtimeTask,
        string policyHref,
        string runtimeHref)
    {
        var state = ProtectionStateProjection.Profile(profile, utcNow);
        var name = string.IsNullOrWhiteSpace(profile.DisplayName)
            ? "This shared blueprint policy" : profile.DisplayName;
        const string purpose = "A blueprint policy is shared by every agent using that blueprint. Saving it does not change each agent's Purview On or Off choice.";
        const string limits = "Connection, saved policy, approved sample behavior and downstream telemetry are separate. No report proves every future prompt or identifies which classifier matched.";

        if (!isAdministrator)
            return new("Review the shared policy", state.Current,
                $"{name}: {state.Requested}. {state.Explanation}", purpose, limits,
                "A Gateway Administrator must review changes or approve test samples. You can inspect the saved policy and agent settings.",
                "Continue to agents", "/agents");

        return state.Current switch
        {
            "Off" => new("Policy saved as Off", "Off",
                $"{name} is saved with the shared policy disabled.", purpose,
                "Off is a valid choice. This policy does not block content and cannot run a new behavior test. Prompt Shields remains independent.",
                "Continue to agent settings, or return to the shared policy if you want to explicitly review a different mode.",
                "Continue to agents", "/agents"),
            "Simulation" => new("Simulation policy configured", "Simulation",
                $"{name} is configured in a non-blocking simulation mode.", purpose,
                "Simulation does not certify blocking or promise that a downstream app displays a policy tip. Behavior tests are optional diagnostics, not a requirement to use this mode.",
                "Open an agent using this blueprint and review its Purview choice. Saving this policy did not turn protection on for that agent.",
                "Continue to agents", "/agents"),
            "Enforcing" => new("Approved behavior is currently verified", "Enforcing",
                $"{name} has current server-checked enforcement readiness.", purpose, limits,
                "Open an agent using this blueprint and review its Purview choice. Then evaluate prompts through the Gateway and verify delivery in the selected telemetry destinations.",
                "Continue to agents", "/agents"),
            "Verification expired" => new("Earlier verification has expired", "Verification expired",
                $"{name} is still saved, but its earlier readiness no longer establishes current protection.", purpose, limits,
                "Refresh the tenant connection and inventory first. Then review this same saved policy and its current readiness; do not replay an old test.",
                "Review connection and inventory", $"/settings/connection?profile={profile.Id:D}"),
            "Verifying" => new("The shared policy is still being checked", "Verifying",
                $"{name} is saved with checks still pending.", purpose, limits,
                "Follow its existing operation until the Gateway reports a result. Do not create the same policy again.",
                "Refresh current state", Action: ProtectionJourneyAction.RefreshState),
            "Configured" when profile.Readiness.Readback == "Ready" => new(
                runtimeTask ? "Verify how this policy behaves" : "Policy saved; behavior is not verified",
                "Configured",
                $"{name} has saved Enforce settings and a successful configuration readback.", purpose,
                "Saved Enforce settings alone do not prove blocking. Approve a clean negative and an example for each intended sensitive information type; the Gateway checks the effective policy scope.",
                runtimeTask
                    ? "Choose test samples below. Review the exact profile, test agent and synthetic examples before running them. No sample is sent just by opening this page."
                    : "Continue to behavior tests for this exact profile. Review approved examples before running the separate verification.",
                runtimeTask ? "Choose test samples" : "Continue to behavior tests",
                runtimeTask ? $"#profile-runtime-{profile.Id:D}" : runtimeHref),
            "Configured" or "Action required" or "Simulation unavailable" => new(
                "Review the policy's current checks", state.Current,
                $"{name}: {state.Explanation}", purpose, limits,
                "Inspect the saved profile's blockers below. A fresh reviewed reconciliation reads the exact configuration; it does not rewrite policy or substitute for sample verification.",
                runtimeTask ? "Review this shared policy" : "Inspect policy checks",
                runtimeTask ? policyHref : $"#profile-{profile.Id:D}"),
            _ => new("Policy readiness is not confirmed", state.Current,
                $"{name}: {state.Explanation}", purpose, limits,
                "Check the shared capability and the exact saved profile before approving changes or tests. No readiness is inferred from a completed operation.",
                "Refresh current state", Action: ProtectionJourneyAction.RefreshState)
        };
    }
}
