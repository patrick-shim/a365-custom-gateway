using RabbitMQ.Client;
using RabbitMQ.Client.Events;

namespace Gateway.Provisioning.Worker;

/// <summary>Settles only after a confirmed retry/dead-letter publication. Consumers use a confirm-enabled channel.</summary>
internal static class RabbitMqDelivery
{
    public const string AttemptHeader = "x-gateway-attempt";

    public static int Attempt(IReadOnlyBasicProperties properties) =>
        properties.Headers?.TryGetValue(AttemptHeader, out var value) == true && value is int count && count > 0
            ? count : 1;

    public static async Task HandleAsync(IChannel channel, BasicDeliverEventArgs delivery, string queue,
        int maximumDeliveries, Func<CancellationToken, Task<MessageHandlingResult>> handle,
        Func<CancellationToken, Task<MessageHandlingResult?>> finalize, CancellationToken ct)
    {
        MessageHandlingResult? result;
        var attempt = Attempt(delivery.BasicProperties);
        try { result = await handle(ct); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
        catch (Exception)
        {
            result = null;
            if (attempt >= Math.Max(1, maximumDeliveries))
            {
                // Caller opens a fresh scope, so failed tracked state is never certified.
                try { result = await finalize(ct); }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
                catch (Exception) { /* Keep the original durable message if finalization cannot be verified. */ }
            }
        }
        try
        {
            if (result is null || result.ShouldDeadLetter)
            {
                var target = result is null ? queue : queue + ".dead-letter";
                await channel.QueueDeclareAsync(target, durable: true, exclusive: false, autoDelete: false, cancellationToken: ct);
                var properties = new BasicProperties(delivery.BasicProperties)
                {
                    DeliveryMode = DeliveryModes.Persistent,
                    Headers = delivery.BasicProperties.Headers is null ? new Dictionary<string, object?>()
                        : new Dictionary<string, object?>(delivery.BasicProperties.Headers)
                };
                properties.Headers[AttemptHeader] = attempt == int.MaxValue ? attempt : attempt + 1;
                if (result is null) await Task.Delay(TimeSpan.FromSeconds(1), ct);
                await channel.BasicPublishAsync(string.Empty, target, mandatory: true, properties, delivery.Body, ct);
            }
            await channel.BasicAckAsync(delivery.DeliveryTag, multiple: false, ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
        catch (Exception)
        {
            // Publication/ack failure is not a business-operation failure. Requeue
            // the original. An uncertain confirm may duplicate; handlers are idempotent.
            if (channel.IsOpen) await channel.BasicNackAsync(delivery.DeliveryTag, multiple: false, requeue: true, ct);
        }
    }
}
