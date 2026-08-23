using System.Security.Claims;

namespace Gateway.Api.Extensions;

public static class ClaimsPrincipalExtensions
{
    public static string GetObjectId(this ClaimsPrincipal principal)
    {
        return principal.FindFirstValue("http://schemas.microsoft.com/identity/claims/objectidentifier")
            ?? principal.FindFirstValue("oid")
            ?? throw new InvalidOperationException("Missing oid claim");
    }

    public static string GetClientId(this ClaimsPrincipal principal)
    {
        return principal.FindFirstValue("appid")
            ?? principal.FindFirstValue("azp")
            ?? throw new InvalidOperationException("Missing appid/azp claim");
    }
}
