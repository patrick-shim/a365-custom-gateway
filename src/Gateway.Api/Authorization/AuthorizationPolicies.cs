using Microsoft.AspNetCore.Authorization;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.Api.Authorization;

public static class AuthorizationPolicies
{
    public const string AdministratorOnly = "AdministratorOnly";
    public const string AdministratorOrOperator = "AdministratorOrOperator";
    public const string AdministratorOrAuditor = "AdministratorOrAuditor";
    public const string AllControlPlane = "AllControlPlane";
    public const string ExternalAgentOnly = "ExternalAgentOnly";

    public static IServiceCollection ConfigureAuthorizationPolicies(this IServiceCollection services)
    {
        services.AddAuthorizationBuilder()
            .AddPolicy(AdministratorOnly, p => p.RequireRole("Gateway.Administrator"))
            .AddPolicy(AdministratorOrOperator, p => p.RequireRole("Gateway.Administrator", "Gateway.Operator"))
            .AddPolicy(AdministratorOrAuditor, p => p.RequireRole("Gateway.Administrator", "Gateway.Auditor"))
            .AddPolicy(AllControlPlane, p => p.RequireRole(
                "Gateway.Administrator", "Gateway.Operator", "Gateway.Auditor", "Gateway.SupportReader"))
            .AddPolicy(ExternalAgentOnly, p => p.RequireRole("ExternalAgent"));

        return services;
    }
}
