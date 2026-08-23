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
        var message = new ServiceBusMessage(payload)
        {
            Subject = messageType,
            CorrelationId = correlationId.ToString(),
            ContentType = "application/json"
        };

        await _sender.SendMessageAsync(message, ct);
        _logger.LogDebug("Published outbox message {CorrelationId} with type {MessageType}", correlationId, messageType);
    }
}
