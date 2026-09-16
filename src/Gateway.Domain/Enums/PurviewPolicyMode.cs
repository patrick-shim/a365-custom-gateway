namespace Gateway.Domain.Enums;

public enum PurviewPolicyMode
{
    Enforce,
    SimulationWithTips,
    SimulationWithoutTips,
    Disabled
}

public static class PurviewPolicyModeCompatibility
{
    public static PurviewPolicyMode FromLegacy(PurviewMode mode) =>
        mode == PurviewMode.Enforce
            ? PurviewPolicyMode.Enforce
            : PurviewPolicyMode.SimulationWithoutTips;

    public static PurviewMode ToLegacy(this PurviewPolicyMode mode) =>
        mode == PurviewPolicyMode.Enforce ? PurviewMode.Enforce : PurviewMode.AuditOnly;

    public static PurviewExecutionMode ToExecutionMode(this PurviewPolicyMode mode) =>
        mode is PurviewPolicyMode.Enforce or PurviewPolicyMode.SimulationWithTips
            ? PurviewExecutionMode.EvaluateInline : PurviewExecutionMode.EvaluateOffline;

    public static string ToProviderMode(this PurviewPolicyMode mode) => mode switch
    {
        PurviewPolicyMode.Enforce => "Enable",
        PurviewPolicyMode.SimulationWithTips => "TestWithNotifications",
        PurviewPolicyMode.SimulationWithoutTips => "TestWithoutNotifications",
        PurviewPolicyMode.Disabled => "Disable",
        _ => throw new ArgumentOutOfRangeException(nameof(mode))
    };
}
