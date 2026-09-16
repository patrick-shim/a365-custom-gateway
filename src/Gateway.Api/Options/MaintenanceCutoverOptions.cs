using Gateway.Infrastructure.Persistence;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Options;

public enum MaintenanceCutoverPhase
{
    Open,
    PreSchemaClosed,
    PostSchemaClosed
}

public sealed record MaintenanceCutoverOptions
{
    public const string SectionName = "MaintenanceCutover";

    public MaintenanceCutoverPhase Phase { get; }
    public string? CutoverId { get; }
    public string? PlanFingerprint { get; }
    public string? CandidateSourceFingerprint { get; }

    private MaintenanceCutoverOptions(
        MaintenanceCutoverPhase phase, string? cutoverId, string? planFingerprint,
        string? candidateSourceFingerprint)
    {
        Phase = phase;
        CutoverId = cutoverId;
        PlanFingerprint = planFingerprint;
        CandidateSourceFingerprint = candidateSourceFingerprint;
    }

    // Capture once, before any normal service registration: configuration reload cannot reopen a host.
    public static MaintenanceCutoverOptions Read(IConfiguration configuration)
    {
        var section = configuration.GetSection(SectionName);
        var keys = new[] { nameof(Phase), nameof(CutoverId), nameof(PlanFingerprint), nameof(CandidateSourceFingerprint) };
        if (section.Value is not null && (section.Value.Length != 0 || !section.GetChildren().Any()) ||
            section.GetChildren().Any(child =>
                !keys.Contains(child.Key, StringComparer.OrdinalIgnoreCase) || child.GetChildren().Any()))
            throw InvalidConfiguration();

        var phaseText = section[nameof(Phase)];
        var phase = phaseText switch
        {
            null when !section.GetChildren().Any() => MaintenanceCutoverPhase.Open,
            nameof(MaintenanceCutoverPhase.Open) => MaintenanceCutoverPhase.Open,
            nameof(MaintenanceCutoverPhase.PreSchemaClosed) => MaintenanceCutoverPhase.PreSchemaClosed,
            nameof(MaintenanceCutoverPhase.PostSchemaClosed) => MaintenanceCutoverPhase.PostSchemaClosed,
            _ => throw InvalidConfiguration()
        };
        var cutoverId = section[nameof(CutoverId)];
        var plan = section[nameof(PlanFingerprint)];
        var candidate = section[nameof(CandidateSourceFingerprint)];
        if (phase == MaintenanceCutoverPhase.Open)
        {
            if (section.GetChildren().Any(child => !child.Key.Equals(nameof(Phase), StringComparison.OrdinalIgnoreCase)))
                throw InvalidConfiguration();
        }
        else if (!DatabaseUpgradeAttestation.IsCanonicalGuid(cutoverId) ||
                 plan is not { Length: 71 } || !DatabaseUpgradeAttestation.IsFingerprint(plan) ||
                 candidate is not { Length: 71 } || !DatabaseUpgradeAttestation.IsFingerprint(candidate))
            throw InvalidConfiguration();

        return new MaintenanceCutoverOptions(phase, cutoverId, plan, candidate);
    }

    private static OptionsValidationException InvalidConfiguration() => new(
        SectionName, typeof(MaintenanceCutoverOptions),
        ["MaintenanceCutover requires an exact phase and canonical closed-phase pins; unknown controls and Open with pins are forbidden."]);
}
