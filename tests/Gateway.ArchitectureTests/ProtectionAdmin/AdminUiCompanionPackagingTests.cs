using System.Diagnostics;
using System.Xml.Linq;
using FluentAssertions;

namespace Gateway.ArchitectureTests.ProtectionAdmin;

public sealed class AdminUiCompanionPackagingTests
{
    private const string CompanionName = "Connect-PurviewTenant.ps1";
    private static readonly string RepositoryRoot = FindRepositoryRoot();

    [Fact]
    public void AdminUiProject_LinksTheSingleCanonicalCompanionIntoStaticDownloads()
    {
        var projectPath = Path.Combine(
            RepositoryRoot,
            "src",
            "Gateway.AdminUi",
            "Gateway.AdminUi.csproj");
        var document = XDocument.Load(projectPath);
        var companionItems = document
            .Descendants("Content")
            .Where(element => string.Equals(
                NormalizePath(element.Attribute("Include")?.Value),
                "../Gateway.Purview/Automation/Connect-PurviewTenant.ps1",
                StringComparison.Ordinal))
            .ToArray();

        var item = companionItems.Should().ContainSingle().Subject;
        NormalizePath(item.Attribute("Link")?.Value).Should().Be(
            "wwwroot/downloads/Connect-PurviewTenant.ps1");
        item.Attribute("CopyToOutputDirectory")?.Value.Should().Be(
            "PreserveNewest");
        item.Attribute("CopyToPublishDirectory")?.Value.Should().Be(
            "PreserveNewest");

        Directory.GetFiles(
                Path.Combine(
                    RepositoryRoot,
                    "src",
                    "Gateway.AdminUi",
                    "wwwroot"),
                CompanionName,
                SearchOption.AllDirectories)
            .Should().BeEmpty(
                "the provider-owned script must remain the single source");
    }

    [Fact]
    public void AdminUiDockerfile_CopiesTheCanonicalSourceBeforePublishAndVerifiesIt()
    {
        var dockerfile = File.ReadAllText(Path.Combine(
            RepositoryRoot,
            "src",
            "Gateway.AdminUi",
            "Dockerfile"));
        const string copy =
            "COPY [\"src/Gateway.Purview/Automation/Connect-PurviewTenant.ps1\", \"src/Gateway.Purview/Automation/\"]";
        const string publish = "RUN dotnet publish \"Gateway.AdminUi.csproj\"";
        const string verification =
            "test -s /app/publish/wwwroot/downloads/Connect-PurviewTenant.ps1";

        dockerfile.Should().Contain(copy);
        dockerfile.IndexOf(copy, StringComparison.Ordinal).Should().BeLessThan(
            dockerfile.IndexOf(publish, StringComparison.Ordinal));
        dockerfile.Should().Contain(verification);
    }

    [Fact]
    public async Task ReleasePublish_ContainsTheExactCanonicalCompanionBytes()
    {
        var publishDirectory = Path.Combine(
            Path.GetTempPath(),
            $"a365-admin-companion-{Guid.NewGuid():N}");
        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = "dotnet",
                WorkingDirectory = RepositoryRoot,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false
            };
            startInfo.ArgumentList.Add("publish");
            startInfo.ArgumentList.Add(
                "src/Gateway.AdminUi/Gateway.AdminUi.csproj");
            startInfo.ArgumentList.Add("--configuration");
            startInfo.ArgumentList.Add("Release");
            startInfo.ArgumentList.Add("--no-restore");
            startInfo.ArgumentList.Add("--no-build");
            startInfo.ArgumentList.Add("--output");
            startInfo.ArgumentList.Add(publishDirectory);
            startInfo.ArgumentList.Add("-p:UseAppHost=false");

            using var process = Process.Start(startInfo)
                ?? throw new InvalidOperationException(
                    "The Admin UI publish process did not start.");
            var standardOutput = process.StandardOutput.ReadToEndAsync();
            var standardError = process.StandardError.ReadToEndAsync();
            using var timeout = new CancellationTokenSource(
                TimeSpan.FromMinutes(2));
            await process.WaitForExitAsync(timeout.Token);
            var output = await standardOutput;
            var error = await standardError;
            process.ExitCode.Should().Be(
                0,
                $"Admin UI publish must succeed. {Bound(error)} {Bound(output)}");

            var sourcePath = Path.Combine(
                RepositoryRoot,
                "src",
                "Gateway.Purview",
                "Automation",
                CompanionName);
            var publishedPath = Path.Combine(
                publishDirectory,
                "wwwroot",
                "downloads",
                CompanionName);
            File.Exists(publishedPath).Should().BeTrue();
            File.ReadAllBytes(publishedPath).Should().Equal(
                File.ReadAllBytes(sourcePath));
        }
        finally
        {
            if (Directory.Exists(publishDirectory))
            {
                Directory.Delete(publishDirectory, recursive: true);
            }
        }
    }

    private static string NormalizePath(string? value) =>
        (value ?? string.Empty).Replace('\\', '/');

    private static string Bound(string value) =>
        value.Length <= 2_000 ? value : value[^2_000..];

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null &&
               !File.Exists(Path.Combine(directory.FullName, "AGENTS.md")))
        {
            directory = directory.Parent;
        }

        return directory?.FullName
            ?? throw new DirectoryNotFoundException("Repository root not found.");
    }
}
