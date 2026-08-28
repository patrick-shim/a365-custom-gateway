using System.Security.Claims;
using FluentAssertions;
using Gateway.AdminUi.Authentication;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Authorization.Infrastructure;
using Microsoft.AspNetCore.Authorization.Policy;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.AdminUi.Tests.Authentication;

public sealed class GatewayPoliciesTests
{
    [Theory]
    [InlineData(GatewayRoles.Administrator, true, true, true, true)]
    [InlineData(GatewayRoles.Operator, false, true, false, true)]
    [InlineData(GatewayRoles.Auditor, false, false, true, true)]
    [InlineData(GatewayRoles.SupportReader, false, false, false, true)]
    [InlineData("ExternalAgent", false, false, false, false)]
    public async Task NamedPolicies_EnforceTheControlPlaneRoleMatrix(
        string role,
        bool administrator,
        bool administratorOrOperator,
        bool administratorOrAuditor,
        bool allControlPlane)
    {
        await using var provider = CreateProvider();
        var authorization = provider.GetRequiredService<IAuthorizationService>();
        var principal = PrincipalWithRole(role);

        (await authorization.AuthorizeAsync(
            principal,
            resource: null,
            GatewayPolicies.AdministratorOnly)).Succeeded.Should().Be(administrator);
        (await authorization.AuthorizeAsync(
            principal,
            resource: null,
            GatewayPolicies.AdministratorOrOperator)).Succeeded.Should().Be(administratorOrOperator);
        (await authorization.AuthorizeAsync(
            principal,
            resource: null,
            GatewayPolicies.AdministratorOrAuditor)).Succeeded.Should().Be(administratorOrAuditor);
        (await authorization.AuthorizeAsync(
            principal,
            resource: null,
            GatewayPolicies.AllControlPlane)).Succeeded.Should().Be(allControlPlane);
    }

    [Fact]
    public async Task FallbackPolicy_RequiresAuthenticatedUser()
    {
        await using var provider = CreateProvider();
        var policyProvider = provider.GetRequiredService<IAuthorizationPolicyProvider>();
        var fallback = await policyProvider.GetFallbackPolicyAsync();
        var evaluator = provider.GetRequiredService<IPolicyEvaluator>();

        fallback.Should().NotBeNull();
        fallback!.Requirements.Should().ContainSingle(requirement =>
            requirement is DenyAnonymousAuthorizationRequirement);
        evaluator.Should().NotBeNull();
    }

    private static ServiceProvider CreateProvider()
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddGatewayAuthorization();
        services.AddAuthorizationPolicyEvaluator();
        return services.BuildServiceProvider();
    }

    private static ClaimsPrincipal PrincipalWithRole(string role) =>
        new(new ClaimsIdentity(
            [new Claim(ClaimTypes.Role, role)],
            "test",
            ClaimTypes.Name,
            ClaimTypes.Role));
}
