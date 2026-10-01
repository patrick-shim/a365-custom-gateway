using FluentAssertions;
using Gateway.Setup.Models;
using Gateway.Setup.Services;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Gateway.Setup.Tests.Services;

public sealed class BootstrapConfigLoaderTests : IDisposable
{
    private readonly string root = Path.Combine(
        AppContext.BaseDirectory,
        $"gateway-setup-loader-{Guid.NewGuid():N}");

    [Fact]
    public async Task LoadAsync_MissingConfigurationLeavesTheFixtureUntouched()
    {
        var result = await NewLoader().LoadAsync();

        result.Status.Should().Be(ExistingConfigurationStatus.Missing);
        result.Form.Should().BeNull();
        Directory.Exists(root).Should().BeFalse();
    }

    [Theory]
    [InlineData(0, 0, "F0")]
    [InlineData(0, 1, "S0")]
    [InlineData(0, 2, "F0")]
    [InlineData(1, 1, "F0")]
    [InlineData(2, 2, "S0")]
    public async Task WriteAndLoad_RoundTripsEverySupportedPublicFieldWithoutChangingThePublishedFile(
        int profileValue, int presetValue, string sku)
    {
        var form = ValidForm();
        form.ApplyProfile((DeploymentProfile)profileValue);
        form.ApplyCapabilityPreset((CapabilityPreset)presetValue);
        form.PromptShieldSkuName = sku;
        form.RegistryBetaAcknowledged = form.AllowDevelopmentRegistryPreview;
        form.PromptShieldCostAndQuotaAcknowledged = true;
        form.PurviewAuthorityRequirementsAcknowledged = form.PurviewEnabled;
        await WriteValidAsync(form);
        var path = Path.Combine(root, "bootstrap", "config.json");
        var before = await File.ReadAllBytesAsync(path);

        var result = await NewLoader().LoadAsync();

        result.Status.Should().Be(ExistingConfigurationStatus.Loaded);
        result.MigrationNotice.Should().BeNull();
        BootstrapConfigurationDocument.Serialize(BootstrapConfiguration.From(result.Form!))
            .Should().Be(BootstrapConfigurationDocument.Serialize(BootstrapConfiguration.From(form)));
        (await File.ReadAllBytesAsync(path)).Should().Equal(before);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    public async Task LoadAsync_LegacyDisabledPromptShieldsRemainUnchangedAndCannotAuthorizeNewPlan(int presetValue)
    {
        var legacy = ValidForm();
        legacy.CapabilityPreset = (CapabilityPreset)presetValue;
        legacy.PromptShieldEnabled = false;
        legacy.PromptShieldCostAndQuotaAcknowledged = false;
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var path = Path.Combine(root, "bootstrap", "config.json");
        var json = BootstrapConfigurationDocument.Serialize(BootstrapConfiguration.From(legacy));
        await File.WriteAllTextAsync(path, json);

        var result = await NewLoader().LoadAsync();
        var state = new SetupWizardState(new FixedProjectNameGenerator());
        state.ApplyExistingConfiguration(result);
        state.SetSubscriptions([
            new AzureSubscription(legacy.SubscriptionId, legacy.TenantId, "Offline legacy fixture", true, "Enabled")
        ]);
        state.ApplyLocationDiscovery(new AzureLocationDiscoveryResult(
            legacy.SubscriptionId, [new AzureLocation(legacy.Location, "Offline fixture region")], null));

        result.Status.Should().Be(ExistingConfigurationStatus.Loaded);
        result.Form!.PromptShieldEnabled.Should().BeFalse();
        result.MigrationNotice.Should().Contain("legacy deployment").And.Contain("without enabling or rewriting");
        state.HasEnabledSelectedSubscription.Should().BeTrue();
        state.HasValidSelectedLocation.Should().BeTrue();
        state.ManagerApplicationsAccepted.Should().BeTrue();
        state.CanWriteConfigurationAndRunPlan.Should().BeFalse();
        (await File.ReadAllTextAsync(path)).Should().Be(json);
    }

    [Fact]
    public async Task LoadAsync_ImportsCurrentCapabilityConfiguration()
    {
        var expected = ValidForm();
        await WriteValidAsync(expected);

        var result = await NewLoader().LoadAsync();

        result.Status.Should().Be(ExistingConfigurationStatus.Loaded);
        result.Guidance.Should().BeNull();
        result.MigrationNotice.Should().BeNull();
        result.Form.Should().NotBeNull();
        result.Form!.CapabilityPreset.Should().Be(CapabilityPreset.Custom);
        result.Form.SubscriptionId.Should().Be(expected.SubscriptionId);
        result.Form.TenantId.Should().Be(expected.TenantId);
        result.Form.ProjectName.Should().Be(expected.ProjectName);
        result.Form.ReviewedManagerApplicationIds.Should().Be(expected.ReviewedManagerApplicationIds);
        result.Form.PromptShieldSkuName.Should().Be("F0");
        result.Form.PurviewEnabled.Should().BeFalse();
    }

    [Fact]
    public async Task LoadAsync_AcceptsLegacyPurviewFieldsOnlyAsMigrationNotice()
    {
        var expected = ValidForm();
        expected.ApplyCapabilityPreset(CapabilityPreset.FullEvaluation);
        expected.RegistryBetaAcknowledged = true;
        expected.PromptShieldCostAndQuotaAcknowledged = true;
        expected.PurviewAuthorityRequirementsAcknowledged = true;
        await WriteValidAsync(expected);
        var path = Path.Combine(root, "bootstrap", "config.json");
        var rootNode = JsonNode.Parse(await File.ReadAllTextAsync(path))!.AsObject();
        rootNode.Remove("capabilityPreset");
        rootNode["agent365"]!.AsObject().Remove("registryBetaAcknowledged");
        rootNode["promptShield"]!.AsObject().Remove("costAndQuotaAcknowledged");
        var purview = rootNode["purview"]!.AsObject();
        purview.Remove("authorityRequirementsAcknowledged");
        purview["collectionPolicyName"] = "Legacy collection";
        purview["dlpPolicyName"] = "Legacy DLP";
        purview["dlpRuleName"] = "Legacy rule";
        purview["sensitiveInformationTypeId"] = "50842eb7-edc8-4019-85dd-5a5c1f2bb085";
        purview["sensitiveInformationType"] = "Legacy classifier";
        await File.WriteAllTextAsync(
            path,
            rootNode.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));

        var result = await NewLoader().LoadAsync();

        result.Status.Should().Be(ExistingConfigurationStatus.Loaded);
        result.MigrationNotice.Should().Contain("legacy Purview");
        result.MigrationNotice.Should().Contain("Gateway Settings");
        result.Form.Should().NotBeNull();
        result.Form!.CapabilityPreset.Should().Be(CapabilityPreset.FullEvaluation);
        result.Form.RegistryBetaAcknowledged.Should().BeTrue();
        result.Form.PromptShieldCostAndQuotaAcknowledged.Should().BeTrue();
        result.Form.PurviewEnabled.Should().BeTrue();
        result.Form.PurviewAuthorityRequirementsAcknowledged.Should().BeTrue();
        result.Form.GetType().GetProperty("PurviewSensitiveInformationType")
            .Should().BeNull("legacy SIT values must not enter the active form");
    }

    [Fact]
    public async Task LoadAsync_RejectsUnknownPropertiesWithoutOverwriting()
    {
        await WriteValidAsync(ValidForm());
        var path = Path.Combine(root, "bootstrap", "config.json");
        var json = await File.ReadAllTextAsync(path);
        await File.WriteAllTextAsync(
            path,
            json.Replace("{", "{\"unknown\":\"value\",", StringComparison.Ordinal));

        var result = await NewLoader().LoadAsync();

        result.Status.Should().Be(ExistingConfigurationStatus.Rejected);
        result.Form.Should().BeNull();
        (await File.ReadAllTextAsync(path)).Should().Contain("unknown");
    }

    [Fact]
    public async Task LoadAsync_RejectsOversizedConfigurationBeforeParsing()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        await File.WriteAllTextAsync(
            Path.Combine(root, "bootstrap", "config.json"),
            new string('x', 64 * 1024 + 1));

        var result = await NewLoader().LoadAsync();

        result.Status.Should().Be(ExistingConfigurationStatus.Rejected);
        result.Guidance.Should().Contain("64 KiB");
    }

    [Fact]
    public void WizardState_PreservesImportedExactSubscriptionDuringDiscovery()
    {
        var form = ValidForm();
        var state = new SetupWizardState(new FixedProjectNameGenerator());
        state.ApplyExistingConfiguration(new ExistingConfigurationResult(
            ExistingConfigurationStatus.Loaded,
            form,
            null));
        var another = new AzureSubscription(Guid.NewGuid(), Guid.NewGuid(), "Other", true, "Enabled");
        var exact = new AzureSubscription(form.SubscriptionId, form.TenantId, "Exact", false, "Enabled");

        state.SetSubscriptions([another, exact]);

        state.Form.SubscriptionId.Should().Be(exact.SubscriptionId);
        state.Form.TenantId.Should().Be(exact.TenantId);
        state.AccountSelectionIssue.Should().BeNull();
    }

    private BootstrapConfigLoader NewLoader() => new(new RepositoryLayout(root));

    private async Task WriteValidAsync(SetupConfigurationForm form)
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var writer = new BootstrapConfigWriter(
            new RepositoryLayout(root),
            new AtomicFileWriter());
        using var staged = await writer.StageAsync(ReadyState(form).CreatePlanReadyConfiguration());
        staged.TryPublish().Should().NotBeNull();
    }

    private static SetupWizardState ReadyState(SetupConfigurationForm form)
    {
        var state = new SetupWizardState(new FixedProjectNameGenerator());
        state.ApplyExistingConfiguration(new ExistingConfigurationResult(
            ExistingConfigurationStatus.Loaded,
            form,
            null));
        state.SetSubscriptions([
            new AzureSubscription(
                form.SubscriptionId,
                form.TenantId,
                "Selected target",
                true,
                "Enabled")
        ]);
        state.ApplyLocationDiscovery(new AzureLocationDiscoveryResult(
            form.SubscriptionId,
            [new AzureLocation(form.Location, "Selected region")],
            null));
        return state;
    }

    private static SetupConfigurationForm ValidForm() => new()
    {
        Profile = DeploymentProfile.QuickDevelopment,
        CapabilityPreset = CapabilityPreset.Custom,
        SubscriptionId = Guid.NewGuid(),
        TenantId = Guid.NewGuid(),
        Environment = "dev",
        Location = "eastus2",
        ProjectName = "gwabcde",
        ResourceGroupName = "rg-gwabcde-dev",
        AlertEmail = "operator@example.com",
        SeedBlueprintName = "A365 Gateway Seed dev",
        AllowDevelopmentRegistryPreview = false,
        ReviewedManagerApplicationIds = "33333333-3333-4333-8333-333333333333",
        PromptShieldEnabled = true,
        PromptShieldSkuName = "F0",
        PromptShieldCostAndQuotaAcknowledged = true,
        PurviewEnabled = false
    };

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private sealed class FixedProjectNameGenerator : IProjectNameGenerator
    {
        public string Create() => "gwfixed";
    }
}
