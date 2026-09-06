using System.Security.Claims;

namespace Gateway.Purview.Executor;

internal sealed record ExecutorCallerBinding(
    Guid TenantId,
    Guid WorkerPrincipalId,
    Guid WorkerApplicationId);

internal static class ExecutorCallerAuthorization
{
    internal const string RequiredRole = "Purview.Executor.Invoke";

    // Only call after JWT signature, issuer, audience and lifetime validation.
    // App Service authentication is an additional check, not a replacement.
    public static bool IsAuthorized(ClaimsPrincipal caller, ExecutorCallerBinding binding)
    {
        if (caller.Identity?.IsAuthenticated != true ||
            binding.TenantId == Guid.Empty ||
            binding.WorkerPrincipalId == Guid.Empty ||
            binding.WorkerApplicationId == Guid.Empty ||
            caller.HasClaim(claim => claim.Type is "scp" or
                "http://schemas.microsoft.com/identity/claims/scope"))
        {
            return false;
        }

        if (!HasExactGuid(caller, "tid", binding.TenantId) ||
            !HasExactGuid(caller, "oid", binding.WorkerPrincipalId))
        {
            return false;
        }

        var applicationClaims = caller.FindAll("azp").Concat(caller.FindAll("appid")).ToArray();
        if (applicationClaims.Length == 0 ||
            caller.FindAll("azp").Count() > 1 ||
            caller.FindAll("appid").Count() > 1 ||
            applicationClaims.Any(claim =>
                !Guid.TryParseExact(claim.Value, "D", out var value) ||
                value != binding.WorkerApplicationId))
        {
            return false;
        }

        return caller.HasClaim("roles", RequiredRole);
    }

    private static bool HasExactGuid(ClaimsPrincipal caller, string type, Guid expected)
    {
        var claims = caller.FindAll(type).ToArray();
        return claims.Length == 1 &&
               Guid.TryParseExact(claims[0].Value, "D", out var actual) &&
               actual == expected;
    }
}
