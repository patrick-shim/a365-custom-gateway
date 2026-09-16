using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;

namespace Gateway.AdminUi.Models;

public sealed class PurviewRuntimeReviewTicket
{
    private string? token;

    internal PurviewRuntimeReviewTicket(PurviewRuntimeTestReviewResponse response, ReviewPurviewDlpRuntimeTestRequest request)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(response.ReviewToken);
        if (response.ReviewTokenId == Guid.Empty || !RuntimeTestUiProtocol.Matches(request, response.Review))
            throw new InvalidOperationException("The runtime review does not match the requested manifest.");
        ReviewTokenId = response.ReviewTokenId;
        ExpiresAtUtc = response.ExpiresAtUtc;
        Review = response.Review;
        ExpectedRowVersion = request.ExpectedRowVersion;
        token = response.ReviewToken;
    }

    public Guid ReviewTokenId { get; }
    public DateTime ExpiresAtUtc { get; }
    public PurviewRuntimeTestReviewDto Review { get; }
    public string ExpectedRowVersion { get; }
    public bool IsAvailable => token is not null && ExpiresAtUtc > DateTime.UtcNow;
    public void Discard() => Interlocked.Exchange(ref token, null);
    internal RuntimeBrowserAuthorization ConsumeForBrowser()
    {
        if (!IsAvailable || Review.PolicyMode == "Disabled")
        {
            Discard();
            throw new InvalidOperationException("A fresh, non-disabled runtime review is required.");
        }
        return new(Review.ProfileId, ReviewTokenId,
            Interlocked.Exchange(ref token, null) ?? throw new InvalidOperationException("Runtime confirmation was already used."),
            Guid.NewGuid(), ExpectedRowVersion, Review.PolicyMode, Review.SuiteHash, Review.Suite.SuiteNonce,
            Review.PositiveCaseIds, Review.Suite.NegativeSample.CaseId);
    }
    public override string ToString() => nameof(PurviewRuntimeReviewTicket);
}

// Authorization metadata only. Raw content is assembled exclusively in the browser module.
public sealed record RuntimeBrowserAuthorization(
    Guid ProfileId, Guid ReviewTokenId, string ReviewToken, Guid IdempotencyKey,
    string ExpectedRowVersion, string PolicyMode, string SuiteHash, string SuiteNonce, IReadOnlyList<Guid> PositiveCaseIds, Guid NegativeCaseId)
{
    public override string ToString() => nameof(RuntimeBrowserAuthorization);
}

public sealed record RuntimePreparedManifest(PurviewRuntimeTestSuiteManifestDto Suite, IReadOnlyList<IReadOnlyList<Guid>> Batches);
public sealed record RuntimeBrowserExecutionResult(PurviewRuntimeTestResultResponse? Report, bool OutcomeUnknown, Guid OperationId);

// HTTP bridge body only, never a circuit model. Confirmation is exchanged and retained only in this request's BFF scope.
public sealed class RuntimePortalExecutionRequest(
    Guid reviewTokenId, string reviewToken, Guid idempotencyKey, string expectedRowVersion,
    IReadOnlyList<PurviewRuntimeTestSampleContentDto> samples)
{
    public Guid ReviewTokenId { get; } = reviewTokenId;
    public string ReviewToken { get; } = reviewToken;
    public Guid IdempotencyKey { get; } = idempotencyKey;
    public string ExpectedRowVersion { get; } = expectedRowVersion;
    public IReadOnlyList<PurviewRuntimeTestSampleContentDto> Samples { get; } = Array.AsReadOnly(samples?.ToArray() ?? []);
    public override string ToString() => nameof(RuntimePortalExecutionRequest);
}
