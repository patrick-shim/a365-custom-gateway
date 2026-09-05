using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using FluentAssertions;
using Gateway.Setup.Models;
using Gateway.Setup.Services;

namespace Gateway.Setup.Tests.Services;

public sealed class BootstrapConfigWriterTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"gateway-setup-config-{Guid.NewGuid():N}");

    [Fact]
    public async Task WriteAsync_AtomicallyPublishesCapabilityOnlyConfiguration()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var form = ValidForm();
        var writer = NewWriter();

        using var staged = await writer.StageAsync(
            ReadyState(form).CreatePlanReadyConfiguration());

        var result = staged.TryPublish();
        result.Should().NotBeNull();
        var json = await File.ReadAllTextAsync(result!.Path);
        using var document = JsonDocument.Parse(json);
        var configuration = document.RootElement;
        var purview = configuration.GetProperty("purview");

        configuration.GetProperty("capabilityPreset").GetString().Should().Be("custom");
        configuration.GetProperty("agent365")
            .GetProperty("registryBetaAcknowledged").GetBoolean().Should().BeFalse();
        configuration.GetProperty("promptShield")
            .GetProperty("costAndQuotaAcknowledged").GetBoolean().Should().BeFalse();
        purview.EnumerateObject().Select(property => property.Name)
            .Should().Equal("enabled", "authorityRequirementsAcknowledged");
        json.Should().NotContain("sensitiveInformationType");
        json.Should().NotContain("collectionPolicyName");
        json.Should().NotContain("dlpPolicyName");
        json.Should().NotContain("dlpRuleName");
        PlanFingerprintPolicy.IsCanonical(result.ConfigurationFileFingerprint).Should().BeTrue();
        Directory.GetFiles(root, "*", SearchOption.AllDirectories).Should().Equal(result.Path);
    }

    [Fact]
    public void SerializeForTest_UsesOnlyPropertiesDeclaredByBootstrapSchema()
    {
        using var configuration = JsonDocument.Parse(
            BootstrapConfigWriter.SerializeForTest(BootstrapConfiguration.From(ValidForm())));
        using var schema = JsonDocument.Parse(File.ReadAllText(FindRepositoryFile(
            "bootstrap",
            "config.schema.json")));

        AssertOnlyDeclaredProperties(configuration.RootElement, schema.RootElement);
    }

    [Fact]
    public async Task WriteAsync_AcceptsMultipleReviewedManagerApplicationIds()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var form = ValidForm();
        form.SetReviewedManagerApplicationIds(
        [
            Guid.Parse("33333333-3333-4333-8333-333333333333"),
            Guid.Parse("44444444-4444-4444-8444-444444444444")
        ]);

        var result = await StageAndPublishAsync(NewWriter(), ReadyState(form));

        result.Configuration.Agent365.ReviewedManagerApplicationIds.Should().Equal(
            Guid.Parse("33333333-3333-4333-8333-333333333333"),
            Guid.Parse("44444444-4444-4444-8444-444444444444"));
    }

    [Fact]
    public async Task WriteAsync_RejectsAResourceGroupEndingInAPeriod()
    {
        var form = ValidForm();
        form.ResourceGroupName = "rg-invalid.";

        var action = () => NewWriter().StageAsync(
            ReadyState(form).CreatePlanReadyConfiguration());

        await action.Should().ThrowAsync<ValidationException>();
    }

    [Fact]
    public async Task WriteAsync_RefusesToOverwriteAConfigurationThatChangedAfterReview()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var target = Path.Combine(root, "bootstrap", "config.json");
        var existing = ValidForm();
        existing.ProjectName = "gwfirst";
        existing.ResourceGroupName = "rg-gwfirst-dev";
        var existingJson = BootstrapConfigWriter.SerializeForTest(
            BootstrapConfiguration.From(existing));
        await File.WriteAllTextAsync(target, existingJson);

        var action = () => NewWriter().StageAsync(
            ReadyState(ValidForm()).CreatePlanReadyConfiguration());

        await action.Should().ThrowAsync<ExistingConfigurationChangedException>();
        (await File.ReadAllTextAsync(target)).Should().Be(existingJson);
    }

    [Fact]
    public async Task WriteAsync_RejectsStaleReadinessProofs()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var state = ReadyState(ValidForm());
        state.Form.ReviewedManagerApplicationIds = Guid.NewGuid().ToString("D");

        var action = () => NewWriter().StageAsync(state.CreatePlanReadyConfiguration());

        await action.Should().ThrowAsync<ValidationException>();
        File.Exists(Path.Combine(root, "bootstrap", "config.json")).Should().BeFalse();
    }

    [Fact]
    public async Task AtomicWriter_CancellationPreservesExistingTargetAndRemovesTemporaryFile()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var target = Path.Combine(root, "bootstrap", "config.json");
        await File.WriteAllTextAsync(target, "preserve-me");
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var action = () => new AtomicFileWriter().WriteUtf8Async(
            target,
            "replacement",
            cancellation.Token);

        await action.Should().ThrowAsync<OperationCanceledException>();
        (await File.ReadAllTextAsync(target)).Should().Be("preserve-me");
        Directory.GetFiles(Path.Combine(root, "bootstrap"), "*.tmp").Should().BeEmpty();
    }

    private BootstrapConfigWriter NewWriter() => new(
        new RepositoryLayout(root),
        new AtomicFileWriter());

    private static async Task<ConfigurationWriteResult> StageAndPublishAsync(
        BootstrapConfigWriter writer,
        SetupWizardState state)
    {
        using var staged = await writer.StageAsync(state.CreatePlanReadyConfiguration());
        return staged.TryPublish()
            ?? throw new InvalidOperationException("The deterministic test stage changed unexpectedly.");
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

    private static void AssertOnlyDeclaredProperties(JsonElement value, JsonElement schema)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            return;
        }

        schema.TryGetProperty("properties", out var declaredProperties).Should().BeTrue();
        foreach (var property in value.EnumerateObject())
        {
            declaredProperties.TryGetProperty(property.Name, out var propertySchema)
                .Should().BeTrue($"'{property.Name}' must be declared by bootstrap/config.schema.json");
            AssertOnlyDeclaredProperties(property.Value, propertySchema);
        }
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

        throw new FileNotFoundException("Could not locate a repository file for the schema contract test.");
    }

    private static SetupConfigurationForm ValidForm() => new()
    {
        Profile = DeploymentProfile.QuickDevelopment,
        CapabilityPreset = CapabilityPreset.Custom,
        SubscriptionId = Guid.NewGuid(),
        TenantId = Guid.NewGuid(),
        Environment = "dev",
        Location = "eastus2",
        ProjectName = "a365gw",
        ResourceGroupName = "rg-a365gw-dev",
        AlertEmail = "operator@example.com",
        SeedBlueprintName = "A365 Gateway Seed dev",
        AllowDevelopmentRegistryPreview = false,
        ReviewedManagerApplicationIds = "33333333-3333-4333-8333-333333333333",
        PromptShieldEnabled = false,
        PromptShieldSkuName = "F0",
        PurviewEnabled = false
    };

    private sealed class FixedProjectNameGenerator : IProjectNameGenerator
    {
        public string Create() => "gwfixed";
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
