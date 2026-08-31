using FluentAssertions;
using Gateway.Setup.Services;

namespace Gateway.Setup.Tests.Services;

public sealed class AzureCliRunnerTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"gateway-setup-az-runner-{Guid.NewGuid():N}");

    [Fact]
    public void WindowsCmdLauncher_ResolvesToBundledPythonModule()
    {
        var commandDirectory = Directory.CreateDirectory(Path.Combine(root, "Azure CLI wbin")).FullName;
        var commandPath = Path.Combine(commandDirectory, "az.cmd");
        var pythonPath = Path.Combine(root, "python.exe");
        File.WriteAllText(commandPath, "@exit /b 0");
        File.WriteAllText(pythonPath, string.Empty);

        var result = AzureCliExecutableResolver.Resolve(
            isWindows: true,
            searchPath: $"\"{commandDirectory}\"");

        result.Should().NotBeNull();
        result!.FileName.Should().Be(Path.GetFullPath(pythonPath));
        result.PrefixArguments.Should().Equal("-IBm", "azure.cli");
    }

    [Fact]
    public void WindowsExecutableLauncher_RunsDirectly()
    {
        var commandDirectory = Directory.CreateDirectory(Path.Combine(root, "bin")).FullName;
        var executablePath = Path.Combine(commandDirectory, "az.exe");
        File.WriteAllText(executablePath, string.Empty);

        var result = AzureCliExecutableResolver.Resolve(
            isWindows: true,
            searchPath: commandDirectory);

        result.Should().NotBeNull();
        result!.FileName.Should().Be(Path.GetFullPath(executablePath));
        result.PrefixArguments.Should().BeEmpty();
    }

    [Fact]
    public void WindowsCmdWithoutBundledPython_FailsClosed()
    {
        var commandDirectory = Directory.CreateDirectory(Path.Combine(root, "wbin")).FullName;
        File.WriteAllText(Path.Combine(commandDirectory, "az.cmd"), "@exit /b 0");

        var result = AzureCliExecutableResolver.Resolve(
            isWindows: true,
            searchPath: commandDirectory);

        result.Should().BeNull();
    }

    [Fact]
    public void WindowsMissingLauncher_FailsClosed()
    {
        var commandDirectory = Directory.CreateDirectory(Path.Combine(root, "empty")).FullName;

        var result = AzureCliExecutableResolver.Resolve(
            isWindows: true,
            searchPath: commandDirectory);

        result.Should().BeNull();
    }

    [Fact]
    public void WindowsBrokenFirstCmd_DoesNotBypassPathPrecedence()
    {
        var firstDirectory = Directory.CreateDirectory(Path.Combine(root, "first")).FullName;
        var secondDirectory = Directory.CreateDirectory(Path.Combine(root, "second")).FullName;
        File.WriteAllText(Path.Combine(firstDirectory, "az.cmd"), "@exit /b 0");
        File.WriteAllText(Path.Combine(secondDirectory, "az.exe"), string.Empty);

        var result = AzureCliExecutableResolver.Resolve(
            isWindows: true,
            searchPath: string.Join(Path.PathSeparator, firstDirectory, secondDirectory));

        result.Should().BeNull();
    }

    [Fact]
    public void NonWindowsLauncher_RemainsDirectAzureCli()
    {
        var result = AzureCliExecutableResolver.Resolve(
            isWindows: false,
            searchPath: null);

        result.Should().NotBeNull();
        result!.FileName.Should().Be("az");
        result.PrefixArguments.Should().BeEmpty();
    }

    [Fact]
    public void StartInfo_PrependsOnlyReviewedPythonModuleArgumentsAndPreservesGraphUrl()
    {
        var executable = new AzureCliExecutable(
            Path.Combine(root, "python.exe"),
            ["-IBm", "azure.cli"]);
        var graphUrl =
            "https://graph.microsoft.com/v1.0/applications?$select=id&$skiptoken=a%2Fb";

        var startInfo = AzureCliRunner.CreateStartInfo(
            executable,
            ["rest", "--url", graphUrl, "--output", "json"]);

        startInfo.FileName.Should().Be(executable.FileName);
        startInfo.ArgumentList.Should().Equal(
            "-IBm",
            "azure.cli",
            "rest",
            "--url",
            graphUrl,
            "--output",
            "json");
        startInfo.UseShellExecute.Should().BeFalse();
        startInfo.RedirectStandardOutput.Should().BeTrue();
        startInfo.RedirectStandardError.Should().BeTrue();
        startInfo.Environment["AZURE_CORE_NO_COLOR"].Should().Be("1");
    }

    [Fact]
    public async Task UnavailableExecutable_ReturnsSafeStatusWithoutStartingAProcess()
    {
        var runner = new AzureCliRunner(new FixedResolver(null));

        var result = await runner.RunAsync(
            ["account", "list"],
            TimeSpan.FromSeconds(1),
            CancellationToken.None);

        result.Status.Should().Be(AzureCliInvocationStatus.Unavailable);
        result.ExitCode.Should().Be(-1);
        result.StandardOutput.Should().BeEmpty();
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private sealed class FixedResolver(AzureCliExecutable? executable) : IAzureCliExecutableResolver
    {
        public AzureCliExecutable? Resolve() => executable;
    }
}
