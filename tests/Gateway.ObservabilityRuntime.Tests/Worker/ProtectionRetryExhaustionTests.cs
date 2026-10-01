using System.Text.Json;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Services;
using Gateway.ObservabilityRuntime.Tests.Fixtures;
using Gateway.Provisioning.Worker;
using Gateway.Purview;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Gateway.ObservabilityRuntime.Tests.Worker;

public sealed class ProtectionRetryExhaustionTests
{
    [Fact]
    public async Task Transient_read_queues_a_new_same_step_generation_and_old_delivery_cannot_consume_it()
    {
        var fixture = new ProtectionFixture { TransientConnectionRead = true };
        fixture.Operation.OrderedSteps[0].Status = ProtectionAdminStepStatus.Completed;
        var original = fixture.Payload(1);

        Assert.False((await fixture.Handler().HandleAsync(
            nameof(ProtectionAdminOperationMessage), original, default)).ShouldDeadLetter);

        var retry = Assert.Single(fixture.Outbox);
        using var payload = JsonDocument.Parse(retry.Payload);
        Assert.True(payload.RootElement.TryGetProperty("expectedStepAttemptCount", out var generation));
        Assert.Equal(1, generation.GetInt32());
        Assert.Equal(ProtectionAdminOperationStatus.PendingPropagation, fixture.Operation.Status);
        Assert.Equal(1, fixture.Operation.OrderedSteps[1].AttemptCount);
        fixture.Clock.UtcNow = new DateTimeOffset(fixture.Operation.NextAttemptAtUtc!.Value);

        Assert.False((await fixture.Handler().HandleAsync(
            nameof(ProtectionAdminOperationMessage), original, default)).ShouldDeadLetter);
        Assert.False((await fixture.Handler().HandleRetryExhaustedAsync(
            nameof(ProtectionAdminOperationMessage), original, "SYNTHETIC_FAILURE", default))!.ShouldDeadLetter);

        Assert.Equal(1, fixture.ProviderReads);
        Assert.Equal(2, fixture.Saves);
        Assert.Single(fixture.Outbox);
        Assert.Equal(ProtectionAdminOperationStatus.PendingPropagation, fixture.Operation.Status);
        Assert.Equal("SYNTHETIC_TRANSIENT", fixture.Operation.LastFailureCode);

        Assert.True((await fixture.Handler().HandleRetryExhaustedAsync(
            nameof(ProtectionAdminOperationMessage), retry.Payload, "SYNTHETIC_FAILURE", default))!.ShouldDeadLetter);
        Assert.Equal(ProtectionAdminOperationStatus.RequiresManualIntervention, fixture.Operation.Status);
        Assert.Equal(1, fixture.ProviderReads);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(true, true)]
    public async Task Legacy_unbound_delivery_is_explicitly_rejected_without_provider_or_state_changes(
        bool exhaustion, bool explicitNull)
    {
        var fixture = new ProtectionFixture();
        var payload = explicitNull ? fixture.Payload(0, null) : JsonSerializer.Serialize(new
        {
            OperationId = fixture.Operation.Id,
            fixture.Operation.WorkflowVersion,
            ExpectedStepIndex = 0,
            fixture.Operation.CorrelationId
        });

        var result = exhaustion
            ? await fixture.Handler().HandleRetryExhaustedAsync(
                nameof(ProtectionAdminOperationMessage), payload, "SYNTHETIC_FAILURE", default)
            : await fixture.Handler().HandleAsync(nameof(ProtectionAdminOperationMessage), payload, default);

        Assert.Equal("PROTECTION_ADMIN_MESSAGE_ATTEMPT_UNBOUND", result!.DeadLetterReason);
        fixture.AssertUnchanged();
    }

    [Fact]
    public async Task Running_attempt_recovery_uses_its_original_generation_until_a_retry_commits()
    {
        var fixture = new ProtectionFixture { TransientConnectionRead = true };
        fixture.Operation.OrderedSteps[0].Status = ProtectionAdminStepStatus.Completed;
        var step = fixture.Operation.OrderedSteps[1];
        step.Status = ProtectionAdminStepStatus.Running;
        step.AttemptCount = 2;
        fixture.Operation.Status = ProtectionAdminOperationStatus.Running;
        fixture.Operation.AttemptCount = 2;
        var original = fixture.Payload(1, 1);

        Assert.False((await fixture.Handler().HandleAsync(
            nameof(ProtectionAdminOperationMessage), original, default)).ShouldDeadLetter);

        Assert.Equal(1, fixture.ProviderReads);
        Assert.Equal(1, fixture.Saves);
        Assert.Equal(2, step.AttemptCount);
        Assert.Equal(ProtectionAdminStepStatus.PendingPropagation, step.Status);
        var retry = JsonSerializer.Deserialize<ProtectionAdminOperationMessage>(
            Assert.Single(fixture.Outbox).Payload, new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
        Assert.Equal(2, retry.ExpectedStepAttemptCount);
        Assert.False((await fixture.Handler().HandleRetryExhaustedAsync(
            nameof(ProtectionAdminOperationMessage), original, "SYNTHETIC_FAILURE", default))!.ShouldDeadLetter);
        Assert.Equal(1, fixture.Saves);
        Assert.Equal(ProtectionAdminOperationStatus.PendingPropagation, fixture.Operation.Status);
    }

    [Fact]
    public async Task Processing_failure_recovery_can_exhaust_the_legitimately_started_current_attempt()
    {
        var fixture = new ProtectionFixture { FailNextRead = true };
        fixture.Operation.OrderedSteps[0].Status = ProtectionAdminStepStatus.Completed;
        fixture.Operation.OrderedSteps[1].Status = ProtectionAdminStepStatus.Running;
        fixture.Operation.OrderedSteps[1].AttemptCount = 2;
        fixture.Operation.Status = ProtectionAdminOperationStatus.Running;
        fixture.Operation.AttemptCount = 2;
        var handlers = 0;
        using var services = new ServiceCollection().AddScoped(_ =>
        {
            handlers++;
            return fixture.Handler();
        }).BuildServiceProvider();
        await using var worker = new ProtectionAdminWorkerService(new WorkerServiceBusClient(),
            Options.Create(new ProtectionAdminWorkerOptions()), services.GetRequiredService<IServiceScopeFactory>(),
            NullLogger<ProtectionAdminWorkerService>.Instance);
        var args = new WorkerMessageEventArgs(nameof(ProtectionAdminOperationMessage), fixture.Payload(1, 1));

        await args.ProcessAsync(worker);

        Assert.Equal(2, handlers);
        Assert.Equal(["PROTECTION_ADMIN_UNEXPECTED_FAILURE"], args.DeadLetters);
        Assert.Equal(0, args.Completions);
        Assert.Equal(0, args.Abandons);
        Assert.Equal(ProtectionAdminOperationStatus.RequiresManualIntervention, fixture.Operation.Status);
        Assert.Equal(ProtectionAdminStepStatus.RequiresManualIntervention, fixture.Operation.OrderedSteps[1].Status);
        Assert.Equal(2, fixture.Operation.OrderedSteps[1].AttemptCount);
        Assert.Equal(1, fixture.Saves);
        Assert.Equal(0, fixture.ProviderReads);
        Assert.Empty(fixture.HeldLocks);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Future_attempt_generation_is_rejected_without_consuming_current_work(bool exhaustion)
    {
        var fixture = new ProtectionFixture();
        fixture.Operation.OrderedSteps[0].Status = ProtectionAdminStepStatus.Completed;
        fixture.Operation.OrderedSteps[1].Status = ProtectionAdminStepStatus.PendingPropagation;
        fixture.Operation.OrderedSteps[1].AttemptCount = 1;
        fixture.Operation.Status = ProtectionAdminOperationStatus.PendingPropagation;
        var payload = fixture.Payload(1, 2);

        var result = exhaustion
            ? await fixture.Handler().HandleRetryExhaustedAsync(
                nameof(ProtectionAdminOperationMessage), payload, "SYNTHETIC_FAILURE", default)
            : await fixture.Handler().HandleAsync(nameof(ProtectionAdminOperationMessage), payload, default);

        Assert.Equal("PROTECTION_ADMIN_MESSAGE_OUT_OF_ORDER", result!.DeadLetterReason);
        Assert.Equal(ProtectionAdminOperationStatus.PendingPropagation, fixture.Operation.Status);
        Assert.Equal(0, fixture.Saves);
        Assert.Equal(0, fixture.ProviderReads);
        Assert.Empty(fixture.Outbox);
    }

    [Theory]
    [InlineData(ProtectionAdminStepStatus.Completed, false)]
    [InlineData(ProtectionAdminStepStatus.Skipped, false)]
    [InlineData(ProtectionAdminStepStatus.Completed, true)]
    [InlineData(ProtectionAdminStepStatus.Skipped, true)]
    public async Task Exhausted_old_step_cannot_fail_the_advanced_operation(ProtectionAdminStepStatus settled, bool unbound)
    {
        var fixture = new ProtectionFixture();
        fixture.Operation.OrderedSteps[0].Status = settled;

        var result = await fixture.Handler().HandleRetryExhaustedAsync(
            nameof(ProtectionAdminOperationMessage), fixture.Payload(0, unbound ? null : 0), "SYNTHETIC_FAILURE", default);

        Assert.False(result!.ShouldDeadLetter);
        Assert.False((await fixture.Handler().HandleAsync(
            nameof(ProtectionAdminOperationMessage), fixture.Payload(0, unbound ? null : 0), default)).ShouldDeadLetter);
        fixture.AssertUnchanged();
        Assert.Equal(ProtectionAdminStepStatus.Pending, fixture.Operation.OrderedSteps[1].Status);
    }

    [Fact]
    public async Task Exhausted_future_step_is_dead_lettered_without_terminalizing_current_work()
    {
        var fixture = new ProtectionFixture();

        var result = await fixture.Handler().HandleRetryExhaustedAsync(
            nameof(ProtectionAdminOperationMessage), fixture.Payload(1), "SYNTHETIC_FAILURE", default);

        Assert.Equal("PROTECTION_ADMIN_MESSAGE_OUT_OF_ORDER", result!.DeadLetterReason);
        fixture.AssertUnchanged();
    }

    [Theory]
    [InlineData(ProtectionAdminOperationStatus.Completed, false)]
    [InlineData(ProtectionAdminOperationStatus.Failed, false)]
    [InlineData(ProtectionAdminOperationStatus.RequiresManualIntervention, false)]
    [InlineData(ProtectionAdminOperationStatus.Cancelled, false)]
    [InlineData(ProtectionAdminOperationStatus.Completed, true)]
    [InlineData(ProtectionAdminOperationStatus.Failed, true)]
    [InlineData(ProtectionAdminOperationStatus.RequiresManualIntervention, true)]
    [InlineData(ProtectionAdminOperationStatus.Cancelled, true)]
    public async Task Terminal_operations_complete_exhausted_redeliveries_without_writes(
        ProtectionAdminOperationStatus status, bool unbound)
    {
        var fixture = new ProtectionFixture();
        fixture.Operation.Status = status;

        var result = await fixture.Handler().HandleRetryExhaustedAsync(
            nameof(ProtectionAdminOperationMessage), fixture.Payload(0, unbound ? null : 0), "SYNTHETIC_FAILURE", default);

        Assert.False(result!.ShouldDeadLetter);
        Assert.False((await fixture.Handler().HandleAsync(
            nameof(ProtectionAdminOperationMessage), fixture.Payload(0, unbound ? null : 0), default)).ShouldDeadLetter);
        Assert.Equal(status, fixture.Operation.Status);
        Assert.Equal(0, fixture.Saves);
        Assert.Empty(fixture.HeldLocks);
    }

    [Fact]
    public async Task Exhaustion_with_no_unfinished_step_does_not_invent_a_failure()
    {
        var fixture = new ProtectionFixture();
        foreach (var step in fixture.Operation.OrderedSteps)
            step.Status = ProtectionAdminStepStatus.Completed;

        var result = await fixture.Handler().HandleRetryExhaustedAsync(
            nameof(ProtectionAdminOperationMessage), fixture.Payload(7), "SYNTHETIC_FAILURE", default);

        Assert.False(result!.ShouldDeadLetter);
        fixture.AssertUnchanged();
    }

    [Fact]
    public async Task Exact_current_exhaustion_remains_manual_and_redelivery_never_replays_a_provider()
    {
        var fixture = new ProtectionFixture();
        fixture.Operation.OrderedSteps[0].Status = ProtectionAdminStepStatus.Completed;
        fixture.Operation.OrderedSteps[1].Status = ProtectionAdminStepStatus.Skipped;
        fixture.Operation.OrderedSteps[2].Status = ProtectionAdminStepStatus.Running;
        fixture.Operation.OrderedSteps[2].AttemptCount = 1;

        var result = await fixture.Handler().HandleRetryExhaustedAsync(
            nameof(ProtectionAdminOperationMessage), fixture.Payload(2), "SYNTHETIC_FAILURE", default);
        var redelivery = await fixture.Handler().HandleAsync(
            nameof(ProtectionAdminOperationMessage), fixture.Payload(2), default);

        Assert.True(result!.ShouldDeadLetter);
        Assert.Equal("SYNTHETIC_FAILURE", result.DeadLetterReason);
        Assert.False(redelivery.ShouldDeadLetter);
        Assert.Equal(ProtectionAdminOperationStatus.RequiresManualIntervention, fixture.Operation.Status);
        Assert.Equal(ProtectionAdminStepStatus.RequiresManualIntervention, fixture.Operation.OrderedSteps[2].Status);
        Assert.Equal(1, fixture.Saves);
        Assert.Empty(fixture.Outbox);
        Assert.Empty(fixture.HeldLocks);
    }

    [Fact]
    public async Task Completion_failure_after_committed_advancement_never_exhausts_the_next_step()
    {
        var fixture = new ProtectionFixture();
        using var services = new ServiceCollection().AddScoped(_ => fixture.Handler()).BuildServiceProvider();
        await using var worker = new ProtectionAdminWorkerService(new WorkerServiceBusClient(),
            Options.Create(new ProtectionAdminWorkerOptions()), services.GetRequiredService<IServiceScopeFactory>(),
            NullLogger<ProtectionAdminWorkerService>.Instance);
        var error = new InvalidOperationException("Synthetic broker completion response loss.");
        var args = new WorkerMessageEventArgs(nameof(ProtectionAdminOperationMessage), fixture.Payload(0))
        {
            CompletionFailure = error
        };

        Assert.Same(error, await Assert.ThrowsAsync<InvalidOperationException>(() => args.ProcessAsync(worker)));

        Assert.Equal(1, args.Completions);
        Assert.Empty(args.DeadLetters);
        Assert.Equal(0, args.Abandons);
        Assert.Equal(ProtectionAdminOperationStatus.Pending, fixture.Operation.Status);
        Assert.Equal(ProtectionAdminStepStatus.Completed, fixture.Operation.OrderedSteps[0].Status);
        Assert.Equal(ProtectionAdminStepStatus.Pending, fixture.Operation.OrderedSteps[1].Status);
        Assert.Equal(2, fixture.Saves);
        var next = JsonSerializer.Deserialize<ProtectionAdminOperationMessage>(
            Assert.Single(fixture.Outbox).Payload, new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
        Assert.Equal(1, next.ExpectedStepIndex);
        Assert.Equal(0, next.ExpectedStepAttemptCount);
        var replay = await fixture.Handler().HandleAsync(
            nameof(ProtectionAdminOperationMessage), fixture.Payload(0), default);
        Assert.False(replay.ShouldDeadLetter);
        Assert.Equal(2, fixture.Saves);
        Assert.Single(fixture.Outbox);
        Assert.Empty(fixture.HeldLocks);
    }

    [Theory]
    [InlineData(false, 10)]
    [InlineData(true, 10)]
    [InlineData(false, 1)]
    public async Task Processing_failure_recovers_final_deliveries_in_a_new_scope_or_abandons(bool advanced, int deliveryCount)
    {
        var fixture = new ProtectionFixture { FailNextRead = true };
        if (advanced)
            fixture.Operation.OrderedSteps[0].Status = ProtectionAdminStepStatus.Completed;
        var handlers = 0;
        using var services = new ServiceCollection().AddScoped(_ =>
        {
            handlers++;
            return fixture.Handler();
        }).BuildServiceProvider();
        await using var worker = new ProtectionAdminWorkerService(new WorkerServiceBusClient(),
            Options.Create(new ProtectionAdminWorkerOptions()), services.GetRequiredService<IServiceScopeFactory>(),
            NullLogger<ProtectionAdminWorkerService>.Instance);
        var args = new WorkerMessageEventArgs(nameof(ProtectionAdminOperationMessage), fixture.Payload(0), deliveryCount);

        await args.ProcessAsync(worker);

        var final = deliveryCount == 10;
        Assert.Equal(final ? 2 : 1, handlers);
        Assert.Equal(final && advanced ? 1 : 0, args.Completions);
        Assert.Equal(final && !advanced ? 1 : 0, args.DeadLetters.Count);
        Assert.Equal(final ? 0 : 1, args.Abandons);
        Assert.Equal(final && !advanced ? ProtectionAdminOperationStatus.RequiresManualIntervention :
            ProtectionAdminOperationStatus.Pending, fixture.Operation.Status);
        Assert.Equal(final && !advanced ? 1 : 0, fixture.Saves);
        Assert.Empty(fixture.HeldLocks);
    }

    [Fact]
    public async Task Dead_letter_settlement_failure_is_not_a_second_processing_failure()
    {
        var fixture = new ProtectionFixture();
        using var services = new ServiceCollection().AddScoped(_ => fixture.Handler()).BuildServiceProvider();
        await using var worker = new ProtectionAdminWorkerService(new WorkerServiceBusClient(),
            Options.Create(new ProtectionAdminWorkerOptions()), services.GetRequiredService<IServiceScopeFactory>(),
            NullLogger<ProtectionAdminWorkerService>.Instance);
        var error = new InvalidOperationException("Synthetic dead-letter response loss.");
        var args = new WorkerMessageEventArgs(nameof(ProtectionAdminOperationMessage), fixture.Payload(1))
        {
            DeadLetterFailure = error
        };

        Assert.Same(error, await Assert.ThrowsAsync<InvalidOperationException>(() => args.ProcessAsync(worker)));

        Assert.Equal(["PROTECTION_ADMIN_MESSAGE_OUT_OF_ORDER"], args.DeadLetters);
        Assert.Equal(0, args.Completions);
        Assert.Equal(0, args.Abandons);
        fixture.AssertUnchanged();
    }

    private sealed class ProtectionFixture : IProtectionAdminOperationLockProvider
    {
        private const string CertificateUri = "https://m5-offline.vault.azure.net/secrets/synthetic-certificate";
        public ProtectionAdminOperation Operation { get; }
        public PurviewTenantConnection Connection { get; }
        public HashSet<Guid> HeldLocks { get; } = [];
        public List<OutboxMessage> Outbox { get; } = [];
        public int Saves { get; private set; }
        public bool FailNextRead { get; set; }
        public bool TransientConnectionRead { get; init; }
        public int ProviderReads { get; private set; }
        public FixedClock Clock { get; } = new();

        public ProtectionFixture()
        {
            Connection = new()
            {
                Id = FixtureIds.Principal, TenantId = new(FixtureIds.Tenant),
                Status = PurviewTenantConnectionStatus.PendingVerification,
                AuthorityKind = "InteractiveSubmissionUnverified", CreatedByObjectId = FixtureIds.Actor.ToString("D")
            };
            Operation = new()
            {
                Id = FixtureIds.Agent, WorkflowVersion = ProtectionAdminWorkflow.CurrentVersion,
                Type = ProtectionAdminOperationType.ConnectPurviewTenant, Status = ProtectionAdminOperationStatus.Pending,
                TenantId = Connection.TenantId, ActorObjectId = FixtureIds.Actor.ToString("D"),
                TargetType = ProtectionAdminTargetType.PurviewTenantConnection, TargetIdentifier = Connection.Id.ToString("D"),
                ReviewedPayloadHash = ProtectionAdminIntentFingerprint.ForConnection(FixtureIds.Tenant),
                AcceptedRequestHash = "sha256:" + new string('a', 64), MaximumAttempts = 5,
                CorrelationId = FixtureIds.Registry,
                ConfirmationVerifier = new(Guid.NewGuid(), Guid.NewGuid(), 1, "SHA256",
                    new byte[16], new byte[32], FixtureIds.Timestamp.AddMinutes(5))
            };
            Operation.ConfirmationVerifier.MarkConsumed(FixtureIds.Timestamp);
            foreach (var (stepType, index) in ProtectionAdminWorkflow.CurrentSteps.Select((step, index) => (step, index)))
                Operation.AddStep(new() { Id = Guid.NewGuid(), StepType = stepType, OrderIndex = index });
        }

        public string Payload(int index, int? attempt = 0) => JsonSerializer.Serialize(new ProtectionAdminOperationMessage(
            Operation.Id, Operation.WorkflowVersion, index, Operation.CorrelationId, attempt));

        public ProtectionAdminMessageHandler Handler() => new(
            WorkerDependencyProxy.Create<IProtectionAdminOperationRepository>((method, args) =>
            {
                Assert.Equal(nameof(IProtectionAdminOperationRepository.GetByIdAsync), method.Name);
                Assert.Contains(Operation.Id, HeldLocks);
                if (FailNextRead)
                {
                    FailNextRead = false;
                    throw new InvalidOperationException("Synthetic read failure before processing.");
                }
                Assert.Equal(Operation.Id, args![0]);
                return Task.FromResult<ProtectionAdminOperation?>(Operation);
            }),
            WorkerDependencyProxy.Create<IProtectionCapabilityRepository>((method, _) =>
            {
                Assert.Equal(nameof(IProtectionCapabilityRepository.GetByKindAsync), method.Name);
                return Task.FromResult<ProtectionCapability?>(new()
                {
                    Kind = ProtectionCapabilityKind.Purview, Status = ProtectionCapabilityStatus.Installed,
                    LastReadbackAtUtc = FixtureIds.Timestamp,
                    ResourceIdentifiers = new(
                        GatewayApiManagedIdentityPrincipalObjectId: new(FixtureIds.Principal),
                        PurviewRuntimeManagedIdentityPrincipalObjectId: new(FixtureIds.Principal),
                        PurviewAutomationApplicationId: new(FixtureIds.Blueprint),
                        PurviewAutomationServicePrincipalObjectId: new(FixtureIds.Principal),
                        KeyVaultResourceId: $"/subscriptions/{FixtureIds.Tenant:D}/resourceGroups/offline/providers/Microsoft.KeyVault/vaults/m5-offline",
                        CertificateName: "synthetic-certificate", BootstrapDeploymentOwnershipId: FixtureIds.Registry,
                        BootstrapSourceFingerprint: "sha256:" + new string('a', 64),
                        KeyVaultHost: "m5-offline.vault.azure.net", CertificateSecretUri: CertificateUri)
                });
            }),
            WorkerDependencyProxy.Create<IPurviewTenantConnectionRepository>((method, args) =>
            {
                Assert.Equal(nameof(IPurviewTenantConnectionRepository.GetByIdAsync), method.Name);
                Assert.Equal(Connection.Id, args![0]);
                return Task.FromResult<PurviewTenantConnection?>(Connection);
            }),
            WorkerDependencyProxy.Create<IPurviewSensitiveInformationTypeSnapshotRepository>(),
            WorkerDependencyProxy.Create<IPurviewKnowYourDataConfigurationRepository>(),
            WorkerDependencyProxy.Create<IPurviewDlpProfileRepository>(),
            WorkerDependencyProxy.Create<IPurviewConnectionVerificationProvider>((method, _) =>
            {
                Assert.Equal(nameof(IPurviewConnectionVerificationProvider.VerifyAsync), method.Name);
                if (!TransientConnectionRead)
                    throw new UnexpectedFixtureCallException("No connection provider read was scripted.");
                ProviderReads++;
                throw new PurviewConnectionVerificationException("SYNTHETIC_TRANSIENT", isTransient: true);
            }),
            WorkerDependencyProxy.Create<IPurviewSettingsProvider>(),
            WorkerDependencyProxy.Create<IPurviewTokenRoleAttestor>(),
            WorkerDependencyProxy.Create<IPurviewRuntimeReadinessValidator>(),
            WorkerDependencyProxy.Create<IOutboxRepository>((method, args) =>
            {
                Assert.Equal(nameof(IOutboxRepository.AddAsync), method.Name);
                Outbox.Add(Assert.IsType<OutboxMessage>(args![0]));
                return Task.CompletedTask;
            }),
            WorkerDependencyProxy.Create<IUnitOfWork>((method, _) =>
            {
                Assert.Equal(nameof(IUnitOfWork.SaveChangesAsync), method.Name);
                Assert.Contains(Operation.Id, HeldLocks);
                Saves++;
                return Task.FromResult(1);
            }), this, Options.Create(new ProtectionAdminWorkerOptions()),
            Options.Create(new PurviewOptions
            {
                Enabled = true, PolicyProvisioningEnabled = true,
                PolicyProvisioningApplicationId = FixtureIds.Blueprint.ToString("D"),
                PolicyProvisioningCertificateSecretUri = CertificateUri
            }),
            new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["PurviewRuntimeIdentity:ManagedIdentityPrincipalObjectId"] = FixtureIds.Principal.ToString("D")
            }).Build(), NullLogger<ProtectionAdminMessageHandler>.Instance, Clock);

        public void AssertUnchanged()
        {
            Assert.Equal(ProtectionAdminOperationStatus.Pending, Operation.Status);
            Assert.Null(Operation.LastFailureCode);
            Assert.Equal(0, Saves);
            Assert.Empty(Outbox);
            Assert.Empty(HeldLocks);
        }

        public Task<IAsyncDisposable> AcquireExecutionAsync(Guid operationId, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            Assert.True(HeldLocks.Add(operationId));
            return Task.FromResult<IAsyncDisposable>(new Lease(this, operationId));
        }

        public Task<IProtectionAdminIdempotencyLease> AcquireIdempotencyAsync(
            EntraTenantId tenantId, ProtectionIdempotencyKey idempotencyKey, CancellationToken ct) =>
            throw new UnexpectedFixtureCallException("No idempotency creation is allowed during worker recovery.");

        private sealed class Lease(ProtectionFixture owner, Guid id) : IAsyncDisposable
        {
            public ValueTask DisposeAsync()
            {
                Assert.True(owner.HeldLocks.Remove(id));
                return ValueTask.CompletedTask;
            }
        }
    }

    private sealed class FixedClock : TimeProvider
    {
        public DateTimeOffset UtcNow { get; set; } = new(FixtureIds.Timestamp);
        public override DateTimeOffset GetUtcNow() => UtcNow;
    }
}
