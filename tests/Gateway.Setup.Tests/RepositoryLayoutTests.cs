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

    [Fact]
    public void StoppedDeploymentResume_RequiresAReadOnlyReviewBeforeASeparateConfirmation()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "tools",
            "Gateway.Setup",
            "Components",
            "Pages",
            "Progress.razor"));

        source.Should().Contain("TryStartResumeReview()");
        source.Should().Contain("Review the stopped deployment");
        source.Should().Contain("snapshot.ResumeAuthorizationReady");
        source.Should().Contain("resumeConfirmed");
        source.Should().Contain(".bootstrap");

        var reviewIndex = source.IndexOf("Review the stopped deployment", StringComparison.Ordinal);
        var authorizationGateIndex = source.IndexOf("snapshot.ResumeAuthorizationReady", StringComparison.Ordinal);
        var confirmedMutationIndex = source.IndexOf(
            "StartMutation(BootstrapCommand.Resume)",
            StringComparison.Ordinal);

        confirmedMutationIndex.Should().BePositive("a confirmed Resume must still be reachable");
        reviewIndex.Should().BeLessThan(
            authorizationGateIndex,
            "the read-only review is offered before any authorization exists");
        authorizationGateIndex.Should().BeLessThan(
            confirmedMutationIndex,
            "the confirmation is gated on the review-produced authorization");
        source[..authorizationGateIndex].Should().NotContain(
            "StartMutation(BootstrapCommand.Resume)",
            "a stopped deployment never offers direct Resume mutation");
    }

    [Fact]
    public void ResumeConsent_DescribesTheSameMutationBoundaryAsApplyAndClaimsNoAbsoluteSafety()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "tools",
            "Gateway.Setup",
            "Components",
            "Pages",
            "Progress.razor"));

        var authorizationGateIndex = source.IndexOf("snapshot.ResumeAuthorizationReady", StringComparison.Ordinal);
        var resumeConsent = source[authorizationGateIndex..];

        resumeConsent.Should().Contain(
            "I authorize Azure, Entra, Agent 365, SQL, and optional policy changes",
            "Resume continues the same deployment boundary Apply started");
        source.Should().NotContain(
            "mutates nothing",
            "the review still authenticates and reads Azure, so only the mutation boundary may be claimed");
        source.Should().Contain(
            "changes no Azure, Entra, Agent 365, SQL, or policy resource",
            "the read-only review states the exact boundary it preserves");
    }

    [Fact]
    public void RestartedSetupProcess_CanReachProgressFromTheLoadedConfiguration()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "tools",
            "Gateway.Setup",
            "Components",
            "Pages",
            "Welcome.razor"));

        source.Should().Contain("State.ExistingConfigurationLoaded");
        source.Should().Contain("/setup/progress");
    }

    private void WritePublicCheckoutMarkers()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        Directory.CreateDirectory(Path.Combine(root, "src"));
        File.WriteAllText(Path.Combine(root, "bootstrap", "bootstrap.ps1"), string.Empty);
        File.WriteAllText(Path.Combine(root, "src", "A365Gateway.slnx"), string.Empty);
    }

    [Fact]
    public void StageIndicator_AnimatesTheNewestStageWhileRunningAndMarksItStoppedOtherwise()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "tools",
            "Gateway.Setup",
            "Components",
            "Pages",
            "Progress.razor"));

        source.Should().Contain("StageStateClass(isLast)");
        source.Should().Contain("snapshot.IsRunning");
        source.Should().Contain("\"active\"");
        source.Should().Contain("\"stopped\"");
        source.Should().Contain("class=\"run-spinner\"");
        source.Should().Contain("aria-label=\"Working\"");

        var activeIndex = source.IndexOf("return \"active\";", StringComparison.Ordinal);
        var stoppedIndex = source.IndexOf("? \"stopped\"", StringComparison.Ordinal);
        activeIndex.Should().BePositive("a live run marks its newest stage as working");
        stoppedIndex.Should().BePositive("a run that ended without succeeding marks where it stopped");
        activeIndex.Should().BeLessThan(
            stoppedIndex,
            "a running snapshot is never rendered as stopped");
    }

    [Fact]
    public void StageIndicator_KeepsAStaticCueWhenMotionIsReduced()
    {
        var css = File.ReadAllText(FindRepositoryFile(
            "tools",
            "Gateway.Setup",
            "wwwroot",
            "app.css"));

        css.Should().Contain("@keyframes event-spin");
        css.Should().Contain("@keyframes event-pulse");
        css.Should().Contain(".event-item.active .event-dot");
        css.Should().Contain(".event-item.stopped .event-dot");

        var reducedMotionIndex = css.IndexOf(
            "@media (prefers-reduced-motion: reduce)",
            StringComparison.Ordinal);
        reducedMotionIndex.Should().BePositive();
        var reducedMotion = css[reducedMotionIndex..];
        reducedMotion.Should().Contain(
            ".event-item.active .event-dot",
            "the working cue survives the reduced-motion animation reset");
        reducedMotion.Should().Contain(
            ".event-item.stopped .event-dot",
            "the stopped cue survives the reduced-motion animation reset");
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
