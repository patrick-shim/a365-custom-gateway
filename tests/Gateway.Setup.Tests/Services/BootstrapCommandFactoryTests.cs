using FluentAssertions;
using Gateway.Setup.Services;

namespace Gateway.Setup.Tests.Services;

public sealed class BootstrapCommandFactoryTests
{
    private const string ReviewedFingerprint =
        "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    [Theory]
    [InlineData(0, "Plan", false)]
    [InlineData(1, "Up", true)]
    [InlineData(2, "Resume", true)]
    public void Create_UsesOnlyReviewedPlanAndExplicitMutationArguments(
        int commandValue,
        string expectedMode,
        bool expectsAcceptance)
    {
        var command = (BootstrapCommand)commandValue;
        var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), $"gateway-setup-command-{Guid.NewGuid():N}"));
        var factory = new BootstrapCommandFactory(new RepositoryLayout(root));

        var specification = factory.Create(
            command,
            command == BootstrapCommand.Plan ? null : ReviewedFingerprint);

        specification.FileName.Should().Be("pwsh");
        specification.WorkingDirectory.Should().Be(root);
        var expectedArguments = new List<string>
        {
            "-NoLogo",
            "-NoProfile",
            "-File",
            Path.Combine(root, "bootstrap", "bootstrap.ps1"),
            "-Mode",
            expectedMode,
            "-Config",
            Path.Combine(root, "bootstrap", "config.json"),
            "-OutputFormat",
            "Json",
            "-EventStreamOnly"
        };
        if (command == BootstrapCommand.Plan)
        {
            expectedArguments.Add("-NonInteractive");
        }
        else
        {
            expectedArguments.Add("-ExpectedPlanFingerprint");
            expectedArguments.Add(ReviewedFingerprint);
            expectedArguments.Add("-Yes");
        }

        specification.Arguments.Should().Equal(expectedArguments);
        specification.Arguments.Contains("-NonInteractive").Should().Be(command == BootstrapCommand.Plan);
        specification.Arguments.Contains("-Yes").Should().Be(expectsAcceptance);
        specification.Arguments.Should().NotContain("-OpenBrowser");
        specification.Arguments.Should().NotContain("-Command");
        specification.Arguments.Should().NotContain(argument =>
            argument.Contains(".secrets", StringComparison.OrdinalIgnoreCase) ||
            argument.Contains("Destroy", StringComparison.OrdinalIgnoreCase));

        var startInfo = specification.ToStartInfo();
        startInfo.UseShellExecute.Should().BeFalse();
        startInfo.RedirectStandardInput.Should().BeFalse();
        startInfo.RedirectStandardOutput.Should().BeTrue();
        startInfo.RedirectStandardError.Should().BeTrue();
    }

    [Fact]
    public void Create_RejectsAnyCommandOutsideTheEnumAllowlist()
    {
        var factory = new BootstrapCommandFactory(new RepositoryLayout(Path.GetTempPath()));

        var action = () => factory.Create((BootstrapCommand)999);

        action.Should().Throw<ArgumentOutOfRangeException>();
    }

    [Theory]
    [InlineData(1, null)]
    [InlineData(2, "")]
    [InlineData(1, "sha256:ABCDEF")]
    [InlineData(2, "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg")]
    public void Create_RejectsMutationWithoutAnExactCanonicalReviewedFingerprint(
        int commandValue,
        string? fingerprint)
    {
        var factory = new BootstrapCommandFactory(new RepositoryLayout(Path.GetTempPath()));

        var action = () => factory.Create((BootstrapCommand)commandValue, fingerprint);

        action.Should().Throw<ArgumentException>();
    }

    [Fact]
    public void Create_RejectsAnExpectedFingerprintForTheReadOnlyPlan()
    {
        var factory = new BootstrapCommandFactory(new RepositoryLayout(Path.GetTempPath()));

        var action = () => factory.Create(BootstrapCommand.Plan, ReviewedFingerprint);

        action.Should().Throw<ArgumentException>();
    }
}
