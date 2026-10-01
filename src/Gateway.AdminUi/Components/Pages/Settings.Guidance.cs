using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Models;
using Gateway.Contracts.Dtos;
using Microsoft.AspNetCore.WebUtilities;

namespace Gateway.AdminUi.Components.Pages;

public partial class Settings
{
    private Guid? requestedProfileId;
    private string? profileReferenceError;
    private ProtectionJourneyOutcome? outcomePanel;
    private bool focusOutcomeRequested;
    private readonly Dictionary<Guid, PurviewDlpProfileDto?> runtimeReadbacks = [];

    private IEnumerable<PurviewDlpProfileDto> VisibleProfiles =>
        profileReferenceError is not null ? [] :
        requestedProfileId is { } id
            ? profilesResource?.Value.Items.Where(profile => profile.Id == id) ?? []
            : profilesResource?.Value.Items ?? [];

    private PurviewDlpProfileDto? GuidanceProfile
    {
        get
        {
            var profiles = profilesResource?.Value.Items;
            if (profiles is null || profileReferenceError is not null)
                return null;
            if (requestedProfileId is { } requested)
                return ProfileForGuidance(profiles.SingleOrDefault(profile => profile.Id == requested));
            if (ActiveOperation is { TargetType: "DlpProfile" } operation &&
                Guid.TryParseExact(operation.TargetIdentifier, "D", out var target))
                return ProfileForGuidance(profiles.SingleOrDefault(profile => profile.Id == target));
            return profiles.Count == 1 ? ProfileForGuidance(profiles[0]) : null;
        }
    }

    private PurviewDlpProfileDto? ProfileForGuidance(PurviewDlpProfileDto? profile) =>
        profile is not null && runtimeReadbacks.TryGetValue(profile.Id, out var readback)
            ? readback ?? profile : profile;

    private void RetainRuntimeReadback(Guid profileId, long generation, PurviewDlpProfileDto? readback)
    {
        if (!IsCurrent(generation) || CurrentTask != SettingsTask.Runtime ||
            profilesResource?.Value.Items.Any(profile => profile.Id == profileId) != true)
            return;
        runtimeReadbacks[profileId] = readback?.Id == profileId ? readback : null;
    }

    private ProtectionJourneyGuidance JourneyGuidance
    {
        get
        {
            const string purpose = "Connection, shared policy, behavior verification and each agent's protection choice are separate steps.";
            const string remaining = "No policy or test is started merely by viewing or refreshing this page.";
            if (protectionOutcomeUnknown || operationError is not null)
                return new("The protection result is not confirmed", "Outcome unknown",
                    "The retained operation is still the recovery reference. A missing response does not mean its work was undone.",
                    purpose, "Do not repeat a connection, policy change or sample submission to recover a missing result.",
                    "Check this same operation. The Gateway will read its saved result without submitting it again.",
                    "Check existing operation", Action: ProtectionJourneyAction.CheckOperation);
            if (profileReferenceError is not null)
                return new("The profile link cannot be used", "Action required", profileReferenceError,
                    "A next step must stay bound to the exact selected shared policy.", remaining,
                    "Return to the policy list and explicitly choose the intended profile.",
                    "Show all shared policies", TaskHref("policy", clearProfile: true));
            if (reloading || operationContextRefreshing || capabilitiesLoading || connectionLoading ||
                CurrentTask is SettingsTask.Policy or SettingsTask.Runtime && profilesLoading)
                return new("Reading current protection state", "Verifying",
                    "The Gateway is reading the saved operation and its current configuration.", purpose, remaining,
                    "Wait for the result below. Reading current state does not repeat the operation.");
            if (capabilitiesError is not null || connectionError is not null)
                return new("Current protection state is unavailable", "Unavailable",
                    "The current capability or connection could not be read. Earlier completed work has not been undone.",
                    purpose, "No current readiness is inferred from a previous operation or report.",
                    "Refresh current state, or use the safe error reference below for administrator support.",
                    "Refresh current state", Action: ProtectionJourneyAction.RefreshState);
            if (operationContextRefreshNeeded)
                return new("Operation recorded; current details need a refresh", "Action required",
                    "The saved operation result was read, but its current connection or policy details have not been confirmed.",
                    purpose, "Earlier readiness is not reused while this refresh is incomplete.",
                    "Refresh current state before continuing. This reads the saved result; it does not repeat the operation.",
                    "Refresh current state", Action: ProtectionJourneyAction.RefreshState);
            if (OperationMatchesTask && ActiveOperation is { Status: "Cancelled" })
                return new("The operation was cancelled", "Cancelled",
                    "The retained operation reports cancellation. Cancellation alone does not establish which external steps completed.",
                    purpose, remaining,
                    "Read the current configuration and inspect the recorded steps before reviewing any new request.",
                    "Refresh current state", Action: ProtectionJourneyAction.RefreshState);
            if (OperationMatchesTask && ActiveOperation is { Status: "AwaitingBlueprint" })
                return new("Waiting for the selected blueprint", "Waiting for blueprint",
                    "The reviewed policy intent is retained, but its exact new blueprint has not resolved.",
                    purpose, "Deferred intent is not configured or effective protection. Do not create a substitute policy.",
                    "Follow the original agent registration until its blueprint is available.",
                    "Continue to agents", "/agents");
            if (OperationMatchesTask && ActiveOperation is { Status: "AwaitingConfirmation" })
                return new("The saved review was not submitted", "Awaiting confirmation",
                    "This operation reference identifies a review, not an accepted configuration change.",
                    purpose, remaining,
                    "A previous confirmation cannot be restored from this link. Refresh current state and explicitly review the intended action again.",
                    "Refresh current state", Action: ProtectionJourneyAction.RefreshState);
            if (OperationMatchesTask && ActiveOperation is { Status: "Failed" or "RequiresManualIntervention" } failed)
                return PolicyFailureGuidance(failed) ?? new("The saved operation needs attention", "Failed",
                    $"The retained {FriendlyOperation(failed.Type)} operation did not finish successfully.",
                    purpose, "A successful Windows sign-in or an earlier report does not override this operation's result.",
                    "Inspect the failure reference and technical details below. Resolve the cause before reviewing a new action; refreshing only reads current state.",
                    "Refresh current state", Action: ProtectionJourneyAction.RefreshState);
            if (OperationMatchesTask && ActiveOperation is { } active &&
                ProtectionOperationPresentation.IsInProgress(active.Status))
                return new(active.Type == "ConnectPurviewTenant" ? "Checking the Purview connection" : "Checking the approved protection change",
                    "Verifying",
                    active.Type == "ConnectPurviewTenant"
                        ? "The companion result was accepted. The Gateway is independently verifying its own access."
                        : "The approved operation is still running. Configuration and runtime readiness are not yet confirmed.",
                    purpose, "Acceptance is not completion. Do not submit the same request or result again.",
                    "Keep this page open for automatic read-only updates. If updates pause, resume them using the status controls below.");
            if (!canReadProtectionGovernance)
                return new("Protection details require an administrator", "Restricted",
                    "Your role can read the safe operation information returned by the Gateway.",
                    purpose, "Restricted information is not evidence that a connection or policy is missing.",
                    "Ask a Gateway Administrator to review the next configuration or verification step.",
                    "Continue to agents", "/agents");
            if (PurviewCapability?.Status != "Installed" && CurrentTask != SettingsTask.Defaults)
                return new("Purview is an optional capability", CapabilityDisplayStatus(PurviewCapability),
                    "This deployment does not currently report Microsoft Purview as installed.",
                    purpose, "Agents with Purview Off can be fully registered. Prompt Shields is independent.",
                    "Continue with core agent setup, or ask the deployment administrator to prepare the optional capability.",
                    "Continue to agents", "/agents");

            return CurrentTask switch
            {
                SettingsTask.Connection => ConnectionGuidance(),
                SettingsTask.Policy or SettingsTask.Runtime => ProfileGuidance(),
                SettingsTask.Collection => CollectionGuidance(),
                SettingsTask.Defaults => new(
                    settingsSaved ? "Registration defaults saved" : "Choose defaults for future registrations",
                    settingsSaved ? "Completed" : "Optional configuration",
                    settingsSaved ? "The confirmed defaults were saved." : "These settings provide starting choices for new registrations.",
                    "Defaults do not change existing agents or enable protection for them.",
                    "An On default still needs its current prerequisites. Off remains a valid choice.",
                    settingsSaved ? "Register a new agent when needed, or review an existing agent's own settings separately."
                        : "Review and save the choices below. Each registration still requires its own review and one-time key handoff.",
                    settingsSaved ? "Register an agent" : "Review registration defaults",
                    settingsSaved ? "/agents/register" : "#defaults-heading"),
                _ => new("Choose the next protection task", "Optional configuration",
                    ConnectionIsReady ? "The tenant connection is currently verified. Shared policy and behavior checks remain separate."
                        : "Protection is optional; both protections Off is a complete core choice.",
                    purpose, "Tenant-wide collection is optional and is not required to configure a blueprint DLP policy.",
                    ConnectionIsReady ? "Continue to the shared policies, choose the intended blueprint, and review its current configuration."
                        : "If you want to use Purview, connect the tenant before reviewing a shared policy.",
                    ConnectionIsReady ? "Continue to shared policies" : "Review connection and inventory",
                    TaskHref(ConnectionIsReady ? "policy" : "connection"))
            };
        }
    }

    private bool OperationMatchesTask => ActiveOperation?.Type switch
    {
        "ConnectPurviewTenant" or "RefreshSensitiveInformationTypes" => CurrentTask == SettingsTask.Connection,
        "CreateOrUpdateKnowYourData" => CurrentTask == SettingsTask.Collection,
        "CreateOrUpdateDlpProfile" or "ReconcileDlpProfile" or "ValidateDlpRuntime" or "TestDlpRuntime" =>
            CurrentTask is SettingsTask.Policy or SettingsTask.Runtime,
        _ => CurrentTask == SettingsTask.Overview
    };

    private ProtectionJourneyGuidance? PolicyFailureGuidance(ProtectionAdminOperationDto operation)
    {
        if (operation.Type is not ("CreateOrUpdateDlpProfile" or "ReconcileDlpProfile"))
            return null;
        if (operation.TargetType != "DlpProfile" ||
            !Guid.TryParseExact(operation.TargetIdentifier, "D", out var targetProfileId))
            return null;
        const string purpose = "The Gateway checks the exact Microsoft policy and rule before it can report configuration as complete.";
        const string remaining = "Earlier steps may have taken effect. This result does not prove that Microsoft objects are absent, and it does not enable protection for an agent.";
        if (requestedProfileId is { } requested && requested != targetProfileId)
            return new("This operation belongs to another shared policy", "Check the profile",
                "The selected profile and the retained operation do not have the same policy identity.",
                purpose, "Changing the selected profile would not resolve the other policy's operation.",
                "Open the exact policy named by this operation before reviewing its next action.",
                "Open this operation's policy", TaskHref("policy", targetProfileId));
        var profile = ProfileForGuidance(profilesResource?.Value.Items.SingleOrDefault(item => item.Id == targetProfileId));
        var expiredRequest = operation.FailureCode is "PURVIEW_INVENTORY_STALE" or "PURVIEW_CONNECTION_EVIDENCE_STALE";
        if (!expiredRequest && operation.FailureCode is not ("PURVIEW_SETTINGS_READ_TIMEOUT" or "PURVIEW_EXECUTOR_READ_UNAVAILABLE"))
            return null;
        if (!ConnectionIsReady)
            return new("Policy setup needs fresh prerequisite checks", "Refresh required",
                expiredRequest ? "The connection or sensitive-information-type inventory used by this request is no longer current."
                    : "The earlier policy read did not finish successfully, and the tenant connection is no longer current.",
                purpose, remaining,
                "First review a fresh tenant connection. Then return to this saved policy and review reconciliation before another change. If you have an unsaved draft, use the editor's separate-tab connection link to keep it open.",
                "Review connection and inventory", TaskHref("connection"));
        return new(expiredRequest ? "Recheck the saved policy with current prerequisites"
                : operation.FailureCode == "PURVIEW_SETTINGS_READ_TIMEOUT"
                    ? "Microsoft policy read took too long" : "Microsoft policy state could not be confirmed",
                "Action required",
                expiredRequest ? "The earlier request used expired prerequisites. The connection is available now; a new review must recheck the exact saved selections against its current inventory."
                    : operation.FailureCode == "PURVIEW_SETTINGS_READ_TIMEOUT"
                    ? "The read reached its time limit, so the Gateway stopped waiting and did not mark this operation complete."
                    : "The saved operation could not obtain a trustworthy Microsoft policy readback. This is not evidence that you selected the wrong sensitive information types.",
                purpose, remaining,
                isAdministrator
                    ? "Use Review existing policy check in this saved policy's details. After a new review and confirmation, it reads the existing Microsoft objects without creating them again. Do not resubmit the previous change to recover its result."
                    : "Ask a Gateway Administrator to review an existing policy check for this exact saved profile. Do not create a replacement to recover the earlier result.",
                profile is not null ? "Open saved policy details" : "Refresh current state",
                profile is not null ? CurrentTask == SettingsTask.Policy ? $"#profile-{profile.Id:D}"
                    : TaskHref("policy", profile.Id) : null,
                profile is null ? ProtectionJourneyAction.RefreshState : ProtectionJourneyAction.None);
    }

    private ProtectionJourneyGuidance ConnectionGuidance()
    {
        const string purpose = "The Gateway needs its own verified tenant access and current classifier definitions before you can configure what a shared policy should look for.";
        const string remaining = "This connection check does not create a DLP policy, change an agent's protection choice or test runtime blocking.";
        if (Connection is { } connection && connection.TenantId != signedInTenantId)
            return new("This connection belongs to another tenant", "Wrong tenant",
                "The returned connection cannot be used with the signed-in tenant.", purpose, remaining,
                "Refresh the signed-in tenant context. No connection action is available from this mismatched response.",
                "Refresh current state", Action: ProtectionJourneyAction.RefreshState);
        if (ConnectionIsReady)
        {
            if (isAdministrator && !inventoryLoading && inventoryError is null &&
                inventoryResource?.Value is { } inventory &&
                inventory.TenantId == signedInTenantId && inventory.GenerationId != Guid.Empty &&
                inventory.GenerationId == Connection?.ActiveInventoryGenerationId &&
                (inventory.IsExpired || AsUtc(inventory.ExpiresAtUtc) <= Clock.GetUtcNow().UtcDateTime))
                return new("Classifier inventory expired; refresh required", "Refresh required",
                    "The Gateway connection is still available, but its matching classifier inventory is no longer current.",
                    purpose, remaining,
                    "Review a fresh connection check to retrieve current definitions. Use its new command and result; do not reuse an earlier completion.",
                    CanReviewConnection ? "Review connection refresh" : "Refresh current state",
                    Action: CanReviewConnection ? ProtectionJourneyAction.ReviewConnection : ProtectionJourneyAction.RefreshState);
            if (isAdministrator && (inventoryLoading || inventoryError is not null || !InventoryIsCurrent))
                return new("Connection verified; inventory needs a check", "Action required",
                    "The Gateway verified its own access, but a matching current classifier inventory is not available in this view.",
                    purpose, remaining,
                    "Reload the connection details to read its inventory. If the inventory is expired, review a fresh connection check; do not reuse old evidence.",
                    "Refresh current state", Action: ProtectionJourneyAction.RefreshState);
            return new("Purview connection verified", "Connection verified",
                isAdministrator
                    ? $"The Gateway independently verified its own access. The inventory contains {inventoryResource!.Value.Items.Count} sensitive information type{(inventoryResource.Value.Items.Count == 1 ? "" : "s")}."
                    : "The Gateway independently verified its own access. An administrator can review the current classifier inventory.",
                purpose, remaining,
                isAdministrator
                    ? "Continue to shared policies. Choose the blueprint used by the intended agents, then review classifiers, thresholds and policy mode. After saving Enforce settings, approve a separate behavior test."
                    : "Continue to the shared policies to inspect their state. A Gateway Administrator must approve configuration changes and behavior tests.",
                "Continue to shared policies", TaskHref("policy"));
        }
        if (Connection is { Status: "Connected" or "Expired", LastVerifiedAtUtc: not null })
            return new("Connection verified earlier; refresh required", "Refresh required",
                $"The earlier successful connection is preserved. Its current readiness has expired (last verified {FormatUtc(Connection.LastVerifiedAtUtc.Value)}).",
                purpose, remaining,
                CanReviewConnection ? "Review a fresh connection check when you are ready. Use only its new command and result; the old completion must not be resubmitted."
                    : "A Gateway Administrator must review a fresh connection check. Earlier completion is not a failed operation.",
                CanReviewConnection ? "Review connection refresh" : "Refresh current state",
                Action: CanReviewConnection ? ProtectionJourneyAction.ReviewConnection : ProtectionJourneyAction.RefreshState);
        if (Connection?.Status == "VerificationFailed")
            return new("Connection verification failed", "Failed",
                "The Gateway could not verify its own configured access. The Windows sign-in alone does not establish that access.",
                purpose, remaining,
                "Use the failure reference below to resolve the access issue, then review a fresh attempt. Do not resubmit an already accepted companion result.",
                "Refresh current state", Action: ProtectionJourneyAction.RefreshState);
        if (Connection?.Status == "PendingVerification")
            return new("Checking the Purview connection", "Verifying",
                "Independent Gateway access verification is still pending.", purpose, remaining,
                activeOperationId is not null ? "Follow automatic updates for this saved operation; do not submit its result again."
                    : "Reopen the saved operation link to follow its progress. Refreshing this page reads current state without repeating the connection.",
                activeOperationId is null ? "Refresh current state" : null,
                Action: activeOperationId is null ? ProtectionJourneyAction.RefreshState : ProtectionJourneyAction.None);
        if (Connection?.Status == "AwaitingAdministrator")
            return new(ConnectionLaunchExpired ? "Connection launch expired" : "Finish the Windows connection step",
                ConnectionLaunchExpired ? "Refresh required" : "Awaiting admin",
                ConnectionLaunchExpired ? "The old command can no longer authorize this connection."
                    : "The Gateway is waiting for the intended administrator's companion result.",
                purpose, remaining,
                ConnectionLaunchExpired ? ExpiredConnectionNextAction
                    : CanReadCompanionEvidence ? "Follow the download and trust instructions below, run the current command, then paste its complete result. No text file is required."
                    : "Check the existing operation to recover the correct administrator-bound instructions. Do not create another connection to recover a missing response.",
                ConnectionLaunchExpired && CanReviewConnection ? "Review connection refresh"
                    : CanReadCompanionEvidence ? "Go to companion result" : activeOperationId is not null ? "Check existing operation" : null,
                CanReadCompanionEvidence ? "#purview-companion-output" : null,
                ConnectionLaunchExpired && CanReviewConnection ? ProtectionJourneyAction.ReviewConnection
                    : activeOperationId is not null ? ProtectionJourneyAction.CheckOperation : ProtectionJourneyAction.None);
        return new("Connect Microsoft Purview", "Not connected",
            "A verified connection is not currently available for this tenant.", purpose, remaining,
            isAdministrator ? "Review the tenant connection first. The next screen explains the Windows sign-in and result handoff."
                : "Ask a Gateway Administrator to review the tenant connection. Your read-only view cannot start that sign-in.",
            CanReviewConnection ? "Review tenant connection" : "Continue to agents",
            CanReviewConnection ? null : "/agents",
            CanReviewConnection ? ProtectionJourneyAction.ReviewConnection : ProtectionJourneyAction.None);
    }

    private ProtectionJourneyGuidance ProfileGuidance()
    {
        if (profilesError is not null)
            return new("Shared policies could not be read", "Unavailable",
                "Current saved profiles are unavailable. This does not mean they were deleted.",
                "The next step must use a current, exact profile rather than a guessed default.",
                "No policy or sample has been submitted.",
                "Refresh the policy list before choosing configuration or verification.",
                "Refresh current state", Action: ProtectionJourneyAction.RefreshState);
        if (requestedProfileId is not null && GuidanceProfile is null)
            return new("The selected profile is unavailable", "Action required",
                "The current response does not contain the exact profile from this link.",
                "A different profile must not be silently selected for configuration or tests.",
                "No configuration or sample has been submitted.",
                "Return to the policy list and choose the intended shared profile.",
                "Show all shared policies", TaskHref("policy", clearProfile: true));
        if (GuidanceProfile is { } current && runtimeReadbacks.TryGetValue(current.Id, out var readback) && readback is null)
            return new("The test's current readiness needs a check", "Action required",
                "The current profile readiness is being read or could not be confirmed after the runtime test.",
                "The report and saved-profile readiness are separate; an earlier badge cannot override a newer result.",
                "No sample is replayed by a readiness read.",
                "Follow the runtime result below and refresh its current readiness if requested.",
                "Go to runtime result", $"#profile-runtime-{current.Id:D}");
        if (GuidanceProfile is { } disabledProfile &&
            ProtectionStateProjection.Profile(disabledProfile, Clock.GetUtcNow().UtcDateTime).Current == "Off")
            return ProtectionJourneyGuidance.ForProfile(disabledProfile, Clock.GetUtcNow().UtcDateTime,
                isAdministrator, CurrentTask == SettingsTask.Runtime,
                TaskHref("policy", disabledProfile.Id), TaskHref("runtime", disabledProfile.Id));
        if (!ConnectionIsReady)
            return new("Refresh the connection before continuing", "Refresh required",
                "A current tenant connection is required for this policy task.",
                "Classifiers and policy checks must belong to the same tenant and current inventory.",
                "Your saved policies and earlier reports are preserved; no settings were changed.",
                "Review the connection and inventory, then return to this exact profile.",
                "Review connection and inventory", TaskHref("connection"));
        if (GuidanceProfile is { } profile)
            return ProtectionJourneyGuidance.ForProfile(profile, Clock.GetUtcNow().UtcDateTime,
                isAdministrator, CurrentTask == SettingsTask.Runtime,
                TaskHref("policy", profile.Id), TaskHref("runtime", profile.Id));
        return new("Choose a shared blueprint policy", "Optional configuration",
            profilesResource?.Value.Items.Count > 0 ? "More than one shared profile is available. Choose the exact profile you want to review."
                : "The connection is available, but no shared blueprint DLP profile is currently returned.",
            "A policy is shared by agents using its blueprint. Choose the blueprint, exact classifiers, thresholds and mode before approving any change.",
            "Optional tenant-wide collection is not required. Saved Enforce settings still need a separately approved behavior check; simulation and Off have different requirements.",
            isAdministrator
                ? CurrentTask == SettingsTask.Runtime ? "Configure or choose a shared policy first, then return here to approve its test samples."
                    : blueprints.Count == 0 ? "A blueprint must exist before a shared policy can target it. Register an agent first, or refresh the available blueprint list."
                    : "Choose an existing profile below, or select a blueprint to review its policy. Nothing changes until you explicitly confirm."
                : "Inspect the profiles below. A Gateway Administrator must approve changes or runtime samples.",
            CurrentTask == SettingsTask.Runtime ? "Continue to shared policies"
                : isAdministrator && blueprints.Count > 0 ? "Choose a blueprint" : "Continue to agents",
            CurrentTask == SettingsTask.Runtime ? TaskHref("policy")
                : isAdministrator && blueprints.Count > 0 ? "#dlp-blueprint" : "/agents");
    }

    private ProtectionJourneyGuidance CollectionGuidance() => new(
        KnowYourData is { Status: "Ready", ReadbackStatus: "Ready" } ? "Optional collection is configured" : "Review optional tenant-wide collection",
        KnowYourDataDisplayStatus,
        KnowYourData is { Status: "Ready", ReadbackStatus: "Ready" }
            ? "The fixed tenant-wide collection configuration has a successful readback."
            : "This separate task manages the fixed Know Your Data Group, not a blueprint DLP policy.",
        "Collection and DLP use different scopes. Collection is optional and is not a prerequisite to configure or test DLP.",
        "Configuration readback does not prove that an activity reached a downstream portal or that sensitive content was blocked.",
        "Continue to shared policies for DLP, or review the optional collection settings below only if you need this separate capability.",
        "Continue to shared policies", TaskHref("policy"));

    private bool GuidanceActionDisabled => !RendererInfo.IsInteractive || disposed ||
        (JourneyGuidance.Action switch
        {
            ProtectionJourneyAction.CheckOperation => activeOperationId is null || operationLoading,
            ProtectionJourneyAction.ReviewConnection => !CanReviewConnection,
            ProtectionJourneyAction.RefreshState => reloading || saving || protectionActionBusy || operationLoading || operationContextRefreshing,
            _ => true
        });

    private Task RunGuidanceActionAsync(ProtectionJourneyAction action)
    {
        if (action != JourneyGuidance.Action || GuidanceActionDisabled)
        {
            protectionAnnouncement = "The state changed. Review the current next step; no action was submitted.";
            return Task.CompletedTask;
        }
        return action switch
        {
            ProtectionJourneyAction.CheckOperation => LoadActiveOperationAsync(),
            ProtectionJourneyAction.ReviewConnection => ReviewConnectionAsync(),
            ProtectionJourneyAction.RefreshState => ReloadAllAsync(),
            _ => Task.CompletedTask
        };
    }

    private void ReadProfileFromLocation()
    {
        requestedProfileId = null;
        profileReferenceError = null;
        var query = QueryHelpers.ParseQuery(Navigation.ToAbsoluteUri(Navigation.Uri).Query);
        var supplied = query.TryGetValue("profile", out var values);
        var reference = ProfileReference ?? (supplied && values.Count == 1 ? values[0] : null);
        if (!supplied && ProfileReference is null)
            return;
        if ((!supplied || values.Count == 1) && Guid.TryParseExact(reference, "D", out var id) && id != Guid.Empty)
            requestedProfileId = id;
        else
            profileReferenceError = "The saved profile reference is invalid. No different profile has been selected.";
    }
}
