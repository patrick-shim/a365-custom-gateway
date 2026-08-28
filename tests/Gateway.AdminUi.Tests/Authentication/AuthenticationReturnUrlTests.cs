using FluentAssertions;
using Gateway.AdminUi.Authentication;

namespace Gateway.AdminUi.Tests.Authentication;

public sealed class AuthenticationReturnUrlTests
{
    [Theory]
    [InlineData(null, "/")]
    [InlineData("", "/")]
    [InlineData("   ", "/")]
    [InlineData("/", "/")]
    [InlineData("/dashboard", "/dashboard")]
    [InlineData("/agents/00000000-0000-0000-0000-000000000001?tab=audit", "/agents/00000000-0000-0000-0000-000000000001?tab=audit")]
    [InlineData("relative/path", "/")]
    [InlineData("https://attacker.example/path", "/")]
    [InlineData("//attacker.example/path", "/")]
    [InlineData("/\\attacker.example/path", "/")]
    [InlineData("/dashboard\r\nX-Injected: true", "/")]
    public void Normalize_AllowsOnlyLocalRootedControlFreePaths(
        string? candidate,
        string expected)
    {
        AuthenticationReturnUrl.Normalize(candidate).Should().Be(expected);
    }
}
