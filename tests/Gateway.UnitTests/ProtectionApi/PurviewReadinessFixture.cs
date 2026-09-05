using Gateway.Application.Protection;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using NSubstitute;

namespace Gateway.UnitTests.ProtectionApi;

internal sealed class PurviewReadinessFixture
{
    public IBootstrapPurviewRuntimeBinding Binding { get; } = Substitute.For<IBootstrapPurviewRuntimeBinding>();
    public IPurviewTenantConnectionRepository Connections { get; } = Substitute.For<IPurviewTenantConnectionRepository>();
    public IPurviewSensitiveInformationTypeSnapshotRepository Inventory { get; } =
        Substitute.For<IPurviewSensitiveInformationTypeSnapshotRepository>();
    public PurviewTenantConnection Connection { get; private set; } = null!;
    public PurviewSensitiveInformationTypeSnapshotGeneration Generation { get; private set; } = null!;

    public PurviewReadinessFixture() => Binding.IsExact(Arg.Any<ProtectionCapability>()).Returns(true);

    public PurviewDlpProfile Seed(PurviewDlpProfile profile)
    {
        profile.PurviewTenantConnectionId = Guid.NewGuid();
        profile.InventoryGenerationId = new(Guid.NewGuid());
        profile.SensitiveInformationTypeId = new(Guid.NewGuid());
        profile.SensitiveInformationTypeName = "Synthetic information type";
        Connection = new PurviewTenantConnection
        {
            Id = profile.PurviewTenantConnectionId,
            TenantId = new(Guid.NewGuid()),
            Status = PurviewTenantConnectionStatus.Connected,
            ActiveInventoryGenerationId = profile.InventoryGenerationId,
            LastVerifiedAtUtc = profile.LastReadbackAtUtc
        };
        Generation = new PurviewSensitiveInformationTypeSnapshotGeneration
        {
            Id = profile.InventoryGenerationId,
            PurviewTenantConnectionId = Connection.Id,
            TenantId = Connection.TenantId,
            ExpiresAtUtc = profile.SensitiveInformationTypeSnapshotExpiresAtUtc,
            ItemCount = 1,
            Items =
            [
                new()
                {
                    Id = Guid.NewGuid(),
                    GenerationId = profile.InventoryGenerationId,
                    SensitiveInformationTypeId = profile.SensitiveInformationTypeId,
                    ExactName = profile.SensitiveInformationTypeName
                }
            ]
        };
        Connections.GetByIdAsync(Connection.Id, Arg.Any<CancellationToken>()).Returns(Connection);
        Inventory.GetGenerationAsync(Generation.Id, Arg.Any<CancellationToken>()).Returns(Generation);
        return profile;
    }
}
