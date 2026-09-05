using Gateway.Domain.Enums;

namespace Gateway.Domain.Models;

public sealed record ProtectionReadiness(
    ProtectionCapabilityStatus Capability,
    ProtectionReadbackStatus Readback,
    ProtectionPropagationStatus Propagation,
    ProtectionTokenRoleStatus TokenRoles,
    ProtectionRuntimeVerdictStatus RuntimeVerdict)
{
    public static ProtectionReadiness NotEvaluated { get; } = new(
        ProtectionCapabilityStatus.NotInstalled,
        ProtectionReadbackStatus.NotChecked,
        ProtectionPropagationStatus.NotChecked,
        ProtectionTokenRoleStatus.NotChecked,
        ProtectionRuntimeVerdictStatus.NotChecked);

    public static ProtectionReadiness Ready { get; } = new(
        ProtectionCapabilityStatus.Installed,
        ProtectionReadbackStatus.Ready,
        ProtectionPropagationStatus.Ready,
        ProtectionTokenRoleStatus.Ready,
        ProtectionRuntimeVerdictStatus.Ready);

    public bool IsReady =>
        Capability == ProtectionCapabilityStatus.Installed &&
        Readback == ProtectionReadbackStatus.Ready &&
        Propagation == ProtectionPropagationStatus.Ready &&
        TokenRoles == ProtectionTokenRoleStatus.Ready &&
        RuntimeVerdict == ProtectionRuntimeVerdictStatus.Ready;
}
