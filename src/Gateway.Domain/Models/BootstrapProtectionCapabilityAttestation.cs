using Gateway.Domain.Enums;

namespace Gateway.Domain.Models;

public sealed record BootstrapProtectionCapabilityAttestation(
    Guid DeploymentOwnershipId,
    string AcceptedSourceFingerprint,
    DateTime AttestedAtUtc,
    IReadOnlyList<BootstrapProtectionCapabilityFact> Capabilities);

public sealed record BootstrapProtectionCapabilityFact(
    ProtectionCapabilityKind Kind,
    ProtectionCapabilityStatus Status,
    ProtectionCapabilityResourceIdentifiers ResourceIdentifiers);
