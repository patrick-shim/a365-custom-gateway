namespace Gateway.Domain.Interfaces;

public interface IInteractionContentStore
{
    Task DiscardStagedAsync(Guid agentRegistrationId, Guid interactionRecordId, string contentReference, CancellationToken ct);

    Task<string> StoreAsync(
        Guid agentRegistrationId,
        Guid interactionRecordId,
        string promptContent,
        string promptContentType,
        string responseContent,
        string responseContentType,
        CancellationToken ct);
}
