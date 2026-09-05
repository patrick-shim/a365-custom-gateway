using System.Security.Cryptography;
using System.Text;
using Gateway.Application.Exceptions;
using Gateway.Contracts;

namespace Gateway.Application.Protection;

internal static class ProtectionRowVersion
{
    private const int SqlRowVersionBytes = 8;

    public static string Encode(
        byte[] rowVersion,
        Guid resourceId,
        DateTime updatedAtUtc)
    {
        ArgumentNullException.ThrowIfNull(rowVersion);
        if (rowVersion.Length > 0)
        {
            return Convert.ToBase64String(rowVersion);
        }

        var material = Encoding.UTF8.GetBytes(
            $"{resourceId:D}\n{updatedAtUtc.ToUniversalTime().Ticks}");
        try
        {
            return Convert.ToBase64String(SHA256.HashData(material)[..SqlRowVersionBytes]);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(material);
        }
    }

    public static byte[] DecodeExpected(string expectedRowVersion)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(expectedRowVersion);
        if (string.Equals(expectedRowVersion, "*", StringComparison.Ordinal))
        {
            return [];
        }

        try
        {
            var decoded = Convert.FromBase64String(expectedRowVersion);
            if (decoded.Length != SqlRowVersionBytes ||
                !string.Equals(
                    Convert.ToBase64String(decoded),
                    expectedRowVersion,
                    StringComparison.Ordinal))
            {
                throw Invalid();
            }

            return decoded;
        }
        catch (FormatException)
        {
            throw Invalid();
        }
    }

    public static string EncodeExpected(byte[] expectedRowVersion) =>
        expectedRowVersion.Length == 0
            ? "*"
            : Convert.ToBase64String(expectedRowVersion);

    public static void EnsureMatches(
        string expectedRowVersion,
        bool resourceExists,
        byte[]? actualRowVersion,
        Guid resourceId,
        DateTime updatedAtUtc)
    {
        if (!resourceExists)
        {
            if (!string.Equals(expectedRowVersion, "*", StringComparison.Ordinal))
            {
                throw Changed();
            }

            return;
        }

        if (string.Equals(expectedRowVersion, "*", StringComparison.Ordinal) ||
            actualRowVersion is null)
        {
            throw Changed();
        }

        _ = DecodeExpected(expectedRowVersion);
        var actual = Encode(actualRowVersion, resourceId, updatedAtUtc);
        if (!string.Equals(actual, expectedRowVersion, StringComparison.Ordinal))
        {
            throw Changed();
        }
    }

    private static PreconditionFailedException Invalid() =>
        new(
            "If-Match must contain the exact canonical row version returned by the Gateway.",
            ErrorCodes.CONCURRENCY_CONFLICT);

    private static PreconditionFailedException Changed() =>
        new(
            "The protection resource changed. Refresh it and review the operation again.",
            ErrorCodes.CONCURRENCY_CONFLICT);
}
