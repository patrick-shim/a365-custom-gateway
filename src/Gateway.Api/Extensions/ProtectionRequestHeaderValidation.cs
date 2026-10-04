using Gateway.Application.Exceptions;
using Gateway.Contracts;

namespace Gateway.Api.Extensions;

internal static class ProtectionRequestHeaderValidation
{
    private const string IdempotencyHeader = "Idempotency-Key";
    private const string IfMatchHeader = "If-Match";

    public static void RequireReviewHeaders(
        HttpRequest request,
        string expectedRowVersion)
    {
        ArgumentNullException.ThrowIfNull(request);
        var ifMatch = ReadSingleHeader(request, IfMatchHeader);
        if (!string.Equals(
                ifMatch,
                expectedRowVersion,
                StringComparison.Ordinal) ||
            !IsExpectedRowVersion(expectedRowVersion))
        {
            throw Precondition();
        }
    }

    public static void RequireMutationHeaders(
        HttpRequest request,
        Guid idempotencyKey,
        string expectedRowVersion)
    {
        ArgumentNullException.ThrowIfNull(request);
        var suppliedIdempotencyKey = ReadSingleHeader(
            request,
            IdempotencyHeader);
        var suppliedIfMatch = ReadSingleHeader(request, IfMatchHeader);
        var canonicalKey = idempotencyKey.ToString("D");
        if (!IdempotencyKeyValidation.TryNormalizeUuidV4(
                suppliedIdempotencyKey,
                out var normalizedKey) ||
            !string.Equals(
                suppliedIdempotencyKey,
                normalizedKey,
                StringComparison.Ordinal) ||
            !string.Equals(
                canonicalKey,
                normalizedKey,
                StringComparison.Ordinal))
        {
            throw new ValidationException(new Dictionary<string, string[]>
            {
                [IdempotencyHeader] =
                ["Idempotency-Key must be one canonical lowercase UUIDv4 value and match the request body."]
            });
        }

        if (!string.Equals(
                suppliedIfMatch,
                expectedRowVersion,
                StringComparison.Ordinal) ||
            !IsExpectedRowVersion(expectedRowVersion))
        {
            throw Precondition();
        }
    }

    private static string? ReadSingleHeader(
        HttpRequest request,
        string name)
    {
        var values = request.Headers[name];
        return values.Count == 1 ? values[0] : null;
    }

    private static bool IsExpectedRowVersion(string value)
    {
        if (string.Equals(value, "*", StringComparison.Ordinal))
            return true;
        return RowVersionValidation.IsCanonical(value);
    }

    private static PreconditionFailedException Precondition() =>
        new(
            "If-Match must be one exact row version matching the reviewed request body.",
            ErrorCodes.CONCURRENCY_CONFLICT);
}
