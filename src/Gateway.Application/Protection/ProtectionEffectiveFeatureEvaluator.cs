using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;

namespace Gateway.Application.Protection;

internal sealed class ProtectionEffectiveFeatureEvaluator
{
    private readonly IProtectionCapabilityRepository _capabilities;
    private readonly IPurviewDlpProfileRepository _profiles;
    private readonly TimeProvider _timeProvider;
    private readonly IBootstrapPromptShieldRuntimeBinding? _promptShieldBinding;
    private readonly IBootstrapPurviewRuntimeBinding? _purviewBinding;
    private readonly IPurviewTenantConnectionRepository? _connections;
    private readonly IPurviewSensitiveInformationTypeSnapshotRepository? _inventory;

    public ProtectionEffectiveFeatureEvaluator(
        IProtectionCapabilityRepository capabilities,
        IPurviewDlpProfileRepository profiles,
        TimeProvider timeProvider,
        IBootstrapPromptShieldRuntimeBinding? promptShieldBinding = null,
        IBootstrapPurviewRuntimeBinding? purviewBinding = null,
        IPurviewTenantConnectionRepository? connections = null,
        IPurviewSensitiveInformationTypeSnapshotRepository? inventory = null)
    {
        _capabilities = capabilities;
        _profiles = profiles;
        _timeProvider = timeProvider;
        _promptShieldBinding = promptShieldBinding;
        _purviewBinding = purviewBinding;
        _connections = connections;
        _inventory = inventory;
    }

    public async Task<bool> HasPurviewCapabilityRecordAsync(
        CancellationToken cancellationToken) =>
        await _capabilities.GetByKindAsync(
            ProtectionCapabilityKind.Purview,
            cancellationToken) is not null;

    public async Task EnsurePromptShieldReadyAsync(
        CancellationToken cancellationToken)
    {
        var capability = await _capabilities.GetByKindAsync(
            ProtectionCapabilityKind.PromptShields,
            cancellationToken);
        if (!IsPromptShieldReady(capability))
        {
            throw new DomainException(
                "Prompt Shields requires an exact installed Content Safety capability readback.",
                ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE);
        }
    }

    public async Task<bool> HasAnyReadyDlpProfileAsync(
        CancellationToken cancellationToken)
    {
        var capability = await _capabilities.GetByKindAsync(
            ProtectionCapabilityKind.Purview,
            cancellationToken);
        if (!IsPurviewCapabilityReady(capability))
            return false;
        var now = UtcNow();
        foreach (var profile in await _profiles.ListAsync(cancellationToken))
        {
            if (profile.IsExactlyReadyFor(profile.BlueprintApplicationId, now) &&
                await IsCurrentInventoryAsync(profile, now, cancellationToken))
                return true;
        }
        return false;
    }

    public async Task<PurviewDlpProfile> RequireReadyProfileAsync(
        Guid blueprintApplicationId,
        PurviewDlpProfileSelectionDto? selection,
        CancellationToken cancellationToken)
    {
        if (blueprintApplicationId == Guid.Empty ||
            selection is null ||
            selection.ProfileId == Guid.Empty ||
            selection.BlueprintApplicationId != blueprintApplicationId)
        {
            throw NotReady();
        }

        var capability = await _capabilities.GetByKindAsync(
            ProtectionCapabilityKind.Purview,
            cancellationToken);
        var profile = await _profiles.GetByIdAsync(
            new PurviewDlpProfileId(selection.ProfileId),
            cancellationToken);
        EnsurePurviewCapability(capability);
        if (profile is null ||
            profile.BlueprintApplicationId.Value !=
                blueprintApplicationId ||
            !profile.IsExactlyReadyFor(
                new BlueprintApplicationId(blueprintApplicationId),
                UtcNow()) ||
            !await IsCurrentInventoryAsync(profile, UtcNow(), cancellationToken))
        {
            throw NotReady();
        }

        if (selection.ExpectedProfileRowVersion is not null)
        {
            ProtectionRowVersion.EnsureMatches(
                selection.ExpectedProfileRowVersion,
                resourceExists: true,
                profile.RowVersion,
                profile.Id.Value,
                profile.UpdatedAtUtc);
        }

        return profile;
    }

    public async Task EnsureRuntimeReadyAsync(
        AgentRegistration agent,
        CancellationToken cancellationToken)
    {
        if (!agent.FeatureConfiguration.PurviewEnabled)
            return;

        var capability = await _capabilities.GetByKindAsync(
            ProtectionCapabilityKind.Purview,
            cancellationToken);
        EnsurePurviewCapability(capability);
        if (!Guid.TryParse(
                agent.BlueprintId,
                out var blueprintApplicationId) ||
            blueprintApplicationId == Guid.Empty)
        {
            throw NotReady();
        }

        var profile = await _profiles.GetByBlueprintApplicationIdAsync(
            new BlueprintApplicationId(blueprintApplicationId),
            cancellationToken);
        if (profile is null ||
            !profile.IsExactlyReadyFor(
                new BlueprintApplicationId(blueprintApplicationId),
                UtcNow()) ||
            !await IsCurrentInventoryAsync(profile, UtcNow(), cancellationToken))
        {
            throw NotReady();
        }
    }

    public async Task<AgentFeaturesDto> ToDtoAsync(
        AgentRegistration agent,
        CancellationToken cancellationToken)
    {
        var destinations =
            agent.FeatureConfiguration.ObservabilityMode.ToDestinations();
        var purviewCapability = await _capabilities.GetByKindAsync(
            ProtectionCapabilityKind.Purview,
            cancellationToken);
        var promptCapability = await _capabilities.GetByKindAsync(
            ProtectionCapabilityKind.PromptShields,
            cancellationToken);

        PurviewDlpProfile? profile = null;
        if (Guid.TryParse(
                agent.BlueprintId,
                out var blueprintApplicationId) &&
            blueprintApplicationId != Guid.Empty)
        {
            profile = await _profiles.GetByBlueprintApplicationIdAsync(
                new BlueprintApplicationId(blueprintApplicationId),
                cancellationToken);
        }

        var capabilityReady = IsPurviewCapabilityReady(purviewCapability);
        var inventoryReady = profile is not null &&
            await IsCurrentInventoryAsync(profile, UtcNow(), cancellationToken);
        var purviewReady =
            agent.FeatureConfiguration.PurviewEnabled &&
            capabilityReady && inventoryReady &&
            profile is not null &&
            profile.IsExactlyReadyFor(
                profile.BlueprintApplicationId,
                UtcNow());
        var promptReady =
            agent.FeatureConfiguration.PromptShieldEnabled &&
            IsPromptShieldReady(promptCapability);
        return new AgentFeaturesDto(
            agent.FeatureConfiguration.ObservabilityMode.ToString(),
            agent.FeatureConfiguration.PurviewEnabled,
            agent.FeatureConfiguration.PurviewMode?.ToString(),
            destinations.Agent365ObservabilityEnabled,
            destinations.AzureMonitorExportEnabled,
            agent.FeatureConfiguration.PromptShieldEnabled,
            profile is null
                ? null
                : new PurviewDlpProfileSelectionDto(
                    profile.Id.Value,
                    profile.BlueprintApplicationId.Value,
                    ProtectionRowVersion.Encode(
                        profile.RowVersion,
                        profile.Id.Value,
                        profile.UpdatedAtUtc)),
            PurviewEffectivelyEnabled: purviewReady,
            PurviewReadiness: profile is null
                ? null
                : ToReadinessDto(profile, purviewCapability, capabilityReady, inventoryReady),
            PromptShieldEffectivelyEnabled: promptReady,
            PromptShieldCapabilityStatus:
                promptCapability?.Status.ToString());
    }

    private static bool IsInstalled(ProtectionCapability? capability) =>
        capability is
        {
            Status: ProtectionCapabilityStatus.Installed,
            LastReadbackAtUtc: not null
        };

    private bool IsPromptShieldReady(ProtectionCapability? capability) =>
        IsInstalled(capability) &&
        _promptShieldBinding?.IsExact(capability) == true;

    private bool IsPurviewCapabilityReady(ProtectionCapability? capability) =>
        IsInstalled(capability) && _purviewBinding?.IsExact(capability) == true;

    private async Task<bool> IsCurrentInventoryAsync(
        PurviewDlpProfile profile, DateTime now, CancellationToken cancellationToken)
    {
        if (_connections is null || _inventory is null ||
            profile.PurviewTenantConnectionId == Guid.Empty ||
            profile.InventoryGenerationId.Value == Guid.Empty ||
            profile.SensitiveInformationTypeId.Value == Guid.Empty)
            return false;

        var connection = await _connections.GetByIdAsync(profile.PurviewTenantConnectionId, cancellationToken);
        if (connection is null || connection.Id != profile.PurviewTenantConnectionId ||
            !connection.IsUsableAt(now) ||
            connection.ActiveInventoryGenerationId != profile.InventoryGenerationId)
            return false;

        var inventory = await _inventory.GetGenerationAsync(profile.InventoryGenerationId, cancellationToken);
        return inventory is not null && inventory.Id == profile.InventoryGenerationId &&
            inventory.PurviewTenantConnectionId == connection.Id && inventory.TenantId == connection.TenantId &&
            !inventory.IsExpired(now) && inventory.ExpiresAtUtc == profile.SensitiveInformationTypeSnapshotExpiresAtUtc &&
            inventory.Items.Count(item => item.GenerationId == inventory.Id &&
                item.SensitiveInformationTypeId == profile.SensitiveInformationTypeId &&
                string.Equals(item.ExactName, profile.SensitiveInformationTypeName, StringComparison.Ordinal)) == 1;
    }

    public async Task<PurviewDlpProfileDto> ToProfileDtoAsync(
        PurviewDlpProfile profile, CancellationToken cancellationToken)
    {
        var capability = await _capabilities.GetByKindAsync(ProtectionCapabilityKind.Purview, cancellationToken);
        var dto = ProtectionAdministrationMapper.ToDto(profile, UtcNow());
        return dto with
        {
            Readiness = ToReadinessDto(profile, capability, IsPurviewCapabilityReady(capability),
                await IsCurrentInventoryAsync(profile, UtcNow(), cancellationToken))
        };
    }

    private ProtectionReadinessDto ToReadinessDto(
        PurviewDlpProfile profile, ProtectionCapability? capability, bool capabilityReady, bool inventoryReady)
    {
        var readiness = ProtectionAdministrationMapper.ToDto(profile, UtcNow()).Readiness;
        return readiness with
        {
            Capability = capabilityReady ? readiness.Capability : ProtectionCapabilityStatus.Unavailable.ToString(),
            IsReady = readiness.IsReady && capabilityReady && inventoryReady,
            Blockers = readiness.Blockers
                .Concat(capabilityReady ? [] : new[] { ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE })
                .Concat(inventoryReady ? [] : new[] { ErrorCodes.PURVIEW_INVENTORY_STALE })
                .Distinct(StringComparer.Ordinal).ToArray(),
            CapabilityReadbackAtUtc = capabilityReady ? capability?.LastReadbackAtUtc : null
        };
    }

    private DateTime UtcNow() => _timeProvider.GetUtcNow().UtcDateTime;

    private static DomainException NotReady() =>
        new(
            "Purview requires the exact Ready DLP profile for this registration blueprint.",
            ErrorCodes.PURVIEW_DLP_PROFILE_NOT_READY);

    private void EnsurePurviewCapability(
        ProtectionCapability? capability)
    {
        if (!IsPurviewCapabilityReady(capability))
        {
            throw new DomainException(
                "Purview requires an exact installed capability readback.",
                ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE);
        }
    }
}
