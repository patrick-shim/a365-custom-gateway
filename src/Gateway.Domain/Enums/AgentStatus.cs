namespace Gateway.Domain.Enums;

public enum AgentStatus
{
    Draft,
    Provisioning,
    AwaitingAdminApproval,
    Active,
    Disabled,
    Failed,
    Deleting,
    Deleted,
    RequiresManualIntervention
}
