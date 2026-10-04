namespace Gateway.Agent365;

public interface IAgentPurviewAccessProvisioner
{
    Task EnsureAsync(Guid tenantId, Guid principalId, Guid childId, Guid blueprintId, CancellationToken ct);
}
