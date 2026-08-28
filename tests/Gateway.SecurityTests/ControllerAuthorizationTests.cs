using System.Reflection;
using FluentAssertions;
using Gateway.Api.Authorization;
using Gateway.Api.Controllers;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Identity.Web;

namespace Gateway.SecurityTests;

/// <summary>
/// Verifies that every controller action in the API project is protected by an
/// authorization attribute and that specific endpoints are bound to the correct policy.
/// </summary>
public class ControllerAuthorizationTests
{
    private static readonly Assembly ApiAssembly = typeof(AgentsController).Assembly;

    // ---------------------------------------------------------------
    // Global coverage: no unprotected endpoints
    // ---------------------------------------------------------------

    [Fact]
    public void AllControllerActions_Should_HaveAuthorizeOrAllowAnonymousAttribute()
    {
        var controllerTypes = ApiAssembly.GetTypes()
            .Where(t => typeof(ControllerBase).IsAssignableFrom(t) && !t.IsAbstract);

        var unprotectedActions = new List<string>();

        foreach (var controller in controllerTypes)
        {
            var classHasAuthorize = controller.GetCustomAttribute<AuthorizeAttribute>() is not null;
            var classHasAllowAnonymous = controller.GetCustomAttribute<AllowAnonymousAttribute>() is not null;

            var actionMethods = controller
                .GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
                .Where(IsActionMethod);

            foreach (var method in actionMethods)
            {
                var methodHasAuthorize = method.GetCustomAttribute<AuthorizeAttribute>() is not null;
                var methodHasAllowAnonymous = method.GetCustomAttribute<AllowAnonymousAttribute>() is not null;

                bool isProtected = classHasAuthorize || classHasAllowAnonymous
                                   || methodHasAuthorize || methodHasAllowAnonymous;

                if (!isProtected)
                    unprotectedActions.Add($"{controller.Name}.{method.Name}");
            }
        }

        unprotectedActions.Should().BeEmpty(
            "all controller actions must have [Authorize] or [AllowAnonymous]. " +
            "Unprotected: {0}", string.Join(", ", unprotectedActions));
    }

    // ---------------------------------------------------------------
    // HealthController uses [AllowAnonymous]
    // ---------------------------------------------------------------

    [Fact]
    public void HealthController_Should_HaveAllowAnonymousAttribute()
    {
        var attr = typeof(HealthController).GetCustomAttribute<AllowAnonymousAttribute>();

        attr.Should().NotBeNull(
            "HealthController must be accessible without authentication");
    }

    [Fact]
    public void HealthController_Should_NotHaveAuthorizeAttribute()
    {
        var attr = typeof(HealthController).GetCustomAttribute<AuthorizeAttribute>();

        attr.Should().BeNull(
            "HealthController must not require authorization");
    }

    // ---------------------------------------------------------------
    // Agents controller: action-to-policy mapping
    // ---------------------------------------------------------------

    [Theory]
    [InlineData(nameof(AgentsController.RegisterAgent), "AdministratorOnly")]
    [InlineData(nameof(AgentsController.ListAgents), "AllControlPlane")]
    [InlineData(nameof(AgentsController.GetAgent), "AllControlPlane")]
    [InlineData(nameof(AgentsController.UpdateFeatures), "AdministratorOnly")]
    [InlineData(nameof(AgentsController.EnableAgent), "AdministratorOrOperator")]
    [InlineData(nameof(AgentsController.DisableAgent), "AdministratorOrOperator")]
    [InlineData(nameof(AgentsController.DeleteAgent), "AdministratorOnly")]
    [InlineData(nameof(AgentsController.RetryProvisioning), "AdministratorOnly")]
    [InlineData(nameof(AgentsController.GetAuditEvents), "AdministratorOrAuditor")]
    [InlineData(nameof(AgentsController.GetProvisioningHistory), "AdministratorOrOperator")]
    public void AgentsController_Action_Should_RequireExpectedPolicy(
        string methodName, string expectedPolicy)
    {
        AssertActionPolicy(typeof(AgentsController), methodName, expectedPolicy);
    }

    [Fact]
    public void AgentIdentityBlueprintsController_List_Should_RequireAdministratorOnlyPolicy()
    {
        AssertActionPolicy(
            typeof(AgentIdentityBlueprintsController),
            nameof(AgentIdentityBlueprintsController.ListAgentIdentityBlueprints),
            AuthorizationPolicies.AdministratorOnly);
    }

    // ---------------------------------------------------------------
    // Data-plane controllers: action-to-policy mapping
    // ---------------------------------------------------------------

    [Theory]
    [InlineData(typeof(ActivitiesController), nameof(ActivitiesController.SubmitActivity))]
    [InlineData(typeof(ActivitiesController), nameof(ActivitiesController.SubmitBatchActivities))]
    [InlineData(typeof(InteractionsController), nameof(InteractionsController.SubmitInteraction))]
    public void DataPlaneAction_Should_RequireExternalAgentOnlyPolicy(
        Type controllerType, string methodName)
    {
        AssertActionPolicy(controllerType, methodName, AuthorizationPolicies.ExternalAgentOnly);
    }

    [Fact]
    public void DataPlaneControllers_Should_OnlyUseExternalAgentPolicy()
    {
        var dataPlaneControllers = new[] { typeof(ActivitiesController), typeof(InteractionsController) };

        foreach (var controller in dataPlaneControllers)
        {
            var actionMethods = controller
                .GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
                .Where(IsActionMethod);

            foreach (var method in actionMethods)
            {
                var authorizeAttr = method.GetCustomAttribute<AuthorizeAttribute>();
                authorizeAttr.Should().NotBeNull(
                    $"{controller.Name}.{method.Name} must have [Authorize]");
                authorizeAttr!.Policy.Should().Be(AuthorizationPolicies.ExternalAgentOnly,
                    $"data-plane action {controller.Name}.{method.Name} must use ExternalAgentOnly policy");
            }
        }
    }

    // ---------------------------------------------------------------
    // Operations controller: action-to-policy mapping
    // ---------------------------------------------------------------

    [Fact]
    public void GetOperationStatus_Should_RequireAdministratorOrOperatorPolicy()
    {
        AssertActionPolicy(
            typeof(OperationsController),
            nameof(OperationsController.GetOperationStatus),
            AuthorizationPolicies.AdministratorOrOperator);
    }

    [Fact]
    public void CompleteAgent365Registration_ShouldRequireDelegatedAdministratorRegistryPolicy()
    {
        AssertActionPolicy(
            typeof(OperationsController),
            nameof(OperationsController.CompleteAgent365Registration),
            AuthorizationPolicies.DelegatedAdministratorRegistry);
    }

    [Fact]
    public void CompleteAgent365Registration_ShouldNotUseWebAppAuthorizeForScopesRedirectFilter()
    {
        var method = typeof(OperationsController).GetMethod(
            nameof(OperationsController.CompleteAgent365Registration));

        method.Should().NotBeNull();
        method!.GetCustomAttributes<AuthorizeForScopesAttribute>()
            .Should().BeEmpty(
                "web APIs must return an OBO challenge response instead of invoking a web-app redirect filter");
    }

    // ---------------------------------------------------------------
    // System controller: action-to-policy mapping
    // ---------------------------------------------------------------

    [Theory]
    [InlineData(nameof(SystemController.GetSystemConfig), "AdministratorOnly")]
    [InlineData(nameof(SystemController.UpdateSystemConfig), "AdministratorOnly")]
    public void SystemController_Action_Should_RequireExpectedPolicy(
        string methodName, string expectedPolicy)
    {
        AssertActionPolicy(typeof(SystemController), methodName, expectedPolicy);
    }

    // ---------------------------------------------------------------
    // No controller uses Roles directly (must use named policies)
    // ---------------------------------------------------------------

    [Fact]
    public void AllAuthorizeAttributes_Should_SpecifyPolicyNotRolesDirectly()
    {
        var controllerTypes = ApiAssembly.GetTypes()
            .Where(t => typeof(ControllerBase).IsAssignableFrom(t) && !t.IsAbstract);

        var violatingActions = new List<string>();

        foreach (var controller in controllerTypes)
        {
            // Check class-level [Authorize] attributes
            var classAuth = controller.GetCustomAttribute<AuthorizeAttribute>();
            if (classAuth is not null && !string.IsNullOrEmpty(classAuth.Roles))
                violatingActions.Add($"{controller.Name} (class-level)");

            // Check method-level [Authorize] attributes
            var actionMethods = controller
                .GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
                .Where(IsActionMethod);

            foreach (var method in actionMethods)
            {
                var methodAuth = method.GetCustomAttribute<AuthorizeAttribute>();
                if (methodAuth is not null && !string.IsNullOrEmpty(methodAuth.Roles))
                    violatingActions.Add($"{controller.Name}.{method.Name}");
            }
        }

        violatingActions.Should().BeEmpty(
            "all [Authorize] attributes should use Policy, not Roles. " +
            "Direct role usage bypasses centralized policy definitions. " +
            "Violations: {0}", string.Join(", ", violatingActions));
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    private static void AssertActionPolicy(Type controllerType, string methodName, string expectedPolicy)
    {
        var method = controllerType.GetMethod(methodName);
        method.Should().NotBeNull(
            $"{controllerType.Name} should have a public method named '{methodName}'");

        var authorizeAttr = method!.GetCustomAttribute<AuthorizeAttribute>();
        authorizeAttr.Should().NotBeNull(
            $"{controllerType.Name}.{methodName} must have [Authorize] attribute");

        authorizeAttr!.Policy.Should().Be(expectedPolicy,
            $"{controllerType.Name}.{methodName} should require policy '{expectedPolicy}'");
    }

    private static bool IsActionMethod(MethodInfo method)
    {
        return method.GetCustomAttributes(true).Any(a =>
            a is HttpGetAttribute or HttpPostAttribute or HttpPutAttribute
                or HttpPatchAttribute or HttpDeleteAttribute);
    }
}
