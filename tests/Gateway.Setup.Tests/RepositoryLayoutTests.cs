using FluentAssertions;

namespace Gateway.Setup.Tests;

public sealed class RepositoryLayoutTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"gateway-setup-layout-{Guid.NewGuid():N}");

    [Fact]
    public void Resolve_AcceptsCompletePublicCheckoutWithoutLocalDevelopmentFiles()
    {
        WritePublicCheckoutMarkers();
        var normalizedWindowsLauncherRoot = Path.Combine(root, ".");

        var result = RepositoryLayout.Resolve(normalizedWindowsLauncherRoot);

        result.RootPath.Should().Be(Path.GetFullPath(root));
    }

    [Fact]
    public void Resolve_SearchesParentsFromARepositorySubdirectory()
    {
        WritePublicCheckoutMarkers();
        var child = Directory.CreateDirectory(Path.Combine(root, "tools", "Gateway.Setup"));

        var result = RepositoryLayout.Resolve(child.FullName);

        result.RootPath.Should().Be(Path.GetFullPath(root));
    }

    [Fact]
    public void Resolve_RejectsCheckoutMissingEitherPublicMarker()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        File.WriteAllText(Path.Combine(root, "bootstrap", "bootstrap.ps1"), string.Empty);

        var act = () => RepositoryLayout.Resolve(root);

        act.Should().Throw<InvalidOperationException>()
            .WithMessage("*complete A365 Custom Gateway repository checkout*");
    }

    [Fact]
    public void RegionUx_RemainsASelectWithFriendlyAndCanonicalValues()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "tools",
            "Gateway.Setup",
            "Components",
            "Pages",
            "ProfileFeatures.razor"));

        source.Should().Contain("<select id=\"location\"");
        source.Should().Contain("value=\"@location.Name\"");
        source.Should().Contain("@location.DisplayName · @location.Name");
        source.Should().NotContain("<InputText id=\"location\"");
    }

    [Fact]
    public void PurviewUx_RemainsANativeNoDefaultTenantInventorySelect()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "tools",
            "Gateway.Setup",
            "Components",
            "Pages",
            "ProfileFeatures.razor"));

        source.Should().Contain("<select id=\"purview-classifier\"");
        source.Should().Contain("value=\"@type.Id.ToString(\"D\")\"");
        source.Should().Contain("@type.Name · @type.Id");
        source.Should().Contain("Load tenant types");
        source.Should().Contain("Retry tenant type discovery");
        source.Should().Contain("!PurviewDiscovery.IsSupported");
        source.Should().Contain("PurviewDiscovery.UnsupportedGuidance");
        source.Should().Contain("Purview setup requires Windows");
        source.Should().NotContain("<InputText id=\"purview-classifier\"");
        source.Should().NotContain("@bind-Value=\"State.Form.PurviewSensitiveInformationType\"");
    }

    [Fact]
    public void SetupWizardState_RemainsCircuitScoped()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "tools",
            "Gateway.Setup",
            "Services",
            "SetupServiceCollectionExtensions.cs"));

        source.Should().Contain("AddScoped<SetupWizardState>()");
        source.Should().NotContain("AddSingleton<SetupWizardState>()");
        source.Should().Contain("AddSingleton<IPurviewSensitiveInformationTypeDiscovery,");
        source.Should().Contain("AddSingleton<IPurviewSensitiveInformationTypeRunner,");
        source.Should().Contain("AddSingleton<IPurviewSensitiveInformationTypePlatformSupport,");
    }

    [Fact]
    public void SetupRoutes_OwnOneInteractiveServerCircuitAcrossPages()
    {
        var appSource = File.ReadAllText(FindRepositoryFile(
            "tools",
            "Gateway.Setup",
            "Components",
            "App.razor"));

        appSource.Should().Contain("<HeadOutlet @rendermode=\"InteractiveServer\" />");
        appSource.Should().Contain("<Routes @rendermode=\"InteractiveServer\" />");
        appSource.Split(
                "<Routes @rendermode=\"InteractiveServer\" />",
                StringSplitOptions.None)
            .Should().HaveCount(2, "the app must own exactly one interactive router");

        var pagesDirectory = Path.GetDirectoryName(FindRepositoryFile(
            "tools",
            "Gateway.Setup",
            "Components",
            "Pages",
            "Welcome.razor"))!;

        foreach (var page in Directory.GetFiles(
                     pagesDirectory,
                     "*.razor",
                     SearchOption.AllDirectories))
        {
            File.ReadAllText(page).Should().NotContain(
                "@rendermode",
                $"{Path.GetFileName(page)} must share the router's circuit-scoped setup state");
        }
    }

    [Fact]
    public void FailedPlanRetry_ReturnsToReviewedPreparationInsteadOfStartingDirectly()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "tools",
            "Gateway.Setup",
            "Components",
            "Pages",
            "Progress.razor"));

        source.Should().Contain("Review and run Plan again");
        source.Should().Contain("Href=\"/setup/permissions\"");
        source.Should().NotContain("TryStart(BootstrapCommand.Plan");
        source.Should().NotContain("OnClick=\"RetryPlan\"");
    }

    private void WritePublicCheckoutMarkers()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        Directory.CreateDirectory(Path.Combine(root, "src"));
        File.WriteAllText(Path.Combine(root, "bootstrap", "bootstrap.ps1"), string.Empty);
        File.WriteAllText(Path.Combine(root, "src", "A365Gateway.slnx"), string.Empty);
    }

    private static string FindRepositoryFile(params string[] segments)
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory);
             directory is not null;
             directory = directory.Parent)
        {
            var candidate = Path.Combine([directory.FullName, .. segments]);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new FileNotFoundException("Could not locate the repository source file.");
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
