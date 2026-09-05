using Gateway.Domain.Enums;

namespace Gateway.Domain.Models;

public static class ProtectionAdminWorkflow
{
    public const int CurrentVersion = 1;

    public static IReadOnlyList<ProtectionAdminStepType> CurrentSteps { get; } =
    [
        ProtectionAdminStepType.ValidateReviewedIntent,
        ProtectionAdminStepType.DiscoverProviderState,
        ProtectionAdminStepType.ApplyReviewedMutation,
        ProtectionAdminStepType.RecordExactReadback,
        ProtectionAdminStepType.VerifyPropagation,
        ProtectionAdminStepType.AttestTokenRoles,
        ProtectionAdminStepType.ValidateRuntimeVerdict,
        ProtectionAdminStepType.Complete
    ];
}
