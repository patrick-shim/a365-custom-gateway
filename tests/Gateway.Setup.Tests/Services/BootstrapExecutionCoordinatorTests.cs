using FluentAssertions;
using Gateway.Setup.Security;
using Gateway.Setup.Services;
using Microsoft.Extensions.Hosting;

namespace Gateway.Setup.Tests.Services;

public sealed class BootstrapExecutionCoordinatorTests
{
    private const string ReviewedFingerprint =
        "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    [Fact]
    public async Task Apply_ReceivesOnlyTheApplyReadyFingerprintEmittedByTheReviewedPlan()
    {
        var factory = new RecordingCommandFactory();
        var runner = new SequencedProcessRunner(
            new RunResult(
                [PlanResult(ReviewedFingerprint, applyReady: true)],
                new BootstrapProcessResult(0, false)),
            new RunResult([], new BootstrapProcessResult(0, false)));
        var coordinator = CreateCoordinator(factory, runner);

        coordinator.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);
        coordinator.Snapshot().PlanSucceeded.Should().BeTrue();

        coordinator.TryStart(BootstrapCommand.Apply, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);

        factory.Calls.Should().Equal(
            new CommandCall(BootstrapCommand.Plan, null),
            new CommandCall(BootstrapCommand.Apply, ReviewedFingerprint));
    }

    [Fact]
    public async Task SuccessfulProcessWithoutAnApplyReadyFingerprint_DoesNotAuthorizeMutation()
    {
        var factory = new RecordingCommandFactory();
        var runner = new SequencedProcessRunner(
            new RunResult([], new BootstrapProcessResult(0, false)));
        var coordinator = CreateCoordinator(factory, runner);

        coordinator.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);

        var snapshot = coordinator.Snapshot();
        snapshot.Status.Should().Be(BootstrapExecutionStatus.Failed);
        snapshot.PlanSucceeded.Should().BeFalse();
        snapshot.Events.Should().Contain(progress =>
            progress.Message == "Plan ended without one apply-ready canonical fingerprint. No mutation was authorized.");
        coordinator.TryStart(BootstrapCommand.Apply, explicitlyConfirmed: true).Should().BeFalse();
        factory.Calls.Should().ContainSingle().Which.Should().Be(new CommandCall(BootstrapCommand.Plan, null));
    }

    [Fact]
    public async Task ConflictingPlanFingerprints_FailClosed()
    {
        const string otherFingerprint =
            "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
        var factory = new RecordingCommandFactory();
        var runner = new SequencedProcessRunner(
            new RunResult(
                [
                    PlanResult(ReviewedFingerprint, applyReady: true),
                    PlanResult(otherFingerprint, applyReady: true)
                ],
                new BootstrapProcessResult(0, false)));
        var coordinator = CreateCoordinator(factory, runner);

        coordinator.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);

        coordinator.Snapshot().PlanSucceeded.Should().BeFalse();
        coordinator.TryStart(BootstrapCommand.Resume, explicitlyConfirmed: true).Should().BeFalse();
    }

    private static BootstrapExecutionCoordinator CreateCoordinator(
        IBootstrapCommandFactory factory,
        IBootstrapProcessRunner runner) =>
        new(factory, runner, new SetupActivityTracker(), new TestHostApplicationLifetime());

    private static BootstrapProgressEvent PlanResult(string fingerprint, bool applyReady) =>
        new(
            DateTimeOffset.UtcNow,
            BootstrapProgressKind.Success,
            applyReady ? "Plan is ready for explicit acceptance." : "Plan is not apply-ready.",
            "Plan review",
            6,
            null,
            fingerprint,
            applyReady);

    private static async Task WaitForCompletionAsync(BootstrapExecutionCoordinator coordinator)
    {
        for (var attempt = 0; attempt < 100 && coordinator.Snapshot().IsRunning; attempt++)
        {
            await Task.Delay(10);
        }

        coordinator.Snapshot().IsRunning.Should().BeFalse();
    }

    private sealed record CommandCall(BootstrapCommand Command, string? ExpectedPlanFingerprint);

    private sealed class RecordingCommandFactory : IBootstrapCommandFactory
    {
        public List<CommandCall> Calls { get; } = [];

        public BootstrapCommandSpec Create(
            BootstrapCommand command,
            string? expectedPlanFingerprint = null)
        {
            Calls.Add(new CommandCall(command, expectedPlanFingerprint));
            return new BootstrapCommandSpec(command, "pwsh", Path.GetTempPath(), []);
        }
    }

    private sealed record RunResult(
        IReadOnlyList<BootstrapProgressEvent> Events,
        BootstrapProcessResult Result);

    private sealed class SequencedProcessRunner(params RunResult[] results) : IBootstrapProcessRunner
    {
        private readonly Queue<RunResult> results = new(results);

        public async Task<BootstrapProcessResult> RunAsync(
            BootstrapCommandSpec command,
            Func<BootstrapProgressEvent, ValueTask> onProgress,
            CancellationToken cancellationToken)
        {
            var next = results.Dequeue();
            foreach (var progressEvent in next.Events)
            {
                await onProgress(progressEvent);
            }

            return next.Result;
        }
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
