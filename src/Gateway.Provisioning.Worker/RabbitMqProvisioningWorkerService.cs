using System.Text;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Messaging;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using RabbitMQ.Client.Exceptions;

namespace Gateway.Provisioning.Worker;

internal sealed class RabbitMqProvisioningWorkerService(
    IOptions<RabbitMqOptions> rabbitOptions,
    IOptions<ProvisioningWorkerOptions> workerOptions,
    IServiceScopeFactory scopeFactory,
    ILogger<RabbitMqProvisioningWorkerService> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var options = workerOptions.Value;
        if (!options.ProcessingEnabled)
        {
            logger.LogWarning("RabbitMQ provisioning processing is disabled.");
            await Task.Delay(Timeout.Infinite, stoppingToken)
                .ConfigureAwait(ConfigureAwaitOptions.SuppressThrowing);
            return;
        }

        var rabbit = rabbitOptions.Value;
        var factory = new ConnectionFactory { Uri = new Uri(rabbit.ConnectionUri) };
        await using var connection = await ConnectWithRetryAsync(
            ct => factory.CreateConnectionAsync(ct), logger, stoppingToken);
        await using var channel = await connection.CreateChannelAsync(new CreateChannelOptions(true, true), stoppingToken);
        await channel.QueueDeclareAsync(
            rabbit.ProvisioningQueueName,
            durable: true,
            exclusive: false,
            autoDelete: false,
            cancellationToken: stoppingToken);
        await channel.BasicQosAsync(0, (ushort)Math.Clamp(options.MaxConcurrentCalls, 1, 16), false, stoppingToken);

        var consumer = new AsyncEventingBasicConsumer(channel);
        consumer.ReceivedAsync += async (_, args) =>
        {
            var messageType = args.BasicProperties.Type ?? string.Empty;
            var payload = Encoding.UTF8.GetString(args.Body.ToArray());
            await RabbitMqDelivery.HandleAsync(channel, args, rabbit.ProvisioningQueueName, options.MaxDeliveryCount,
                async ct => {
                    await using var scope = scopeFactory.CreateAsyncScope();
                    return await scope.ServiceProvider.GetRequiredService<ProvisioningMessageHandler>()
                        .HandleAsync(messageType, payload, ct);
                },
                async ct => {
                    await using var scope = scopeFactory.CreateAsyncScope();
                    return await scope.ServiceProvider.GetRequiredService<ProvisioningMessageHandler>()
                        .HandleRetryExhaustedAsync(messageType, payload, "RABBITMQ_RETRIES_EXHAUSTED", ct);
                }, stoppingToken);
        };

        await channel.BasicConsumeAsync(
            rabbit.ProvisioningQueueName,
            autoAck: false,
            consumer: consumer,
            cancellationToken: stoppingToken);

        logger.LogInformation("Provisioning worker is consuming its configured queue.");

        await Task.Delay(Timeout.Infinite, stoppingToken)
            .ConfigureAwait(ConfigureAwaitOptions.SuppressThrowing);
    }

    internal static async Task<IConnection> ConnectWithRetryAsync(
        Func<CancellationToken, Task<IConnection>> connect,
        ILogger logger,
        CancellationToken cancellationToken,
        TimeSpan? retryDelay = null)
    {
        var attempt = 0;
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                return await connect(cancellationToken);
            }
            catch (BrokerUnreachableException) when (!cancellationToken.IsCancellationRequested)
            {
                // Never log the connection URI: it contains broker credentials.
                logger.LogWarning("Message broker is unavailable; retrying worker connection (attempt {Attempt}).", ++attempt);
                await Task.Delay(retryDelay ?? TimeSpan.FromSeconds(Math.Min(attempt * 2, 30)), cancellationToken);
            }
        }
    }
}
