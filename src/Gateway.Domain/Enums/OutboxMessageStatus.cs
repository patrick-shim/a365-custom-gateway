namespace Gateway.Domain.Enums;

public enum OutboxMessageStatus
{
    Pending,
    Published,
    Failed,
    Processing
}
