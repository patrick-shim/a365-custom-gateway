using System.Security.Claims;
using FluentAssertions;
using Gateway.Api.Extensions;

namespace Gateway.SecurityTests;

/// <summary>
/// Verifies that <see cref="ClaimsPrincipalExtensions"/> correctly extracts
/// identity claims used for authorization and agent-to-client binding.
/// These are the foundational methods used throughout the API to identify callers.
/// </summary>
public class ClaimExtractionTests
{
    private const string FullOidClaimType =
        "http://schemas.microsoft.com/identity/claims/objectidentifier";
    private const string ShortOidClaimType = "oid";
    private const string AppIdClaimType = "appid";
    private const string AzpClaimType = "azp";

    // ---------------------------------------------------------------
    // Helper
    // ---------------------------------------------------------------

    private static ClaimsPrincipal CreatePrincipal(params Claim[] claims)
    {
        var identity = new ClaimsIdentity(claims, "TestAuth");
        return new ClaimsPrincipal(identity);
    }

    // ---------------------------------------------------------------
    // GetObjectId: primary claim (full URI)
    // ---------------------------------------------------------------

    [Fact]
    public void GetObjectId_Should_ReturnValue_When_FullOidClaimPresent()
    {
        var objectId = Guid.NewGuid().ToString();
        var principal = CreatePrincipal(new Claim(FullOidClaimType, objectId));

        var result = principal.GetObjectId();

        result.Should().Be(objectId);
    }

    // ---------------------------------------------------------------
    // GetObjectId: fallback claim (short "oid")
    // ---------------------------------------------------------------

    [Fact]
    public void GetObjectId_Should_FallBackToShortOid_When_FullOidClaimMissing()
    {
        var objectId = Guid.NewGuid().ToString();
        var principal = CreatePrincipal(new Claim(ShortOidClaimType, objectId));

        var result = principal.GetObjectId();

        result.Should().Be(objectId);
    }

    // ---------------------------------------------------------------
    // GetObjectId: precedence when both claims exist
    // ---------------------------------------------------------------

    [Fact]
    public void GetObjectId_Should_PreferFullOidClaim_When_BothClaimsPresent()
    {
        var fullOid = Guid.NewGuid().ToString();
        var shortOid = Guid.NewGuid().ToString();
        var principal = CreatePrincipal(
            new Claim(FullOidClaimType, fullOid),
            new Claim(ShortOidClaimType, shortOid));

        var result = principal.GetObjectId();

        result.Should().Be(fullOid,
            "the full URI oid claim must take precedence over the short 'oid' claim");
    }

    // ---------------------------------------------------------------
    // GetObjectId: missing claim throws
    // ---------------------------------------------------------------

    [Fact]
    public void GetObjectId_Should_ThrowInvalidOperationException_When_NoOidClaimPresent()
    {
        var principal = CreatePrincipal(
            new Claim("some_unrelated_claim", "some-value"));

        var act = () => principal.GetObjectId();

        act.Should().Throw<InvalidOperationException>()
            .WithMessage("*oid*");
    }

    [Fact]
    public void GetObjectId_Should_ThrowInvalidOperationException_When_PrincipalHasNoClaims()
    {
        var principal = CreatePrincipal();

        var act = () => principal.GetObjectId();

        act.Should().Throw<InvalidOperationException>();
    }

    // ---------------------------------------------------------------
    // GetClientId: primary claim (appid)
    // ---------------------------------------------------------------

    [Fact]
    public void GetClientId_Should_ReturnAppIdValue_When_AppIdClaimPresent()
    {
        var clientId = Guid.NewGuid().ToString();
        var principal = CreatePrincipal(new Claim(AppIdClaimType, clientId));

        var result = principal.GetClientId();

        result.Should().Be(clientId);
    }

    // ---------------------------------------------------------------
    // GetClientId: fallback claim (azp)
    // ---------------------------------------------------------------

    [Fact]
    public void GetClientId_Should_FallBackToAzp_When_AppIdClaimMissing()
    {
        var clientId = Guid.NewGuid().ToString();
        var principal = CreatePrincipal(new Claim(AzpClaimType, clientId));

        var result = principal.GetClientId();

        result.Should().Be(clientId);
    }

    // ---------------------------------------------------------------
    // GetClientId: precedence when both claims exist
    // ---------------------------------------------------------------

    [Fact]
    public void GetClientId_Should_PreferAppId_When_BothClaimsPresent()
    {
        var appId = Guid.NewGuid().ToString();
        var azp = Guid.NewGuid().ToString();
        var principal = CreatePrincipal(
            new Claim(AppIdClaimType, appId),
            new Claim(AzpClaimType, azp));

        var result = principal.GetClientId();

        result.Should().Be(appId,
            "the 'appid' claim must take precedence over the 'azp' claim");
    }

    // ---------------------------------------------------------------
    // GetClientId: missing claim throws
    // ---------------------------------------------------------------

    [Fact]
    public void GetClientId_Should_ThrowInvalidOperationException_When_NoClientIdClaimPresent()
    {
        var principal = CreatePrincipal(
            new Claim("some_unrelated_claim", "some-value"));

        var act = () => principal.GetClientId();

        act.Should().Throw<InvalidOperationException>()
            .WithMessage("*appid*");
    }

    [Fact]
    public void GetClientId_Should_ThrowInvalidOperationException_When_PrincipalHasNoClaims()
    {
        var principal = CreatePrincipal();

        var act = () => principal.GetClientId();

        act.Should().Throw<InvalidOperationException>();
    }

    // ---------------------------------------------------------------
    // Both methods work with typical Entra ID token claims
    // ---------------------------------------------------------------

    [Fact]
    public void BothMethods_Should_ExtractCorrectValues_When_TypicalEntraIdClaimsPresent()
    {
        var objectId = Guid.NewGuid().ToString();
        var clientId = Guid.NewGuid().ToString();

        var principal = CreatePrincipal(
            new Claim(FullOidClaimType, objectId),
            new Claim(AppIdClaimType, clientId),
            new Claim("name", "Test User"),
            new Claim(ClaimTypes.Role, "Gateway.Administrator"));

        principal.GetObjectId().Should().Be(objectId);
        principal.GetClientId().Should().Be(clientId);
    }

    // ---------------------------------------------------------------
    // Edge case: empty claim values
    // ---------------------------------------------------------------

    [Fact]
    public void GetObjectId_Should_ReturnEmptyString_When_OidClaimValueIsEmpty()
    {
        // An empty oid claim should still be returned (not treated as missing).
        // The caller is responsible for validating the value.
        var principal = CreatePrincipal(new Claim(FullOidClaimType, string.Empty));

        var result = principal.GetObjectId();

        result.Should().BeEmpty();
    }

    [Fact]
    public void GetClientId_Should_ReturnEmptyString_When_AppIdClaimValueIsEmpty()
    {
        var principal = CreatePrincipal(new Claim(AppIdClaimType, string.Empty));

        var result = principal.GetClientId();

        result.Should().BeEmpty();
    }
}
