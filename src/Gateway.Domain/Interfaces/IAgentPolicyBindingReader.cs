using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

// Assignment evidence is durable until the assignment or agent protection revision
// changes. An optional deadline is reserved for explicitly time-bounded evidence;
// display-catalog retrieval time is not an authorization deadline.
public sealed record AgentPolicyBinding(string Digest, DateTime? ValidUntilUtc = null);
public interface IAgentPolicyBindingReader
{
    Task<AgentPolicyBinding?> ReadAsync(AgentRegistration agent, CancellationToken ct);
}
