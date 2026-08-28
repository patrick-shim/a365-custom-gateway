using Azure.Messaging.ServiceBus;
using Microsoft.Extensions.Logging;

namespace Gateway.Infrastructure.Outbox;

internal sealed class ServiceBusPublisher : IServiceBusPublisher
{
    private readonly ServiceBusSender _sender;
    private readonly ILogger<ServiceBusPublisher> _logger;

    public ServiceBusPublisher(ServiceBusSender sender, ILogger<ServiceBusPublisher> logger)
    {
        _sender = sender;
        _logger = logger;
    }

    public async Task PublishAsync(string messageType, string payload, Guid correlationId, CancellationToken ct)
    {
        var message = CreateMessage(messageType, payload, correlationId);

        await _sender.SendMessageAsync(message, ct);
        _logger.LogDebug("Published outbox message {CorrelationId} with type {MessageType}", correlationId, messageType);
    }

    internal static ServiceBusMessage CreateMessage(
        string messageType,
        string payload,
        Guid outboxMessageId)
    {
        var stableId = outboxMessageId.ToString("D");
        return new ServiceBusMessage(payload)
        {
            Subject = messageType,
            MessageId = stableId,
            CorrelationId = stableId,
            ContentType = "application/json"
        };
    }
}
