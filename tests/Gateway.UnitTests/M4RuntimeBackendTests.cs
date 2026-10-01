using System.Text.Json;
using Gateway.Application.Protection;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Microsoft.Extensions.Time.Testing;

namespace Gateway.UnitTests;

public sealed class M4RuntimeBackendTests
{
    private static readonly DateTimeOffset Now = new(2030, 1, 2, 3, 4, 5, TimeSpan.Zero);
    private static readonly Guid SitId = Guid.Parse("66666666-6666-4666-8666-666666666661");
    private static readonly Guid PositiveId = Guid.Parse("66666666-6666-4666-8666-666666666662");
    private static readonly Guid NegativeId = Guid.Parse("66666666-6666-4666-8666-666666666663");
    private const string Version = "AAAAAAAAAAE=";
    private const string Positive = "SYNTHETIC POSITIVE CONTENT";
    private const string Negative = "SYNTHETIC BENIGN CONTROL";

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Provider_execution_stops_at_exactly_sixty_seconds_on_the_injected_clock(bool honorsCancellation)
    {
        var clock = new FakeTimeProvider(Now);
        var plan = Plan();
        using var samples = Samples(plan);
        using var caller = new CancellationTokenSource();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var ignoredCancellation = new TaskCompletionSource<PurviewRuntimeProbeResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var probes = new Probe(async (_, token) =>
        {
            entered.SetResult();
            if (!honorsCancellation)
                return await ignoredCancellation.Task;
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            throw new InvalidOperationException("A cancelled fixture probe cannot produce a verdict.");
        });
        var runner = new PurviewRuntimeTestRunner(probes, new Roles(), clock);
        var task = runner.RunAsync(Guid.NewGuid(), plan, samples, Now.AddSeconds(60), caller.Token);
        try
        {
            await entered.Task;
            clock.Advance(TimeSpan.FromSeconds(59));
            Assert.False(task.IsCompleted);
            clock.Advance(TimeSpan.FromSeconds(1));
            var completed = await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(1)));
            Assert.Same(task, completed);
            Assert.Equal(PurviewRuntimeTestFailureCodes.DeadlineExceeded, (await task).FailureCode);
            Assert.Equal([NegativeId], probes.Calls);
        }
        finally
        {
            caller.Cancel();
            ignoredCancellation.TrySetResult(new(PurviewRuntimeProbeDecision.Unknown,
                PurviewRuntimeContentProcessing.NotSubmitted, PurviewRuntimeActionSource.None, clock.GetUtcNow()));
            await task;
        }
    }

    [Theory]
    [InlineData(PurviewPolicyMode.Enforce)]
    [InlineData(PurviewPolicyMode.SimulationWithTips)]
    [InlineData(PurviewPolicyMode.SimulationWithoutTips)]
    public async Task Actual_runner_checks_negative_then_positive_once_without_classifier_attribution(PurviewPolicyMode mode)
    {
        var plan = Plan(mode);
        using var samples = Samples(plan);
        var probes = new Probe((sample, _) => Task.FromResult(new PurviewRuntimeProbeResult(
            sample.CaseId == PositiveId && mode == PurviewPolicyMode.Enforce ? PurviewRuntimeProbeDecision.Blocked : PurviewRuntimeProbeDecision.Allowed,
            PurviewRuntimeContentProcessing.Processed, sample.CaseId == PositiveId ? PurviewRuntimeActionSource.Content : PurviewRuntimeActionSource.None, Now)));
        var result = await new PurviewRuntimeTestRunner(probes, new Roles(), new FakeTimeProvider(Now))
            .RunAsync(Guid.NewGuid(), plan, samples, Now.AddSeconds(60), default);
        Assert.Null(result.FailureCode);
        Assert.Equal([NegativeId, PositiveId], probes.Calls);
        Assert.All(result.Cases, item => Assert.Equal(PurviewRuntimeBehaviorObservation.BehaviorObserved, item.Behavior));
        Assert.Equal("Unavailable", result.SitMatchAttribution);
    }

    [Theory]
    [InlineData("scope")]
    [InlineData("metadata")]
    [InlineData("wrong-positive")]
    [InlineData("wrong-negative")]
    public async Task Scope_blocks_and_missing_or_wrong_content_verdicts_cannot_certify(string fault)
    {
        var plan = Plan();
        using var samples = Samples(plan);
        var probes = new Probe((sample, _) => Task.FromResult(new PurviewRuntimeProbeResult(
            sample.CaseId == NegativeId
                ? fault == "wrong-negative" ? PurviewRuntimeProbeDecision.Blocked : PurviewRuntimeProbeDecision.Allowed
                : fault == "wrong-positive" ? PurviewRuntimeProbeDecision.Allowed : PurviewRuntimeProbeDecision.Blocked,
            fault == "metadata" && sample.CaseId == PositiveId ? PurviewRuntimeContentProcessing.MetadataOnly : PurviewRuntimeContentProcessing.Processed,
            fault == "scope" && sample.CaseId == PositiveId ? PurviewRuntimeActionSource.ProtectionScope : PurviewRuntimeActionSource.Content,
            Now)));
        var result = await new PurviewRuntimeTestRunner(probes, new Roles(), new FakeTimeProvider(Now))
            .RunAsync(Guid.NewGuid(), plan, samples, Now.AddSeconds(60), default);
        Assert.Equal(PurviewRuntimeTestFailureCodes.UnexpectedVerdict, result.FailureCode);
        Assert.Equal(fault == "wrong-negative" ? 1 : 2, probes.Calls.Count);
    }

    [Fact]
    public async Task Missing_roles_prevent_all_sample_submission()
    {
        var plan = Plan();
        using var samples = Samples(plan);
        var probes = new Probe((_, _) => throw new InvalidOperationException("No probe was authorized."));
        var result = await new PurviewRuntimeTestRunner(probes, new Roles(false), new FakeTimeProvider(Now))
            .RunAsync(Guid.NewGuid(), plan, samples, Now.AddSeconds(60), default);
        Assert.Equal(PurviewRuntimeTestFailureCodes.ProviderUnavailable, result.FailureCode);
        Assert.Empty(probes.Calls);
    }

    [Fact]
    public void Off_and_expired_inventory_do_not_admit_a_runtime_plan()
    {
        var disabled = Assert.Throws<PurviewRuntimeTestValidationException>(() => Plan(PurviewPolicyMode.Disabled));
        Assert.Equal(PurviewRuntimeTestFailureCodes.Disabled, disabled.FailureCode);
        var context = Context();
        var expired = Copy(context, versions: context.Versions with { InventoryExpiresAtUtc = Now });
        var error = Assert.Throws<PurviewRuntimeTestValidationException>(() =>
            PurviewRuntimeTestValidation.CreatePlan(expired, Request(expired), Now));
        Assert.Equal(PurviewRuntimeTestFailureCodes.InventoryExpired, error.FailureCode);
    }

    [Theory]
    [InlineData("profile-version")]
    [InlineData("identity")]
    [InlineData("mode")]
    [InlineData("inventory")]
    public void A_changed_context_invalidates_the_exact_review(string change)
    {
        var plan = Plan();
        var context = plan.Context;
        var changed = change switch
        {
            "profile-version" => Copy(context, versions: context.Versions with { ProfileRowVersion = "AAAAAAAAAAI=" }),
            "identity" => Copy(context, identity: context.Identity with { AgentRegistrationId = Guid.NewGuid() }),
            "mode" => Copy(context, mode: PurviewPolicyMode.SimulationWithoutTips),
            _ => Copy(context, versions: context.Versions with { InventoryGenerationId = Guid.NewGuid() })
        };
        var error = Assert.Throws<PurviewRuntimeTestValidationException>(() => PurviewRuntimeTestValidation.EnsureCurrent(plan, changed, Now));
        Assert.Equal(PurviewRuntimeTestFailureCodes.ContextChanged, error.FailureCode);
    }

    [Fact]
    public void Sample_commitments_and_ephemeral_objects_do_not_serialize_raw_content()
    {
        var plan = Plan();
        using var samples = Samples(plan);
        Assert.DoesNotContain(Positive, JsonSerializer.Serialize(plan));
        Assert.DoesNotContain(Positive, JsonSerializer.Serialize(samples));
        Assert.DoesNotContain(Positive, samples.ToString());
        var sample = samples.GetSample(PositiveId);
        Assert.Equal(Positive, sample.ReadContent());
        samples.Dispose();
        Assert.Throws<ObjectDisposedException>(() => sample.ReadContent());
        var changed = Assert.Throws<PurviewRuntimeTestValidationException>(() =>
            PurviewRuntimeTestValidation.ValidateSamples(plan, [new(PositiveId, Positive + " changed"), new(NegativeId, Negative)]));
        Assert.Equal(PurviewRuntimeTestFailureCodes.SampleMismatch, changed.FailureCode);
    }

    [Theory]
    [InlineData(8192, true)]
    [InlineData(8193, false)]
    public void Backend_sample_byte_boundary_is_exact(int count, bool allowed)
    {
        if (allowed)
            Assert.Equal(count, PurviewRuntimeTestValidation.CommitSample(new string('a', 64), PositiveId, SitId, new string('x', count)).Utf8ByteCount);
        else
            Assert.Equal(PurviewRuntimeTestFailureCodes.SampleBoundsExceeded,
                Assert.Throws<PurviewRuntimeTestValidationException>(() =>
                    PurviewRuntimeTestValidation.CommitSample(new string('a', 64), PositiveId, SitId, new string('x', count))).FailureCode);
    }

    private static PurviewRuntimeTestContext Context(PurviewPolicyMode mode = PurviewPolicyMode.Enforce) => new(
        new(Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid()),
        new(Version, Version, Version, Guid.NewGuid(), Version, Now.AddHours(1), Version, Guid.NewGuid()),
        mode, "Synthetic reviewed policy", "synthetic-policy", "synthetic-rule",
        [new(SitId, "Synthetic classifier", 1, -1, 75, 100)], [PurviewPolicyActivity.UploadText],
        [new(PurviewPolicyActivity.UploadText, PurviewDlpAction.Block)]);
    private static PurviewRuntimeTestContext Copy(PurviewRuntimeTestContext value,
        PurviewRuntimeTestIdentityBinding? identity = null, PurviewRuntimeTestVersionBinding? versions = null, PurviewPolicyMode? mode = null) =>
        new(identity ?? value.Identity, versions ?? value.Versions, mode ?? value.PolicyMode, value.ProfileDisplayName,
            value.PolicyProviderId, value.RuleProviderId, value.SelectedTypes, value.Activities, value.Actions);
    private static ReviewPurviewDlpRuntimeTestRequest Request(PurviewRuntimeTestContext context)
    {
        var nonce = new string('a', 64);
        var positive = PurviewRuntimeTestValidation.CommitSample(nonce, PositiveId, SitId, Positive);
        var negative = PurviewRuntimeTestValidation.CommitSample(nonce, NegativeId, null, Negative);
        return new(context.Identity.ProfileId, Version, context.Versions.InventoryGenerationId,
            new(nonce, [new(PositiveId, SitId, positive.ContentHash, positive.Utf8ByteCount)],
                new(NegativeId, null, negative.ContentHash, negative.Utf8ByteCount)), [PositiveId], true);
    }
    private static PurviewRuntimeTestPlan Plan(PurviewPolicyMode mode = PurviewPolicyMode.Enforce)
    {
        var context = Context(mode);
        return PurviewRuntimeTestValidation.CreatePlan(context, Request(context), Now);
    }
    private static PurviewRuntimeEphemeralBatch Samples(PurviewRuntimeTestPlan plan) =>
        PurviewRuntimeTestValidation.ValidateSamples(plan, [new(PositiveId, Positive), new(NegativeId, Negative)]);

    private sealed class Roles(bool ready = true) : IPurviewRuntimeRoleVerifier
    {
        private int calls;
        public Task<PurviewRuntimeRoleEvidence> VerifyAsync(Guid tenantId, CancellationToken cancellationToken)
        {
            Assert.Equal(1, ++calls);
            return Task.FromResult(new PurviewRuntimeRoleEvidence(ready, Now, Now.AddHours(1)));
        }
    }
    private sealed class Probe(Func<PurviewRuntimeEphemeralSample, CancellationToken, Task<PurviewRuntimeProbeResult>> respond) : IPurviewRuntimeProbeClient
    {
        public List<Guid> Calls { get; } = [];
        public Task<PurviewRuntimeProbeResult> ProbeAsync(Guid operationId, PurviewRuntimeTestContext context,
            PurviewRuntimeEphemeralSample sample, DateTimeOffset deadlineUtc, CancellationToken cancellationToken)
        {
            Assert.True(Calls.Count < 2, "A sample provider call was repeated.");
            Calls.Add(sample.CaseId);
            return respond(sample, cancellationToken);
        }
    }
}
