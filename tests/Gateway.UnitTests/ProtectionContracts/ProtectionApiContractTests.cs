using FluentAssertions;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Messages;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;

namespace Gateway.UnitTests.ProtectionContracts;

public sealed class ProtectionApiContractTests
{
    [Fact]
    public void ExistingRegistrationRequestShape_RemainsSourceCompatible()
    {
        var request = new RegisterAgentRequest(
            "external-agent",
            "Agent",
            null,
            Guid.NewGuid().ToString("D"),
            "Development",
            null,
            null,
            null);

        request.PurviewDlpProfile.Should().BeNull();
    }

    [Fact]
    public void ExistingFeatureRequestShape_RemainsSourceCompatible()
    {
        var features = new AgentFeaturesDto(
            "Agent365",
            true,
            "Enforce",
            true,
            false,
            true);
        var update = new UpdateFeaturesRequest(
            "Agent365",
            true,
            "Enforce",
            true,
            false,
            true);

        features.PurviewDlpProfile.Should().BeNull();
        features.PurviewEffectivelyEnabled.Should().BeFalse();
        update.PurviewDlpProfile.Should().BeNull();
        update.ExpectedRowVersion.Should().BeNull();
    }

    [Fact]
    public void ProtectionMutationConfirmation_RequiresReviewIdOneTimeTokenIdempotencyAndConcurrency()
    {
        var request = new ConfirmProtectionAdminOperationRequest(
            Guid.NewGuid(),
            "one-time-confirmation",
            Guid.NewGuid(),
            "row-version");

        request.ConfirmationTokenId.Should().NotBeEmpty();
        request.ConfirmationToken.Should().NotBeNullOrWhiteSpace();
        request.IdempotencyKey.Should().NotBeEmpty();
        request.ExpectedRowVersion.Should().NotBeNullOrWhiteSpace();
    }

    [Fact]
    public void ReviewResponse_DoesNotItselfContainAConfirmationToken()
    {
        typeof(ProtectionOperationReviewResponse)
            .GetProperties()
            .Select(property => property.Name)
            .Should().NotContain(nameof(ProtectionOperationConfirmationResponse.ConfirmationToken));

        typeof(ProtectionOperationConfirmationResponse)
            .GetProperties()
            .Select(property => property.Name)
            .Should().Contain(
                nameof(ProtectionOperationConfirmationResponse.ReviewTokenId),
                nameof(ProtectionOperationConfirmationResponse.ConfirmationTokenId),
                nameof(ProtectionOperationConfirmationResponse.ConfirmationToken));
    }

    [Fact]
    public void DlpProfileContract_BindsExactlyOneBlueprintApplication()
    {
        var blueprintApplicationId = Guid.NewGuid();
        var profile = new PurviewDlpProfileDto(
            Guid.NewGuid(),
            blueprintApplicationId,
            "Profile",
            Guid.NewGuid(),
            "Sensitive information type",
            "Enforce",
            ["UploadText"],
            [new PurviewDlpRuleActionDto("UploadText", "Block")],
            "Ready",
            new ProtectionReadinessDto(
                "Installed",
                "Ready",
                "Ready",
                "Ready",
                "Ready",
                true,
                [],
                DateTime.UtcNow),
            "policy-id",
            "rule-id",
            DateTime.UtcNow,
            "row-version");

        profile.BlueprintApplicationId.Should().Be(blueprintApplicationId);
        typeof(PurviewDlpProfileDto)
            .GetProperties()
            .Should().ContainSingle(property => property.Name == "BlueprintApplicationId");
        typeof(PurviewDlpProfileDto)
            .GetProperties()
            .Should().NotContain(property =>
                property.Name.Contains("BlueprintApplicationIds", StringComparison.Ordinal));
    }

    [Fact]
    public void KydAndDlpMutationContracts_CannotMergeTheirScopes()
    {
        var kydProperties = typeof(ReviewPurviewKnowYourDataOperationRequest)
            .GetProperties()
            .Select(property => property.Name);
        var dlpProperties = typeof(ReviewPurviewDlpProfileOperationRequest)
            .GetProperties()
            .Select(property => property.Name);

        kydProperties.Should().NotContain("BlueprintApplicationId");
        dlpProperties.Should().Contain("BlueprintApplicationId");
        dlpProperties.Should().NotContain("GroupId");
    }

    [Fact]
    public void ProtectionContracts_ExposeNoProviderOrContentSecrets()
    {
        var protectionContractTypes = typeof(ProtectionCapabilityDto).Assembly
            .GetTypes()
            .Where(type =>
                type.Namespace is "Gateway.Contracts.Dtos"
                    or "Gateway.Contracts.Requests"
                    or "Gateway.Contracts.Responses")
            .Where(type =>
                type.Name.StartsWith("Protection", StringComparison.Ordinal) ||
                type.Name.StartsWith("PurviewTenant", StringComparison.Ordinal) ||
                type.Name.StartsWith("PurviewSensitive", StringComparison.Ordinal) ||
                type.Name.StartsWith("PurviewKnowYourData", StringComparison.Ordinal) ||
                type.Name.StartsWith("PurviewDlp", StringComparison.Ordinal))
            .ToArray();

        string[] forbiddenPropertyNames =
        [
            "AccessToken",
            "RefreshToken",
            "IdentityToken",
            "Credential",
            "CertificateBytes",
            "Prompt",
            "ResponseBody",
            "ProviderBody"
        ];

        protectionContractTypes
            .SelectMany(type => type.GetProperties())
            .Select(property => property.Name)
            .Should().NotContain(name => forbiddenPropertyNames.Any(forbidden =>
                name.Contains(forbidden, StringComparison.OrdinalIgnoreCase)));
    }

    [Fact]
    public void ProtectionAdministrationMessage_UsesItsOwnVersionedQueueContract()
    {
        ProtectionAdminQueueContract.QueueName.Should().Be("gateway-protection-admin-v1");
        ProtectionAdminQueueContract.QueueName.Should().NotBe("gateway-provisioning-v3");
    }

    [Fact]
    public void ReadinessContract_KeepsAllEvidenceDimensionsIndependent()
    {
        var properties = typeof(ProtectionReadinessDto)
            .GetProperties()
            .Select(property => property.Name);

        properties.Should().Contain(
            nameof(ProtectionReadinessDto.Capability),
            nameof(ProtectionReadinessDto.Readback),
            nameof(ProtectionReadinessDto.Propagation),
            nameof(ProtectionReadinessDto.TokenRoles),
            nameof(ProtectionReadinessDto.RuntimeVerdict));
    }

    [Fact]
    public void CompanionContractUsesOffsetAwareLaunchAndEvidenceBindings()
    {
        typeof(PurviewTenantConnectionEvidenceDto)
            .GetProperty(nameof(PurviewTenantConnectionEvidenceDto.ObservedAtUtc))!
            .PropertyType.Should().Be(typeof(DateTimeOffset));
        typeof(PurviewTenantConnectionEvidenceDto)
            .GetProperty(nameof(PurviewTenantConnectionEvidenceDto.InventoryExpiresAtUtc))!
            .PropertyType.Should().Be(typeof(DateTimeOffset));
        typeof(ProtectionOperationAcceptedResponse)
            .GetProperty(nameof(ProtectionOperationAcceptedResponse.CompanionLaunch))
            .Should().NotBeNull();
        typeof(ReviewPurviewTenantConnectionCompletionRequest)
            .GetProperties()
            .Select(property => property.Name)
            .Should().Contain(
                nameof(ReviewPurviewTenantConnectionCompletionRequest.OperationId),
                nameof(ReviewPurviewTenantConnectionCompletionRequest.InventoryGenerationId),
                nameof(ReviewPurviewTenantConnectionCompletionRequest.EvidenceDigest),
                nameof(ReviewPurviewTenantConnectionCompletionRequest.Evidence),
                nameof(ReviewPurviewTenantConnectionCompletionRequest.ExpectedRowVersion));
    }

    [Fact]
    public void DlpActionReviewsHaveDistinctTypedRequestContracts()
    {
        typeof(ReviewReconcilePurviewDlpProfileRequest)
            .Should().NotBe(
                typeof(ReviewPurviewDlpProfileOperationRequest));
        typeof(ReviewValidatePurviewDlpRuntimeRequest)
            .Should().NotBe(
                typeof(ReviewPurviewDlpProfileOperationRequest));
    }
}
