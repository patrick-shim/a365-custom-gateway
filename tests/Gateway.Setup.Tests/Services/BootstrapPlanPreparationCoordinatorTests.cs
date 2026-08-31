using System.Text;
using System.Text.Json;
using FluentAssertions;
using Gateway.Setup.Models;
using Gateway.Setup.Security;
using Gateway.Setup.Services;
using Microsoft.Extensions.Hosting;

namespace Gateway.Setup.Tests.Services;

public sealed class BootstrapPlanPreparationCoordinatorTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"gateway-setup-plan-preparation-{Guid.NewGuid():N}");

    [Fact]
    public async Task CompetingTargets_LoserWritesZeroBytesAndPlanUsesWinnerSnapshot()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var atomicWriter = new BlockingAtomicFileWriter();
        var factory = new SnapshotReadingCommandFactory(
            Path.Combine(root, "bootstrap", "config.json"));
        var execution = CreateExecution(factory);
        var preparation = CreatePreparation(atomicWriter, execution);
        var winner = ReadyState(ValidForm("gwwin", "koreacentral"));
        var loser = ReadyState(ValidForm("gwlose", "australiaeast"));

        var winnerTask = preparation.TryPrepareAndStartAsync(
            winner,
            explicitlyConfirmed: true);
        await atomicWriter.WaitUntilEnteredAsync();

        execution.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true)
            .Should().BeFalse("the preparation lease must exclude direct command starts");
        var loserResult = await preparation.TryPrepareAndStartAsync(
            loser,
            explicitlyConfirmed: true);

        loserResult.Status.Should().Be(BootstrapPlanPreparationStatus.Busy);
        atomicWriter.CallCount.Should().Be(1);
        atomicWriter.BytesWritten.Should().Be(0);
        File.Exists(Path.Combine(root, "bootstrap", "config.json")).Should().BeFalse();

        atomicWriter.Release();
        var winnerResult = await winnerTask;

        winnerResult.Status.Should().Be(BootstrapPlanPreparationStatus.Started);
        atomicWriter.CallCount.Should().Be(1);
        atomicWriter.WrittenContents.Should().ContainSingle();
        atomicWriter.BytesWritten.Should().Be(
            Encoding.UTF8.GetByteCount(atomicWriter.WrittenContents.Single()));
        using var written = JsonDocument.Parse(atomicWriter.WrittenContents.Single());
        written.RootElement.GetProperty("subscriptionId").GetGuid()
            .Should().Be(winner.Form.SubscriptionId);
        written.RootElement.GetProperty("subscriptionId").GetGuid()
            .Should().NotBe(loser.Form.SubscriptionId);
        var plan = factory.PlanSnapshots.Should().ContainSingle().Which;
        plan.SubscriptionId.Should().Be(winner.Form.SubscriptionId);
        plan.Location.Should().Be("koreacentral");
        plan.ExpectedConfigurationFileFingerprint.Should().Be(
            plan.PublishedConfigurationFileFingerprint);
        PlanFingerprintPolicy.IsCanonical(plan.ExpectedConfigurationFileFingerprint)
            .Should().BeTrue();
    }

    [Fact]
    public async Task StateChangingAfterSnapshot_PreservesCanonicalAndRetryUsesCurrentSnapshot()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var atomicWriter = new BlockingAtomicFileWriter();
        var factory = new SnapshotReadingCommandFactory(
            Path.Combine(root, "bootstrap", "config.json"));
        var execution = CreateExecution(factory);
        var preparation = CreatePreparation(atomicWriter, execution);
        var state = ReadyState(ValidForm("gwstate", "koreacentral"));

        var preparationTask = preparation.TryPrepareAndStartAsync(
            state,
            explicitlyConfirmed: true);
        await atomicWriter.WaitUntilEnteredAsync();
        state.Form.AlertEmail = "changed@example.com";
        atomicWriter.Release();

        var result = await preparationTask;

        result.Status.Should().Be(BootstrapPlanPreparationStatus.StateChanged);
        atomicWriter.CallCount.Should().Be(1);
        File.Exists(Path.Combine(root, "bootstrap", "config.json")).Should().BeFalse();
        Directory.GetFiles(Path.Combine(root, "bootstrap"), "*.stage")
            .Should().BeEmpty();
        factory.PlanSnapshots.Should().BeEmpty();
        execution.Snapshot().Status.Should().Be(BootstrapExecutionStatus.NotStarted);

        var retry = await preparation.TryPrepareAndStartAsync(
            state,
            explicitlyConfirmed: true);

        retry.Status.Should().Be(BootstrapPlanPreparationStatus.Started);
        using var published = JsonDocument.Parse(
            await File.ReadAllTextAsync(Path.Combine(root, "bootstrap", "config.json")));
        published.RootElement.GetProperty("alertEmail").GetString()
            .Should().Be("changed@example.com");
        factory.PlanSnapshots.Should().ContainSingle()
            .Which.SubscriptionId.Should().Be(state.Form.SubscriptionId);
    }

    [Fact]
    public async Task ProvisionalFileDrift_DoesNotPublishOrLaunchPlan()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var driftConfiguration = BootstrapConfiguration.From(
            ValidForm("gwdrift", "australiaeast"));
        var driftJson = BootstrapConfigWriter.SerializeForTest(driftConfiguration) +
            Environment.NewLine;
        var factory = new SnapshotReadingCommandFactory(
            Path.Combine(root, "bootstrap", "config.json"));
        var execution = CreateExecution(factory);
        var preparation = CreatePreparation(
            new DriftingAtomicFileWriter(driftJson),
            execution);
        var state = ReadyState(ValidForm("gwplan", "koreacentral"));

        var result = await preparation.TryPrepareAndStartAsync(
            state,
            explicitlyConfirmed: true);

        result.Status.Should().Be(BootstrapPlanPreparationStatus.ConfigurationChanged);
        File.Exists(Path.Combine(root, "bootstrap", "config.json")).Should().BeFalse();
        Directory.GetFiles(Path.Combine(root, "bootstrap"), "*.stage")
            .Should().BeEmpty();
        factory.PlanSnapshots.Should().BeEmpty();
        execution.Snapshot().Status.Should().Be(BootstrapExecutionStatus.NotStarted);
    }

    [Fact]
    public async Task PostPublishTamper_CannotChangeFingerprintPassedToPlan()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var state = ReadyState(ValidForm("gwbound", "koreacentral"));
        var expectedFingerprint = state.CreatePlanReadyConfiguration()
            .Readiness.ConfigurationFingerprint;
        var replacement = BootstrapConfigurationDocument.Serialize(
            BootstrapConfiguration.From(ValidForm("gwtamper", "australiaeast")));
        var factory = new SnapshotReadingCommandFactory(
            Path.Combine(root, "bootstrap", "config.json"),
            replacement);
        var execution = CreateExecution(factory);
        var preparation = CreatePreparation(new AtomicFileWriter(), execution);

        var result = await preparation.TryPrepareAndStartAsync(
            state,
            explicitlyConfirmed: true);

        result.Status.Should().Be(BootstrapPlanPreparationStatus.Started);
        var plan = factory.PlanSnapshots.Should().ContainSingle().Which;
        plan.ExpectedConfigurationFileFingerprint.Should().Be(expectedFingerprint);
        plan.PublishedConfigurationFileFingerprint.Should().NotBe(expectedFingerprint);
    }

    [Fact]
    public async Task StageException_ReleasesLeaseAndLeavesRetryAvailable()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var atomicWriter = new FailOnceAtomicFileWriter();
        var factory = new SnapshotReadingCommandFactory(
            Path.Combine(root, "bootstrap", "config.json"));
        var execution = CreateExecution(factory);
        var preparation = CreatePreparation(atomicWriter, execution);
        var state = ReadyState(ValidForm("gwthrow", "koreacentral"));

        var first = () => preparation.TryPrepareAndStartAsync(
            state,
            explicitlyConfirmed: true);

        await first.Should().ThrowAsync<IOException>();
        File.Exists(Path.Combine(root, "bootstrap", "config.json")).Should().BeFalse();

        var retry = await preparation.TryPrepareAndStartAsync(
            state,
            explicitlyConfirmed: true);

        retry.Status.Should().Be(BootstrapPlanPreparationStatus.Started);
        atomicWriter.CallCount.Should().Be(2);
        factory.PlanSnapshots.Should().ContainSingle();
    }

    [Fact]
    public async Task StageCancellation_ReleasesLeaseAndLeavesRetryAvailable()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        var factory = new SnapshotReadingCommandFactory(
            Path.Combine(root, "bootstrap", "config.json"));
        var execution = CreateExecution(factory);
        var preparation = CreatePreparation(new AtomicFileWriter(), execution);
        var state = ReadyState(ValidForm("gwcancel", "koreacentral"));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var first = () => preparation.TryPrepareAndStartAsync(
            state,
            explicitlyConfirmed: true,
            cancellation.Token);

        await first.Should().ThrowAsync<OperationCanceledException>();
        File.Exists(Path.Combine(root, "bootstrap", "config.json")).Should().BeFalse();

        var retry = await preparation.TryPrepareAndStartAsync(
            state,
            explicitlyConfirmed: true);

        retry.Status.Should().Be(BootstrapPlanPreparationStatus.Started);
        factory.PlanSnapshots.Should().ContainSingle();
    }

    private BootstrapPlanPreparationCoordinator CreatePreparation(
        IAtomicFileWriter atomicFileWriter,
        BootstrapExecutionCoordinator execution) =>
        new(
            new BootstrapConfigWriter(
                new RepositoryLayout(root),
                atomicFileWriter),
            execution);

    private static BootstrapExecutionCoordinator CreateExecution(
        IBootstrapCommandFactory commandFactory) =>
        new(
            commandFactory,
            new ImmediateFailureProcessRunner(),
            new SetupActivityTracker(),
            new TestHostApplicationLifetime());

    private static SetupWizardState ReadyState(SetupConfigurationForm form)
    {
        var state = new SetupWizardState(new FixedProjectNameGenerator());
        state.ApplyExistingConfiguration(new ExistingConfigurationResult(
            ExistingConfigurationStatus.Loaded,
            form,
            null));
        state.SetSubscriptions([
            new AzureSubscription(
                form.SubscriptionId,
                form.TenantId,
                "Selected target",
                true,
                "Enabled")
        ]);
        state.ApplyLocationDiscovery(new AzureLocationDiscoveryResult(
            form.SubscriptionId,
            [new AzureLocation(form.Location, "Selected region")],
            null));
        return state;
    }

    private static SetupConfigurationForm ValidForm(string projectName, string location) => new()
    {
        Profile = DeploymentProfile.QuickDevelopment,
        SubscriptionId = Guid.NewGuid(),
        TenantId = Guid.NewGuid(),
        Environment = "dev",
        Location = location,
        ProjectName = projectName,
        ResourceGroupName = $"rg-{projectName}-dev",
        AlertEmail = "operator@example.com",
        SeedBlueprintName = $"A365 Gateway {projectName} dev",
        ReviewedManagerApplicationIds = "33333333-3333-4333-8333-333333333333",
        PromptShieldEnabled = false,
        PromptShieldSkuName = "F0",
        PurviewEnabled = false,
        PurviewSensitiveInformationType = string.Empty
    };

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private sealed class BlockingAtomicFileWriter : IAtomicFileWriter
    {
        private readonly AtomicFileWriter inner = new();
        private readonly TaskCompletionSource<bool> entered = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource<bool> released = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly object sync = new();
        private readonly List<string> writtenContents = [];
        private int callCount;
        private long bytesWritten;

        public int CallCount => Volatile.Read(ref callCount);

        public long BytesWritten => Interlocked.Read(ref bytesWritten);

        public IReadOnlyList<string> WrittenContents
        {
            get
            {
                lock (sync)
                {
                    return writtenContents.ToArray();
                }
            }
        }

        public async Task WriteUtf8Async(
            string targetPath,
            string content,
            CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref callCount);
            lock (sync)
            {
                writtenContents.Add(content);
            }

            entered.TrySetResult(true);
            await released.Task.WaitAsync(cancellationToken);
            await inner.WriteUtf8Async(targetPath, content, cancellationToken);
            Interlocked.Add(ref bytesWritten, Encoding.UTF8.GetByteCount(content));
        }

        public Task WaitUntilEnteredAsync() =>
            entered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        public void Release() => released.TrySetResult(true);
    }

    private sealed class DriftingAtomicFileWriter(string replacement) : IAtomicFileWriter
    {
        private readonly AtomicFileWriter inner = new();

        public async Task WriteUtf8Async(
            string targetPath,
            string content,
            CancellationToken cancellationToken)
        {
            await inner.WriteUtf8Async(targetPath, content, cancellationToken);
            await File.WriteAllTextAsync(targetPath, replacement, cancellationToken);
        }
    }

    private sealed class FailOnceAtomicFileWriter : IAtomicFileWriter
    {
        private readonly AtomicFileWriter inner = new();
        private int callCount;

        public int CallCount => Volatile.Read(ref callCount);

        public Task WriteUtf8Async(
            string targetPath,
            string content,
            CancellationToken cancellationToken)
        {
            if (Interlocked.Increment(ref callCount) == 1)
            {
                throw new IOException("Deterministic staged-write failure.");
            }

            return inner.WriteUtf8Async(targetPath, content, cancellationToken);
        }
    }

    private sealed record PlanSnapshot(
        Guid SubscriptionId,
        string Location,
        string? ExpectedConfigurationFileFingerprint,
        string PublishedConfigurationFileFingerprint);

    private sealed class SnapshotReadingCommandFactory(
        string configPath,
        string? replacementBeforeRead = null) : IBootstrapCommandFactory
    {
        public List<PlanSnapshot> PlanSnapshots { get; } = [];

        public BootstrapCommandSpec Create(
            BootstrapCommand command,
            string? expectedPlanFingerprint = null,
            string? expectedConfigurationFileFingerprint = null)
        {
            command.Should().Be(BootstrapCommand.Plan);
            if (replacementBeforeRead is not null)
            {
                File.WriteAllText(configPath, replacementBeforeRead);
            }

            var publishedJson = File.ReadAllText(configPath);
            using var document = JsonDocument.Parse(publishedJson);
            PlanSnapshots.Add(new PlanSnapshot(
                document.RootElement.GetProperty("subscriptionId").GetGuid(),
                document.RootElement.GetProperty("location").GetString()!,
                expectedConfigurationFileFingerprint,
                BootstrapConfigurationDocument.Fingerprint(publishedJson)));
            return new BootstrapCommandSpec(command, "pwsh", Path.GetTempPath(), []);
        }
    }

    private sealed class ImmediateFailureProcessRunner : IBootstrapProcessRunner
    {
        public Task<BootstrapProcessResult> RunAsync(
            BootstrapCommandSpec command,
            Func<BootstrapProgressEvent, ValueTask> onProgress,
            CancellationToken cancellationToken) =>
            Task.FromResult(new BootstrapProcessResult(1, false));
    }

    private sealed class FixedProjectNameGenerator : IProjectNameGenerator
    {
        public string Create() => "gwfixed";
    }

    private sealed class TestHostApplicationLifetime : IHostApplicationLifetime
    {
        public CancellationToken ApplicationStarted => CancellationToken.None;

        public CancellationToken ApplicationStopping => CancellationToken.None;

        public CancellationToken ApplicationStopped => CancellationToken.None;

        public void StopApplication()
        {
        }
    }
}
