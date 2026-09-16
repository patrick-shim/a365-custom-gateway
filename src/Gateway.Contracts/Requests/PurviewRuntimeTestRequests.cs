using System.Collections.Immutable;
using System.Text.Json.Serialization;
using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Requests;

public sealed class ReviewPurviewDlpRuntimeTestRequest
{
    [JsonConstructor]
    public ReviewPurviewDlpRuntimeTestRequest(
        Guid profileId,
        string expectedRowVersion,
        Guid inventoryGenerationId,
        PurviewRuntimeTestSuiteManifestDto suite,
        IReadOnlyList<Guid> positiveCaseIds,
        bool acknowledgeSyntheticData)
    {
        ProfileId = profileId;
        ExpectedRowVersion = expectedRowVersion;
        InventoryGenerationId = inventoryGenerationId;
        Suite = suite;
        PositiveCaseIds = positiveCaseIds?.ToImmutableArray() ?? [];
        AcknowledgeSyntheticData = acknowledgeSyntheticData;
    }

    public Guid ProfileId { get; }
    public string ExpectedRowVersion { get; }
    public Guid InventoryGenerationId { get; }
    public PurviewRuntimeTestSuiteManifestDto Suite { get; }
    public IReadOnlyList<Guid> PositiveCaseIds { get; }
    public bool AcknowledgeSyntheticData { get; }
    public override string ToString() => nameof(ReviewPurviewDlpRuntimeTestRequest);
}

public sealed class ExecutePurviewDlpRuntimeTestRequest
{
    [JsonConstructor]
    public ExecutePurviewDlpRuntimeTestRequest(
        Guid confirmationTokenId,
        string confirmationToken,
        Guid idempotencyKey,
        string expectedRowVersion,
        IReadOnlyList<PurviewRuntimeTestSampleContentDto> samples)
    {
        ConfirmationTokenId = confirmationTokenId;
        ConfirmationToken = confirmationToken;
        IdempotencyKey = idempotencyKey;
        ExpectedRowVersion = expectedRowVersion;
        Samples = samples?.ToImmutableArray() ?? [];
    }

    public Guid ConfirmationTokenId { get; }
    public string ConfirmationToken { get; }
    public Guid IdempotencyKey { get; }
    public string ExpectedRowVersion { get; }
    public IReadOnlyList<PurviewRuntimeTestSampleContentDto> Samples { get; }
    public override string ToString() => $"{nameof(ExecutePurviewDlpRuntimeTestRequest)} {{ ContentAndToken = [redacted] }}";
}
