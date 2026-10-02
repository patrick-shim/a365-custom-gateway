using System.Globalization;

namespace Gateway.Infrastructure.Persistence;

public sealed record DatabaseUpgradeQueueQuarantineObservation(
    int SchemaVersion,
    string EvidenceKind,
    string PlanFingerprint,
    string UpgradeSourceFingerprint,
    string BaselineFingerprint,
    string ObservedAtUtc,
    string Phase)
{
    public const string CountOnly = "NormalDeadLetterCountOnly";

    public void AssertValid(string phase)
    {
        if (SchemaVersion != 1 || EvidenceKind != CountOnly || Phase != phase ||
            !DatabaseUpgradeAttestation.IsFingerprint(PlanFingerprint) ||
            !DatabaseUpgradeAttestation.IsFingerprint(UpgradeSourceFingerprint) ||
            !DatabaseUpgradeAttestation.IsFingerprint(BaselineFingerprint) || !IsCanonicalUtc(ObservedAtUtc))
            throw new InvalidOperationException("UpgradeQueueQuarantineInvalid: exact phase-bound count-only evidence is required.");
    }

    public static bool IsCanonicalUtc(string? value) =>
        DateTimeOffset.TryParseExact(value, "O", CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed) &&
        parsed.Offset == TimeSpan.Zero && parsed.ToString("O", CultureInfo.InvariantCulture) == value;
}

public sealed record DatabaseUpgradeQueueQuarantineProof(
    DatabaseUpgradeQueueQuarantineObservation Before,
    DatabaseUpgradeQueueQuarantineObservation After)
{
    public void AssertValid()
    {
        if (Before is null || After is null)
            throw new InvalidOperationException("UpgradeQueueQuarantineMissing: both held observations are required.");
        Before.AssertValid("SqlBefore");
        After.AssertValid("SqlAfter");
        if (Before.PlanFingerprint != After.PlanFingerprint ||
            Before.UpgradeSourceFingerprint != After.UpgradeSourceFingerprint ||
            Before.BaselineFingerprint != After.BaselineFingerprint ||
            string.CompareOrdinal(Before.ObservedAtUtc, After.ObservedAtUtc) > 0)
            throw new InvalidOperationException("UpgradeQueueQuarantineMismatch: no changed or rebaselined queue evidence is accepted.");
    }
}
