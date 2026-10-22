namespace Gateway.Domain.Enums;

public enum PurviewConnectorState
{
    NotConfigured,
    Connecting,
    Connected,
    Refreshing,
    Degraded,
    Disconnected
}
