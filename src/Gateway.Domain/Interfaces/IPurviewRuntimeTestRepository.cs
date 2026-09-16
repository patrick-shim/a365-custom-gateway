using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public sealed record PurviewRuntimeTestSnapshot(
    PurviewDlpProfile Profile,
    PurviewTenantConnection Connection,
    ProtectionCapability Capability,
    PurviewSensitiveInformationTypeSnapshotGeneration Inventory,
    AgentRegistration? Agent);

public interface IPurviewRuntimeWriteLease : IAsyncDisposable
{
    Task CompleteAsync(CancellationToken cancellationToken);
}

public interface IPurviewRuntimeTestRepository
{
    Task<PurviewRuntimeTestSnapshot?> LoadFreshSnapshotAsync(
        Guid profileId, Guid tenantId, Guid? registrationId, CancellationToken cancellationToken);
    Task<IReadOnlyList<ProtectionAdminOperation>> ListSuiteOperationsAsync(
        string configurationFingerprint, string suiteHash, DateTime sinceUtc, CancellationToken cancellationToken);
    Task<ProtectionAdminOperation?> GetFreshCertificationOperationAsync(Guid operationId, CancellationToken cancellationToken);
    Task<IPurviewRuntimeWriteLease> BeginFreshWriteAsync(CancellationToken cancellationToken);
    void EnsureNoActiveTransaction();
    void UpdateProfile(PurviewDlpProfile profile);
}
