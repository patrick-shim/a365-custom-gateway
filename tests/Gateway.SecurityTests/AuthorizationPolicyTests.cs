using FluentAssertions;
using Gateway.Api.Authentication;
using Gateway.Api.Authorization;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Authorization.Infrastructure;
using Microsoft.Extensions.DependencyInjection;
using System.Security.Claims;

namespace Gateway.SecurityTests;

/// <summary>
/// Verifies that authorization policy constants are defined and that each policy
/// is mapped to the correct set of application roles.
/// </summary>
public class AuthorizationPolicyTests
{
    private readonly IAuthorizationPolicyProvider _policyProvider;
    private readonly IAuthorizationService _authorizationService;

    public AuthorizationPolicyTests()
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.ConfigureAuthorizationPolicies();
        var provider = services.BuildServiceProvider();
        _policyProvider = provider.GetRequiredService<IAuthorizationPolicyProvider>();
        _authorizationService = provider.GetRequiredService<IAuthorizationService>();
    }

    // ---------------------------------------------------------------
    // Policy constant definition tests
    // ---------------------------------------------------------------

    [Theory]
    [InlineData(nameof(AuthorizationPolicies.AdministratorOnly), "AdministratorOnly")]
    [InlineData(nameof(AuthorizationPolicies.AdministratorOrOperator), "AdministratorOrOperator")]
    [InlineData(nameof(AuthorizationPolicies.AdministratorOrAuditor), "AdministratorOrAuditor")]
    [InlineData(nameof(AuthorizationPolicies.AllControlPlane), "AllControlPlane")]
    [InlineData(nameof(AuthorizationPolicies.ExternalAgentOnly), "ExternalAgentOnly")]
    [InlineData(
        nameof(AuthorizationPolicies.DelegatedAdministratorRegistry),
        "DelegatedAdministratorRegistry")]
    public void PolicyConstant_Should_HaveExpectedStringValue(string fieldName, string expectedValue)
    {
        var field = typeof(AuthorizationPolicies)
            .GetField(fieldName, System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static);

        field.Should().NotBeNull($"constant '{fieldName}' must be defined on AuthorizationPolicies");
        field!.IsLiteral.Should().BeTrue($"'{fieldName}' must be a const field");

        var value = (string?)field.GetRawConstantValue();
        value.Should().Be(expectedValue);
    }

    [Fact]
    public void AuthorizationPolicies_Should_DefineExactlySixPolicies()
    {
        var constants = typeof(AuthorizationPolicies)
            .GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static)
            .Where(f => f.IsLiteral && f.FieldType == typeof(string))
            .ToList();

        constants.Should().HaveCount(6,
            "there should be exactly 6 authorization policies defined");
    }

    // ---------------------------------------------------------------
    // Policy-to-role mapping tests
    // ---------------------------------------------------------------

    [Fact]
    public async Task AdministratorOnly_Should_RequireOnlyGatewayAdministratorRole()
    {
        var policy = await _policyProvider.GetPolicyAsync(AuthorizationPolicies.AdministratorOnly);

        policy.Should().NotBeNull();
        var roleRequirement = policy!.Requirements
            .OfType<RolesAuthorizationRequirement>().Single();

        roleRequirement.AllowedRoles.Should().BeEquivalentTo(
            new[] { "Gateway.Administrator" });
    }

    [Fact]
    public async Task AdministratorOrOperator_Should_RequireAdministratorOrOperatorRoles()
    {
        var policy = await _policyProvider.GetPolicyAsync(AuthorizationPolicies.AdministratorOrOperator);

        policy.Should().NotBeNull();
        var roleRequirement = policy!.Requirements
            .OfType<RolesAuthorizationRequirement>().Single();

        roleRequirement.AllowedRoles.Should().BeEquivalentTo(
            new[] { "Gateway.Administrator", "Gateway.Operator" });
    }

    [Fact]
    public async Task AdministratorOrAuditor_Should_RequireAdministratorOrAuditorRoles()
    {
        var policy = await _policyProvider.GetPolicyAsync(AuthorizationPolicies.AdministratorOrAuditor);

        policy.Should().NotBeNull();
        var roleRequirement = policy!.Requirements
            .OfType<RolesAuthorizationRequirement>().Single();

        roleRequirement.AllowedRoles.Should().BeEquivalentTo(
            new[] { "Gateway.Administrator", "Gateway.Auditor" });
    }

    [Fact]
    public async Task AllControlPlane_Should_RequireAllFourControlPlaneRoles()
    {
        var policy = await _policyProvider.GetPolicyAsync(AuthorizationPolicies.AllControlPlane);

        policy.Should().NotBeNull();
        var roleRequirement = policy!.Requirements
            .OfType<RolesAuthorizationRequirement>().Single();

        roleRequirement.AllowedRoles.Should().BeEquivalentTo(
            new[]
            {
                "Gateway.Administrator",
                "Gateway.Operator",
                "Gateway.Auditor",
                "Gateway.SupportReader"
            });
    }

    [Fact]
    public async Task ExternalAgentOnly_Should_RequireGatewayAgentCredentialSchemeAndRegistrationClaim()
    {
        var policy = await _policyProvider.GetPolicyAsync(AuthorizationPolicies.ExternalAgentOnly);

        policy.Should().NotBeNull();
        policy!.AuthenticationSchemes.Should().Equal(
            GatewayAgentApiKeyDefaults.AuthenticationScheme);
        policy.Requirements.OfType<DenyAnonymousAuthorizationRequirement>()
            .Should().ContainSingle();
        policy.Requirements.OfType<ClaimsAuthorizationRequirement>()
            .Should().ContainSingle(requirement =>
                requirement.ClaimType == GatewayAgentClaimTypes.AgentRegistrationId);
        policy.Requirements.OfType<RolesAuthorizationRequirement>()
            .Should().BeEmpty();
    }

    [Fact]
    public async Task DelegatedAdministratorRegistry_ShouldAllowOnlyInteractiveAdministratorWithOidAndGatewayScope()
    {
        var principal = CreatePrincipal(
            new Claim(ClaimTypes.Role, "Gateway.Administrator"),
            new Claim("oid", Guid.NewGuid().ToString("D")),
            new Claim("scp", "profile access_as_user"));

        var result = await _authorizationService.AuthorizeAsync(
            principal,
            resource: null,
            AuthorizationPolicies.DelegatedAdministratorRegistry);

        result.Succeeded.Should().BeTrue();
        var policy = await _policyProvider.GetPolicyAsync(
            AuthorizationPolicies.DelegatedAdministratorRegistry);
        policy.Should().NotBeNull();
        policy!.Requirements.OfType<DenyAnonymousAuthorizationRequirement>()
            .Should().ContainSingle();
        policy.Requirements.OfType<RolesAuthorizationRequirement>()
            .Should().ContainSingle(requirement =>
                requirement.AllowedRoles.SequenceEqual(
                    new[] { "Gateway.Administrator" }));
        policy.Requirements.OfType<AssertionRequirement>().Should().ContainSingle();
    }

    [Fact]
    public async Task DelegatedAdministratorRegistry_ShouldAllowMappedDelegatedScopeClaim()
    {
        var principal = CreatePrincipal(
            new Claim(ClaimTypes.Role, "Gateway.Administrator"),
            new Claim("oid", Guid.NewGuid().ToString("D")),
            new Claim(
                "http://schemas.microsoft.com/identity/claims/scope",
                "profile access_as_user"));

        var result = await _authorizationService.AuthorizeAsync(
            principal,
            resource: null,
            AuthorizationPolicies.DelegatedAdministratorRegistry);

        result.Succeeded.Should().BeTrue();
    }

    [Fact]
    public async Task DelegatedAdministratorRegistry_ShouldRejectAppOnlyAdministratorToken()
    {
        var principal = CreatePrincipal(
            new Claim(ClaimTypes.Role, "Gateway.Administrator"),
            new Claim("oid", Guid.NewGuid().ToString("D")),
            new Claim("roles", "Gateway.Administrator"));

        var result = await _authorizationService.AuthorizeAsync(
            principal,
            resource: null,
            AuthorizationPolicies.DelegatedAdministratorRegistry);

        result.Succeeded.Should().BeFalse(
            "an app-only roles token has no delegated access_as_user scope");
    }

    [Fact]
    public async Task DelegatedAdministratorRegistry_ShouldRejectOperatorEvenWithDelegatedScope()
    {
        var principal = CreatePrincipal(
            new Claim(ClaimTypes.Role, "Gateway.Operator"),
            new Claim("oid", Guid.NewGuid().ToString("D")),
            new Claim("scp", "access_as_user"));

        var result = await _authorizationService.AuthorizeAsync(
            principal,
            resource: null,
            AuthorizationPolicies.DelegatedAdministratorRegistry);

        result.Succeeded.Should().BeFalse();
    }

    [Theory]
    [InlineData(null, "access_as_user")]
    [InlineData("not-a-guid", "access_as_user")]
    [InlineData("00000000-0000-0000-0000-000000000000", "access_as_user")]
    [InlineData("4cf04bc9-d340-4b82-87d2-e305535af48b", null)]
    [InlineData("4cf04bc9-d340-4b82-87d2-e305535af48b", "User.Read")]
    public async Task DelegatedAdministratorRegistry_ShouldRejectMissingOrInvalidUserBinding(
        string? objectId,
        string? scopes)
    {
        var claims = new List<Claim>
        {
            new(ClaimTypes.Role, "Gateway.Administrator")
        };
        if (objectId is not null)
            claims.Add(new Claim("oid", objectId));
        if (scopes is not null)
            claims.Add(new Claim("scp", scopes));

        var result = await _authorizationService.AuthorizeAsync(
            CreatePrincipal(claims.ToArray()),
            resource: null,
            AuthorizationPolicies.DelegatedAdministratorRegistry);

        result.Succeeded.Should().BeFalse();
    }

    [Fact]
    public async Task ControlPlanePolicies_Should_HaveExactlyOneRolesRequirement()
    {
        var policyNames = new[]
        {
            AuthorizationPolicies.AdministratorOnly,
            AuthorizationPolicies.AdministratorOrOperator,
            AuthorizationPolicies.AdministratorOrAuditor,
            AuthorizationPolicies.AllControlPlane,
            AuthorizationPolicies.DelegatedAdministratorRegistry
        };

        foreach (var name in policyNames)
        {
            var policy = await _policyProvider.GetPolicyAsync(name);
            policy.Should().NotBeNull($"policy '{name}' must be registered");

            var roleRequirements = policy!.Requirements
                .OfType<RolesAuthorizationRequirement>().ToList();

            roleRequirements.Should().ContainSingle(
                $"policy '{name}' must have exactly one RolesAuthorizationRequirement");
        }
    }

    private static ClaimsPrincipal CreatePrincipal(params Claim[] claims) => new(
        new ClaimsIdentity(claims, authenticationType: "test"));
}
