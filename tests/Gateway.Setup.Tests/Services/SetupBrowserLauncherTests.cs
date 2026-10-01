using System.ComponentModel;
using System.Diagnostics;
using FluentAssertions;
using Gateway.Setup.Services;
using Gateway.Setup.Tests.Fixtures;

namespace Gateway.Setup.Tests.Services;

public sealed class SetupBrowserLauncherTests
{
    private static readonly Uri InitialAddress = new("http://127.0.0.1:43123/setup?nonce=offline-fixture");

    [Theory]
    [InlineData("--no-open")]
    [InlineData("--help")]
    [InlineData("-h")]
    public void NoOpenAndHelpNeverInvokeTheBrowserBoundary(string flag)
    {
        var launcher = new FixtureBrowserLauncher();

        var result = SetupBrowserLauncher.OpenIfRequested(
            SetupHostArguments.Parse([flag]), launcher, InitialAddress);

        result.Should().BeFalse();
        launcher.Calls.Should().BeEmpty();
    }

    [Fact]
    public void DefaultLaunchPassesOnlyTheInitialAddressToTheFakeBrowser()
    {
        var launcher = new FixtureBrowserLauncher();

        SetupBrowserLauncher.OpenIfRequested(SetupHostArguments.Parse([]), launcher, InitialAddress)
            .Should().BeTrue();

        launcher.Calls.Should().Equal(InitialAddress);
    }

    [Fact]
    public void LauncherUsesAnExplicitFakeProcessBoundaryForTheLoopbackAddress()
    {
        var calls = new List<ProcessStartInfo>();
        var launcher = new SetupBrowserLauncher(calls.Add);

        launcher.TryOpen(InitialAddress).Should().BeTrue();

        var startInfo = calls.Should().ContainSingle().Which;
        startInfo.FileName.Should().Be(InitialAddress.AbsoluteUri);
        startInfo.UseShellExecute.Should().BeTrue();
        startInfo.ArgumentList.Should().BeEmpty();
    }

    [Theory]
    [InlineData("https://127.0.0.1:43123/setup")]
    [InlineData("http://192.0.2.10:43123/setup")]
    [InlineData("https://example.invalid/setup")]
    [InlineData("file:///fixture.html")]
    [InlineData("/setup")]
    public void NonLoopbackOrNonHttpAddressesNeverReachTheProcessBoundary(string value)
    {
        var calls = new List<ProcessStartInfo>();
        var launcher = new SetupBrowserLauncher(calls.Add);

        launcher.TryOpen(new Uri(value, UriKind.RelativeOrAbsolute)).Should().BeFalse();

        calls.Should().BeEmpty();
    }

    [Fact]
    public void BrowserLaunchFailureIsReportedWithoutLeakingTheProviderException()
    {
        var launcher = new SetupBrowserLauncher(_ =>
            throw new Win32Exception("fixture-sensitive-launch-diagnostic"));

        launcher.TryOpen(InitialAddress).Should().BeFalse();
    }
}
