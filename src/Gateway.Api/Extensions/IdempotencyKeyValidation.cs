namespace Gateway.Api.Extensions;

internal static class IdempotencyKeyValidation
{
    public static bool TryNormalizeUuidV4(string? value, out string normalized)
    {
        normalized = string.Empty;

        if (value is null ||
            value.Length != 36 ||
            value[14] != '4' ||
            !IsRfc4122Variant(value[19]) ||
            !Guid.TryParseExact(value, "D", out var parsed))
        {
            return false;
        }

        normalized = parsed.ToString("D");
        return true;
    }

    private static bool IsRfc4122Variant(char value) =>
        value is '8' or '9' or 'a' or 'b' or 'A' or 'B';
}
