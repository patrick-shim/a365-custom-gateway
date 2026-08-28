using Azure.Messaging.ServiceBus;
using Gateway.Agent365;
using Gateway.Domain.Models;
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
    private readonly ProvisioningWorkerOptions _options;

    public ProvisioningWorkerService(
        ServiceBusClient serviceBusClient,
        IOptions<ProvisioningWorkerOptions> options,
        IServiceScopeFactory scopeFactory,
        ILogger<ProvisioningWorkerService> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
        _options = options.Value;

        if (_options.MaxDeliveryCount < 1)
            throw new ArgumentOutOfRangeException(nameof(options), "MaxDeliveryCount must be at least 1.");

        _processor = serviceBusClient.CreateProcessor(
            _options.QueueName,
            new ServiceBusProcessorOptions
            {
                MaxConcurrentCalls = _options.MaxConcurrentCalls,
                AutoCompleteMessages = false
            });
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!ShouldStartProcessing(_options))
        {
            _logger.LogWarning(
                "Service Bus processing is disabled while worker configuration is being finalized");
            await Task.Delay(Timeout.Infinite, stoppingToken)
                .ConfigureAwait(ConfigureAwaitOptions.SuppressThrowing);
            return;
        }

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

        try
        {
            var result = await handler.HandleAsync(messageType, payload, args.CancellationToken);
            if (result.ShouldDeadLetter)
            {
                _logger.LogWarning(
                    "Dead-lettering Service Bus message {MessageId}, type {MessageType}, reason {Reason}: {SafeSummary}",
                    args.Message.MessageId,
                    messageType,
                    result.DeadLetterReason,
                    result.DeadLetterDescription);

                await args.DeadLetterMessageAsync(
                    args.Message,
                    result.DeadLetterReason,
                    result.DeadLetterDescription,
                    args.CancellationToken);
                return;
            }

            await args.CompleteMessageAsync(args.Message, args.CancellationToken);
        }
        catch (OperationCanceledException) when (args.CancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Agent365ObservabilityExportException exception)
        {
            if (await TryFinalizeObservabilityRetriesAsync(
                    handler,
                    args,
                    messageType,
                    payload,
                    exception.Code))
            {
                return;
            }

            _logger.LogWarning(
                "Abandoning Service Bus message {MessageId}, type {MessageType} for retry after observability failure {FailureCode}",
                args.Message.MessageId,
                messageType,
                exception.Code);

            await args.AbandonMessageAsync(
                args.Message,
                cancellationToken: args.CancellationToken);
        }
        catch (Agent365ProvisioningException exception)
        {
            if (await TryFinalizeObservabilityRetriesAsync(
                    handler,
                    args,
                    messageType,
                    payload,
                    exception.ErrorCode))
            {
                return;
            }

            _logger.LogWarning(
                "Abandoning Service Bus message {MessageId}, type {MessageType} for retry after provisioning failure {FailureCode}",
                args.Message.MessageId,
                messageType,
                exception.ErrorCode);

            await args.AbandonMessageAsync(
                args.Message,
                cancellationToken: args.CancellationToken);
        }
        catch (Exception exception)
        {
            if (await TryFinalizeObservabilityRetriesAsync(
                    handler,
                    args,
                    messageType,
                    payload,
                    exception.GetType().Name))
            {
                return;
            }

            _logger.LogWarning(
                "Abandoning Service Bus message {MessageId}, type {MessageType} for retry after {FailureType}",
                args.Message.MessageId,
                messageType,
                exception.GetType().Name);

            await args.AbandonMessageAsync(
                args.Message,
                cancellationToken: args.CancellationToken);
        }
    }

    private async Task<bool> TryFinalizeObservabilityRetriesAsync(
        ProvisioningMessageHandler handler,
        ProcessMessageEventArgs args,
        string messageType,
        string payload,
        string lastFailureCode)
    {
        if (!IsFinalDelivery(args.Message.DeliveryCount, _options.MaxDeliveryCount))
            return false;

        var result = await handler.HandleRetryExhaustedAsync(
            messageType,
            payload,
            lastFailureCode,
            args.CancellationToken);
        if (result is null)
            return false;

        _logger.LogError(
            "Dead-lettering Service Bus message {MessageId}, type {MessageType} after {DeliveryCount} delivery attempts",
            args.Message.MessageId,
            messageType,
            args.Message.DeliveryCount);

        await args.DeadLetterMessageAsync(
            args.Message,
            result.DeadLetterReason,
            result.DeadLetterDescription,
            args.CancellationToken);
        return true;
    }

    internal static bool IsFinalDelivery(int deliveryCount, int maxDeliveryCount) =>
        deliveryCount >= maxDeliveryCount;

    internal static bool ShouldStartProcessing(ProvisioningWorkerOptions options) =>
        options.ProcessingEnabled;

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
