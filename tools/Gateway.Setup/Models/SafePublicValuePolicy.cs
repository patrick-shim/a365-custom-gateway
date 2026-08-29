using System.Text.RegularExpressions;

namespace Gateway.Setup.Models;

internal static partial class SafePublicValuePolicy
{
    public static bool IsAllowed(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return true;
        }

        if (value.Any(char.IsControl) || value.Length > 512)
        {
            return false;
        }

        return !BearerPattern().IsMatch(value) &&
            !JwtPattern().IsMatch(value) &&
            !PrivateKeyPattern().IsMatch(value) &&
            !ConnectionSecretPattern().IsMatch(value) &&
            !OpenAiKeyPattern().IsMatch(value);
    }

    [GeneratedRegex("(?i)\\bbearer\\s+[A-Za-z0-9._~+/=-]{8,}", RegexOptions.CultureInvariant)]
    private static partial Regex BearerPattern();

    [GeneratedRegex("\\beyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}(?:\\.[A-Za-z0-9_-]{8,})?\\b", RegexOptions.CultureInvariant)]
    private static partial Regex JwtPattern();

    [GeneratedRegex("-----BEGIN [A-Z ]*(?:PRIVATE KEY|CERTIFICATE)-----", RegexOptions.CultureInvariant)]
    private static partial Regex PrivateKeyPattern();

    [GeneratedRegex("(?i)\\b(?:password|accountkey|client_secret|accesstoken|refreshtoken)\\s*[=:]", RegexOptions.CultureInvariant)]
    private static partial Regex ConnectionSecretPattern();

    [GeneratedRegex("\\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}\\b", RegexOptions.CultureInvariant)]
    private static partial Regex OpenAiKeyPattern();
}
