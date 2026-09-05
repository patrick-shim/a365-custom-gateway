using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using FluentAssertions;
using Gateway.Setup.Models;
using Gateway.Setup.Services;

namespace Gateway.Setup.Tests.Services;

public sealed class CapabilitySelectionTests
{
    [Fact]
    public void NewQuickDevelopmentConfiguration_DefaultsToFullEvaluationWithoutImplicitAcknowledgement()
    {
        var form = ValidForm();

        form.Profile.Should().Be(DeploymentProfile.QuickDevelopment);
        form.CapabilityPreset.Should().Be(CapabilityPreset.FullEvaluation);
        form.AllowDevelopmentRegistryPreview.Should().BeTrue();
        form.PromptShieldEnabled.Should().BeTrue();
        form.PurviewEnabled.Should().BeTrue();
        form.RegistryBetaAcknowledged.Should().BeFalse();
        form.PromptShieldCostAndQuotaAcknowledged.Should().BeFalse();
        form.PurviewAuthorityRequirementsAcknowledged.Should().BeFalse();
    }

    [Fact]
    public void CoreGateway_KeepsDevelopmentRegistrationButOmitsOptionalProtectionDependencies()
    {
        var form = ValidForm();

        form.ApplyCapabilityPreset(CapabilityPreset.CoreGateway);

        form.AllowDevelopmentRegistryPreview.Should().BeTrue();
        form.PromptShieldEnabled.Should().BeFalse();
        form.PurviewEnabled.Should().BeFalse();
    }

    [Fact]
    public void StagingAndProductionMakeRegistryBetaImpossible()
    {
        foreach (var profile in new[]
                 {
                     DeploymentProfile.StagingFoundation,
                     DeploymentProfile.ProductionSafeFoundation
                 })
        {
            var form = ValidForm();
            form.ApplyProfile(profile);
            form.AllowDevelopmentRegistryPreview = true;
            form.RegistryBetaAcknowledged = true;

            var errors = Validate(form);

            errors.Should().Contain(error =>
                error.MemberNames.Contains(nameof(form.AllowDevelopmentRegistryPreview)) &&
                error.ErrorMessage!.Contains("cannot be enabled", StringComparison.Ordinal));
        }
    }

    [Fact]
    public void EnabledCapabilitiesRequireTheirOwnExplicitReviews()
    {
        var form = ValidForm();
        form.ApplyCapabilityPreset(CapabilityPreset.FullEvaluation);

        var errors = Validate(form);

        errors.Should().Contain(error =>
            error.MemberNames.Contains(nameof(form.RegistryBetaAcknowledged)));
        errors.Should().Contain(error =>
            error.MemberNames.Contains(nameof(form.PromptShieldCostAndQuotaAcknowledged)));
        errors.Should().Contain(error =>
            error.MemberNames.Contains(nameof(form.PurviewAuthorityRequirementsAcknowledged)));
    }

    [Fact]
    public void FreshConfigurationSerializesCapabilityAcknowledgementsAndNoPolicyOrSitChoice()
    {
        var form = ValidForm();
        form.RegistryBetaAcknowledged = true;
        form.PromptShieldCostAndQuotaAcknowledged = true;
        form.PurviewAuthorityRequirementsAcknowledged = true;

        using var document = JsonDocument.Parse(
            BootstrapConfigWriter.SerializeForTest(BootstrapConfiguration.From(form)));
        var root = document.RootElement;
        var purview = root.GetProperty("purview");

        root.GetProperty("capabilityPreset").GetString().Should().Be("fullEvaluation");
        root.GetProperty("agent365").GetProperty("registryBetaAcknowledged").GetBoolean()
            .Should().BeTrue();
        root.GetProperty("promptShield").GetProperty("costAndQuotaAcknowledged").GetBoolean()
            .Should().BeTrue();
        purview.GetProperty("authorityRequirementsAcknowledged").GetBoolean()
            .Should().BeTrue();
        purview.TryGetProperty("sensitiveInformationTypeId", out _).Should().BeFalse();
        purview.TryGetProperty("sensitiveInformationType", out _).Should().BeFalse();
        purview.TryGetProperty("collectionPolicyName", out _).Should().BeFalse();
        purview.TryGetProperty("dlpPolicyName", out _).Should().BeFalse();
        purview.TryGetProperty("dlpRuleName", out _).Should().BeFalse();
    }

    private static IReadOnlyList<ValidationResult> Validate(SetupConfigurationForm form)
    {
        var results = new List<ValidationResult>();
        Validator.TryValidateObject(
            form,
            new ValidationContext(form),
            results,
            validateAllProperties: true);
        return results;
    }

    private static SetupConfigurationForm ValidForm() => new()
    {
        SubscriptionId = Guid.NewGuid(),
        TenantId = Guid.NewGuid(),
        Location = "koreacentral",
        AlertEmail = "operator@example.com",
        ReviewedManagerApplicationIds = "33333333-3333-4333-8333-333333333333"
    };
}
