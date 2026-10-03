using System.Text;
using Gateway.Infrastructure.Outbox;
using Gateway.Infrastructure.ServiceBus;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;

namespace Gateway.Infrastructure.Messaging;

internal sealed class RabbitMqOutboxPublisher : IOutboxQueuePublisher, IAsyncDisposable
{
    private readonly RabbitMqOptions _options;
    private readonly ILogger<RabbitMqOutboxPublisher> _logger;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private IConnection? _connection;
    private IChannel? _channel;

    public RabbitMqOutboxPublisher(
        IOptions<RabbitMqOptions> options,
        ILogger<RabbitMqOutboxPublisher> logger)
    {
        _options = options.Value;
        _logger = logger;
    }

    public async Task PublishAsync(
        string messageType,
        string payload,
        Guid correlationId,
        CancellationToken ct)
    {
        var queueName = OutboxRouting.ResolveQueueName(
            messageType,
            _options.ProvisioningQueueName);
        if (queueName == OutboxRouting.ProtectionAdminDestination &&
            !string.Equals(queueName, _options.ProtectionQueueName, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "RabbitMQ protection queue must remain gateway-protection-admin-v1.");
        }

        await _gate.WaitAsync(ct);
        try
        {
            var channel = await EnsureChannelAsync(ct);
            await channel.QueueDeclareAsync(
                queue: queueName,
                durable: true,
                exclusive: false,
                autoDelete: false,
                arguments: null,
                cancellationToken: ct);

            var body = Encoding.UTF8.GetBytes(payload);
            var properties = new BasicProperties
            {
                ContentType = "application/json",
                DeliveryMode = DeliveryModes.Persistent,
                MessageId = correlationId.ToString("D"),
                CorrelationId = correlationId.ToString("D"),
                Type = messageType
            };

            await channel.BasicPublishAsync(
                exchange: string.Empty,
                routingKey: queueName,
                mandatory: false,
                basicProperties: properties,
                body: body,
                cancellationToken: ct);

            _logger.LogDebug(
                "Published outbox message {CorrelationId} type {MessageType} to RabbitMQ queue {QueueName}",
                correlationId,
                messageType,
                queueName);
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<IChannel> EnsureChannelAsync(CancellationToken ct)
    {
        if (_channel is { IsOpen: true } && _connection is { IsOpen: true })
            return _channel;

        if (_connection is not null)
            await _connection.DisposeAsync();
        if (_channel is not null)
            await _channel.DisposeAsync();

        var factory = new ConnectionFactory
        {
            Uri = new Uri(_options.ConnectionUri)
        };
        _connection = await factory.CreateConnectionAsync(ct);
        _channel = await _connection.CreateChannelAsync(cancellationToken: ct);
        return _channel;
    }

    public async ValueTask DisposeAsync()
    {
        if (_channel is not null)
            await _channel.DisposeAsync();
        if (_connection is not null)
            await _connection.DisposeAsync();
        _gate.Dispose();
    }
}
