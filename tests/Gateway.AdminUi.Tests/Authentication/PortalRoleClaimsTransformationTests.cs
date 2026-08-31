using System.Security.Claims;
using FluentAssertions;
using Gateway.AdminUi.Authentication;

namespace Gateway.AdminUi.Tests.Authentication;

public sealed class PortalRoleClaimsTransformationTests
{
    [Theory]
    [InlineData("Administrator", GatewayRoles.Administrator)]
    [InlineData("operator", GatewayRoles.Operator)]
    [InlineData("AUDITOR", GatewayRoles.Auditor)]
    [InlineData("Reader", GatewayRoles.SupportReader)]
    public async Task TransformAsync_MapsPortalRoleToCanonicalGatewayRole(
        string portalRole,
        string expectedRole)
    {
        var principal = AuthenticatedPrincipal(new Claim("roles", portalRole));
        var sut = new PortalRoleClaimsTransformation();

        var transformed = await sut.TransformAsync(principal);

        transformed.Should().BeSameAs(principal);
        transformed.IsInRole(expectedRole).Should().BeTrue();
    }

    [Fact]
    public async Task TransformAsync_DoesNotDuplicateCanonicalRoleAcrossRepeatedTransforms()
    {
        var principal = AuthenticatedPrincipal(
            new Claim("roles", "Administrator"),
            new Claim(ClaimTypes.Role, GatewayRoles.Administrator));
        var sut = new PortalRoleClaimsTransformation();

        await sut.TransformAsync(principal);
        await sut.TransformAsync(principal);

        principal.Claims
            .Count(claim => claim.Type == ClaimTypes.Role &&
                claim.Value == GatewayRoles.Administrator)
            .Should().Be(1);
    }

    [Fact]
    public async Task TransformAsync_NormalizesCanonicalInboundRoleToIdentityRoleClaimType()
    {
        var principal = new ClaimsPrincipal(new ClaimsIdentity(
            [new Claim(ClaimTypes.Role, GatewayRoles.Administrator)],
            "test",
            ClaimTypes.Name,
            "roles"));
        var sut = new PortalRoleClaimsTransformation();

        await sut.TransformAsync(principal);

        principal.IsInRole(GatewayRoles.Administrator).Should().BeTrue();
        principal.Claims.Should().ContainSingle(claim =>
            claim.Type == "roles" &&
            claim.Value == GatewayRoles.Administrator);
    }

    [Fact]
    public async Task TransformAsync_LeavesUnauthenticatedPrincipalUnchanged()
    {
        var identity = new ClaimsIdentity([new Claim("roles", "Administrator")]);
        var principal = new ClaimsPrincipal(identity);
        var sut = new PortalRoleClaimsTransformation();

        var transformed = await sut.TransformAsync(principal);

        transformed.Should().BeSameAs(principal);
        transformed.IsInRole(GatewayRoles.Administrator).Should().BeFalse();
        identity.Claims.Should().ContainSingle();
    }

    [Fact]
    public async Task TransformAsync_DoesNotGrantUnknownPortalRole()
    {
        var principal = AuthenticatedPrincipal(new Claim("roles", "ExternalAgent"));
        var sut = new PortalRoleClaimsTransformation();

        await sut.TransformAsync(principal);

        principal.IsInRole(GatewayRoles.Administrator).Should().BeFalse();
        principal.IsInRole(GatewayRoles.Operator).Should().BeFalse();
        principal.IsInRole(GatewayRoles.Auditor).Should().BeFalse();
        principal.IsInRole(GatewayRoles.SupportReader).Should().BeFalse();
    }

    private static ClaimsPrincipal AuthenticatedPrincipal(params Claim[] claims) =>
        new(new ClaimsIdentity(claims, "test", ClaimTypes.Name, ClaimTypes.Role));
}
