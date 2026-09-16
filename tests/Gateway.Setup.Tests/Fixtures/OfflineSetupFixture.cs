using Bunit;
using Gateway.Setup.Security;
using Gateway.Setup.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.FluentUI.AspNetCore.Components;

namespace Gateway.Setup.Tests.Fixtures;

internal sealed class OfflineSetupFixture : IAsyncDisposable
{
    private readonly SetupFixtureDirectory directory = new();
    private readonly FixtureApplicationLifetime lifetime = new();

    public BunitContext Context { get; } = new();
    public FixtureAccountDiscovery Discovery { get; } = new();
    public FixtureConfigLoader ConfigLoader { get; } = new();
    public FixtureBootstrapRunner ProcessRunner { get; } = new();
    public ForbiddenAzureCli Cli { get; } = new();
    public ForbiddenAzureCliResolver CliResolver { get; } = new();
    public ForbiddenFileWriter FileWriter { get; } = new();
    public FixtureBrowserLauncher Browser { get; } = new();
    public SetupWizardState State => Context.Services.GetRequiredService<SetupWizardState>();
    public BootstrapExecutionCoordinator Execution =>
        Context.Services.GetRequiredService<BootstrapExecutionCoordinator>();

    public OfflineSetupFixture()
    {
        Context.JSInterop.Mode = JSRuntimeMode.Loose;
        Context.Services.AddFluentUIComponents();
        Context.Services.AddSingleton(new RepositoryLayout(directory.RootPath));
        Context.Services.AddSingleton<SetupActivityTracker>();
        Context.Services.AddSingleton<IHostApplicationLifetime>(lifetime);
        Context.Services.AddSetupWorkflow();

        Replace<IProjectNameGenerator>(new FixtureProjectNameGenerator());
        Replace<IAzureAccountDiscovery>(Discovery);
        Replace<IAzureCliRunner>(Cli);
        Replace<IAzureCliExecutableResolver>(CliResolver);
        Replace<IBootstrapConfigLoader>(ConfigLoader);
        Replace<IBootstrapProcessRunner>(ProcessRunner);
        Replace<IAtomicFileWriter>(FileWriter);
        Replace<ISetupBrowserLauncher>(Browser);
    }

    public void AssertProviderIsolation()
    {
        Assert.Same(Discovery, Assert.Single(Context.Services.GetServices<IAzureAccountDiscovery>()));
        Assert.Same(Cli, Assert.Single(Context.Services.GetServices<IAzureCliRunner>()));
        Assert.Same(CliResolver, Assert.Single(Context.Services.GetServices<IAzureCliExecutableResolver>()));
        Assert.Same(ConfigLoader, Assert.Single(Context.Services.GetServices<IBootstrapConfigLoader>()));
        Assert.Same(ProcessRunner, Assert.Single(Context.Services.GetServices<IBootstrapProcessRunner>()));
        Assert.Same(FileWriter, Assert.Single(Context.Services.GetServices<IAtomicFileWriter>()));
        Assert.Same(Browser, Assert.Single(Context.Services.GetServices<ISetupBrowserLauncher>()));
        Assert.Equal(0, Cli.CallCount);
        Assert.Equal(0, CliResolver.CallCount);
        Assert.Equal(0, FileWriter.CallCount);
        Assert.Empty(Browser.Calls);
    }

    private void Replace<T>(T instance) where T : class
    {
        Context.Services.RemoveAll<T>();
        Context.Services.AddSingleton(instance);
    }

    public async ValueTask DisposeAsync()
    {
        lifetime.StopApplication();
        await Context.DisposeAsync();
        lifetime.Dispose();
        directory.Dispose();
    }
}

internal sealed class FixtureAccountDiscovery : IAzureAccountDiscovery
{
    public Task<AzureAccountDiscoveryResult> Accounts { get; set; } =
        Task.FromResult(new AzureAccountDiscoveryResult([], null));
    public Task<AzureLocationDiscoveryResult> Locations { get; set; } =
        Task.FromResult(new AzureLocationDiscoveryResult(SetupFixtureValues.SubscriptionId, [], "Offline fixture has no regions."));
    public Task<ManagerApplicationDiscoveryResult> Managers { get; set; } =
        Task.FromResult(new ManagerApplicationDiscoveryResult(
            SetupFixtureValues.SubscriptionId, SetupFixtureValues.TenantId, [], "Synthetic fixture",
            "Offline fixture has no reviewed manager applications."));
    public int AccountCalls { get; private set; }
    public int LocationCalls { get; private set; }
    public int ManagerCalls { get; private set; }

    public Task<AzureAccountDiscoveryResult> DiscoverAsync(CancellationToken cancellationToken = default)
    {
        AccountCalls++;
        return Accounts.WaitAsync(cancellationToken);
    }

    public Task<AzureLocationDiscoveryResult> DiscoverLocationsAsync(
        Guid subscriptionId, CancellationToken cancellationToken = default)
    {
        Assert.Equal(SetupFixtureValues.SubscriptionId, subscriptionId);
        LocationCalls++;
        return Locations.WaitAsync(cancellationToken);
    }

    public Task<ManagerApplicationDiscoveryResult> DiscoverManagerApplicationsAsync(
        Guid subscriptionId, Guid tenantId, CancellationToken cancellationToken = default)
    {
        Assert.Equal(SetupFixtureValues.SubscriptionId, subscriptionId);
        Assert.Equal(SetupFixtureValues.TenantId, tenantId);
        ManagerCalls++;
        return Managers.WaitAsync(cancellationToken);
    }
}

internal sealed class FixtureConfigLoader : IBootstrapConfigLoader
{
    public ExistingConfigurationResult Result { get; set; } =
        new(ExistingConfigurationStatus.Missing, null, null);
    public int CallCount { get; private set; }

    public Task<ExistingConfigurationResult> LoadAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        CallCount++;
        return Task.FromResult(Result);
    }
}

internal sealed class FixtureBootstrapRunner : IBootstrapProcessRunner
{
    private readonly Queue<(string[] Output, Task<BootstrapProcessResult> Completion)> scripts = new();
    public List<BootstrapCommandSpec> Calls { get; } = [];

    public TaskCompletionSource<BootstrapProcessResult> Hold(params string[] output)
    {
        var completion = new TaskCompletionSource<BootstrapProcessResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        scripts.Enqueue((output, completion.Task));
        return completion;
    }

    public async Task<BootstrapProcessResult> RunAsync(
        BootstrapCommandSpec command,
        Func<BootstrapProgressEvent, ValueTask> onProgress,
        CancellationToken cancellationToken)
    {
        Calls.Add(command);
        if (!scripts.TryDequeue(out var script))
        {
            throw new InvalidOperationException("No synthetic bootstrap process result was arranged.");
        }

        foreach (var line in script.Output)
        {
            await onProgress(BootstrapOutputSanitizer.Parse(line, standardError: false));
        }

        return await script.Completion.WaitAsync(cancellationToken);
    }
}

internal sealed class ForbiddenAzureCli : IAzureCliRunner
{
    public int CallCount { get; private set; }

    public Task<AzureCliInvocationResult> RunAsync(
        IReadOnlyList<string> arguments, TimeSpan timeout, CancellationToken cancellationToken)
    {
        CallCount++;
        throw new InvalidOperationException("Offline Setup fixtures forbid Azure CLI execution.");
    }
}

internal sealed class ForbiddenAzureCliResolver : IAzureCliExecutableResolver
{
    public int CallCount { get; private set; }

    public AzureCliExecutable? Resolve()
    {
        CallCount++;
        throw new InvalidOperationException("Offline Setup fixtures forbid provider executable resolution.");
    }
}

internal sealed class ForbiddenFileWriter : IAtomicFileWriter
{
    public int CallCount { get; private set; }

    public Task WriteUtf8Async(string targetPath, string content, CancellationToken cancellationToken)
    {
        CallCount++;
        throw new InvalidOperationException("Component fixtures cannot publish configuration.");
    }
}

internal sealed class FixtureBrowserLauncher : ISetupBrowserLauncher
{
    public List<Uri> Calls { get; } = [];

    public bool TryOpen(Uri address)
    {
        Calls.Add(address);
        return true;
    }
}

internal sealed class FixtureApplicationLifetime : IHostApplicationLifetime, IDisposable
{
    private readonly CancellationTokenSource stopping = new();
    public CancellationToken ApplicationStarted => CancellationToken.None;
    public CancellationToken ApplicationStopping => stopping.Token;
    public CancellationToken ApplicationStopped => CancellationToken.None;
    public void StopApplication() => stopping.Cancel();
    public void Dispose() => stopping.Dispose();
}
