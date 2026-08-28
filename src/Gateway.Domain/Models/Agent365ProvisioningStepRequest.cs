using Gateway.Domain.Enums;

namespace Gateway.Domain.Models;

public sealed record Agent365ProvisioningStepRequest(
    ProvisioningStepType StepType,
    AgentProvisioningRequest Agent,
    Agent365ProvisioningState State,
    string? CorrelationId);
