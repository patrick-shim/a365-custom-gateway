using Gateway.Purview;
using Gateway.Purview.Executor;
using System.Security.Claims;

namespace Gateway.ObservabilityRuntime.Tests.PurviewExecutor;

public sealed class ExecutorCallerAuthorizationTests
{
    private readonly ExecutorCallerBinding _binding = new(Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid());

    [Fact]
    public void ExactAuthenticatedWorker_IsAuthorized() =>
        Assert.True(ExecutorCallerAuthorization.IsAuthorized(Caller(), _binding));

    [Theory]
    [InlineData("tid")]
    [InlineData("oid")]
    [InlineData("azp")]
    public void WrongIdentity_IsRejected(string claim)
    {
        var caller = Caller();
        var identity = (ClaimsIdentity)caller.Identity!;
        identity.RemoveClaim(identity.FindFirst(claim));
        identity.AddClaim(new Claim(claim, Guid.NewGuid().ToString("D")));
        Assert.False(ExecutorCallerAuthorization.IsAuthorized(caller, _binding));
    }

    [Theory]
    [InlineData("tid")]
    [InlineData("oid")]
    [InlineData("azp")]
    public void DuplicateIdentityClaim_IsRejected(string claim)
    {
        var caller = Caller();
        ((ClaimsIdentity)caller.Identity!).AddClaim(caller.FindFirst(claim)!);
        Assert.False(ExecutorCallerAuthorization.IsAuthorized(caller, _binding));
    }

    [Theory]
    [InlineData("scp", "access_as_user")]
    [InlineData("scp", "")]
    [InlineData("http://schemas.microsoft.com/identity/claims/scope", "access_as_user")]
    public void DelegatedCaller_IsRejected(string type, string value)
    {
        var caller = Caller();
        ((ClaimsIdentity)caller.Identity!).AddClaim(new Claim(type, value));
        Assert.False(ExecutorCallerAuthorization.IsAuthorized(caller, _binding));
    }

    [Fact]
    public void MissingRole_IsRejected()
    {
        var caller = Caller();
        var identity = (ClaimsIdentity)caller.Identity!;
        identity.RemoveClaim(identity.FindFirst("roles"));
        Assert.False(ExecutorCallerAuthorization.IsAuthorized(caller, _binding));
    }

    [Fact]
    public void ContradictoryApplicationClaims_AreRejected()
    {
        var caller = Caller();
        ((ClaimsIdentity)caller.Identity!).AddClaim(new Claim("appid", Guid.NewGuid().ToString("D")));
        Assert.False(ExecutorCallerAuthorization.IsAuthorized(caller, _binding));
    }

    [Fact]
    public void UnauthenticatedClaims_AreRejected() =>
        Assert.False(ExecutorCallerAuthorization.IsAuthorized(
            new ClaimsPrincipal(new ClaimsIdentity(Caller().Claims)), _binding));

    private ClaimsPrincipal Caller() => new(new ClaimsIdentity(new[]
    {
        new Claim("tid", _binding.TenantId.ToString("D")),
        new Claim("oid", _binding.WorkerPrincipalId.ToString("D")),
        new Claim("azp", _binding.WorkerApplicationId.ToString("D")),
        new Claim("roles", ExecutorCallerAuthorization.RequiredRole)
    }, "Bearer"));
}
