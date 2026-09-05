using Gateway.Domain.Enums;
using Gateway.Domain.Models;

namespace Gateway.Purview;

public static class PurviewReadinessEvaluator
{
    public static readonly TimeSpan MaximumEvidenceAge = TimeSpan.FromMinutes(30);

    public static ProtectionReadiness Evaluate(PurviewReadinessEvidence evidence) =>
        Evaluate(evidence, DateTimeOffset.UtcNow);

    public static ProtectionReadiness Evaluate(
        PurviewReadinessEvidence evidence,
        DateTimeOffset utcNow)
    {
        ArgumentNullException.ThrowIfNull(evidence);
        if (utcNow.Offset != TimeSpan.Zero)
            throw new ArgumentException("The readiness clock must be UTC.", nameof(utcNow));

        var readback = evidence.Readback == ProtectionReadbackStatus.Ready &&
            !IsCurrentUtcEvidence(evidence.ExactReadbackAtUtc, utcNow)
                ? ProtectionReadbackStatus.Failed
                : evidence.Readback;
        var propagation = evidence.Propagation == ProtectionPropagationStatus.Ready &&
            !IsCurrentUtcEvidence(evidence.PropagationVerifiedAtUtc, utcNow)
                ? ProtectionPropagationStatus.Failed
                : evidence.Propagation;
        var tokenRoles = evidence.TokenRoles == ProtectionTokenRoleStatus.Ready &&
            !IsCurrentUtcEvidence(evidence.TokenRolesVerifiedAtUtc, utcNow)
                ? ProtectionTokenRoleStatus.Failed
                : evidence.TokenRoles;
        var runtimeVerdict = evidence.RuntimeVerdict ==
                ProtectionRuntimeVerdictStatus.Ready &&
            (!IsCurrentUtcEvidence(evidence.RuntimeAllowVerifiedAtUtc, utcNow) ||
             !IsCurrentUtcEvidence(evidence.RuntimeBlockVerifiedAtUtc, utcNow))
                ? ProtectionRuntimeVerdictStatus.Failed
                : evidence.RuntimeVerdict;
        return new ProtectionReadiness(
            evidence.Capability,
            readback,
            propagation,
            tokenRoles,
            runtimeVerdict);
    }

    private static bool IsCurrentUtcEvidence(
        DateTimeOffset? value,
        DateTimeOffset utcNow) =>
        value is not null &&
        value.Value.Offset == TimeSpan.Zero &&
        value.Value <= utcNow.AddMinutes(2) &&
        value.Value >= utcNow.Subtract(MaximumEvidenceAge);
}
