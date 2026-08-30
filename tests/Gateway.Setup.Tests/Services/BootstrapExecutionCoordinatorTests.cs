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
            new RunResult(
                [DeploymentVerificationResult()],
                new BootstrapProcessResult(0, false)));
        var coordinator = CreateCoordinator(factory, runner);

        coordinator.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);
        coordinator.Snapshot().PlanSucceeded.Should().BeTrue();

        coordinator.TryStart(BootstrapCommand.Apply, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);

        var deployment = coordinator.Snapshot();
        deployment.Status.Should().Be(BootstrapExecutionStatus.Succeeded);
        deployment.HasVerifiedDeployment.Should().BeTrue();
        deployment.VerifiedEndpoints!.AdminUiBaseAddress.Should().Be("https://ca-gateway-admin-dev.safe.azurecontainerapps.io/");
        deployment.VerifiedEndpoints.ApiBaseAddress.Should().Be("https://ca-gateway-api-dev.safe.azurecontainerapps.io/");
        deployment.VerifiedEndpoints.ApiHealthAddress.Should().Be("https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks");
        factory.Calls.Should().Equal(
            new CommandCall(BootstrapCommand.Plan, null),
            new CommandCall(BootstrapCommand.Apply, ReviewedFingerprint));
    }

    [Fact]
    public async Task ResumeSucceedsOnlyWithOneApplyModeVerificationProof()
    {
        var factory = new RecordingCommandFactory();
        var coordinator = CreateCoordinator(
            factory,
            new SequencedProcessRunner(
                new RunResult(
                    [PlanResult(ReviewedFingerprint, applyReady: true)],
                    new BootstrapProcessResult(0, false)),
                new RunResult(
                    [DeploymentVerificationResult()],
                    new BootstrapProcessResult(0, false))));

        coordinator.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);
        coordinator.TryStart(BootstrapCommand.Resume, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);

        var snapshot = coordinator.Snapshot();
        snapshot.Status.Should().Be(BootstrapExecutionStatus.Succeeded);
        snapshot.HasVerifiedDeployment.Should().BeTrue();
        snapshot.VerifiedEndpoints!.VerificationMode.Should().Be(BootstrapVerificationMode.Apply);
        factory.Calls.Should().Equal(
            new CommandCall(BootstrapCommand.Plan, null),
            new CommandCall(BootstrapCommand.Resume, ReviewedFingerprint));
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

    [Fact]
    public async Task DuplicateIdenticalApplyReadyPlanResults_FailClosed()
    {
        var coordinator = CreateCoordinator(
            new RecordingCommandFactory(),
            new SequencedProcessRunner(
                new RunResult(
                    [
                        PlanResult(ReviewedFingerprint, applyReady: true),
                        PlanResult(ReviewedFingerprint, applyReady: true)
                    ],
                    new BootstrapProcessResult(0, false))));

        coordinator.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);

        coordinator.Snapshot().Status.Should().Be(BootstrapExecutionStatus.Failed);
        coordinator.Snapshot().PlanSucceeded.Should().BeFalse();
        coordinator.TryStart(BootstrapCommand.Apply, explicitlyConfirmed: true).Should().BeFalse();
    }

    [Theory]
    [InlineData(false, true)]
    [InlineData(true, false)]
    public async Task ContradictoryPlanResults_FailClosedRegardlessOfOrder(
        bool firstApplyReady,
        bool secondApplyReady)
    {
        var coordinator = CreateCoordinator(
            new RecordingCommandFactory(),
            new SequencedProcessRunner(
                new RunResult(
                    [
                        PlanResult(ReviewedFingerprint, firstApplyReady),
                        PlanResult(ReviewedFingerprint, secondApplyReady)
                    ],
                    new BootstrapProcessResult(0, false))));

        coordinator.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);

        coordinator.Snapshot().Status.Should().Be(BootstrapExecutionStatus.Failed);
        coordinator.Snapshot().PlanSucceeded.Should().BeFalse();
        coordinator.TryStart(BootstrapCommand.Apply, explicitlyConfirmed: true).Should().BeFalse();
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task InvalidAndValidPlanResults_FailClosedRegardlessOfOrder(bool invalidFirst)
    {
        var claims = invalidFirst
            ? new[] { InvalidPlanResult(), PlanResult(ReviewedFingerprint, applyReady: true) }
            : new[] { PlanResult(ReviewedFingerprint, applyReady: true), InvalidPlanResult() };
        var coordinator = CreateCoordinator(
            new RecordingCommandFactory(),
            new SequencedProcessRunner(
                new RunResult(claims, new BootstrapProcessResult(0, false))));

        coordinator.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);

        coordinator.Snapshot().Status.Should().Be(BootstrapExecutionStatus.Failed);
        coordinator.Snapshot().PlanSucceeded.Should().BeFalse();
        coordinator.TryStart(BootstrapCommand.Apply, explicitlyConfirmed: true).Should().BeFalse();
    }

    [Fact]
    public async Task SuccessfulApplyProcessWithoutTypedVerificationProof_FailsClosed()
    {
        var factory = new RecordingCommandFactory();
        var activity = new SetupActivityTracker();
        var runner = new SequencedProcessRunner(
            new RunResult(
                [PlanResult(ReviewedFingerprint, applyReady: true)],
                new BootstrapProcessResult(0, false)),
            new RunResult([], new BootstrapProcessResult(0, false)));
        var coordinator = new BootstrapExecutionCoordinator(
            factory,
            runner,
            activity,
            new TestHostApplicationLifetime());

        coordinator.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);
        coordinator.TryStart(BootstrapCommand.Apply, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);

        var snapshot = coordinator.Snapshot();
        snapshot.Status.Should().Be(BootstrapExecutionStatus.Failed);
        snapshot.HasVerifiedDeployment.Should().BeFalse();
        snapshot.VerifiedEndpoints.Should().BeNull();
        snapshot.Events.Should().Contain(progress =>
            progress.Message == "Apply exited without exactly one nonconflicting typed deployment verification result. Setup did not mark the Gateway ready.");
        activity.Snapshot().CompletedUtc.Should().BeNull();
    }

    [Fact]
    public async Task DuplicateTypedVerificationResults_FailClosedEvenWhenTheyMatch()
    {
        var coordinator = CreateCoordinator(
            new RecordingCommandFactory(),
            new SequencedProcessRunner(
                new RunResult(
                    [PlanResult(ReviewedFingerprint, applyReady: true)],
                    new BootstrapProcessResult(0, false)),
                new RunResult(
                    [DeploymentVerificationResult(), DeploymentVerificationResult()],
                    new BootstrapProcessResult(0, false))));

        coordinator.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);
        coordinator.TryStart(BootstrapCommand.Apply, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);

        coordinator.Snapshot().Status.Should().Be(BootstrapExecutionStatus.Failed);
        coordinator.Snapshot().VerifiedEndpoints.Should().BeNull();
    }

    [Fact]
    public async Task ConflictingTypedVerificationResults_FailClosed()
    {
        var coordinator = CreateCoordinator(
            new RecordingCommandFactory(),
            new SequencedProcessRunner(
                new RunResult(
                    [PlanResult(ReviewedFingerprint, applyReady: true)],
                    new BootstrapProcessResult(0, false)),
                new RunResult(
                    [
                        DeploymentVerificationResult(),
                        DeploymentVerificationResult(adminUiBaseUrl: "https://ca-gateway-admin-dev.other.azurecontainerapps.io/")
                    ],
                    new BootstrapProcessResult(0, false))));

        coordinator.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);
        coordinator.TryStart(BootstrapCommand.Apply, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);

        coordinator.Snapshot().Status.Should().Be(BootstrapExecutionStatus.Failed);
        coordinator.Snapshot().VerifiedEndpoints.Should().BeNull();
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task InvalidAndValidTypedVerificationResults_FailClosedRegardlessOfOrder(bool invalidFirst)
    {
        var claims = invalidFirst
            ? new[] { InvalidDeploymentVerificationResult(), DeploymentVerificationResult() }
            : new[] { DeploymentVerificationResult(), InvalidDeploymentVerificationResult() };
        var coordinator = CreateCoordinator(
            new RecordingCommandFactory(),
            new SequencedProcessRunner(
                new RunResult(
                    [PlanResult(ReviewedFingerprint, applyReady: true)],
                    new BootstrapProcessResult(0, false)),
                new RunResult(claims, new BootstrapProcessResult(0, false))));

        coordinator.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);
        coordinator.TryStart(BootstrapCommand.Apply, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);

        coordinator.Snapshot().Status.Should().Be(BootstrapExecutionStatus.Failed);
        coordinator.Snapshot().VerifiedEndpoints.Should().BeNull();
    }

    [Fact]
    public async Task ApplyRejectsVerifyModeEndpointProof()
    {
        var coordinator = CreateCoordinator(
            new RecordingCommandFactory(),
            new SequencedProcessRunner(
                new RunResult(
                    [PlanResult(ReviewedFingerprint, applyReady: true)],
                    new BootstrapProcessResult(0, false)),
                new RunResult(
                    [DeploymentVerificationResult(BootstrapVerificationMode.Verify)],
                    new BootstrapProcessResult(0, false))));

        coordinator.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);
        coordinator.TryStart(BootstrapCommand.Apply, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);

        coordinator.Snapshot().Status.Should().Be(BootstrapExecutionStatus.Failed);
        coordinator.Snapshot().VerifiedEndpoints.Should().BeNull();
    }

    [Fact]
    public async Task NonzeroApplyExitCannotBeOverriddenByTypedVerificationProof()
    {
        var coordinator = CreateCoordinator(
            new RecordingCommandFactory(),
            new SequencedProcessRunner(
                new RunResult(
                    [PlanResult(ReviewedFingerprint, applyReady: true)],
                    new BootstrapProcessResult(0, false)),
                new RunResult(
                    [DeploymentVerificationResult()],
                    new BootstrapProcessResult(1, false))));

        coordinator.TryStart(BootstrapCommand.Plan, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);
        coordinator.TryStart(BootstrapCommand.Apply, explicitlyConfirmed: true).Should().BeTrue();
        await WaitForCompletionAsync(coordinator);

        coordinator.Snapshot().Status.Should().Be(BootstrapExecutionStatus.Failed);
        coordinator.Snapshot().VerifiedEndpoints.Should().BeNull();
    }

    private static BootstrapExecutionCoordinator CreateCoordinator(
        IBootstrapCommandFactory factory,
        IBootstrapProcessRunner runner) =>
        new(factory, runner, new SetupActivityTracker(), new TestHostApplicationLifetime());

    private static BootstrapProgressEvent PlanResult(string fingerprint, bool applyReady) =>
        new(
            TimestampUtc: DateTimeOffset.UtcNow,
            Kind: BootstrapProgressKind.Success,
            Message: applyReady ? "Plan is ready for explicit acceptance." : "Plan is not apply-ready.",
            Step: "Plan review",
            ProgressPercent: 6,
            PlanFingerprint: fingerprint,
            PlanApplyReady: applyReady,
            PlanResultClaimObserved: true);

    private static BootstrapProgressEvent InvalidPlanResult() =>
        new(
            TimestampUtc: DateTimeOffset.UtcNow,
            Kind: BootstrapProgressKind.Error,
            Message: BootstrapOutputSanitizer.InvalidPlanResultMessage,
            Step: "Plan review",
            ProgressPercent: 6,
            PlanResultClaimObserved: true);

    private static BootstrapProgressEvent DeploymentVerificationResult(
        BootstrapVerificationMode mode = BootstrapVerificationMode.Apply,
        string adminUiBaseUrl = "https://ca-gateway-admin-dev.safe.azurecontainerapps.io/") =>
        new(
            TimestampUtc: DateTimeOffset.UtcNow,
            Kind: BootstrapProgressKind.Success,
            Message: "Gateway deployment completed and verified.",
            Step: "End-to-end deployment verification",
            ProgressPercent: 100,
            VerifiedEndpoints: new BootstrapVerifiedEndpoints(
                mode,
                new Uri(adminUiBaseUrl),
                new Uri("https://ca-gateway-api-dev.safe.azurecontainerapps.io/"),
                new Uri("https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks")),
            DeploymentVerificationClaimObserved: true);

    private static BootstrapProgressEvent InvalidDeploymentVerificationResult() =>
        new(
            TimestampUtc: DateTimeOffset.UtcNow,
            Kind: BootstrapProgressKind.Error,
            Message: BootstrapOutputSanitizer.InvalidVerificationMessage,
            Step: "End-to-end deployment verification",
            ProgressPercent: 100,
            DeploymentVerificationClaimObserved: true);

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
