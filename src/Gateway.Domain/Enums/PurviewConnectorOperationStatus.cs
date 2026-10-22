namespace Gateway.Domain.Enums;

public enum PurviewConnectorOperationStatus
{
    Pending,
    Running,
    Succeeded,
    Failed,
    NeedsAttention,
    TimedOut,
    Cancelled
}
