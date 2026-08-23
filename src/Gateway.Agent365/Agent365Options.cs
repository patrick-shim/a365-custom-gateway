namespace Gateway.Agent365;

public sealed class Agent365Options
{
    public const string SectionName = "Agent365";

    public string TenantId { get; set; } = string.Empty;
    public string? CliPath { get; set; }
    public bool UseGraphAgentRegistration { get; set; } = true;
    public bool UseCliProvisioningFallback { get; set; } = true;
    public int CliTimeoutSeconds { get; set; } = 300;
}
