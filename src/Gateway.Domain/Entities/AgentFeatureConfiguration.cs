using Gateway.Domain.Enums;

namespace Gateway.Domain.Entities;

public class AgentFeatureConfiguration
{
    public Guid Id { get; set; }
    public Guid AgentRegistrationId { get; set; }
    public ObservabilityMode ObservabilityMode { get; set; }
    public bool PurviewEnabled { get; set; }
    public PurviewMode? PurviewMode { get; set; }
    public DateTime UpdatedAtUtc { get; set; }

    public AgentRegistration AgentRegistration { get; set; } = null!;
}
