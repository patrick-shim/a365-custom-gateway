namespace Gateway.Setup.Security;

internal enum SessionDecision
{
    Deny,
    Establish,
    Allow
}

internal static class SetupSessionPolicy
{
    public const string SessionKey = "a365-setup-authorized";

    public static SessionDecision Evaluate(
        bool hasAuthorizedSession,
        string method,
        string path,
        string? nonce,
        SessionNonceGate gate)
    {
        if (hasAuthorizedSession)
        {
            return SessionDecision.Allow;
        }

        if (string.Equals(method, "GET", StringComparison.OrdinalIgnoreCase) &&
            string.Equals(path, "/setup", StringComparison.Ordinal) &&
            gate.TryConsume(nonce))
        {
            return SessionDecision.Establish;
        }

        return SessionDecision.Deny;
    }
}
