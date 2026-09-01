using FluentAssertions;
using Gateway.Setup.Services;

namespace Gateway.Setup.Tests.Services;

public sealed class BootstrapCommandFactoryTests
{
    private const string ReviewedFingerprint =
        "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    private const string ConfigurationFingerprint =
        "sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    private const string ResumeAuthorizationFingerprint =
        "sha256:9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba";

    [Theory]
    [InlineData(0, "Plan", false)]
    [InlineData(1, "Up", true)]
    [InlineData(2, "Resume", true)]
    [InlineData(3, "Resume", false)]
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
            command is BootstrapCommand.Apply or BootstrapCommand.Resume ? ReviewedFingerprint : null,
            command == BootstrapCommand.Plan ? ConfigurationFingerprint : null,
            command == BootstrapCommand.Resume ? ResumeAuthorizationFingerprint : null);

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
            expectedArguments.Add("-ExpectedConfigurationFileFingerprint");
            expectedArguments.Add(ConfigurationFingerprint);
            expectedArguments.Add("-NonInteractive");
        }
        else if (command == BootstrapCommand.ResumeReview)
        {
            expectedArguments.Add("-InstallPrerequisites:$false");
            expectedArguments.Add("-NonInteractive");
        }
        else
        {
            expectedArguments.Add("-ExpectedPlanFingerprint");
            expectedArguments.Add(ReviewedFingerprint);
            if (command == BootstrapCommand.Resume)
            {
                expectedArguments.Add("-ExpectedResumeAuthorizationFingerprint");
                expectedArguments.Add(ResumeAuthorizationFingerprint);
            }

            expectedArguments.Add("-Yes");
        }

        specification.Arguments.Should().Equal(expectedArguments);
        specification.Arguments.Contains("-NonInteractive").Should()
            .Be(command is BootstrapCommand.Plan or BootstrapCommand.ResumeReview);
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
    public void Create_ResumeReviewStartsOneReadOnlyProcessThatAuthorizesNothing()
    {
        var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), $"gateway-setup-review-{Guid.NewGuid():N}"));
        var factory = new BootstrapCommandFactory(new RepositoryLayout(root));

        var specification = factory.Create(BootstrapCommand.ResumeReview);

        specification.Arguments.Should().Contain("-NonInteractive");
        specification.Arguments.Should().NotContain("-Yes");
        specification.Arguments.Should().NotContain("-ExpectedPlanFingerprint");
        specification.Arguments.Should().NotContain("-ExpectedResumeAuthorizationFingerprint");
        specification.Arguments.Should().NotContain("-ExpectedConfigurationFileFingerprint");
        specification.Arguments.Should().Contain("Resume");
        specification.Arguments.Should().NotContain("Up");
    }

    [Fact]
    public void Create_ResumeReviewNeverInstallsLocalPrerequisites()
    {
        var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), $"gateway-setup-noinstall-{Guid.NewGuid():N}"));
        var factory = new BootstrapCommandFactory(new RepositoryLayout(root));

        var specification = factory.Create(BootstrapCommand.ResumeReview);

        specification.Arguments.Should().Contain(
            "-InstallPrerequisites:$false",
            "the read-only review must not install anything, and only the colon form binds a bool parameter under -File");
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    public void Create_LeavesThePrerequisiteBoundaryUnchangedForEveryReviewedCommand(int commandValue)
    {
        var command = (BootstrapCommand)commandValue;
        var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), $"gateway-setup-install-{Guid.NewGuid():N}"));
        var factory = new BootstrapCommandFactory(new RepositoryLayout(root));

        var specification = factory.Create(
            command,
            command is BootstrapCommand.Apply or BootstrapCommand.Resume ? ReviewedFingerprint : null,
            command == BootstrapCommand.Plan ? ConfigurationFingerprint : null,
            command == BootstrapCommand.Resume ? ResumeAuthorizationFingerprint : null);

        specification.Arguments.Should().NotContain(
            "-InstallPrerequisites:$false",
            "only the read-only review narrows the consented prerequisite boundary");
    }

    [Theory]
    [InlineData(ReviewedFingerprint, null, null)]
    [InlineData(null, ConfigurationFingerprint, null)]
    [InlineData(null, null, ResumeAuthorizationFingerprint)]
    public void Create_RejectsAnyFingerprintForTheReadOnlyResumeReview(
        string? planFingerprint,
        string? configurationFingerprint,
        string? resumeAuthorizationFingerprint)
    {
        var factory = new BootstrapCommandFactory(new RepositoryLayout(Path.GetTempPath()));

        var action = () => factory.Create(
            BootstrapCommand.ResumeReview,
            planFingerprint,
            configurationFingerprint,
            resumeAuthorizationFingerprint);

        action.Should().Throw<ArgumentException>();
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("sha256:ABCDEF")]
    [InlineData("sha256:9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcbz")]
    public void Create_RejectsResumeWithoutAnExactCanonicalResumeAuthorizationFingerprint(
        string? resumeAuthorizationFingerprint)
    {
        var factory = new BootstrapCommandFactory(new RepositoryLayout(Path.GetTempPath()));

        var action = () => factory.Create(
            BootstrapCommand.Resume,
            ReviewedFingerprint,
            expectedResumeAuthorizationFingerprint: resumeAuthorizationFingerprint);

        action.Should().Throw<ArgumentException>();
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    public void Create_RejectsAResumeAuthorizationFingerprintForPlanAndApply(int commandValue)
    {
        var command = (BootstrapCommand)commandValue;
        var factory = new BootstrapCommandFactory(new RepositoryLayout(Path.GetTempPath()));

        var action = () => factory.Create(
            command,
            command == BootstrapCommand.Plan ? null : ReviewedFingerprint,
            command == BootstrapCommand.Plan ? ConfigurationFingerprint : null,
            ResumeAuthorizationFingerprint);

        action.Should().Throw<ArgumentException>();
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

        var action = () => factory.Create(
            BootstrapCommand.Plan,
            ReviewedFingerprint,
            ConfigurationFingerprint);

        action.Should().Throw<ArgumentException>();
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("sha256:ABCDEF")]
    [InlineData("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg")]
    public void Create_RejectsPlanWithoutAnExactPublishedConfigurationFingerprint(
        string? fingerprint)
    {
        var factory = new BootstrapCommandFactory(new RepositoryLayout(Path.GetTempPath()));

        var action = () => factory.Create(
            BootstrapCommand.Plan,
            expectedConfigurationFileFingerprint: fingerprint);

        action.Should().Throw<ArgumentException>();
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    public void Create_RejectsConfigurationFingerprintForMutationCommands(int commandValue)
    {
        var factory = new BootstrapCommandFactory(new RepositoryLayout(Path.GetTempPath()));

        var action = () => factory.Create(
            (BootstrapCommand)commandValue,
            ReviewedFingerprint,
            ConfigurationFingerprint);

        action.Should().Throw<ArgumentException>();
    }
}
