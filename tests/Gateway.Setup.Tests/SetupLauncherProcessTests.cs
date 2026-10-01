using System.Diagnostics;
using System.Runtime.InteropServices;
using FluentAssertions;
using Gateway.Setup.Tests.Fixtures;

namespace Gateway.Setup.Tests;

public sealed class SetupLauncherProcessTests
{
    [Theory]
    [InlineData("-h")]
    [InlineData("--help")]
    public async Task HelpExitsBeforeRepositoryResolutionOrHostStartup(string flag)
    {
        using var directory = new SetupFixtureDirectory();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        using var process = StartLauncher(directory, flag, "--repo-root", "not-a-filesystem-root://fixture");
        try
        {
            var outputTask = process.StandardOutput.ReadToEndAsync(timeout.Token);
            var errorTask = process.StandardError.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token);

            process.ExitCode.Should().Be(0);
            (await outputTask).Should().Contain(SetupHostArguments.Usage)
                .And.NotContain("one-time URL if the browser does not start");
            (await errorTask).Should().BeEmpty();
            Directory.GetFiles(Path.Combine(directory.RootPath, "bootstrap"))
                .Should().ContainSingle().Which.Should().EndWith("bootstrap.ps1");
        }
        finally
        {
            await StopOwnedProcessAsync(process);
        }
    }

    [Fact]
    public async Task InvalidArgumentReturnsUsageWithoutEchoingItsValueOrStartingTheHost()
    {
        using var directory = new SetupFixtureDirectory();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        using var process = StartLauncher(directory, "fixture-sensitive-argument");
        try
        {
            var outputTask = process.StandardOutput.ReadToEndAsync(timeout.Token);
            var errorTask = process.StandardError.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token);

            process.ExitCode.Should().Be(2);
            (await outputTask).Should().BeEmpty();
            (await errorTask).Should().Contain("Usage: Gateway.Setup")
                .And.NotContain("fixture-sensitive-argument");
        }
        finally
        {
            await StopOwnedProcessAsync(process);
        }
    }

    [Theory]
    [Trait("Category", "Guard")]
    [InlineData("--no-open")]
    [InlineData("--repo-root")]
    public void FixtureRejectsCommandsThatCouldStartTheWebHost(string argument)
    {
        using var directory = new SetupFixtureDirectory();

        var action = () => StartLauncher(directory, argument);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("*never start the Setup web host*");
    }

    private static Process StartLauncher(SetupFixtureDirectory directory, params string[] arguments)
    {
        if (arguments.Length == 0 ||
            arguments[0] is not ("-h" or "--help" or "fixture-sensitive-argument"))
        {
            throw new InvalidOperationException("Launcher fixtures must never start the Setup web host.");
        }

        var dotnetRoot = new DirectoryInfo(RuntimeEnvironment.GetRuntimeDirectory()).Parent!.Parent!.Parent!;
        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(dotnetRoot.FullName, OperatingSystem.IsWindows() ? "dotnet.exe" : "dotnet"),
            WorkingDirectory = directory.RootPath,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        startInfo.ArgumentList.Add(typeof(RepositoryLayout).Assembly.Location);
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        // Even an accidental provider call cannot resolve the installed az/pwsh or inherit CLI state.
        startInfo.Environment["PATH"] = directory.RootPath;
        startInfo.Environment["AZURE_CONFIG_DIR"] = Path.Combine(directory.RootPath, "no-azure-session");
        startInfo.Environment["AZD_CONFIG_DIR"] = Path.Combine(directory.RootPath, "no-azd-session");
        startInfo.Environment["TEMP"] = directory.RootPath;
        startInfo.Environment["TMP"] = directory.RootPath;
        startInfo.Environment["DOTNET_ENVIRONMENT"] = "Production";
        startInfo.Environment["ASPNETCORE_ENVIRONMENT"] = "Production";
        return Process.Start(startInfo) ?? throw new InvalidOperationException("The owned local Setup process did not start.");
    }

    private static async Task StopOwnedProcessAsync(Process process)
    {
        if (!process.HasExited)
        {
            process.Kill(entireProcessTree: true);
        }

        await process.WaitForExitAsync();
    }
}
