using FluentAssertions;
using Gateway.Setup.Models;
using Gateway.Setup.Services;

namespace Gateway.Setup.Tests.Services;

public sealed class BootstrapConfigLoaderTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"gateway-setup-loader-{Guid.NewGuid():N}");

    [Fact]
    public async Task LoadAsync_ImportsOnlySupportedPublicConfiguration()
    {
        var expected = ValidForm();
        await WriteValidAsync(expected);

        var result = await NewLoader().LoadAsync();

        result.Status.Should().Be(ExistingConfigurationStatus.Loaded);
        result.Guidance.Should().BeNull();
        result.Form.Should().NotBeNull();
        result.Form!.SubscriptionId.Should().Be(expected.SubscriptionId);
        result.Form.TenantId.Should().Be(expected.TenantId);
        result.Form.ProjectName.Should().Be(expected.ProjectName);
        result.Form.SeedBlueprintName.Should().Be(expected.SeedBlueprintName);
        result.Form.ReviewedManagerApplicationIds.Should().Be(expected.ReviewedManagerApplicationIds);
        result.Form.PromptShieldSkuName.Should().Be("F0");
        result.Form.PurviewCollectionPolicyName.Should().Be(expected.PurviewCollectionPolicyName);
        result.Form.PurviewDlpPolicyName.Should().Be(expected.PurviewDlpPolicyName);
        result.Form.PurviewDlpRuleName.Should().Be(expected.PurviewDlpRuleName);

        var rewrite = () => new BootstrapConfigWriter(
            new RepositoryLayout(root),
            new AtomicFileWriter()).WriteAsync(result.Form);
        await rewrite.Should().NotThrowAsync(
            "a safely imported configuration must be semantically preserved during explicit review");
    }

    [Fact]
    public async Task LoadAsync_RejectsUnknownPropertiesWithoutOverwriting()
    {
        await WriteValidAsync(ValidForm());
        var path = Path.Combine(root, "bootstrap", "config.json");
        var json = await File.ReadAllTextAsync(path);
        await File.WriteAllTextAsync(path, json.Replace("{", "{\"unknown\":\"value\",", StringComparison.Ordinal));

        var result = await NewLoader().LoadAsync();

        result.Status.Should().Be(ExistingConfigurationStatus.Rejected);
        result.Form.Should().BeNull();
        (await File.ReadAllTextAsync(path)).Should().Contain("unknown");
    }

    [Fact]
    public async Task LoadAsync_RejectsCredentialLikeValues()
    {
        await WriteValidAsync(ValidForm());
        var path = Path.Combine(root, "bootstrap", "config.json");
        var json = await File.ReadAllTextAsync(path);
        await File.WriteAllTextAsync(path, json.Replace(
            "A365 Gateway Seed dev",
            "Bearer eyJaaaaaaaaaaa.bbbbbbbbbbb.cccccccc",
            StringComparison.Ordinal));

        var result = await NewLoader().LoadAsync();

        result.Status.Should().Be(ExistingConfigurationStatus.Rejected);
        result.Guidance.Should().NotBeNullOrWhiteSpace();
    }

    [Fact]
    public async Task LoadAsync_RejectsAdvancedConfigurationThatWizardCannotPreserve()
    {
        await WriteValidAsync(ValidForm());
        var path = Path.Combine(root, "bootstrap", "config.json");
        var json = await File.ReadAllTextAsync(path);
        await File.WriteAllTextAsync(path, json.Replace(
            "\"policyProvisioningEnabled\": false",
            "\"policyProvisioningEnabled\": true",
            StringComparison.Ordinal));

        var result = await NewLoader().LoadAsync();

        result.Status.Should().Be(ExistingConfigurationStatus.Rejected);
        result.Form.Should().BeNull();
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

    [Fact]
    public void WizardState_FailsClosedWhenImportedSubscriptionIsUnavailable()
    {
        var state = new SetupWizardState(new FixedProjectNameGenerator());
        state.ApplyExistingConfiguration(new ExistingConfigurationResult(
            ExistingConfigurationStatus.Loaded,
            ValidForm(),
            null));

        state.SetSubscriptions([
            new AzureSubscription(Guid.NewGuid(), Guid.NewGuid(), "Other", true, "Enabled")
        ]);

        state.AccountSelectionIssue.Should().Contain("not available");
    }

    private BootstrapConfigLoader NewLoader() => new(new RepositoryLayout(root));

    private async Task WriteValidAsync(SetupConfigurationForm form)
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var writer = new BootstrapConfigWriter(
            new RepositoryLayout(root),
            new AtomicFileWriter());
        await writer.WriteAsync(form);
    }

    private static SetupConfigurationForm ValidForm() => new()
    {
        Profile = DeploymentProfile.QuickDevelopment,
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
        PromptShieldEnabled = false,
        PromptShieldSkuName = "F0",
        PurviewEnabled = false,
        PurviewSensitiveInformationType = string.Empty,
        PurviewCollectionPolicyName = "Existing collection name",
        PurviewDlpPolicyName = "Existing DLP policy name",
        PurviewDlpRuleName = "Existing DLP rule name"
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
