namespace Gateway.AdminUi.Authentication;

internal static class AuthenticationReturnUrl
{
    public static string Normalize(string? returnUrl)
    {
        if (string.IsNullOrWhiteSpace(returnUrl) ||
            returnUrl.Any(char.IsControl))
        {
            return "/";
        }

        return Uri.TryCreate(returnUrl, UriKind.Relative, out _) &&
            returnUrl.StartsWith("/", StringComparison.Ordinal) &&
            !returnUrl.StartsWith("//", StringComparison.Ordinal) &&
            !returnUrl.StartsWith("/\\", StringComparison.Ordinal)
                ? returnUrl
                : "/";
    }
}
