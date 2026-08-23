namespace Gateway.Infrastructure.Outbox;

internal interface IServiceBusPublisher
{
    Task PublishAsync(string messageType, string payload, Guid correlationId, CancellationToken ct);
}
