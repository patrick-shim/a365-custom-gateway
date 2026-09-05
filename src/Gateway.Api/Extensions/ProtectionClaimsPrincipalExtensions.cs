using System.Security.Claims;
using Gateway.Application.Exceptions;
using Gateway.Application.Protection;
using Microsoft.Identity.Web;

namespace Gateway.Api.Extensions;

public static class ProtectionClaimsPrincipalExtensions
{
    private const string ObjectIdClaim =
        "http://schemas.microsoft.com/identity/claims/objectidentifier";
    private const string TenantIdClaim =
        "http://schemas.microsoft.com/identity/claims/tenantid";

    public static ProtectionActor GetProtectionActor(
        this ClaimsPrincipal principal)
    {
        ArgumentNullException.ThrowIfNull(principal);
        if (principal.Identity?.IsAuthenticated != true ||
            principal.Claims.Any(claim =>
                claim.Type == "idtyp" &&
                string.Equals(
                    claim.Value,
                    "app",
                    StringComparison.OrdinalIgnoreCase)))
        {
            throw new ProtectionAccessDeniedException();
        }

        var objectId = ReadSingleGuidClaim(
            principal,
            ObjectIdClaim,
            "oid");
        var tenantId = ReadSingleGuidClaim(
            principal,
            TenantIdClaim,
            "tid");
        var hasDelegatedScope = principal.Claims
            .Where(claim =>
                claim.Type is ClaimConstants.Scp or ClaimConstants.Scope)
            .SelectMany(claim => claim.Value.Split(
                ' ',
                StringSplitOptions.RemoveEmptyEntries |
                StringSplitOptions.TrimEntries))
            .Contains("access_as_user", StringComparer.Ordinal);
        if (objectId is null || tenantId is null || !hasDelegatedScope)
        {
            throw new ProtectionAccessDeniedException();
        }

        return new ProtectionActor(
            tenantId.Value,
            objectId.Value.ToString("D"));
    }

    private static Guid? ReadSingleGuidClaim(
        ClaimsPrincipal principal,
        params string[] claimTypes)
    {
        var values = principal.Claims
            .Where(claim => claimTypes.Contains(
                claim.Type,
                StringComparer.Ordinal))
            .Select(claim => claim.Value)
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        if (values.Length != 1 ||
            !Guid.TryParse(values[0], out var parsed) ||
            parsed == Guid.Empty)
        {
            return null;
        }

        return parsed;
    }
}
