using Gateway.Api.Authentication;
using Microsoft.AspNetCore.Authorization;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Identity.Web;
using System.Security.Claims;

namespace Gateway.Api.Authorization;

public static class AuthorizationPolicies
{
    public const string AdministratorOnly = "AdministratorOnly";
    public const string AdministratorOrOperator = "AdministratorOrOperator";
    public const string AdministratorOrAuditor = "AdministratorOrAuditor";
    public const string AllControlPlane = "AllControlPlane";
    public const string ExternalAgentOnly = "ExternalAgentOnly";
    public const string DelegatedAdministratorRegistry = "DelegatedAdministratorRegistry";

    public static IServiceCollection ConfigureAuthorizationPolicies(this IServiceCollection services)
    {
        services.AddAuthorizationBuilder()
            .AddPolicy(AdministratorOnly, p => p.RequireRole("Gateway.Administrator"))
            .AddPolicy(AdministratorOrOperator, p => p.RequireRole("Gateway.Administrator", "Gateway.Operator"))
            .AddPolicy(AdministratorOrAuditor, p => p.RequireRole("Gateway.Administrator", "Gateway.Auditor"))
            .AddPolicy(AllControlPlane, p => p.RequireRole(
                "Gateway.Administrator", "Gateway.Operator", "Gateway.Auditor", "Gateway.SupportReader"))
            .AddPolicy(DelegatedAdministratorRegistry, policy =>
            {
                policy.RequireAuthenticatedUser();
                policy.RequireRole("Gateway.Administrator");
                policy.RequireAssertion(context =>
                {
                    var oid = context.User.FindFirstValue(
                                  "http://schemas.microsoft.com/identity/claims/objectidentifier")
                              ?? context.User.FindFirstValue("oid");
                    if (!Guid.TryParse(oid, out var objectId) || objectId == Guid.Empty)
                        return false;

                    return context.User.Claims
                        .Where(claim => claim.Type is ClaimConstants.Scp or ClaimConstants.Scope)
                        .SelectMany(claim => claim.Value.Split(
                            ' ',
                            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                        .Contains("access_as_user", StringComparer.Ordinal);
                });
            })
            .AddPolicy(ExternalAgentOnly, policy =>
            {
                policy.AuthenticationSchemes.Add(
                    GatewayAgentApiKeyDefaults.AuthenticationScheme);
                policy.RequireAuthenticatedUser();
                policy.RequireClaim(GatewayAgentClaimTypes.AgentRegistrationId);
            });

        return services;
    }
}
