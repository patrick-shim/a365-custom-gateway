using Gateway.Domain.Enums;

namespace Gateway.Domain.Models;

public sealed record Agent365ProvisioningStepResult(
    ProvisioningStepType StepType,
    Agent365ProvisioningState State,
    string CompletionEvidence);
