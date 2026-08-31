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
    public async Task WriteAsync_AtomicallyReplacesOnlyIgnoredPublicConfiguration()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var target = Path.Combine(root, "bootstrap", "config.json");
        var form = ValidForm();
        await File.WriteAllTextAsync(
            target,
            BootstrapConfigWriter.SerializeForTest(BootstrapConfiguration.From(form)));
        var writer = NewWriter();

        var result = await writer.WriteAsync(form);

        result.Path.Should().Be(target);
        Directory.GetFiles(root, "*", SearchOption.AllDirectories)
            .Should().Equal(target);
        var json = await File.ReadAllTextAsync(target);
        json.Should().NotContain("Bearer ");
        json.Contains("client_secret", StringComparison.OrdinalIgnoreCase).Should().BeFalse();
        using var document = JsonDocument.Parse(json);
        document.RootElement.GetProperty("subscriptionId").GetGuid().Should().NotBe(Guid.Empty);
        document.RootElement.GetProperty("tenantId").GetGuid().Should().NotBe(Guid.Empty);
        document.RootElement.GetProperty("agent365")
            .GetProperty("reviewedManagerApplicationIds")[0]
            .GetGuid()
            .Should().Be(Guid.Parse("33333333-3333-4333-8333-333333333333"));
        document.RootElement.GetProperty("purview")
            .GetProperty("policyProvisioningCertificateSecretUri")
            .GetString()
            .Should().BeEmpty();
        document.RootElement.GetProperty("purview")
            .GetProperty("collectionPolicyName")
            .GetString()
            .Should().Be("A365 Gateway a365gw AI collection");
    }

    [Fact]
    public async Task WriteAsync_RejectsAResourceGroupEndingInAPeriod()
    {
        var form = ValidForm();
        form.ResourceGroupName = "rg-invalid.";

        var action = () => NewWriter().WriteAsync(form);

        await action.Should().ThrowAsync<ValidationException>();
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
        form.PurviewEnabled = true;
        form.PurviewSensitiveInformationType = "Credit Card Number";

        var result = await NewWriter().WriteAsync(form);

        result.Configuration.Agent365.ReviewedManagerApplicationIds.Should().Equal(
            Guid.Parse("33333333-3333-4333-8333-333333333333"),
            Guid.Parse("44444444-4444-4444-8444-444444444444"));
        result.Configuration.Purview.SensitiveInformationType.Should().Be("Credit Card Number");
    }

    [Fact]
    public async Task WriteAsync_RejectsCredentialLikeContentBeforeReplacingExistingFile()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var target = Path.Combine(root, "bootstrap", "config.json");
        await File.WriteAllTextAsync(target, "preserve-me");
        var form = ValidForm();
        form.PurviewEnabled = true;
        form.PurviewSensitiveInformationType = "Bearer eyJaaaaaaaaaaa.bbbbbbbbbbb.cccccccc";

        var action = () => NewWriter().WriteAsync(form);

        await action.Should().ThrowAsync<ValidationException>();
        (await File.ReadAllTextAsync(target)).Should().Be("preserve-me");
        Directory.GetFiles(Path.Combine(root, "bootstrap"), "*.tmp")
            .Should().BeEmpty();
    }

    [Fact]
    public async Task WriteAsync_RefusesToOverwriteAConfigurationThatChangedAfterReview()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var target = Path.Combine(root, "bootstrap", "config.json");
        var existing = ValidForm();
        existing.ProjectName = "gwfirst";
        existing.ResourceGroupName = "rg-gwfirst-dev";
        var existingJson = BootstrapConfigWriter.SerializeForTest(BootstrapConfiguration.From(existing));
        await File.WriteAllTextAsync(target, existingJson);

        var action = () => NewWriter().WriteAsync(ValidForm());

        await action.Should().ThrowAsync<ExistingConfigurationChangedException>();
        (await File.ReadAllTextAsync(target)).Should().Be(existingJson);
    }

    [Fact]
    public async Task AtomicWriter_CancellationPreservesExistingTargetAndRemovesTemporaryFile()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var target = Path.Combine(root, "bootstrap", "config.json");
        await File.WriteAllTextAsync(target, "preserve-me");
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var action = () => new AtomicFileWriter().WriteUtf8Async(target, "replacement", cancellation.Token);

        await action.Should().ThrowAsync<OperationCanceledException>();
        (await File.ReadAllTextAsync(target)).Should().Be("preserve-me");
        Directory.GetFiles(Path.Combine(root, "bootstrap"), "*.tmp")
            .Should().BeEmpty();
    }

    private BootstrapConfigWriter NewWriter() => new(
        new RepositoryLayout(root),
        new AtomicFileWriter());

    private static SetupConfigurationForm ValidForm() => new()
    {
        Profile = DeploymentProfile.QuickDevelopment,
        SubscriptionId = Guid.NewGuid(),
        TenantId = Guid.NewGuid(),
        Environment = "dev",
        Location = "eastus2",
        ProjectName = "a365gw",
        ResourceGroupName = "rg-a365gw-dev",
        AlertEmail = "operator@example.com",
        AllowDevelopmentRegistryPreview = false,
        ReviewedManagerApplicationIds = "33333333-3333-4333-8333-333333333333",
        PromptShieldEnabled = false,
        PromptShieldSkuName = "F0",
        PurviewEnabled = false,
        PurviewSensitiveInformationType = string.Empty
    };

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
