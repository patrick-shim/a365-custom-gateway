using Gateway.Contracts.Dtos;

namespace Gateway.AdminUi.Models;

public static class ProtectionOperationPresentation
{
    public static string StepTitle(string operationType, string step) => step switch
    {
        "ValidateReviewedIntent" => "Check your approved request",
        "DiscoverProviderState" when IsConnection(operationType) => "Check the Gateway's own Purview access",
        "DiscoverProviderState" => "Read the current Microsoft configuration",
        "ApplyReviewedMutation" => "Apply only the approved change",
        "RecordExactReadback" when IsConnection(operationType) => "Save the verified connection and inventory",
        "RecordExactReadback" => "Read back the exact saved configuration",
        "VerifyPropagation" => "Check whether the policy change is available",
        "AttestTokenRoles" => "Check runtime permissions",
        "ValidateRuntimeVerdict" => "Check approved runtime behavior",
        "Complete" => "Record the operation result",
        _ => "Additional recorded check"
    };

    public static string StepExplanation(string operationType, ProtectionAdminOperationStepDto step)
    {
        if (step.Status == "Skipped")
        {
            if (IsConnection(operationType))
                return step.Step switch
                {
                    "ApplyReviewedMutation" => "Not needed for a connection check. This step does not create or change a DLP policy.",
                    "VerifyPropagation" or "AttestTokenRoles" => "Not part of connection verification. Policy propagation and runtime permissions are checked separately when needed.",
                    "ValidateRuntimeVerdict" => "No runtime samples were tested. Approving and running examples is a separate step after configuring a policy.",
                    _ => "The Gateway did not run this check. Skipped does not mean the check passed."
                };
            if (operationType == "ReconcileDlpProfile")
                return step.Step == "ApplyReviewedMutation"
                    ? "Reconciliation reads the existing policy; it does not silently rewrite it."
                    : "This readback-only operation does not renew policy propagation, runtime permission or sample-behavior evidence.";
            if (step.Step == "ValidateRuntimeVerdict")
                return "Runtime examples require their own review and execution. This operation did not test blocking.";
            return "This check was not run for this operation. Skipped is not proof of runtime protection.";
        }

        return step.Step switch
        {
            "ValidateReviewedIntent" => "Checks that the tenant, administrator, target and reviewed choices still match the authorized request.",
            "DiscoverProviderState" when IsConnection(operationType) => "Uses the Gateway's configured app identity, not your Windows sign-in session, to verify access.",
            "DiscoverProviderState" => "Reads Microsoft state before deciding whether any approved change is still needed.",
            "ApplyReviewedMutation" => "Performs only the change covered by your confirmation; unrelated policy and identity settings stay outside this operation.",
            "RecordExactReadback" when IsConnection(operationType) => "Records the matching connection and classifier definitions for later policy selection. Definitions are not your prompts or documents.",
            "RecordExactReadback" => "Compares the recorded result with the exact reviewed configuration. Saved configuration alone is not proof of blocking.",
            "VerifyPropagation" => "Checks whether Microsoft has made the relevant configuration available for use.",
            "AttestTokenRoles" => "Checks the permissions needed for the relevant runtime binding.",
            "ValidateRuntimeVerdict" => "Checks approved behavior in effective policy scope; it cannot identify which sensitive information type matched.",
            "Complete" => "Closes this operation. The current connection, saved profile and runtime readiness remain separate facts.",
            _ => "Inspect the operation reference for support; no additional readiness is inferred from an unrecognized check."
        };
    }

    public static bool IsConnection(string type) =>
        type is "ConnectPurviewTenant" or "RefreshSensitiveInformationTypes";

    public static bool IsInProgress(string? status) =>
        status is "Pending" or "Running" or "PendingPropagation";
}
