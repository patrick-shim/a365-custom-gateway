using System.Reflection;
using System.Security.Claims;
using FluentAssertions;
using Gateway.Api.Authorization;
using Gateway.Api.Controllers;
using Gateway.Api.Extensions;
using Gateway.Api.Middleware;
using Gateway.Api.Options;
using Gateway.Application.Exceptions;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.SecurityTests.ProtectionApi;

public sealed class ProtectionApiSecurityTests
{
    [Fact]
    public void MutationsRequireAdministratorAndReadsAreBoundedByNamedPolicies()
    {
        string[] mutations =
        [
            nameof(ProtectionController.ReviewPurviewConnection),
            nameof(ProtectionController.ConfirmOperationReview),
            nameof(ProtectionController.StartPurviewConnection),
            nameof(ProtectionController.CompletePurviewConnection),
            nameof(ProtectionController.ReviewPurviewConnectionCompletion),
            nameof(ProtectionController.ReviewKnowYourData),
            nameof(ProtectionController.StartKnowYourData),
            nameof(ProtectionController.ReviewDlpProfile),
            nameof(ProtectionController.StartDlpProfile),
            nameof(ProtectionController.ReconcileDlpProfile),
            nameof(ProtectionController.ReviewReconcileDlpProfile),
            nameof(ProtectionController.ValidateDlpProfileRuntime),
            nameof(ProtectionController.ReviewValidateDlpProfileRuntime)
        ];
        foreach (var methodName in mutations)
        {
            GetPolicy(methodName).Should().Be(
                AuthorizationPolicies.AdministratorOnly);
        }

        GetPolicy(nameof(ProtectionController.GetCapabilities)).Should().Be(
            AuthorizationPolicies.AllControlPlane);
        GetPolicy(nameof(ProtectionController.GetOperation)).Should().Be(
            AuthorizationPolicies.AllControlPlane);
        GetPolicy(nameof(ProtectionController.GetSensitiveInformationTypes))
            .Should().Be(AuthorizationPolicies.AdministratorOnly);
        GetPolicy(nameof(ProtectionController.GetPurviewConnection))
            .Should().Be(AuthorizationPolicies.AdministratorOrOperator);
        GetPolicy(nameof(ProtectionController.GetKnowYourData))
            .Should().Be(AuthorizationPolicies.AdministratorOrOperator);
        GetPolicy(nameof(ProtectionController.GetDlpProfiles))
            .Should().Be(AuthorizationPolicies.AdministratorOrOperator);
    }

    [Fact]
    public void ProtectionActorRequiresExactDelegatedUserAndTenantBinding()
    {
        var tenantId = Guid.NewGuid();
        var objectId = Guid.NewGuid();
        var principal = CreatePrincipal(
            new Claim("tid", tenantId.ToString("D")),
            new Claim("oid", objectId.ToString("D")),
            new Claim("scp", "profile access_as_user"));

        var actor = principal.GetProtectionActor();

        actor.TenantId.Should().Be(tenantId);
        actor.ObjectId.Should().Be(objectId.ToString("D"));
    }

    [Theory]
    [InlineData(false, false, false)]
    [InlineData(true, false, false)]
    [InlineData(true, true, true)]
    public void ProtectionActorRejectsMissingBindingAndAppOnlyTokens(
        bool includeTenant,
        bool includeScope,
        bool appOnly)
    {
        var claims = new List<Claim>
        {
            new("oid", Guid.NewGuid().ToString("D"))
        };
        if (includeTenant)
            claims.Add(new Claim("tid", Guid.NewGuid().ToString("D")));
        if (includeScope)
            claims.Add(new Claim("scp", "access_as_user"));
        if (appOnly)
            claims.Add(new Claim("idtyp", "app"));

        var action = () => CreatePrincipal(claims.ToArray())
            .GetProtectionActor();

        action.Should().Throw<ProtectionAccessDeniedException>();
    }

    [Fact]
    public void ControllerDoesNotInjectOrCallAProviderSynchronously()
    {
        typeof(ProtectionController)
            .GetConstructors()
            .Single()
            .GetParameters()
            .Select(parameter => parameter.ParameterType.FullName)
            .Should().OnlyContain(name =>
                name == "MediatR.ISender" ||
                name ==
                    "Gateway.Infrastructure.Services.IProtectionAdminOperationLockProvider");
    }

    [Theory]
    [InlineData("POST", "/api/v1/protection/operation-reviews:confirm")]
    [InlineData("POST", "/API/V1/PROTECTION/PURVIEW/DLP-PROFILE-OPERATIONS:REVIEW")]
    [InlineData("PATCH", "/API/V1/SYSTEM/CONFIG")]
    [InlineData("PATCH", "/api/v1/agents/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/FEATURES")]
    public async Task ProtectionMutationEndpointsAreRateLimitedByUserAndIp(
        string method,
        string path)
    {
        var nextCalls = 0;
        var middleware = new ProtectionAdministrationRateLimitMiddleware(
            _ =>
            {
                nextCalls++;
                return Task.CompletedTask;
            });
        var store = new ProtectionAdministrationRateLimitStore(
            TimeProvider.System,
            userLimit: 1,
            ipLimit: 2,
            maximumPartitions: 16);
        var principal = CreatePrincipal(
            new Claim("tid", Guid.NewGuid().ToString("D")),
            new Claim("oid", Guid.NewGuid().ToString("D")),
            new Claim("scp", "access_as_user"));

        var first = CreateRateLimitedContext(principal, method, path);
        await middleware.InvokeAsync(first, store);
        var second = CreateRateLimitedContext(principal, method, path);
        await middleware.InvokeAsync(second, store);

        nextCalls.Should().Be(1);
        second.Response.StatusCode.Should().Be(
            StatusCodes.Status429TooManyRequests);
        second.Response.ContentType.Should().StartWith(
            "application/problem+json");
        second.Response.Headers.RetryAfter.Should().NotBeEmpty();
    }

    [Theory]
    [InlineData("N")]
    [InlineData("B")]
    [InlineData("P")]
    [InlineData("X")]
    public async Task AgentFeatureGuidFormatsShareTheSameRateLimitBucket(
        string routeFormat)
    {
        var nextCalls = 0;
        var middleware = new ProtectionAdministrationRateLimitMiddleware(
            _ =>
            {
                nextCalls++;
                return Task.CompletedTask;
            });
        var store = new ProtectionAdministrationRateLimitStore(
            TimeProvider.System,
            userLimit: 1,
            ipLimit: 2,
            maximumPartitions: 16);
        var principal = CreatePrincipal(
            new Claim("tid", Guid.NewGuid().ToString("D")),
            new Claim("oid", Guid.NewGuid().ToString("D")),
            new Claim("scp", "access_as_user"));
        var agentId = Guid.Parse(
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee");

        await middleware.InvokeAsync(
            CreateRateLimitedContext(
                principal,
                "PATCH",
                $"/API/V1/AGENTS/{agentId:D}/FEATURES"),
            store);
        var nFormat = CreateRateLimitedContext(
            principal,
            "PATCH",
            $"/api/v1/agents/{agentId.ToString(routeFormat)}/features");
        await middleware.InvokeAsync(nFormat, store);

        nextCalls.Should().Be(1);
        nFormat.Response.StatusCode.Should().Be(
            StatusCodes.Status429TooManyRequests);
    }

    [Fact]
    public void BootstrapCapabilityInitializerHasNoProviderOrCredentialDependency()
    {
        var parameterTypes = typeof(BootstrapCapabilitiesInitializer)
            .GetConstructors()
            .Single()
            .GetParameters()
            .Select(parameter => parameter.ParameterType)
            .ToArray();

        parameterTypes.Should().NotContain(type =>
            (type.FullName ?? type.Name).Contains(
                "Purview",
                StringComparison.OrdinalIgnoreCase) ||
            (type.FullName ?? type.Name).Contains(
                "PromptShield",
                StringComparison.OrdinalIgnoreCase) ||
            (type.FullName ?? type.Name).Contains(
                "HttpClient",
                StringComparison.OrdinalIgnoreCase));
        typeof(BootstrapCapabilityFactOptions)
            .GetProperties()
            .Select(property => property.Name)
            .Should().NotContain(name =>
                name.Contains("Token", StringComparison.OrdinalIgnoreCase) ||
                name.Contains("Credential", StringComparison.OrdinalIgnoreCase));
    }

    private static string? GetPolicy(string methodName) =>
        typeof(ProtectionController)
            .GetMethod(methodName, BindingFlags.Public | BindingFlags.Instance)!
            .GetCustomAttribute<AuthorizeAttribute>()!
            .Policy;

    private static ClaimsPrincipal CreatePrincipal(params Claim[] claims) =>
        new(new ClaimsIdentity(claims, "test"));

    private static DefaultHttpContext CreateRateLimitedContext(
        ClaimsPrincipal principal,
        string method,
        string path)
    {
        var context = new DefaultHttpContext
        {
            User = principal
        };
        context.Request.Method = method;
        context.Request.Path = path;
        context.Connection.RemoteIpAddress =
            System.Net.IPAddress.Parse("192.0.2.10");
        context.Response.Body = new MemoryStream();
        return context;
    }
}
