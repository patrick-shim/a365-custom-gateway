namespace Gateway.Contracts;

public static class RowVersionValidation
{
    // PostgreSQL application-generated concurrency tokens.
    public static bool IsCanonical(string? value)
    {
        if (value is null || value.Length != 24)
            return false;

        Span<byte> bytes = stackalloc byte[16];
        return Convert.TryFromBase64String(value, bytes, out var length) &&
            length == 16 &&
            Convert.ToBase64String(bytes[..length]) == value;
    }
}
