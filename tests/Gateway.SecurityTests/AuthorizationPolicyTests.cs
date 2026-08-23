using FluentAssertions;
using Gateway.Api.Authorization;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Authorization.Infrastructure;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.SecurityTests;

/// <summary>
/// Verifies that authorization policy constants are defined and that each policy
/// is mapped to the correct set of application roles.
/// </summary>
public class AuthorizationPolicyTests
{
    private readonly IAuthorizationPolicyProvider _policyProvider;

    public AuthorizationPolicyTests()
    {
        var services = new ServiceCollection();
        services.ConfigureAuthorizationPolicies();
        var provider = services.BuildServiceProvider();
        _policyProvider = provider.GetRequiredService<IAuthorizationPolicyProvider>();
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
    public void AuthorizationPolicies_Should_DefineExactlyFivePolicies()
    {
        var constants = typeof(AuthorizationPolicies)
            .GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static)
            .Where(f => f.IsLiteral && f.FieldType == typeof(string))
            .ToList();

        constants.Should().HaveCount(5,
            "there should be exactly 5 authorization policies defined");
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
    public async Task ExternalAgentOnly_Should_RequireExternalAgentRole()
    {
        var policy = await _policyProvider.GetPolicyAsync(AuthorizationPolicies.ExternalAgentOnly);

        policy.Should().NotBeNull();
        var roleRequirement = policy!.Requirements
            .OfType<RolesAuthorizationRequirement>().Single();

        roleRequirement.AllowedRoles.Should().BeEquivalentTo(
            new[] { "ExternalAgent" });
    }

    [Fact]
    public async Task AllPolicies_Should_HaveExactlyOneRolesRequirement()
    {
        var policyNames = new[]
        {
            AuthorizationPolicies.AdministratorOnly,
            AuthorizationPolicies.AdministratorOrOperator,
            AuthorizationPolicies.AdministratorOrAuditor,
            AuthorizationPolicies.AllControlPlane,
            AuthorizationPolicies.ExternalAgentOnly
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
}
