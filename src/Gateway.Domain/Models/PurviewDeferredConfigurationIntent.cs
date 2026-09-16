using Gateway.Domain.Enums;

namespace Gateway.Domain.Models;

public sealed record PurviewDeferredConfigurationIntent(
    Guid AgentRegistrationId,
    string ExternalAgentId,
    string BlueprintDisplayName,
    Guid ProfileId,
    Guid TenantConnectionId,
    string DisplayName,
    Guid InventoryGenerationId,
    PurviewPolicyMode PolicyMode,
    IReadOnlyList<PurviewSelectedSensitiveInformationType> SensitiveInformationTypes,
    IReadOnlyList<PurviewPolicyActivity> Activities,
    IReadOnlyList<PurviewDlpRuleAction> Actions,
    string SourceReviewedPayloadHash);
