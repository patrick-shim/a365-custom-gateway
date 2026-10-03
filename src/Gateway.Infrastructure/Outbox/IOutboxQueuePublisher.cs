namespace Gateway.Infrastructure.Outbox;

internal interface IOutboxQueuePublisher
{
    Task PublishAsync(string messageType, string payload, Guid correlationId, CancellationToken ct);
}
