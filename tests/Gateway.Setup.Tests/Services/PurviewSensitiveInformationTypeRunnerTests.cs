using FluentAssertions;
using Gateway.Setup.Services;

namespace Gateway.Setup.Tests.Services;

public sealed class PurviewSensitiveInformationTypeRunnerTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"gateway-setup-purview-runner-{Guid.NewGuid():N}");

    [Fact]
    public void CreateStartInfo_UsesFixedFileContractAndArgumentList()
    {
        var tenantId = Guid.NewGuid();
        var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Gateway Setup runner"));
        var script = Path.Combine(root, "bootstrap", "get-purview-sensitive-information-types.ps1");

        var startInfo = PurviewSensitiveInformationTypeRunner.CreateStartInfo(
            "pwsh",
            root,
            script,
            tenantId,
            "operator@contoso.example");

        startInfo.FileName.Should().Be("pwsh");
        startInfo.WorkingDirectory.Should().Be(root);
        startInfo.ArgumentList.Should().Equal(
            "-NoLogo",
            "-NoProfile",
            "-File",
            script,
            "-TenantId",
            tenantId.ToString("D"),
            "-UserPrincipalName",
            "operator@contoso.example");
        startInfo.ArgumentList.Should().NotContain("-Command");
        startInfo.UseShellExecute.Should().BeFalse();
        startInfo.RedirectStandardOutput.Should().BeTrue();
        startInfo.RedirectStandardError.Should().BeTrue();
        startInfo.RedirectStandardInput.Should().BeFalse();
        startInfo.StandardOutputEncoding.Should().Be(System.Text.Encoding.UTF8);
        startInfo.StandardErrorEncoding.Should().Be(System.Text.Encoding.UTF8);
    }

    [Theory]
    [InlineData(PurviewHostPlatform.Windows, true)]
    [InlineData(PurviewHostPlatform.Linux, false)]
    [InlineData(PurviewHostPlatform.MacOS, false)]
    [InlineData(PurviewHostPlatform.Other, false)]
    internal void PlatformSupport_AllowsOnlyWindows(
        PurviewHostPlatform platform,
        bool expectedSupport)
    {
        PurviewSensitiveInformationTypePlatformSupport
            .IsSupportedPlatform(platform)
            .Should()
            .Be(expectedSupport);
    }

    [Fact]
    public async Task UnsupportedPlatform_ReturnsBeforeResolvingOrStartingPowerShell()
    {
        var resolver = new FixedResolver("pwsh");
        var runner = new PurviewSensitiveInformationTypeRunner(
            new RepositoryLayout(Path.GetTempPath()),
            resolver,
            new FixedPlatformSupport(isSupported: false));

        var result = await runner.RunAsync(
            Guid.NewGuid(),
            "operator@contoso.example",
            TimeSpan.FromSeconds(1),
            CancellationToken.None);

        result.Status.Should().Be(PurviewSensitiveInformationTypeInvocationStatus.Unavailable);
        result.StandardOutput.Should().BeEmpty();
        resolver.Calls.Should().Be(0);
    }

    [Fact]
    public async Task MissingPowerShell_ReturnsSafeUnavailableStatusWithoutStartingProcess()
    {
        var runner = new PurviewSensitiveInformationTypeRunner(
            new RepositoryLayout(Path.GetTempPath()),
            new FixedResolver(null),
            new FixedPlatformSupport(isSupported: true));

        var result = await runner.RunAsync(
            Guid.NewGuid(),
            "operator@contoso.example",
            TimeSpan.FromSeconds(1),
            CancellationToken.None);

        result.Status.Should().Be(PurviewSensitiveInformationTypeInvocationStatus.Unavailable);
        result.StandardOutput.Should().BeEmpty();
    }

    [Fact]
    public async Task Timeout_KillsTheBoundedChildAndReturnsNoOutput()
    {
        var runner = CreateRunner("Start-Sleep -Seconds 30");

        var result = await runner.RunAsync(
            Guid.NewGuid(),
            "operator@contoso.example",
            TimeSpan.FromMilliseconds(100),
            CancellationToken.None);

        result.Status.Should().Be(PurviewSensitiveInformationTypeInvocationStatus.TimedOut);
        result.StandardOutput.Should().BeEmpty();
    }

    [Fact]
    public async Task CallerCancellation_KillsTheBoundedChildAndPropagatesCancellation()
    {
        var runner = CreateRunner("Start-Sleep -Seconds 30");
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));

        var action = () => runner.RunAsync(
            Guid.NewGuid(),
            "operator@contoso.example",
            TimeSpan.FromSeconds(10),
            cancellation.Token);

        await action.Should().ThrowAsync<OperationCanceledException>();
    }

    [Fact]
    public async Task StandardError_IsDrainedButNeverReturned()
    {
        const string sentinel = "provider-body-sentinel-must-not-render";
        var runner = CreateRunner($"[Console]::Error.Write('{sentinel}'); exit 9");

        var result = await runner.RunAsync(
            Guid.NewGuid(),
            "operator@contoso.example",
            TimeSpan.FromSeconds(5),
            CancellationToken.None);

        result.Status.Should().Be(PurviewSensitiveInformationTypeInvocationStatus.Completed);
        result.ExitCode.Should().Be(9);
        result.StandardOutput.Should().BeEmpty();
        result.StandardOutput.Should().NotContain(sentinel);
    }

    [Fact]
    public async Task OversizedStandardOutput_IsDrainedAndRejectedWithoutReturningContent()
    {
        var runner = CreateRunner("[Console]::Out.Write('x' * 2097153)");

        var result = await runner.RunAsync(
            Guid.NewGuid(),
            "operator@contoso.example",
            TimeSpan.FromSeconds(10),
            CancellationToken.None);

        result.Status.Should().Be(PurviewSensitiveInformationTypeInvocationStatus.OutputRejected);
        result.StandardOutput.Should().BeEmpty();
    }

    private PurviewSensitiveInformationTypeRunner CreateRunner(string body)
    {
        var bootstrap = Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var scriptPath = Path.Combine(
            bootstrap.FullName,
            "get-purview-sensitive-information-types.ps1");
        File.WriteAllText(
            scriptPath,
            $"param([guid]$TenantId, [string]$UserPrincipalName){Environment.NewLine}{body}");
        return new PurviewSensitiveInformationTypeRunner(
            new RepositoryLayout(root),
            new FixedResolver("pwsh"),
            new FixedPlatformSupport(isSupported: true));
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private sealed class FixedResolver(string? executable) : IPurviewPowerShellExecutableResolver
    {
        public int Calls { get; private set; }

        public string? Resolve()
        {
            Calls++;
            return executable;
        }
    }

    private sealed class FixedPlatformSupport(bool isSupported)
        : IPurviewSensitiveInformationTypePlatformSupport
    {
        public bool IsSupported => isSupported;
    }
}
