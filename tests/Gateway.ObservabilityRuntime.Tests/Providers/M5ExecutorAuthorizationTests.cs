using System.Security.Claims;
using Gateway.ObservabilityRuntime.Tests.Fixtures;
using Gateway.Purview.Executor;

namespace Gateway.ObservabilityRuntime.Tests.Providers;

public sealed class M5ExecutorAuthorizationTests
{
    private static ExecutorCallerBinding Binding =>
        new(FixtureIds.Tenant, FixtureIds.Principal, FixtureIds.Child);

    [Theory]
    [InlineData("azp")]
    [InlineData("appid")]
    [InlineData("both")]
    public void ExactAuthenticatedApplicationCallerIsAdmitted(string applicationClaim)
    {
        var claims = Claims();
        if (applicationClaim == "appid") claims.RemoveAll(claim => claim.Type == "azp");
        if (applicationClaim is "appid" or "both")
            claims.Add(new("appid", FixtureIds.Child.ToString("D")));

        Assert.True(ExecutorCallerAuthorization.IsAuthorized(
            new ClaimsPrincipal(new ClaimsIdentity(claims, "synthetic-validated-jwt")), Binding));
    }

    [Theory]
    [InlineData("tid")]
    [InlineData("oid")]
    [InlineData("azp")]
    [InlineData("roles")]
    public void MissingRequiredAuthorityIsDenied(string type)
    {
        var claims = Claims();
        claims.RemoveAll(claim => claim.Type == type);
        Assert.False(Authorize(claims));
    }

    [Theory]
    [InlineData("tid")]
    [InlineData("oid")]
    [InlineData("azp")]
    public void WrongOrDuplicateIdentityIsDenied(string type)
    {
        var claims = Claims();
        claims.Add(new(type, claims.Single(claim => claim.Type == type).Value));
        Assert.False(Authorize(claims));
        claims.RemoveAll(claim => claim.Type == type);
        claims.Add(new(type, FixtureIds.Registry.ToString("D")));
        Assert.False(Authorize(claims));
    }

    [Theory]
    [InlineData("scp")]
    [InlineData("http://schemas.microsoft.com/identity/claims/scope")]
    public void DelegatedScopeCannotSatisfyApplicationOnlyAuthority(string scope)
    {
        var claims = Claims();
        claims.Add(new(scope, ""));
        Assert.False(Authorize(claims));
    }

    [Fact]
    public void ConflictingApplicationClaimsAndIncorrectRoleAreDenied()
    {
        var claims = Claims();
        claims.Add(new("appid", FixtureIds.Registry.ToString("D")));
        Assert.False(Authorize(claims));
        claims.RemoveAll(claim => claim.Type is "appid" or "roles");
        claims.Add(new("roles", "purview.executor.invoke"));
        Assert.False(Authorize(claims));
    }

    [Fact]
    public void UnauthenticatedPrincipalOrEmptyConfiguredBindingIsDenied()
    {
        Assert.False(ExecutorCallerAuthorization.IsAuthorized(
            new ClaimsPrincipal(new ClaimsIdentity(Claims())), Binding));
        Assert.False(ExecutorCallerAuthorization.IsAuthorized(
            new ClaimsPrincipal(new ClaimsIdentity(Claims(), "synthetic-validated-jwt")),
            Binding with { WorkerPrincipalId = Guid.Empty }));
    }

    private static bool Authorize(IEnumerable<Claim> claims) =>
        ExecutorCallerAuthorization.IsAuthorized(
            new ClaimsPrincipal(new ClaimsIdentity(claims, "synthetic-validated-jwt")), Binding);

    private static List<Claim> Claims() =>
    [
        new("tid", FixtureIds.Tenant.ToString("D")),
        new("oid", FixtureIds.Principal.ToString("D")),
        new("azp", FixtureIds.Child.ToString("D")),
        new("roles", ExecutorCallerAuthorization.RequiredRole)
    ];
}
