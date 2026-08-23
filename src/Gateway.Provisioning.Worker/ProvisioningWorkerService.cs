using Azure.Messaging.ServiceBus;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Provisioning.Worker;

internal sealed class ProvisioningWorkerService : BackgroundService, IAsyncDisposable
{
    private readonly ServiceBusProcessor _processor;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<ProvisioningWorkerService> _logger;

    public ProvisioningWorkerService(
        ServiceBusClient serviceBusClient,
        IOptions<ProvisioningWorkerOptions> options,
        IServiceScopeFactory scopeFactory,
        ILogger<ProvisioningWorkerService> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
        _processor = serviceBusClient.CreateProcessor(
            options.Value.QueueName,
            new ServiceBusProcessorOptions
            {
                MaxConcurrentCalls = options.Value.MaxConcurrentCalls,
                AutoCompleteMessages = false
            });
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _processor.ProcessMessageAsync += ProcessMessageAsync;
        _processor.ProcessErrorAsync += ProcessErrorAsync;

        await _processor.StartProcessingAsync(stoppingToken);

        await Task.Delay(Timeout.Infinite, stoppingToken).ConfigureAwait(ConfigureAwaitOptions.SuppressThrowing);

        await _processor.StopProcessingAsync();
    }

    private async Task ProcessMessageAsync(ProcessMessageEventArgs args)
    {
        var messageType = args.Message.Subject;
        var payload = args.Message.Body.ToString();

        _logger.LogInformation(
            "Received Service Bus message {MessageId}, type {MessageType}",
            args.Message.MessageId,
            messageType);

        using var scope = _scopeFactory.CreateScope();
        var handler = scope.ServiceProvider.GetRequiredService<ProvisioningMessageHandler>();

        await handler.HandleAsync(messageType, payload, args.CancellationToken);
        await args.CompleteMessageAsync(args.Message);
    }

    private Task ProcessErrorAsync(ProcessErrorEventArgs args)
    {
        _logger.LogError(args.Exception,
            "Service Bus processing error. Source: {ErrorSource}, Entity: {EntityPath}",
            args.ErrorSource,
            args.EntityPath);
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        await _processor.DisposeAsync();
        base.Dispose();
    }
}
