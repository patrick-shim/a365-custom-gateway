using System.Reflection;
using Azure.Messaging.ServiceBus;
using Gateway.ObservabilityRuntime.Tests.Fixtures;

namespace Gateway.ObservabilityRuntime.Tests.Worker;

internal sealed class WorkerServiceBusClient : ServiceBusClient
{
    public override ServiceBusProcessor CreateProcessor(string queueName, ServiceBusProcessorOptions options)
    {
        Assert.False(options.AutoCompleteMessages);
        return new OfflineProcessor();
    }

    private sealed class OfflineProcessor : ServiceBusProcessor
    {
        public override Task CloseAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
    }
}

internal sealed class WorkerMessageEventArgs : ProcessMessageEventArgs
{
    public WorkerMessageEventArgs(string subject, string payload, int deliveryCount = 10)
        : base(ServiceBusModelFactory.ServiceBusReceivedMessage(
            body: BinaryData.FromString(payload), messageId: Guid.NewGuid().ToString("D"),
            subject: subject, deliveryCount: deliveryCount), new OfflineReceiver(), CancellationToken.None)
    {
    }

    public Exception? CompletionFailure { get; init; }
    public Exception? DeadLetterFailure { get; init; }
    public int Completions { get; private set; }
    public int Abandons { get; private set; }
    public List<string?> DeadLetters { get; } = [];

    public override Task CompleteMessageAsync(ServiceBusReceivedMessage message, CancellationToken cancellationToken = default)
    {
        Assert.Same(Message, message);
        Completions++;
        return CompletionFailure is null ? Task.CompletedTask : Task.FromException(CompletionFailure);
    }

    public override Task DeadLetterMessageAsync(ServiceBusReceivedMessage message,
        string deadLetterReason, string? deadLetterErrorDescription = default, CancellationToken cancellationToken = default)
    {
        Assert.Same(Message, message);
        DeadLetters.Add(deadLetterReason);
        return DeadLetterFailure is null ? Task.CompletedTask : Task.FromException(DeadLetterFailure);
    }

    public override Task AbandonMessageAsync(ServiceBusReceivedMessage message,
        IDictionary<string, object>? propertiesToModify = default, CancellationToken cancellationToken = default)
    {
        Assert.Same(Message, message);
        Abandons++;
        return Task.CompletedTask;
    }

    public Task ProcessAsync(object worker) => (Task)(worker.GetType()
        .GetMethod("ProcessMessageAsync", BindingFlags.Instance | BindingFlags.NonPublic)!
        .Invoke(worker, [this])!);

    private sealed class OfflineReceiver : ServiceBusReceiver;
}

internal class WorkerDependencyProxy : DispatchProxy
{
    private Func<MethodInfo, object?[]?, object?>? _invoke;

    public static T Create<T>(Func<MethodInfo, object?[]?, object?>? invoke = null) where T : class
    {
        var proxy = Create<T, WorkerDependencyProxy>();
        ((WorkerDependencyProxy)(object)proxy)._invoke = invoke;
        return proxy;
    }

    protected override object? Invoke(MethodInfo? targetMethod, object?[]? args) =>
        _invoke is null
            ? throw new UnexpectedFixtureCallException($"Unscripted worker dependency: {targetMethod?.Name}.")
            : _invoke(targetMethod!, args);
}
