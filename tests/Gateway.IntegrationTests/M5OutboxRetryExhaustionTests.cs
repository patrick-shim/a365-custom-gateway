using System.Reflection;
using System.Text.Json;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.Infrastructure.Services;
using Gateway.IntegrationTests.Fixtures;
using Gateway.TestSupport;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests;

[Collection(SqlServerCollection.Name)]
[Trait("Category", "SqlServer")]
public sealed class M5OutboxRetryExhaustionTests(SqlServerFixture fixture)
{
    [Theory]
    [InlineData(true, false)]
    [InlineData(false, false)]
    [InlineData(true, true)]
    public async Task Same_step_retry_publication_supersedes_an_unacknowledged_earlier_generation(
        bool tiedCreationTimes, bool retryAlreadyRunning)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var (operation, original) = CreatePublication(1, completedPrefix: 1);
        original.Id = Guid.Parse("ffffffff-ffff-4fff-8fff-ffffffffffff");
        original.Payload = BoundPayload(operation, 1, 0);
        await using var worker = database.CreateContext();
        worker.AddRange(operation, original);
        await worker.SaveChangesAsync();
        var step = operation.OrderedSteps[1];
        OutboxMessage retry;
        await using (await new ProtectionAdminOperationLockProvider(worker).AcquireExecutionAsync(operation.Id, default))
        {
            step.AttemptCount = 1;
            step.Status = ProtectionAdminStepStatus.Running;
            operation.AttemptCount = 1;
            operation.Status = ProtectionAdminOperationStatus.Running;
            await worker.SaveChangesAsync();

            step.Status = ProtectionAdminStepStatus.PendingPropagation;
            step.RetryDisposition = ProtectionRetryDisposition.Retryable;
            step.NextAttemptAtUtc = TestData.Now.AddMinutes(1);
            operation.Status = ProtectionAdminOperationStatus.PendingPropagation;
            operation.RetryDisposition = ProtectionRetryDisposition.Retryable;
            operation.NextAttemptAtUtc = step.NextAttemptAtUtc;
            retry = new()
            {
                Id = Guid.Parse("00000000-0000-4000-8000-000000000001"),
                MessageType = nameof(ProtectionAdminOperationMessage),
                Payload = BoundPayload(operation, 1, 1),
                Status = OutboxMessageStatus.Pending,
                CreatedAtUtc = tiedCreationTimes ? original.CreatedAtUtc : original.CreatedAtUtc.AddHours(-1),
                NextRetryAtUtc = step.NextAttemptAtUtc
            };
            worker.Add(retry);
            await worker.SaveChangesAsync();
            if (retryAlreadyRunning)
            {
                step.AttemptCount = 2;
                step.Status = ProtectionAdminStepStatus.Running;
                operation.AttemptCount = 2;
                operation.Status = ProtectionAdminOperationStatus.Running;
                await worker.SaveChangesAsync();
            }
        }
        var expectedStatus = operation.Status;
        var rowVersion = operation.RowVersion.ToArray();

        await using (var publisher = database.CreateContext())
            Assert.True(await new OutboxRepository(publisher).MarkFailedAsync(
                original.Id, original.NextRetryAtUtc!.Value, null, terminal: true, default));

        await using (var verify = database.CreateContext())
        {
            var saved = await verify.ProtectionAdminOperations.SingleAsync();
            Assert.Equal(expectedStatus, saved.Status);
            Assert.Equal(rowVersion, saved.RowVersion);
            Assert.Null(saved.LastFailureCode);
            Assert.Equal(OutboxMessageStatus.Pending,
                (await verify.OutboxMessages.SingleAsync(message => message.Id == retry.Id)).Status);
            Assert.Equal(OutboxMessageStatus.Failed,
                (await verify.OutboxMessages.SingleAsync(message => message.Id == original.Id)).Status);
        }

        await using (var publisher = database.CreateContext())
        {
            var repository = new OutboxRepository(publisher);
            var claimed = Assert.Single(await repository.ClaimPendingAsync(
                1, TestData.Now.AddMinutes(2), TestData.Now.AddMinutes(3), default));
            Assert.Equal(retry.Id, claimed.Id);
            Assert.True(await repository.MarkFailedAsync(
                claimed.Id, claimed.NextRetryAtUtc!.Value, null, terminal: true, default));
        }
        await using var final = database.CreateContext();
        Assert.Equal(ProtectionAdminOperationStatus.Failed, (await final.ProtectionAdminOperations.SingleAsync()).Status);
        Assert.All(await final.OutboxMessages.ToArrayAsync(), message => Assert.Equal(OutboxMessageStatus.Failed, message.Status));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(null)]
    public async Task Non_sql_admission_refreshes_a_tracked_attempt_before_deciding_its_generation(int? expectedAttemptCount)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var (operation, publication) = CreatePublication(1, completedPrefix: 1);
        await using (var seed = database.CreateContext())
        {
            seed.AddRange(operation, publication);
            await seed.SaveChangesAsync();
        }
        await using var relay = database.CreateContext();
        var tracked = await relay.ProtectionAdminOperations.Include("_steps").SingleAsync();
        Assert.Equal(0, tracked.OrderedSteps[1].AttemptCount);
        await using (var worker = database.CreateContext())
        await using (await new ProtectionAdminOperationLockProvider(worker).AcquireExecutionAsync(operation.Id, default))
        {
            var current = await worker.ProtectionAdminOperations.Include("_steps").SingleAsync();
            current.AttemptCount = 1;
            current.Status = ProtectionAdminOperationStatus.PendingPropagation;
            current.OrderedSteps[1].AttemptCount = 1;
            current.OrderedSteps[1].Status = ProtectionAdminStepStatus.PendingPropagation;
            await worker.SaveChangesAsync();
        }

        // Exercise the fallback's tracked-entity admission on real SQL without
        // adding a second EF provider or claiming an InMemory transaction test.
        await using (await new ProtectionAdminOperationLockProvider(relay).AcquireExecutionAsync(operation.Id, default))
        {
            var repository = new OutboxRepository(relay);
            var method = typeof(OutboxRepository).GetMethod(
                "TryApplyProtectionTerminalFailureAsync", BindingFlags.Instance | BindingFlags.NonPublic)!;
            var admission = (Task<bool>)method.Invoke(repository,
            [
                new ProtectionAdminOperationMessage(
                    operation.Id, operation.WorkflowVersion, 1, operation.CorrelationId, expectedAttemptCount),
                CancellationToken.None
            ])!;
            if (expectedAttemptCount is null)
            {
                var error = await Assert.ThrowsAsync<InvalidOperationException>(() => admission);
                Assert.Contains("PROTECTION_ADMIN_PUBLICATION_GENERATION_UNBOUND", error.Message);
            }
            else
            {
                Assert.True(await admission);
            }
            Assert.Equal(1, tracked.OrderedSteps[1].AttemptCount);
            Assert.Equal(expectedAttemptCount == 1 ? ProtectionAdminOperationStatus.Failed :
                ProtectionAdminOperationStatus.PendingPropagation, tracked.Status);
            await relay.SaveChangesAsync();
        }

        await using var verify = database.CreateContext();
        Assert.Equal(expectedAttemptCount == 1 ? ProtectionAdminOperationStatus.Failed :
            ProtectionAdminOperationStatus.PendingPropagation, (await verify.ProtectionAdminOperations.SingleAsync()).Status);
    }

    [Theory]
    [InlineData(false, 0)]
    [InlineData(true, 0)]
    [InlineData(false, 1)]
    [InlineData(true, 1)]
    public async Task Unbound_publication_exhaustion_reports_unknown_without_terminalizing_the_operation(
        bool explicitNull, int attemptCount)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var (operation, publication) = CreatePublication(1, completedPrefix: 1);
        publication.Payload = explicitNull
            ? BoundPayload(operation, 1, null)
            : JsonSerializer.Serialize(new
            {
                OperationId = operation.Id,
                operation.WorkflowVersion,
                ExpectedStepIndex = 1,
                operation.CorrelationId
            });
        operation.Status = attemptCount == 0
            ? ProtectionAdminOperationStatus.Pending : ProtectionAdminOperationStatus.PendingPropagation;
        operation.AttemptCount = attemptCount;
        operation.OrderedSteps[1].Status = attemptCount == 0
            ? ProtectionAdminStepStatus.Pending : ProtectionAdminStepStatus.PendingPropagation;
        operation.OrderedSteps[1].AttemptCount = attemptCount;
        var boundRetry = new OutboxMessage
        {
            Id = Guid.NewGuid(), MessageType = nameof(ProtectionAdminOperationMessage),
            Payload = BoundPayload(operation, 1, attemptCount),
            Status = OutboxMessageStatus.Pending, CreatedAtUtc = publication.CreatedAtUtc
        };
        await using (var seed = database.CreateContext())
        {
            seed.AddRange(operation, publication, boundRetry);
            await seed.SaveChangesAsync();
        }

        await using (var publisher = database.CreateContext())
        {
            var error = await Assert.ThrowsAsync<InvalidOperationException>(() => new OutboxRepository(publisher)
                .MarkFailedAsync(publication.Id, publication.NextRetryAtUtc!.Value, null, terminal: true, default));
            Assert.Contains("PROTECTION_ADMIN_PUBLICATION_GENERATION_UNBOUND", error.Message);
            Assert.Null(publisher.Database.CurrentTransaction);
        }

        await using var verify = database.CreateContext();
        Assert.Equal(operation.Status, (await verify.ProtectionAdminOperations.SingleAsync()).Status);
        var unresolved = await verify.OutboxMessages.SingleAsync(message => message.Id == publication.Id);
        Assert.Equal(OutboxMessageStatus.Processing, unresolved.Status);
        Assert.Equal(publication.RetryCount, unresolved.RetryCount);
        Assert.Equal(publication.NextRetryAtUtc, unresolved.NextRetryAtUtc);
        Assert.Equal(OutboxMessageStatus.Pending,
            (await verify.OutboxMessages.SingleAsync(message => message.Id == boundRetry.Id)).Status);
    }

    [Theory]
    [InlineData(0, 1, false)]
    [InlineData(0, 1, true)]
    [InlineData(1, 0, false)]
    [InlineData(7, 8, true)]
    public async Task Old_future_or_finished_publication_cannot_terminalize_another_step(
        int expectedStep, int completedPrefix, bool camelCase)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var (operation, publication) = CreatePublication(expectedStep, completedPrefix, camelCase);
        await using (var seed = database.CreateContext())
        {
            seed.AddRange(operation, publication);
            await seed.SaveChangesAsync();
        }
        var rowVersion = operation.RowVersion.ToArray();

        await using (var writer = database.CreateContext())
            Assert.True(await new OutboxRepository(writer).MarkFailedAsync(
                publication.Id, publication.NextRetryAtUtc!.Value, null, terminal: true, default));

        await using var verify = database.CreateContext();
        var saved = await verify.ProtectionAdminOperations.SingleAsync();
        Assert.Equal(ProtectionAdminOperationStatus.Pending, saved.Status);
        Assert.Equal(rowVersion, saved.RowVersion);
        Assert.Null(saved.LastFailureCode);
        Assert.Equal(completedPrefix, await verify.ProtectionAdminOperationSteps.CountAsync(
            step => step.Status == ProtectionAdminStepStatus.Completed));
        Assert.Equal(OutboxMessageStatus.Failed, (await verify.OutboxMessages.SingleAsync()).Status);
    }

    [Theory]
    [InlineData(ProtectionAdminOperationStatus.Completed, false)]
    [InlineData(ProtectionAdminOperationStatus.Failed, false)]
    [InlineData(ProtectionAdminOperationStatus.RequiresManualIntervention, false)]
    [InlineData(ProtectionAdminOperationStatus.Cancelled, false)]
    [InlineData(ProtectionAdminOperationStatus.AwaitingAdministrator, false)]
    [InlineData(ProtectionAdminOperationStatus.Completed, true)]
    [InlineData(ProtectionAdminOperationStatus.Failed, true)]
    [InlineData(ProtectionAdminOperationStatus.RequiresManualIntervention, true)]
    [InlineData(ProtectionAdminOperationStatus.Cancelled, true)]
    [InlineData(ProtectionAdminOperationStatus.AwaitingAdministrator, true)]
    public async Task Exhausted_publication_preserves_terminal_and_nonworker_operation_states(
        ProtectionAdminOperationStatus status, bool unbound)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var (operation, publication) = CreatePublication(0, expectedAttemptCount: unbound ? null : 0);
        operation.Status = status;
        operation.LastFailureCode = "SYNTHETIC_ORIGINAL_STATUS";
        await using (var seed = database.CreateContext())
        {
            seed.AddRange(operation, publication);
            await seed.SaveChangesAsync();
        }
        var rowVersion = operation.RowVersion.ToArray();

        await using (var writer = database.CreateContext())
            Assert.True(await new OutboxRepository(writer).MarkFailedAsync(
                publication.Id, publication.NextRetryAtUtc!.Value, null, terminal: true, default));

        await using var verify = database.CreateContext();
        var saved = await verify.ProtectionAdminOperations.SingleAsync();
        Assert.Equal(status, saved.Status);
        Assert.Equal("SYNTHETIC_ORIGINAL_STATUS", saved.LastFailureCode);
        Assert.Equal(rowVersion, saved.RowVersion);
        Assert.Equal(OutboxMessageStatus.Failed, (await verify.OutboxMessages.SingleAsync()).Status);
    }

    [Theory]
    [InlineData(ProtectionAdminOperationStatus.Pending)]
    [InlineData(ProtectionAdminOperationStatus.Running)]
    [InlineData(ProtectionAdminOperationStatus.PendingPropagation)]
    public async Task Exact_current_publication_exhaustion_atomically_fails_the_operation_once(
        ProtectionAdminOperationStatus status)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var (operation, publication) = CreatePublication(1, completedPrefix: 1,
            expectedAttemptCount: status == ProtectionAdminOperationStatus.PendingPropagation ? 1 : 0);
        operation.Status = status;
        operation.OrderedSteps[0].Status = ProtectionAdminStepStatus.Skipped;
        operation.OrderedSteps[1].Status = status switch
        {
            ProtectionAdminOperationStatus.Running => ProtectionAdminStepStatus.Running,
            ProtectionAdminOperationStatus.PendingPropagation => ProtectionAdminStepStatus.PendingPropagation,
            _ => ProtectionAdminStepStatus.Pending
        };
        operation.OrderedSteps[1].AttemptCount = status == ProtectionAdminOperationStatus.Pending ? 0 : 1;
        operation.AttemptCount = operation.OrderedSteps[1].AttemptCount;
        await using (var seed = database.CreateContext())
        {
            seed.AddRange(operation, publication);
            await seed.SaveChangesAsync();
        }

        await using (var writer = database.CreateContext())
        {
            var repository = new OutboxRepository(writer);
            Assert.True(await repository.MarkFailedAsync(
                publication.Id, publication.NextRetryAtUtc!.Value, null, terminal: true, default));
            Assert.False(await repository.MarkFailedAsync(
                publication.Id, publication.NextRetryAtUtc.Value, null, terminal: true, default));
        }

        await using var verify = database.CreateContext();
        var saved = await verify.ProtectionAdminOperations.SingleAsync();
        Assert.Equal(ProtectionAdminOperationStatus.Failed, saved.Status);
        Assert.Equal(ProtectionRetryDisposition.Exhausted, saved.RetryDisposition);
        Assert.Equal("PROTECTION_ADMIN_OUTBOX_PUBLISH_FAILED", saved.LastFailureCode);
        Assert.Equal("ReviewOperationFailure", saved.RequiredAction);
        Assert.Null(saved.NextAttemptAtUtc);
        var failed = await verify.OutboxMessages.SingleAsync();
        Assert.Equal(OutboxMessageStatus.Failed, failed.Status);
        Assert.Equal(publication.RetryCount + 1, failed.RetryCount);
        Assert.Null(failed.NextRetryAtUtc);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Exhaustion_waits_for_execution_lock_then_reads_the_committed_advancement(bool sameStepRetry)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var (operation, publication) = CreatePublication(0);
        await using var executing = database.CreateContext();
        executing.AddRange(operation, publication);
        await executing.SaveChangesAsync();
        await using var publisher = database.CreateContext();
        Task<bool> exhausted;
        OutboxMessage next;
        await using (await new ProtectionAdminOperationLockProvider(executing).AcquireExecutionAsync(operation.Id, default))
        {
            exhausted = new OutboxRepository(publisher).MarkFailedAsync(
                publication.Id, publication.NextRetryAtUtc!.Value, null, terminal: true, default);
            await database.WaitForApplicationLockWaitAsync();
            Assert.False(exhausted.IsCompleted);
            operation.OrderedSteps[0].Status = sameStepRetry
                ? ProtectionAdminStepStatus.PendingPropagation : ProtectionAdminStepStatus.Completed;
            operation.OrderedSteps[0].AttemptCount = 1;
            operation.AttemptCount = 1;
            operation.Status = sameStepRetry
                ? ProtectionAdminOperationStatus.PendingPropagation : ProtectionAdminOperationStatus.Pending;
            next = new()
            {
                Id = Guid.NewGuid(), MessageType = nameof(ProtectionAdminOperationMessage),
                Payload = JsonSerializer.Serialize(new ProtectionAdminOperationMessage(
                    operation.Id, operation.WorkflowVersion, sameStepRetry ? 0 : 1, operation.CorrelationId,
                    sameStepRetry ? 1 : 0)),
                Status = OutboxMessageStatus.Pending, CreatedAtUtc = TestData.Now
            };
            executing.Add(next);
            await executing.SaveChangesAsync();
        }

        Assert.True(await exhausted.WaitAsync(TimeSpan.FromSeconds(10)));

        await using var verify = database.CreateContext();
        var saved = await verify.ProtectionAdminOperations.SingleAsync();
        Assert.Equal(operation.Status, saved.Status);
        Assert.Null(saved.LastFailureCode);
        Assert.Equal(ProtectionAdminStepStatus.Pending,
            (await verify.ProtectionAdminOperationSteps.SingleAsync(step => step.OrderIndex == 1)).Status);
        Assert.Equal(OutboxMessageStatus.Pending,
            (await verify.OutboxMessages.SingleAsync(message => message.Id == next.Id)).Status);
        Assert.Equal(OutboxMessageStatus.Failed,
            (await verify.OutboxMessages.SingleAsync(message => message.Id == publication.Id)).Status);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Advancing_to_another_step_preserves_new_work_when_both_old_generations_exhaust(bool unbound)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var (operation, original) = CreatePublication(1, completedPrefix: 2,
            expectedAttemptCount: unbound ? null : 0);
        operation.OrderedSteps[1].AttemptCount = 2;
        operation.AttemptCount = 2;
        var retry = new OutboxMessage
        {
            Id = Guid.NewGuid(), MessageType = nameof(ProtectionAdminOperationMessage),
            Payload = BoundPayload(operation, 1, unbound ? null : 1), Status = OutboxMessageStatus.Processing,
            NextRetryAtUtc = original.NextRetryAtUtc, CreatedAtUtc = original.CreatedAtUtc
        };
        var advanced = new OutboxMessage
        {
            Id = Guid.NewGuid(), MessageType = nameof(ProtectionAdminOperationMessage),
            Payload = BoundPayload(operation, 2, 0), Status = OutboxMessageStatus.Pending,
            CreatedAtUtc = original.CreatedAtUtc
        };
        await using (var seed = database.CreateContext())
        {
            seed.AddRange(operation, original, retry, advanced);
            await seed.SaveChangesAsync();
        }
        var rowVersion = operation.RowVersion.ToArray();

        await using (var publisher = database.CreateContext())
        {
            var repository = new OutboxRepository(publisher);
            Assert.True(await repository.MarkFailedAsync(original.Id, original.NextRetryAtUtc!.Value, null, true, default));
            Assert.True(await repository.MarkFailedAsync(retry.Id, retry.NextRetryAtUtc!.Value, null, true, default));
        }

        await using var verify = database.CreateContext();
        var saved = await verify.ProtectionAdminOperations.SingleAsync();
        Assert.Equal(ProtectionAdminOperationStatus.Pending, saved.Status);
        Assert.Equal(rowVersion, saved.RowVersion);
        Assert.Equal(OutboxMessageStatus.Pending,
            (await verify.OutboxMessages.SingleAsync(message => message.Id == advanced.Id)).Status);
        Assert.Equal(2, await verify.OutboxMessages.CountAsync(message => message.Status == OutboxMessageStatus.Failed));
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(8)]
    public async Task Invalid_step_coordinates_cannot_authorize_terminal_propagation(int expectedStep)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var (operation, publication) = CreatePublication(expectedStep);
        await using (var seed = database.CreateContext())
        {
            seed.AddRange(operation, publication);
            await seed.SaveChangesAsync();
        }

        await using (var writer = database.CreateContext())
            Assert.False(await new OutboxRepository(writer).MarkFailedAsync(
                publication.Id, publication.NextRetryAtUtc!.Value, null, terminal: true, default));

        await using var verify = database.CreateContext();
        Assert.Equal(ProtectionAdminOperationStatus.Pending, (await verify.ProtectionAdminOperations.SingleAsync()).Status);
        Assert.Equal(OutboxMessageStatus.Processing, (await verify.OutboxMessages.SingleAsync()).Status);
    }

    [Fact]
    public async Task Lost_publication_claim_cannot_change_the_operation()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var (operation, publication) = CreatePublication(0);
        await using (var seed = database.CreateContext())
        {
            seed.AddRange(operation, publication);
            await seed.SaveChangesAsync();
        }

        await using (var writer = database.CreateContext())
            Assert.False(await new OutboxRepository(writer).MarkFailedAsync(
                publication.Id, publication.NextRetryAtUtc!.Value.AddTicks(1), null, terminal: true, default));

        await using var verify = database.CreateContext();
        Assert.Equal(ProtectionAdminOperationStatus.Pending, (await verify.ProtectionAdminOperations.SingleAsync()).Status);
        Assert.Equal(OutboxMessageStatus.Processing, (await verify.OutboxMessages.SingleAsync()).Status);
    }

    [Fact]
    public async Task Claim_lost_while_waiting_for_execution_is_rechecked_before_any_terminal_write()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var (operation, publication) = CreatePublication(0);
        await using var executing = database.CreateContext();
        executing.AddRange(operation, publication);
        await executing.SaveChangesAsync();
        await using var publisher = database.CreateContext();
        Task<bool> exhausted;
        await using (await new ProtectionAdminOperationLockProvider(executing).AcquireExecutionAsync(operation.Id, default))
        {
            exhausted = new OutboxRepository(publisher).MarkFailedAsync(
                publication.Id, publication.NextRetryAtUtc!.Value, null, terminal: true, default);
            await database.WaitForApplicationLockWaitAsync();
            await using var acknowledgement = database.CreateContext();
            Assert.True(await new OutboxRepository(acknowledgement).MarkPublishedAsync(
                publication.Id, publication.NextRetryAtUtc.Value, TestData.Now, default));
        }

        Assert.False(await exhausted.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Null(publisher.Database.CurrentTransaction);
        await using var verify = database.CreateContext();
        Assert.Equal(ProtectionAdminOperationStatus.Pending, (await verify.ProtectionAdminOperations.SingleAsync()).Status);
        Assert.Equal(OutboxMessageStatus.Published, (await verify.OutboxMessages.SingleAsync()).Status);
    }

    [Fact]
    public async Task Failed_outbox_write_rolls_back_the_operation_terminalization()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var (operation, publication) = CreatePublication(0);
        await using (var seed = database.CreateContext())
        {
            seed.AddRange(operation, publication);
            await seed.SaveChangesAsync();
            await seed.Database.ExecuteSqlRawAsync("""
                ALTER TABLE dbo.OutboxMessages
                ADD CONSTRAINT CK_M5Fixture_RejectFailedOutbox CHECK ([Status] <> N'Failed');
                """);
        }
        var rowVersion = operation.RowVersion.ToArray();

        await using (var writer = database.CreateContext())
        {
            var error = await Assert.ThrowsAsync<SqlException>(() => new OutboxRepository(writer).MarkFailedAsync(
                publication.Id, publication.NextRetryAtUtc!.Value, null, terminal: true, default));
            Assert.Equal(547, error.Number);
            Assert.Null(writer.Database.CurrentTransaction);
        }

        await using var verify = database.CreateContext();
        var saved = await verify.ProtectionAdminOperations.SingleAsync();
        Assert.Equal(ProtectionAdminOperationStatus.Pending, saved.Status);
        Assert.Equal(rowVersion, saved.RowVersion);
        Assert.Null(saved.LastFailureCode);
        var unchanged = await verify.OutboxMessages.SingleAsync();
        Assert.Equal(OutboxMessageStatus.Processing, unchanged.Status);
        Assert.Equal(publication.RetryCount, unchanged.RetryCount);
        Assert.Equal(publication.NextRetryAtUtc, unchanged.NextRetryAtUtc);
    }

    [Fact]
    public async Task Ordinary_queue_publication_still_terminalizes_without_a_protection_operation()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var (_, publication) = CreatePublication(0);
        publication.MessageType = "ProvisionAgent";
        publication.Payload = "{}";
        await using (var seed = database.CreateContext())
        {
            seed.Add(publication);
            await seed.SaveChangesAsync();
        }

        await using (var writer = database.CreateContext())
            Assert.True(await new OutboxRepository(writer).MarkFailedAsync(
                publication.Id, publication.NextRetryAtUtc!.Value, null, terminal: true, default));

        await using var verify = database.CreateContext();
        Assert.Empty(await verify.ProtectionAdminOperations.ToArrayAsync());
        var failed = await verify.OutboxMessages.SingleAsync();
        Assert.Equal(OutboxMessageStatus.Failed, failed.Status);
        Assert.Equal(publication.RetryCount + 1, failed.RetryCount);
        Assert.Null(failed.NextRetryAtUtc);
    }

    private static (ProtectionAdminOperation Operation, OutboxMessage Publication) CreatePublication(
        int expectedStep, int completedPrefix = 0, bool camelCase = false, int? expectedAttemptCount = 0)
    {
        var operation = new ProtectionAdminOperation
        {
            Id = Guid.NewGuid(), WorkflowVersion = ProtectionAdminWorkflow.CurrentVersion,
            Type = ProtectionAdminOperationType.ConnectPurviewTenant, Status = ProtectionAdminOperationStatus.Pending,
            TenantId = new(Guid.NewGuid()), ActorObjectId = TestData.Caller,
            TargetType = ProtectionAdminTargetType.PurviewTenantConnection, TargetIdentifier = Guid.NewGuid().ToString("D"),
            ReviewedPayloadHash = "sha256:" + new string('a', 64), IdempotencyKey = new(Guid.NewGuid()),
            MaximumAttempts = 5, CorrelationId = Guid.NewGuid(), CreatedAtUtc = TestData.Now, UpdatedAtUtc = TestData.Now
        };
        foreach (var (stepType, index) in ProtectionAdminWorkflow.CurrentSteps.Select((step, index) => (step, index)))
            operation.AddStep(new()
            {
                Id = Guid.NewGuid(), StepType = stepType, OrderIndex = index,
                Status = index < completedPrefix ? ProtectionAdminStepStatus.Completed : ProtectionAdminStepStatus.Pending
            });
        return (operation, new()
        {
            Id = Guid.NewGuid(), MessageType = nameof(ProtectionAdminOperationMessage),
            Payload = JsonSerializer.Serialize(new ProtectionAdminOperationMessage(
                operation.Id, operation.WorkflowVersion, expectedStep, operation.CorrelationId, expectedAttemptCount),
                new JsonSerializerOptions { PropertyNamingPolicy = camelCase ? JsonNamingPolicy.CamelCase : null }),
            Status = OutboxMessageStatus.Processing, RetryCount = 4,
            NextRetryAtUtc = TestData.Now.AddMinutes(1), CreatedAtUtc = TestData.Now
        });
    }

    private static string BoundPayload(ProtectionAdminOperation operation, int step, int? attempt) =>
        JsonSerializer.Serialize(new
        {
            OperationId = operation.Id,
            operation.WorkflowVersion,
            ExpectedStepIndex = step,
            operation.CorrelationId,
            ExpectedStepAttemptCount = attempt
        });
}
