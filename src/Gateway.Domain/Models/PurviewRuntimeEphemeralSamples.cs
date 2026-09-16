using System.Collections.Immutable;

namespace Gateway.Domain.Models;

public sealed class PurviewRuntimeEphemeralSample : IDisposable
{
    private string? _content;

    public PurviewRuntimeEphemeralSample(Guid caseId, string content)
    {
        CaseId = caseId;
        _content = content ?? throw new ArgumentNullException(nameof(content));
    }

    public Guid CaseId { get; }

    // A method rather than a property keeps content out of default JSON/state serialization.
    public string ReadContent() =>
        Volatile.Read(ref _content) ?? throw new ObjectDisposedException(nameof(PurviewRuntimeEphemeralSample));

    public void Dispose() => Interlocked.Exchange(ref _content, null);

    public override string ToString() =>
        $"{nameof(PurviewRuntimeEphemeralSample)} {{ CaseId = {CaseId:D}, Content = [redacted] }}";
}

public sealed class PurviewRuntimeEphemeralBatch : IDisposable
{
    private readonly ImmutableArray<PurviewRuntimeEphemeralSample> _samples;

    public PurviewRuntimeEphemeralBatch(
        IEnumerable<PurviewRuntimeEphemeralSample> samples,
        string suiteHash,
        string reviewedContextFingerprint)
    {
        _samples = samples.ToImmutableArray();
        SuiteHash = suiteHash;
        ReviewedContextFingerprint = reviewedContextFingerprint;
    }

    public string SuiteHash { get; }
    public string ReviewedContextFingerprint { get; }
    public ImmutableArray<Guid> CaseIds => _samples.Select(sample => sample.CaseId).ToImmutableArray();

    public PurviewRuntimeEphemeralSample GetSample(Guid caseId) =>
        _samples.Single(sample => sample.CaseId == caseId);

    public void Dispose()
    {
        foreach (var sample in _samples)
            sample.Dispose();
    }

    public override string ToString() => $"{nameof(PurviewRuntimeEphemeralBatch)} {{ Content = [redacted] }}";
}
