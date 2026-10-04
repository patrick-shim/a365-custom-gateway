namespace Gateway.Domain.Enums;

public enum PurviewPolicyMode
{
    Enforce,
    SimulationWithTips,
    SimulationWithoutTips,
    Disabled
}

public static class PurviewPolicyModeMapping
{
    public static PurviewPolicyMode FromRuntimeMode(PurviewMode mode) =>
        mode == PurviewMode.Enforce
            ? PurviewPolicyMode.Enforce
            : PurviewPolicyMode.SimulationWithoutTips;

    public static PurviewExecutionMode ToExecutionMode(this PurviewPolicyMode mode) =>
        mode is PurviewPolicyMode.Enforce or PurviewPolicyMode.SimulationWithTips
            ? PurviewExecutionMode.EvaluateInline : PurviewExecutionMode.EvaluateOffline;

}
