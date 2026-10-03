using System.Text;
using Gateway.Contracts.Messages;
using Gateway.Infrastructure.Messaging;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;

namespace Gateway.Provisioning.Worker;

internal sealed class RabbitMqProtectionAdminWorkerService(
    IOptions<RabbitMqOptions> rabbitOptions,
    IOptions<ProtectionAdminWorkerOptions> workerOptions,
    IServiceScopeFactory scopeFactory,
    ILogger<RabbitMqProtectionAdminWorkerService> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var options = workerOptions.Value;
        if (!options.ProcessingEnabled)
        {
            logger.LogWarning("RabbitMQ protection-admin processing is disabled.");
            await Task.Delay(Timeout.Infinite, stoppingToken)
                .ConfigureAwait(ConfigureAwaitOptions.SuppressThrowing);
            return;
        }

        var rabbit = rabbitOptions.Value;
        var factory = new ConnectionFactory { Uri = new Uri(rabbit.ConnectionUri) };
        await using var connection = await factory.CreateConnectionAsync(stoppingToken);
        await using var channel = await connection.CreateChannelAsync(cancellationToken: stoppingToken);
        await channel.QueueDeclareAsync(
            rabbit.ProtectionQueueName,
            durable: true,
            exclusive: false,
            autoDelete: false,
            cancellationToken: stoppingToken);
        await channel.BasicQosAsync(0, 1, false, stoppingToken);

        var consumer = new AsyncEventingBasicConsumer(channel);
        consumer.ReceivedAsync += async (_, args) =>
        {
            var payload = Encoding.UTF8.GetString(args.Body.ToArray());
            try
            {
                await using var scope = scopeFactory.CreateAsyncScope();
                var handler = scope.ServiceProvider.GetRequiredService<ProtectionAdminMessageHandler>();
                var result = await handler.HandleAsync(
                    nameof(ProtectionAdminOperationMessage),
                    payload,
                    stoppingToken);
                if (result.ShouldDeadLetter)
                    await channel.BasicNackAsync(args.DeliveryTag, false, false, stoppingToken);
                else
                    await channel.BasicAckAsync(args.DeliveryTag, false, stoppingToken);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "RabbitMQ protection-admin message failed; requeue.");
                await channel.BasicNackAsync(args.DeliveryTag, false, true, stoppingToken);
            }
        };

        await channel.BasicConsumeAsync(
            rabbit.ProtectionQueueName,
            autoAck: false,
            consumer: consumer,
            cancellationToken: stoppingToken);

        await Task.Delay(Timeout.Infinite, stoppingToken)
            .ConfigureAwait(ConfigureAwaitOptions.SuppressThrowing);
    }
}
