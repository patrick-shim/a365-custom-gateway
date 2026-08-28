namespace Gateway.Infrastructure.Security;

public sealed class AgentIngressCredentialOptions
{
    public const string SectionName = "AgentIngressCredentials";

    public int LifetimeDays { get; set; } = 365;
}
