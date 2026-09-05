using Azure.Messaging.ServiceBus;
using Gateway.Infrastructure.ServiceBus;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Infrastructure.Outbox;

internal sealed class ServiceBusPublisher : IServiceBusPublisher
{
    private readonly ServiceBusClient _client;
    private readonly string _provisioningQueueName;
    private readonly ILogger<ServiceBusPublisher> _logger;
    private readonly Dictionary<string, ServiceBusSender> _senders =
        new(StringComparer.Ordinal);
    private readonly object _sendersGate = new();

    public ServiceBusPublisher(
        ServiceBusClient client,
        IOptions<ServiceBusOptions> options,
        ILogger<ServiceBusPublisher> logger)
    {
        _client = client;
        _provisioningQueueName = options.Value.QueueName;
        _logger = logger;
    }

    public async Task PublishAsync(string messageType, string payload, Guid correlationId, CancellationToken ct)
    {
        var queueName = OutboxRouting.ResolveQueueName(
            messageType,
            _provisioningQueueName);
        var message = CreateMessage(messageType, payload, correlationId);
        var sender = GetSender(queueName);

        await sender.SendMessageAsync(message, ct);
        _logger.LogDebug(
            "Published outbox message {CorrelationId} with type {MessageType} to route {QueueName}",
            correlationId,
            messageType,
            queueName);
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

    private ServiceBusSender GetSender(string queueName)
    {
        lock (_sendersGate)
        {
            if (_senders.TryGetValue(queueName, out var sender))
                return sender;

            sender = _client.CreateSender(queueName);
            _senders.Add(queueName, sender);
            return sender;
        }
    }
}
