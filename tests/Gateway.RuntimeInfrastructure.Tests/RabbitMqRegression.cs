using System.Text;
using Gateway.Provisioning.Worker;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using RabbitMQ.Client.Exceptions;
using Microsoft.Extensions.Logging.Abstractions;

internal static class RabbitMqRegression
{
    public static async Task RunAsync()
    {
        var uri = Environment.GetEnvironmentVariable("GATEWAY_TEST_RABBITMQ");
        if (string.IsNullOrWhiteSpace(uri)) { Console.WriteLine("RabbitMQ checks skipped (set GATEWAY_TEST_RABBITMQ)."); return; }
        var queue = "gateway-audit-" + Guid.NewGuid().ToString("N");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var ct = timeout.Token;
        var startupAttempts = 0;
        await using var connection = await RabbitMqProvisioningWorkerService.ConnectWithRetryAsync(
            token => ++startupAttempts < 3
                ? Task.FromException<IConnection>(new BrokerUnreachableException(new IOException("Synthetic startup refusal")))
                : new ConnectionFactory { Uri = new Uri(uri) }.CreateConnectionAsync(token),
            NullLogger.Instance, ct, TimeSpan.FromMilliseconds(10));
        if (startupAttempts != 3 || !connection.IsOpen) throw new Exception("Worker failed to recover from initial broker refusal.");
        using (var canceled = new CancellationTokenSource(TimeSpan.FromMilliseconds(50)))
        {
            try
            {
                await RabbitMqProvisioningWorkerService.ConnectWithRetryAsync(
                    _ => Task.FromException<IConnection>(new BrokerUnreachableException(new IOException("Synthetic refusal"))),
                    NullLogger.Instance, canceled.Token, TimeSpan.FromSeconds(30));
                throw new Exception("Worker startup retry ignored cancellation.");
            }
            catch (OperationCanceledException) when (canceled.IsCancellationRequested) { }
        }
        Console.WriteLine("Worker initial broker refusal recovery and cancellation checks passed.");
        await using var channel = await connection.CreateChannelAsync(new CreateChannelOptions(true, true), ct);
        await channel.QueueDeclareAsync(queue, true, false, false, cancellationToken: ct);
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var attempts = 0; var finalizations = 0;
        try
        {
            await channel.BasicQosAsync(0, 1, false, ct);
            var consumer = new AsyncEventingBasicConsumer(channel);
            consumer.ReceivedAsync += async (_, delivery) => {
                try
                {
                    await RabbitMqDelivery.HandleAsync(channel, delivery, queue, 2,
                        _ => { Interlocked.Increment(ref attempts); throw new InvalidOperationException("Synthetic failure"); },
                        _ => { Interlocked.Increment(ref finalizations); return Task.FromResult<MessageHandlingResult?>(MessageHandlingResult.DeadLetter("TEST_EXHAUSTED", "Synthetic")); }, ct);
                    if (finalizations == 1) done.TrySetResult();
                }
                catch (Exception ex) { done.TrySetException(ex); }
            };
            var consumerTag = await channel.BasicConsumeAsync(queue, false, consumer, ct);
            await channel.BasicPublishAsync(string.Empty, queue, true, new BasicProperties { DeliveryMode = DeliveryModes.Persistent, Type = "Synthetic" }, Encoding.UTF8.GetBytes("synthetic"), ct);
            await done.Task.WaitAsync(ct);
            await channel.BasicCancelAsync(consumerTag, cancellationToken: ct);
            var dead = await channel.BasicGetAsync(queue + ".dead-letter", true, ct);
            if (attempts != 2 || finalizations != 1 || dead is null || Encoding.UTF8.GetString(dead.Body.Span) != "synthetic")
                throw new Exception("Retry exhaustion did not preserve the message in its dead-letter queue.");
            if (await channel.BasicGetAsync(queue, true, ct) is not null)
                throw new Exception("The confirmed dead-letter publication did not settle the original message.");
            Console.WriteLine("RabbitMQ confirmed retry, bounded attempts, fresh finalization, and retained dead-letter payload checks passed.");
        }
        finally
        {
            // Only these two freshly generated test queues are removed.
            if (channel.IsOpen)
            {
                await channel.QueueDeleteAsync(queue, false, false);
                await channel.QueueDeleteAsync(queue + ".dead-letter", false, false);
            }
        }
    }
}
