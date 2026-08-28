namespace Gateway.Contracts.Messages;

/// <summary>
/// Durable contract shared by registration/retry producers and the provisioning worker.
/// </summary>
public sealed record ProvisionAgentMessage(
    Guid AgentRegistrationId,
    Guid JobId,
    int ExpectedStepIndex,
    string? CorrelationId);
