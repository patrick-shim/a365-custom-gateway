using Gateway.Domain.Enums;

namespace Gateway.Domain.Models;

public sealed record PurviewInteraction(
    Guid AgentRegistrationId,
    string TenantUserObjectId,
    string ExternalInteractionId,
    string PromptContent,
    string PromptContentType,
    string ResponseContent,
    string ResponseContentType,
    string? ModelProvider,
    string? ModelName,
    string AgentIdentityClientId,
    string BlueprintClientId,
    string AgentName,
    DateTime OccurredAtUtc,
    PurviewExecutionMode ExecutionMode,
    string CorrelationId);
