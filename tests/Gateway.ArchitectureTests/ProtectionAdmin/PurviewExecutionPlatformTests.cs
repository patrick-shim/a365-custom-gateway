using FluentAssertions;

namespace Gateway.ArchitectureTests.ProtectionAdmin;

public sealed class PurviewExecutionPlatformTests
{
    [Fact]
    public void LinuxWorker_DoesNotPackageUnsupportedCompliancePowerShell()
    {
        var dockerfile = ReadSource("Gateway.Provisioning.Worker", "Dockerfile");

        dockerfile.Should().NotContain("Install-Module ExchangeOnlineManagement",
            "Connect-IPPSSession is unsupported on PowerShell 7 Linux; " +
            "installing the module cannot make that execution path supported");
    }

    [Theory]
    [InlineData("Gateway.Provisioning.Worker",
        "PowerShellPurviewConnectionVerificationProvider")]
    [InlineData("Gateway.Purview", "PowerShellPurviewSettingsAutomation")]
    public void GatewayServices_DoNotRegisterLocalCompliancePowerShell(
        string project,
        string localProvider)
    {
        var registration = ReadSource(project, "DependencyInjection.cs");

        registration.Should().NotContain(localProvider,
            "the Linux Gateway must use the supported Windows execution " +
            "boundary for authoritative Purview operations");
    }

    private static string ReadSource(string project, string file)
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null &&
               !File.Exists(Path.Combine(directory.FullName, "AGENTS.md")))
        {
            directory = directory.Parent;
        }

        var root = directory?.FullName
            ?? throw new DirectoryNotFoundException("Repository root not found.");
        return File.ReadAllText(Path.Combine(root, "src", project, file));
    }
}
