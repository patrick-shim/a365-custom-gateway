using System.Security.Claims;

namespace Gateway.EndToEndTests.Fixtures;

public static class HttpClientExtensions
{
    /// <summary>
    /// Sets the test auth handler to authenticate as the specified role.
    /// Call this before making requests with the HttpClient.
    /// </summary>
    public static void SetRole(string role)
    {
        TestAuthHandler.DefaultRole = role;
        TestAuthHandler.Claims = new List<Claim>();
        TestAuthHandler.ShouldAuthenticate = true;
    }

    /// <summary>
    /// Sets the interactive delegated administrator claims required by the
    /// Agent 365 Registry completion boundary.
    /// </summary>
    public static void SetDelegatedAdministrator(string? objectId = null)
    {
        TestAuthHandler.DefaultRole = null;
        TestAuthHandler.Claims = new List<Claim>
        {
            new(ClaimTypes.Role, "Gateway.Administrator"),
            new("oid", objectId ?? TestAuthHandler.DefaultObjectId),
            new("scp", "access_as_user")
        };
        TestAuthHandler.ShouldAuthenticate = true;
    }

    /// <summary>
    /// Sets the test auth handler to authenticate as an ExternalAgent with the specified client ID.
    /// </summary>
    public static void SetExternalAgent(string clientId)
    {
        TestAuthHandler.DefaultRole = "ExternalAgent";
        TestAuthHandler.Claims = new List<Claim>
        {
            new("appid", clientId)
        };
        TestAuthHandler.ShouldAuthenticate = true;
    }

    /// <summary>
    /// Configures the test auth handler to not authenticate (simulates unauthenticated request).
    /// </summary>
    public static void SetUnauthenticated()
    {
        TestAuthHandler.ShouldAuthenticate = false;
        TestAuthHandler.Claims = new List<Claim>();
        TestAuthHandler.DefaultRole = null;
    }

    /// <summary>
    /// Sets the test auth handler to authenticate with specific claims.
    /// </summary>
    public static void SetClaims(params Claim[] claims)
    {
        TestAuthHandler.Claims = claims.ToList();
        TestAuthHandler.DefaultRole = null;
        TestAuthHandler.ShouldAuthenticate = true;
    }
}
