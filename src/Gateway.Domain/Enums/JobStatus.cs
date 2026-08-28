namespace Gateway.Domain.Enums;

public enum JobStatus
{
    Pending,
    Running,
    Completed,
    Failed,
    RequiresManualIntervention,
    AwaitingAdministratorAction
}
