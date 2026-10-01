namespace Gateway.Setup.Services;

internal static class PlanFingerprintPolicy
{
    private const string Prefix = "sha256:";
    private const int DigestCharacters = 64;

    public static bool IsCanonical(string? value)
    {
        if (value is null ||
            value.Length != Prefix.Length + DigestCharacters ||
            !value.StartsWith(Prefix, StringComparison.Ordinal))
        {
            return false;
        }

        foreach (var character in value.AsSpan(Prefix.Length))
        {
            if (!IsLowerHexCharacter(character))
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsLowerHexCharacter(char value) =>
        value is >= '0' and <= '9' or >= 'a' and <= 'f';
}
