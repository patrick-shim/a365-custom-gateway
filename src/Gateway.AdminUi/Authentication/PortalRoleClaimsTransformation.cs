using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;

namespace Gateway.AdminUi.Authentication;

public sealed class PortalRoleClaimsTransformation : IClaimsTransformation
{
    private static readonly IReadOnlyDictionary<string, string> RoleMappings =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            [GatewayRoles.PortalAdministrator] = GatewayRoles.Administrator,
            [GatewayRoles.PortalOperator] = GatewayRoles.Operator,
            [GatewayRoles.PortalAuditor] = GatewayRoles.Auditor,
            [GatewayRoles.PortalReader] = GatewayRoles.SupportReader
        };

    public Task<ClaimsPrincipal> TransformAsync(ClaimsPrincipal principal)
    {
        if (principal.Identity is not ClaimsIdentity identity || !identity.IsAuthenticated)
        {
            return Task.FromResult(principal);
        }

        var roleValues = principal.Claims
            .Where(claim => claim.Type is "roles" or ClaimTypes.Role)
            .Select(claim => claim.Value)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        foreach (var mapping in RoleMappings)
        {
            var hasRecognizedRole = roleValues.Contains(mapping.Key) || roleValues.Contains(mapping.Value);
            var hasCanonicalRoleForIdentity = principal.Claims.Any(claim =>
                string.Equals(claim.Type, identity.RoleClaimType, StringComparison.Ordinal) &&
                string.Equals(claim.Value, mapping.Value, StringComparison.OrdinalIgnoreCase));

            if (hasRecognizedRole && !hasCanonicalRoleForIdentity)
            {
                identity.AddClaim(new Claim(identity.RoleClaimType, mapping.Value));
            }
        }

        return Task.FromResult(principal);
    }
}
