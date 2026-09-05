using Gateway.Api.Options;
using Gateway.Application.Protection;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Purview;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Infrastructure;

public sealed class BootstrapPurviewRuntimeBinding(
    IOptions<BootstrapCapabilitiesOptions> bootstrapOptions,
    IOptions<PurviewOptions> purviewOptions,
    IConfiguration configuration) : IBootstrapPurviewRuntimeBinding, IPurviewRuntimeIdentityBinding
{
    public bool IsExact(string? clientId, Guid? principalObjectId) =>
        IsRuntimeConfigurationExact(bootstrapOptions.Value, purviewOptions.Value) &&
        string.Equals(clientId, configuration["PurviewRuntimeIdentity:ManagedIdentityClientId"], StringComparison.Ordinal) &&
        string.Equals(principalObjectId?.ToString("D"),
            bootstrapOptions.Value.Purview.PurviewRuntimeManagedIdentityPrincipalObjectId, StringComparison.Ordinal);

    public bool IsExact(ProtectionCapability? capability)
    {
        var bootstrap = bootstrapOptions.Value;
        var runtime = purviewOptions.Value;
        if (!IsRuntimeConfigurationExact(bootstrap, runtime) ||
            capability is not
            {
                Kind: ProtectionCapabilityKind.Purview,
                Status: ProtectionCapabilityStatus.Installed,
                LastFailureCode: null
            })
        {
            return false;
        }

        var attestation = BootstrapCapabilitiesOptionsValidator.CreateAttestation(bootstrap);
        var fact = attestation.Capabilities.Single(item => item.Kind == ProtectionCapabilityKind.Purview);
        return fact.Status == ProtectionCapabilityStatus.Installed &&
            capability.LastReadbackAtUtc == attestation.AttestedAtUtc &&
            capability.ResourceIdentifiers == fact.ResourceIdentifiers;
    }

    private bool IsRuntimeConfigurationExact(BootstrapCapabilitiesOptions bootstrap, PurviewOptions runtime) =>
        bootstrap.Enabled && runtime.Enabled &&
        new BootstrapCapabilitiesOptionsValidator().Validate(null, bootstrap).Succeeded &&
        string.Equals(bootstrap.Purview.Status, "Installed", StringComparison.Ordinal) &&
        TryCanonicalGuid(configuration["PurviewRuntimeIdentity:ManagedIdentityClientId"], out var clientId) &&
        TryCanonicalGuid(configuration["PurviewRuntimeIdentity:ManagedIdentityPrincipalObjectId"], out var principalId) &&
        string.Equals(principalId.ToString("D"),
            bootstrap.Purview.PurviewRuntimeManagedIdentityPrincipalObjectId, StringComparison.Ordinal) &&
        (string.IsNullOrEmpty(runtime.ManagedIdentityClientId) ||
            string.Equals(runtime.ManagedIdentityClientId, clientId.ToString("D"), StringComparison.Ordinal));

    private static bool TryCanonicalGuid(string? value, out Guid parsed) =>
        Guid.TryParseExact(value, "D", out parsed) && parsed != Guid.Empty &&
        string.Equals(value, parsed.ToString("D"), StringComparison.Ordinal);
}
