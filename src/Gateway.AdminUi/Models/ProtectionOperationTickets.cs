using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;

namespace Gateway.AdminUi.Models;

/// <summary>
/// Holds a short-lived review token only for the lifetime of the current UI circuit.
/// The opaque value is consumed once and is never exposed as a public property.
/// </summary>
public sealed class ProtectionOperationReviewTicket
{
    private string? _reviewToken;

    internal ProtectionOperationReviewTicket(
        ProtectionOperationReviewResponse response,
        string expectedRowVersion)
    {
        ArgumentNullException.ThrowIfNull(response);
        ArgumentException.ThrowIfNullOrWhiteSpace(response.ReviewToken);
        ArgumentException.ThrowIfNullOrWhiteSpace(response.ReviewedPayloadHash);
        ArgumentNullException.ThrowIfNull(response.Review);
        ValidateRowVersion(expectedRowVersion, nameof(expectedRowVersion));

        if (response.ReviewTokenId == Guid.Empty)
        {
            throw new ArgumentException("The review token identifier cannot be empty.", nameof(response));
        }

        ValidateReview(response.Review, nameof(response));

        ReviewTokenId = response.ReviewTokenId;
        ReviewedPayloadHash = response.ReviewedPayloadHash;
        ExpiresAtUtc = response.ExpiresAtUtc;
        Review = CopyReview(response.Review);
        ExpectedRowVersion = expectedRowVersion;
        _reviewToken = response.ReviewToken;
    }

    public Guid ReviewTokenId { get; }

    public string ReviewedPayloadHash { get; }

    public DateTime ExpiresAtUtc { get; }

    public ProtectionOperationReviewSummaryDto Review { get; }

    public string ExpectedRowVersion { get; }

    public bool IsAvailable => Volatile.Read(ref _reviewToken) is not null;

    public void Discard() => Interlocked.Exchange(ref _reviewToken, null);

    internal ConfirmProtectionOperationReviewRequest Consume()
    {
        var token = Interlocked.Exchange(ref _reviewToken, null);
        if (token is null)
        {
            throw new InvalidOperationException("This protection operation review has already been used.");
        }

        return new ConfirmProtectionOperationReviewRequest(ReviewTokenId, token);
    }

    private static void ValidateReview(
        ProtectionOperationReviewSummaryDto review,
        string parameterName)
    {
        if (review.TenantId == Guid.Empty ||
            string.IsNullOrWhiteSpace(review.OperationType) ||
            string.IsNullOrWhiteSpace(review.TargetType) ||
            string.IsNullOrWhiteSpace(review.TargetIdentifier) ||
            string.IsNullOrWhiteSpace(review.ScopeType) ||
            string.IsNullOrWhiteSpace(review.EnforcementPlane) ||
            string.IsNullOrWhiteSpace(review.ReadinessDisclaimer) ||
            review.Activities is null ||
            review.Actions is null)
        {
            throw new ArgumentException(
                "The protection operation review metadata is incomplete.",
                parameterName);
        }
    }

    private static void ValidateRowVersion(string value, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Contains('\r') || value.Contains('\n'))
        {
            throw new ArgumentException("The expected row version is invalid.", parameterName);
        }
    }

    private static ProtectionOperationReviewSummaryDto CopyReview(
        ProtectionOperationReviewSummaryDto review) =>
        review with
        {
            Activities = Array.AsReadOnly(review.Activities.ToArray()),
            Actions = Array.AsReadOnly(review.Actions.ToArray())
        };

    public override string ToString() =>
        $"{nameof(ProtectionOperationReviewTicket)} {{ ReviewTokenId = {ReviewTokenId:D}, ExpiresAtUtc = {ExpiresAtUtc:O}, IsAvailable = {IsAvailable} }}";
}

/// <summary>
/// Holds a short-lived confirmation token only for the lifetime of the current UI
/// circuit. The opaque value is consumed before the corresponding mutation is sent.
/// </summary>
public sealed class ProtectionOperationConfirmationTicket
{
    private string? _confirmationToken;

    internal ProtectionOperationConfirmationTicket(
        ProtectionOperationConfirmationResponse response,
        ProtectionOperationReviewSummaryDto review,
        string expectedRowVersion)
    {
        ArgumentNullException.ThrowIfNull(response);
        ArgumentNullException.ThrowIfNull(review);
        ArgumentException.ThrowIfNullOrWhiteSpace(response.ConfirmationToken);
        if (string.IsNullOrWhiteSpace(expectedRowVersion) ||
            expectedRowVersion.Contains('\r') ||
            expectedRowVersion.Contains('\n'))
        {
            throw new ArgumentException(
                "The expected row version is invalid.",
                nameof(expectedRowVersion));
        }

        if (response.ReviewTokenId == Guid.Empty)
        {
            throw new ArgumentException("The review token identifier cannot be empty.", nameof(response));
        }

        if (response.ConfirmationTokenId == Guid.Empty)
        {
            throw new ArgumentException(
                "The confirmation token identifier cannot be empty.",
                nameof(response));
        }

        ReviewTokenId = response.ReviewTokenId;
        ConfirmationTokenId = response.ConfirmationTokenId;
        ExpiresAtUtc = response.ExpiresAtUtc;
        Review = review with
        {
            Activities = Array.AsReadOnly(review.Activities.ToArray()),
            Actions = Array.AsReadOnly(review.Actions.ToArray())
        };
        ExpectedRowVersion = expectedRowVersion;
        _confirmationToken = response.ConfirmationToken;
    }

    public Guid ReviewTokenId { get; }

    public Guid ConfirmationTokenId { get; }

    public DateTime ExpiresAtUtc { get; }

    public ProtectionOperationReviewSummaryDto Review { get; }

    public string ExpectedRowVersion { get; }

    public bool IsAvailable => Volatile.Read(ref _confirmationToken) is not null;

    public void Discard() => Interlocked.Exchange(ref _confirmationToken, null);

    internal string Consume()
    {
        var token = Interlocked.Exchange(ref _confirmationToken, null);
        return token ??
            throw new InvalidOperationException(
                "This protection operation confirmation has already been used.");
    }

    public override string ToString() =>
        $"{nameof(ProtectionOperationConfirmationTicket)} {{ ReviewTokenId = {ReviewTokenId:D}, ConfirmationTokenId = {ConfirmationTokenId:D}, ExpiresAtUtc = {ExpiresAtUtc:O}, IsAvailable = {IsAvailable} }}";
}
