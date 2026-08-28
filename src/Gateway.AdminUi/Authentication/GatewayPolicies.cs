using Microsoft.AspNetCore.Authorization;

namespace Gateway.AdminUi.Authentication;

public static class GatewayPolicies
{
    public const string AdministratorOnly = "AdministratorOnly";
    public const string AdministratorOrOperator = "AdministratorOrOperator";
    public const string AdministratorOrAuditor = "AdministratorOrAuditor";
    public const string AllControlPlane = "AllControlPlane";

    public static IServiceCollection AddGatewayAuthorization(this IServiceCollection services)
    {
        services.AddAuthorizationBuilder()
            .SetFallbackPolicy(new AuthorizationPolicyBuilder()
                .RequireAuthenticatedUser()
                .Build())
            .AddPolicy(AdministratorOnly, policy =>
                policy.RequireRole(GatewayRoles.Administrator))
            .AddPolicy(AdministratorOrOperator, policy =>
                policy.RequireRole(GatewayRoles.Administrator, GatewayRoles.Operator))
            .AddPolicy(AdministratorOrAuditor, policy =>
                policy.RequireRole(GatewayRoles.Administrator, GatewayRoles.Auditor))
            .AddPolicy(AllControlPlane, policy =>
                policy.RequireRole(
                    GatewayRoles.Administrator,
                    GatewayRoles.Operator,
                    GatewayRoles.Auditor,
                    GatewayRoles.SupportReader));

        return services;
    }
}
