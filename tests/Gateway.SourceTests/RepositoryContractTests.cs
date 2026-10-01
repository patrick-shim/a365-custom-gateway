using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace Gateway.SourceTests;

public sealed class RepositoryContractTests
{
    [Fact]
    public void EverySolutionProjectAndProjectReferenceHasSource()
    {
        var solution = XDocument.Load(SourceTree.Resolve("src", "A365Gateway.slnx"));
        var projects = solution.Descendants("Project")
            .Select(project => project.Attribute("Path")?.Value).ToArray();
        Assert.NotEmpty(projects);
        foreach (var project in projects)
        {
            Assert.False(string.IsNullOrWhiteSpace(project));
            Assert.True(File.Exists(Path.GetFullPath(
                Path.Combine(SourceTree.Resolve("src"), project!))), $"Missing solution project: {project}");
        }

        foreach (var file in SourceTree.Files(".csproj"))
        {
            var project = XDocument.Load(file);
            Assert.Equal("net10.0", Assert.Single(project.Descendants("TargetFramework")).Value);
            foreach (var reference in project.Descendants("ProjectReference"))
            {
                var include = Assert.IsType<string>(reference.Attribute("Include")?.Value);
                Assert.DoesNotContain("$(", include);
                var resolved = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(file)!, include));
                Assert.True(File.Exists(resolved), $"Missing project reference in {Path.GetRelativePath(SourceTree.Root, file)}: {include}");
            }
            foreach (var item in project.Descendants("Compile").Where(item => item.Attribute("Link") is not null))
            {
                var include = Assert.IsType<string>(item.Attribute("Include")?.Value);
                var resolved = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(file)!, include));
                Assert.True(File.Exists(resolved), $"Missing linked source in {Path.GetRelativePath(SourceTree.Root, file)}: {include}");
            }
        }
    }

    [Fact]
    public void VersionAndPinnedSdkInputsAgree()
    {
        var props = XDocument.Load(SourceTree.Resolve("Directory.Build.props"));
        var prefix = Assert.Single(props.Descendants("VersionPrefix")).Value;
        var suffix = Assert.Single(props.Descendants("VersionSuffix")).Value;
        Assert.Equal($"{prefix}-{suffix}", File.ReadAllText(SourceTree.Resolve("VERSION")).Trim());

        using var global = JsonDocument.Parse(File.ReadAllText(SourceTree.Resolve("global.json")));
        var sdk = global.RootElement.GetProperty("sdk");
        Assert.Equal("10.0.400", sdk.GetProperty("version").GetString());
        Assert.Equal("latestPatch", sdk.GetProperty("rollForward").GetString());
        Assert.True(File.Exists(SourceTree.Resolve("nuget.config")));
    }

    [Fact]
    public void PublisherContainerUsesReviewedRootBuildInputsBeforeRestore()
    {
        var dockerfile = File.ReadAllText(SourceTree.Resolve("src", "Gateway.Purview.PackagePublisher", "Dockerfile"));
        var restore = dockerfile.IndexOf("RUN dotnet restore ", StringComparison.Ordinal);
        var workingDirectory = dockerfile.IndexOf("WORKDIR /source", StringComparison.Ordinal);
        Assert.True(workingDirectory >= 0 && restore > workingDirectory);
        foreach (var input in new[] { "global.json", "nuget.config", "Directory.Build.props" })
        {
            var copy = dockerfile.IndexOf($"COPY [\"{input}\", \"./\"]", StringComparison.Ordinal);
            Assert.True(copy > workingDirectory && copy < restore,
                $"Publisher restore must use the reviewed root input: {input}");
        }
        var restoreLine = Assert.Single(dockerfile.Split('\n'),
            line => line.StartsWith("RUN dotnet restore ", StringComparison.Ordinal));
        Assert.Contains("--configfile nuget.config", restoreLine);
    }

    [Fact]
    public void ApiHttpsForwardingIsWiredBeforeAuthorizationAndBoundToReviewedIngress()
    {
        var program = File.ReadAllText(SourceTree.Resolve("src", "Gateway.Api", "Program.cs"));
        var registration = program.IndexOf("builder.Services.AddGatewayIngress(", StringComparison.Ordinal);
        Assert.True(registration >= 0 && registration < program.IndexOf("var app = builder.Build()", StringComparison.Ordinal));
        Assert.Contains("context.Connection.RemoteIpAddress is not null", program);
        var forwarding = program.IndexOf("ingress => ingress.UseForwardedHeaders()", StringComparison.Ordinal);
        Assert.True(forwarding >= 0 && forwarding < program.IndexOf("app.UseAuthentication()", StringComparison.Ordinal));
        var module = File.ReadAllText(SourceTree.Resolve("infrastructure", "bicep", "modules", "container-app-api.bicep"));
        Assert.Contains("name: 'GatewayIngress__TrustedProxyNetworks__0'", module);
        Assert.Contains("value: '100.100.0.0/17'", module);
        Assert.Contains("allowInsecure: false", module);
        var readback = File.ReadAllText(SourceTree.Resolve("bootstrap", "modules", "Azure.psm1"));
        Assert.Contains("'GatewayIngress__TrustedProxyNetworks__0' = '100.100.0.0/17'", readback);
        var runtimeReadback = File.ReadAllText(SourceTree.Resolve("bootstrap", "modules", "Experience.psm1"));
        Assert.Contains("'GatewayIngress__TrustedProxyNetworks__0' = '100.100.0.0/17'", runtimeReadback);
        var verification = File.ReadAllText(SourceTree.Resolve("bootstrap", "modules", "Verification.psm1"));
        Assert.Contains("$apiIngress = Get-GatewayHttpsIngressEvidence", verification);
    }

    [Theory]
    [InlineData("tools/Gateway.Setup/Gateway.Setup.csproj")]
    [InlineData("tools/Gateway.DatabaseMigrator/Gateway.DatabaseMigrator.csproj")]
    [InlineData("tools/Gateway.LiveVerification/Gateway.LiveVerification.csproj")]
    [InlineData("tools/configure-workflow-v3-entra.ps1")]
    [InlineData("tools/_common.ps1")]
    [InlineData("tools/Test-BootstrapSource.ps1")]
    [InlineData("operations/test-provisioning-prerequisites.ps1")]
    public void RequiredLauncherAndPlanInputsExist(string relativePath) =>
        Assert.True(File.Exists(SourceTree.Resolve(relativePath.Split('/'))), $"Required authored input is absent: {relativePath}");

    [Fact]
    public void AuthoredMarkdownLinksResolveWithoutHistoricalFiles()
    {
        var checkedLinks = 0;
        foreach (var file in SourceTree.Files(".md"))
        {
            var markdown = File.ReadAllText(file);
            foreach (Match match in Regex.Matches(markdown, @"!?\[[^\]]*\]\((?<target><[^>]+>|[^)\s]+)(?:\s+""[^""]*"")?\)"))
            {
                var target = match.Groups["target"].Value.Trim('<', '>');
                if (target.StartsWith('#') || Regex.IsMatch(target, @"^[A-Za-z][A-Za-z0-9+.-]*:"))
                    continue;
                var path = Uri.UnescapeDataString(target.Split('#', 2)[0]);
                var resolved = Path.GetFullPath(Path.Combine(
                    Path.GetDirectoryName(file)!, path.Replace('/', Path.DirectorySeparatorChar)));
                Assert.True(Path.Exists(resolved),
                    $"Broken local link in {Path.GetRelativePath(SourceTree.Root, file)}: {target}");
                checkedLinks++;
            }
        }
        Assert.True(checkedLinks > 0, "No local documentation links were inspected.");
    }

    [Fact]
    public void SourceDeliveryIgnoresGeneratedAndOperationalDirectories()
    {
        var ignore = File.ReadAllText(SourceTree.Resolve(".gitignore"));
        foreach (var required in new[] { "**/bin/", "**/obj/", "TestResults/", "/.test-work/", "/.bootstrap/", "/.maintenance/", "/bootstrap/config.json" })
            Assert.Contains(required, ignore);
        var dockerIgnore = File.ReadAllText(SourceTree.Resolve(".dockerignore"));
        foreach (var required in new[] { ".git/", "**/bin/", "**/obj/", ".test-work/", ".bootstrap/", ".maintenance/", ".copilot-azure/", "bootstrap/config.json" })
            Assert.Contains(required, dockerIgnore);
    }

    [Fact]
    public void LocalBicepModuleAndParameterReferencesResolve()
    {
        var references = 0;
        foreach (var file in SourceTree.Files(".bicep").Concat(SourceTree.Files(".bicepparam")))
        {
            foreach (Match match in Regex.Matches(File.ReadAllText(file), @"(?m)^\s*(?:module\s+\w+\s+|using\s+)'(?<path>[^']+)'"))
            {
                var path = match.Groups["path"].Value;
                Assert.DoesNotContain(":", path);
                Assert.True(File.Exists(Path.GetFullPath(Path.Combine(
                    Path.GetDirectoryName(file)!, path.Replace('/', Path.DirectorySeparatorChar)))),
                    $"Missing local Bicep reference in {Path.GetRelativePath(SourceTree.Root, file)}: {path}");
                references++;
            }
        }
        Assert.True(references > 0, "No local Bicep module or parameter references were inspected.");
    }

    [Theory]
    [InlineData("Gateway.Api", "ConnectionStrings", "GatewayDb")]
    [InlineData("Gateway.Api", "EntraId", "TenantId")]
    [InlineData("Gateway.Api", "EntraId", "ClientId")]
    [InlineData("Gateway.Api", "ServiceBus", "FullyQualifiedNamespace")]
    [InlineData("Gateway.Api", "BlobStorage", "ConnectionString")]
    [InlineData("Gateway.Provisioning.Worker", "ConnectionStrings", "GatewayDb")]
    [InlineData("Gateway.Provisioning.Worker", "ServiceBus", "FullyQualifiedNamespace")]
    [InlineData("Gateway.Provisioning.Worker", "Agent365", "TenantId")]
    [InlineData("Gateway.AdminUi", "EntraId", "TenantId")]
    [InlineData("Gateway.AdminUi", "EntraId", "ClientId")]
    [InlineData("Gateway.AdminUi", "GatewayApi", "BaseUrl")]
    public void AuthoredHostDefaultsDoNotSupplyLiveAuthority(string project, string section, string key)
    {
        using var settings = JsonDocument.Parse(File.ReadAllText(SourceTree.Resolve("src", project, "appsettings.json")));
        Assert.Equal("", settings.RootElement.GetProperty(section).GetProperty(key).GetString());
    }
}
