namespace Gateway.Contracts.Dtos;

public sealed record ProtectionReadinessDto(
    string Capability,
    string Readback,
    string Propagation,
    string TokenRoles,
    string RuntimeVerdict,
    bool IsReady,
    IReadOnlyList<string> Blockers,
    DateTime? EvaluatedAtUtc,
    DateTime? CapabilityReadbackAtUtc = null,
    DateTime? PolicyReadbackAtUtc = null,
    DateTime? PropagationVerifiedAtUtc = null,
    DateTime? TokenRolesVerifiedAtUtc = null,
    DateTime? RuntimeAllowVerifiedAtUtc = null,
    DateTime? RuntimeBlockVerifiedAtUtc = null);
