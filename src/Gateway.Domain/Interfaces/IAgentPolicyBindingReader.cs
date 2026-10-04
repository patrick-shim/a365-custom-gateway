using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public sealed record AgentPolicyBinding(string Digest, DateTime ValidUntilUtc);
public interface IAgentPolicyBindingReader
{
    Task<AgentPolicyBinding?> ReadAsync(AgentRegistration agent, CancellationToken ct);
}
