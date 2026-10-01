using Microsoft.AspNetCore.Authorization;

namespace Gateway.AdminUi.Authentication;

public static class GatewayPolicies
{
    public const string AdministratorOnly = "AdministratorOnly";
    public const string AdministratorOrOperator = "AdministratorOrOperator";
    public const string AdministratorOrAuditor = "AdministratorOrAuditor";
    public const string AllControlPlane = "AllControlPlane";

    public static string DescribeRequiredAccess(Type pageType)
    {
        var requirements = pageType.GetCustomAttributes(typeof(AuthorizeAttribute), inherit: true)
            .Cast<AuthorizeAttribute>()
            .Select(attribute => !string.IsNullOrWhiteSpace(attribute.Roles)
                ? string.Join(" or ", attribute.Roles.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
                    .Select(role => role.Replace("Gateway.", "Gateway ", StringComparison.Ordinal)))
                : attribute.Policy switch
                {
                    AdministratorOnly => "Gateway Administrator",
                    AdministratorOrOperator => "Gateway Administrator or Gateway Operator",
                    AdministratorOrAuditor => "Gateway Administrator or Gateway Auditor",
                    AllControlPlane => "an assigned Gateway control-plane role",
                    _ => "a signed-in user with the required Gateway permissions"
                })
            .Distinct(StringComparer.Ordinal);
        return string.Join(" and ", requirements);
    }

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
