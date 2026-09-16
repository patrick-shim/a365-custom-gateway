using Gateway.Application.Agents.Commands;
using Gateway.Contracts.Dtos;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;

namespace Gateway.TestSupport;

public static class TestData
{
    public static readonly DateTime Now = new(2030, 1, 2, 3, 4, 5, DateTimeKind.Utc);
    public const string Caller = "00000000-0000-4000-8000-000000000001";
    public const string Owner = "00000000-0000-4000-8000-000000000002";
    public const string TenantUser = "00000000-0000-4000-8000-000000000003";
    public const string ShieldPrincipal = "00000000-0000-4000-8000-000000000013";
    public const string ShieldEndpoint = "https://m1offline.cognitiveservices.azure.com/";
    private const string OwnershipId = "00000000-0000-4000-8000-000000000012";
    private const string ShieldResourceId = "/subscriptions/00000000-0000-4000-8000-000000000011/resourceGroups/m1-synthetic/providers/Microsoft.CognitiveServices/accounts/m1offline";

    public static Dictionary<string, string?> ShieldConfiguration() => new()
    {
        ["BootstrapCapabilities:Enabled"] = "true",
        ["BootstrapCapabilities:DeploymentOwnershipId"] = OwnershipId,
        ["BootstrapCapabilities:AcceptedSourceFingerprint"] = $"sha256:{new string('a', 64)}",
        ["BootstrapCapabilities:AttestedAtUtc"] = Now.ToString("O"),
        ["BootstrapCapabilities:PromptShields:Status"] = "Installed",
        ["BootstrapCapabilities:PromptShields:ContentSafetyAccountResourceId"] = ShieldResourceId,
        ["BootstrapCapabilities:PromptShields:ContentSafetyEndpoint"] = ShieldEndpoint,
        ["BootstrapCapabilities:PromptShields:GatewayApiManagedIdentityPrincipalObjectId"] = ShieldPrincipal
    };

    public static ProtectionCapability ShieldCapability() => new()
    {
        Id = Guid.NewGuid(),
        Kind = ProtectionCapabilityKind.PromptShields,
        Status = ProtectionCapabilityStatus.Installed,
        LastReadbackAtUtc = Now,
        CreatedAtUtc = Now,
        UpdatedAtUtc = Now,
        ResourceIdentifiers = new(
            ContentSafetyAccountResourceId: ShieldResourceId,
            ContentSafetyEndpoint: ShieldEndpoint,
            GatewayApiManagedIdentityPrincipalObjectId: new(Guid.Parse(ShieldPrincipal)),
            BootstrapDeploymentOwnershipId: Guid.Parse(OwnershipId),
            BootstrapSourceFingerprint: $"sha256:{new string('a', 64)}")
    };

    public static RegisterAgentCommand Registration(string? externalId = null, AgentBlueprintSelectionDto? blueprint = null) => new(
        externalId ?? $"agent-{Guid.NewGuid():N}", "Synthetic test agent", null, Owner, "Development",
        new AgentFeaturesDto("Disabled", false, null, PromptShieldEnabled: false), Caller,
        blueprint ?? new AgentBlueprintSelectionDto("CreateNew", null, "Synthetic reusable blueprint"));

    public static AgentRegistration Agent(bool promptShield = false, bool purview = false)
    {
        var id = Guid.NewGuid();
        return new AgentRegistration
        {
            Id = id,
            ExternalAgentId = new ExternalAgentId($"agent-{id:N}"),
            Name = "Synthetic test agent",
            OwnerObjectId = Owner,
            CreatedByObjectId = Caller,
            UpdatedByObjectId = Caller,
            CreatedAtUtc = Now,
            UpdatedAtUtc = Now,
            Status = AgentStatus.Active,
            Environment = AgentEnvironment.Development,
            Agent365AgentId = Guid.NewGuid().ToString("D"),
            BlueprintId = Guid.NewGuid().ToString("D"),
            ProtectionRevision = Guid.NewGuid(),
            FeatureConfiguration = new AgentFeatureConfiguration
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = id,
                ObservabilityMode = ObservabilityMode.Disabled,
                PromptShieldEnabled = promptShield,
                PurviewEnabled = purview,
                PurviewMode = purview ? PurviewMode.Enforce : null,
                UpdatedAtUtc = Now
            }
        };
    }

    public static PurviewDlpProfile ReadyProfile() => new()
    {
        Id = new(Guid.NewGuid()),
        BlueprintApplicationId = new(Guid.NewGuid()),
        InventoryGenerationId = new(Guid.NewGuid()),
        SensitiveInformationTypeId = new(Guid.NewGuid()),
        SensitiveInformationTypeName = "Synthetic type",
        DisplayName = "Synthetic profile",
        Mode = PurviewMode.Enforce,
        PolicyMode = PurviewPolicyMode.Enforce,
        Status = PurviewDlpProfileStatus.Ready,
        Readiness = ProtectionReadiness.Ready,
        SensitiveInformationTypeSnapshotExpiresAtUtc = Now.AddHours(2),
        DlpPolicyProviderId = "synthetic-policy",
        DlpRuleProviderId = "synthetic-rule",
        LastReadbackAtUtc = Now.AddMinutes(-5),
        PropagationVerifiedAtUtc = Now.AddMinutes(-4),
        TokenRolesVerifiedAtUtc = Now.AddMinutes(-3),
        RuntimeAllowVerifiedAtUtc = Now.AddMinutes(-2),
        RuntimeBlockVerifiedAtUtc = Now.AddMinutes(-1),
        RuntimeBehaviorCertificationOperationId = Guid.NewGuid(),
        RuntimeBehaviorSuiteHash = $"sha256:{new string('a', 64)}",
        RuntimeBehaviorVerifiedUntilUtc = Now.AddHours(1),
        CreatedAtUtc = Now.AddDays(-1),
        UpdatedAtUtc = Now
    };
}

public sealed class FixedTimeProvider(DateTime utcNow) : TimeProvider
{
    public override DateTimeOffset GetUtcNow() => new(utcNow);
}
