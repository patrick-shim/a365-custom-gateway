using Gateway.Domain.Enums;

namespace Gateway.Domain.Models;

public sealed record PurviewInteraction(
    Guid AgentRegistrationId,
    string TenantUserObjectId,
    string? PromptContentReference,
    string? ResponseContentReference,
    string? ModelProvider,
    string? ModelName,
    PurviewExecutionMode ExecutionMode,
    string CorrelationId);
