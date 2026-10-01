using FluentAssertions;

namespace Gateway.Setup.Tests;

public sealed class SetupHostArgumentsTests
{
    [Fact]
    public void DefaultLaunchKeepsTheExistingBrowserBehavior()
    {
        var arguments = SetupHostArguments.Parse([]);

        arguments.OpenBrowser.Should().BeTrue();
        arguments.ShowHelp.Should().BeFalse();
        arguments.RepositoryRoot.Should().BeNull();
    }

    [Fact]
    public void NoOpenPreservesAnExactRepositoryPathWithoutOpeningABrowser()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "public checkout", ".");

        var arguments = SetupHostArguments.Parse(["--repo-root", path, "--no-open"]);

        arguments.RepositoryRoot.Should().Be(path);
        arguments.OpenBrowser.Should().BeFalse();
        arguments.ShowHelp.Should().BeFalse();
    }

    [Theory]
    [InlineData("-h")]
    [InlineData("--help")]
    public void HelpNeverRequestsABrowser(string flag)
    {
        var arguments = SetupHostArguments.Parse([flag]);

        arguments.ShowHelp.Should().BeTrue();
        arguments.OpenBrowser.Should().BeFalse();
        SetupHostArguments.Usage.Should().Contain("--no-open").And.Contain("--repo-root");
    }

    [Theory]
    [InlineData("--repo-root")]
    [InlineData("--repo-root", "")]
    [InlineData("--repo-root", " ")]
    [InlineData("--repo-root", "--no-open")]
    [InlineData("--repo-root", "-h")]
    [InlineData("--repo-root", "one", "--repo-root", "two")]
    [InlineData("--url", "http://0.0.0.0:5000")]
    [InlineData("--configuration", "ignored")]
    public void AmbiguousOrUnsupportedHostArgumentsAreRejected(params string[] values)
    {
        var parse = () => SetupHostArguments.Parse(values);

        parse.Should().Throw<ArgumentException>();
    }

    [Fact]
    public void UnknownArgumentIsNotEchoedToDiagnostics()
    {
        var parse = () => SetupHostArguments.Parse(["fixture-sensitive-argument"]);

        parse.Should().Throw<ArgumentException>()
            .Which.Message.Should().NotContain("fixture-sensitive-argument");
    }
}
