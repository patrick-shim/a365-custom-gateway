namespace Gateway.Domain.Enums;

public enum ProtectionReadbackStatus
{
    NotChecked,
    Pending,
    Ready,
    Mismatch,
    Failed,
    Stale
}

public enum ProtectionPropagationStatus
{
    NotChecked,
    Pending,
    Ready,
    Failed
}

public enum ProtectionTokenRoleStatus
{
    NotChecked,
    PendingRefresh,
    Ready,
    MissingRequiredRoles,
    Failed
}

public enum ProtectionRuntimeVerdictStatus
{
    NotChecked,
    Pending,
    Ready,
    Failed,
    Unsupported
}
