namespace Gateway.Domain.Interfaces;

/// <summary>
/// Serializes one provisioning job across worker replicas while a Microsoft-side
/// step is being resolved, executed, and durably recorded.
/// </summary>
public interface IProvisioningExecutionLockProvider
{
    Task<IProvisioningExecutionLease> AcquireAsync(Guid jobId, CancellationToken ct);
}

public interface IProvisioningExecutionLease : IAsyncDisposable;
