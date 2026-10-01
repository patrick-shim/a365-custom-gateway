using Gateway.Application.Exceptions;
using Gateway.Application.Prompts;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.IntegrationTests.Fixtures;
using Gateway.TestSupport;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests;

[Collection(SqlServerCollection.Name)]
[Trait("Category", "SqlServer")]
public sealed class PromptWorkflowTests(SqlServerFixture fixture)
{
    [Fact]
    public async Task Allowed_prompt_proof_binds_real_identity_and_content_and_is_consumed_only_once()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = await SeedProtectedAgentAsync(database);
        var provider = GatewaySqlHarness.AllowingShield();
        var store = new OfflineContentStore { AllowStaging = true };
        await using var context = database.CreateContext();
        var harness = new GatewaySqlHarness(context, provider, store);
        var evaluate = GatewaySqlHarness.Evaluation(agent);
        var result = await harness.Evaluate().Handle(evaluate, default);
        Assert.True(result.Allowed);
        Assert.Equal(result.EvaluationId, result.EvaluationReceiptId);
        Assert.Equal(DateTimeKind.Utc, result.ExpiresAtUtc!.Value.Kind);
        var receipt = await context.PromptEvaluationRecords.AsNoTracking().SingleAsync();
        Assert.Equal(Guid.Parse(agent.Agent365AgentId!), receipt.Agent365AgentId);
        Assert.Equal(Guid.Parse(agent.BlueprintId!), receipt.BlueprintId);
        Assert.Equal(agent.ProtectionRevision, receipt.ProtectionRevision);
        Assert.True(PromptReceiptSecurity.Verify(receipt.PromptHashSalt, receipt.PromptHash,
            evaluate.Prompt.ContentType, evaluate.Prompt.Content));
        Assert.Null(receipt.ConsumedAtUtc);
        var subject = Assert.Single(provider.Subjects);
        Assert.Equal(agent.Id, subject.AgentRegistrationId);
        Assert.Equal(receipt.Agent365AgentId, subject.Agent365AgentId);

        var submission = GatewaySqlHarness.Interaction(agent, result.EvaluationReceiptId);
        var accepted = await harness.Submit().Handle(submission, default);
        var replay = await harness.Submit().Handle(submission, default);
        Assert.Equal(accepted, replay);
        Assert.Equal(1, store.Stores);
        Assert.Equal(1, await context.AiInteractionRecords.CountAsync());
        Assert.Equal(1, await context.OutboxMessages.CountAsync());
        Assert.Equal(1, await context.AuditEvents.CountAsync(item => item.EventType == "InteractionSubmitted"));
        Assert.NotNull((await context.PromptEvaluationRecords.AsNoTracking().SingleAsync()).ConsumedAtUtc);

        var usedProof = await Assert.ThrowsAsync<DomainException>(() =>
            harness.Submit().Handle(submission with { IdempotencyKey = "another-submission" }, default));
        Assert.Equal(ErrorCodes.PROMPT_EVALUATION_INVALID, usedProof.ErrorCode);
        var expiredReplay = await Assert.ThrowsAsync<DomainException>(() => harness.Evaluate().Handle(evaluate, default));
        Assert.Equal(ErrorCodes.PROMPT_EVALUATION_INVALID, expiredReplay.ErrorCode);
        Assert.Equal(1, provider.Calls);
        Assert.Equal(1, store.Stores);
    }

    [Theory]
    [InlineData("content")]
    [InlineData("content-type")]
    [InlineData("interaction")]
    [InlineData("user")]
    [InlineData("expired")]
    [InlineData("consumed")]
    [InlineData("feature-revision")]
    [InlineData("legacy-unbound")]
    public async Task Mismatched_stale_expired_consumed_or_legacy_proof_rejects_before_content_staging(string mutation)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = await SeedProtectedAgentAsync(database);
        Guid receiptId;
        await using (var evaluateContext = database.CreateContext())
        {
            var response = await new GatewaySqlHarness(evaluateContext, GatewaySqlHarness.AllowingShield())
                .Evaluate().Handle(GatewaySqlHarness.Evaluation(agent), default);
            receiptId = response.EvaluationReceiptId!.Value;
        }
        var request = GatewaySqlHarness.Interaction(agent, receiptId);
        switch (mutation)
        {
            case "content": request = request with { Prompt = new("text/plain", "different prompt") }; break;
            case "content-type": request = request with { Prompt = new("text/markdown", request.Prompt.Content) }; break;
            case "interaction": request = request with { InteractionId = "different-interaction" }; break;
            case "user": request = request with { UserContext = new(Guid.NewGuid().ToString("D")) }; break;
            default:
                await using (var mutate = database.CreateContext())
                {
                    if (mutation == "feature-revision")
                    {
                        var registered = await mutate.AgentRegistrations.Include(item => item.FeatureConfiguration).SingleAsync();
                        registered.FeatureConfiguration.PromptShieldEnabled = false;
                    }
                    else
                    {
                        var receipt = await mutate.PromptEvaluationRecords.SingleAsync();
                        if (mutation == "expired") receipt.ExpiresAtUtc = DateTime.UtcNow.AddHours(-1);
                        if (mutation == "consumed") receipt.ConsumedAtUtc = DateTime.UtcNow;
                        if (mutation == "legacy-unbound")
                        {
                            receipt.ProtectionRevision = null;
                            receipt.ProtectionContextHash = null;
                            receipt.PromptShieldRequired = null;
                            receipt.EvaluatedPurviewPolicyMode = null;
                        }
                    }
                    await mutate.SaveChangesAsync();
                }
                break;
        }
        await using var context = database.CreateContext();
        var store = new OfflineContentStore { AllowStaging = true };
        var exception = await Assert.ThrowsAsync<DomainException>(() =>
            new GatewaySqlHarness(context, content: store).Submit().Handle(request, default));
        Assert.Equal(ErrorCodes.PROMPT_EVALUATION_INVALID, exception.ErrorCode);
        Assert.Equal(0, store.Stores);
        Assert.Equal(0, await context.AiInteractionRecords.CountAsync());
        Assert.Equal(0, await context.OutboxMessages.CountAsync());
        Assert.Equal(1, await context.IdempotencyRecords.CountAsync());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Protected_registration_requires_a_known_successful_receipt(bool unknownId)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = await SeedProtectedAgentAsync(database);
        await using var context = database.CreateContext();
        var store = new OfflineContentStore { AllowStaging = true };
        var error = await Assert.ThrowsAsync<DomainException>(() =>
            new GatewaySqlHarness(context, content: store).Submit().Handle(
                GatewaySqlHarness.Interaction(agent, unknownId ? Guid.NewGuid() : null), default));
        Assert.Equal(unknownId ? ErrorCodes.PROMPT_EVALUATION_INVALID : ErrorCodes.PROMPT_EVALUATION_REQUIRED, error.ErrorCode);
        Assert.Equal(0, store.Stores);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Caller_registration_and_external_identity_must_agree_before_evaluation_or_ingestion(bool disable)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = await SeedProtectedAgentAsync(database);
        await using var context = database.CreateContext();
        if (disable)
        {
            (await context.AgentRegistrations.SingleAsync()).Status = AgentStatus.Disabled;
            await context.SaveChangesAsync();
        }
        var shield = GatewaySqlHarness.AllowingShield();
        var content = new OfflineContentStore { AllowStaging = true };
        var harness = new GatewaySqlHarness(context, shield, content);
        var evaluation = GatewaySqlHarness.Evaluation(agent);
        var submission = GatewaySqlHarness.Interaction(agent, null);
        if (!disable)
        {
            evaluation = evaluation with { ExternalAgentId = "another-agent" };
            submission = submission with { ExternalAgentId = "another-agent" };
        }
        var evaluateError = await Assert.ThrowsAsync<DomainException>(() => harness.Evaluate().Handle(evaluation, default));
        var submitError = await Assert.ThrowsAsync<DomainException>(() => harness.Submit().Handle(submission, default));
        var expected = disable ? ErrorCodes.AGENT_DISABLED : ErrorCodes.AGENT_IDENTITY_MISMATCH;
        Assert.Equal(expected, evaluateError.ErrorCode);
        Assert.Equal(expected, submitError.ErrorCode);
        Assert.Equal(0, shield.Calls);
        Assert.Equal(0, content.Stores);
        Assert.Equal(0, await context.PromptEvaluationRecords.CountAsync());
        Assert.Equal(0, await context.IdempotencyRecords.CountAsync());
    }

    [Fact]
    public async Task Provider_block_records_denial_but_never_issues_generation_proof()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = await SeedProtectedAgentAsync(database);
        await using var context = database.CreateContext();
        var shield = new OfflinePromptShield
        {
            IsEnabled = true,
            Evaluate = (_, _, _) => Task.FromResult(new PromptShieldEvaluationResult(true))
        };
        var result = await new GatewaySqlHarness(context, shield).Evaluate().Handle(GatewaySqlHarness.Evaluation(agent), default);
        Assert.False(result.Allowed);
        Assert.Null(result.EvaluationReceiptId);
        Assert.Null(result.ExpiresAtUtc);
        Assert.Equal(ErrorCodes.PROMPT_BLOCKED_BY_PROMPT_SHIELD, result.Decision);
        Assert.Equal(PromptEvaluationOutcome.Blocked, (await context.PromptEvaluationRecords.SingleAsync()).Outcome);
        Assert.Equal(403, (await context.IdempotencyRecords.SingleAsync()).ResponseStatusCode);
    }

    [Fact]
    public async Task Provider_failure_is_fail_closed_without_receipt_or_idempotency_result()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = await SeedProtectedAgentAsync(database);
        await using var context = database.CreateContext();
        var shield = new OfflinePromptShield
        {
            IsEnabled = true,
            Evaluate = (_, _, _) => throw new PromptShieldException("SYNTHETIC_UNAVAILABLE", "Synthetic failure")
        };
        var exception = await Assert.ThrowsAsync<DomainException>(() =>
            new GatewaySqlHarness(context, shield).Evaluate().Handle(GatewaySqlHarness.Evaluation(agent), default));
        Assert.Equal(ErrorCodes.PROMPT_EVALUATION_UNAVAILABLE, exception.ErrorCode);
        Assert.Equal(0, await context.PromptEvaluationRecords.CountAsync());
        Assert.Equal(0, await context.IdempotencyRecords.CountAsync());
        Assert.Equal(0, await context.AuditEvents.CountAsync());
    }

    [Fact]
    public async Task Failed_ingestion_rolls_back_real_receipt_consumption_and_releases_the_idempotency_lock()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = await SeedProtectedAgentAsync(database);
        Guid receiptId;
        await using (var initial = database.CreateContext())
            receiptId = (await new GatewaySqlHarness(initial, GatewaySqlHarness.AllowingShield())
                .Evaluate().Handle(GatewaySqlHarness.Evaluation(agent), default)).EvaluationReceiptId!.Value;
        await database.ExecuteAsync("""
            ALTER TABLE dbo.AuditEvents ADD CONSTRAINT CK_M1_RejectInteractionAudit
            CHECK ([EventType] <> N'InteractionSubmitted');
            """);
        var store = new OfflineContentStore { AllowStaging = true, MaximumStores = 2 };
        var request = GatewaySqlHarness.Interaction(agent, receiptId);
        await using (var failed = database.CreateContext())
        {
            var error = await Assert.ThrowsAsync<DbUpdateException>(() =>
                new GatewaySqlHarness(failed, content: store).Submit().Handle(request, default));
            Assert.Equal(547, Assert.IsType<SqlException>(error.InnerException).Number);
        }
        await using (var verify = database.CreateContext())
        {
            Assert.Null((await verify.PromptEvaluationRecords.SingleAsync()).ConsumedAtUtc);
            Assert.Equal(0, await verify.AiInteractionRecords.CountAsync());
            Assert.Equal(0, await verify.OutboxMessages.CountAsync());
            Assert.Equal(1, await verify.AuditEvents.CountAsync());
            Assert.Equal(1, await verify.IdempotencyRecords.CountAsync());
        }
        // The handler only compensates known context rejections, not arbitrary/ambiguous commit failures.
        Assert.Equal(1, store.Stores);
        Assert.Equal(0, store.Discards);
        await database.ExecuteAsync("ALTER TABLE dbo.AuditEvents DROP CONSTRAINT CK_M1_RejectInteractionAudit;");
        await using var retry = database.CreateContext();
        await new GatewaySqlHarness(retry, content: store).Submit().Handle(request, default);
        Assert.NotNull((await retry.PromptEvaluationRecords.SingleAsync()).ConsumedAtUtc);
        Assert.Equal(1, await retry.AiInteractionRecords.CountAsync());
        Assert.Equal(2, await retry.IdempotencyRecords.CountAsync());
    }

    internal static async Task<AgentRegistration> SeedProtectedAgentAsync(LocalSqlDatabase database)
    {
        await using var context = database.CreateContext();
        var agent = TestData.Agent(promptShield: true);
        agent.FeatureConfiguration.ObservabilityMode = ObservabilityMode.GatewayOnly;
        context.Add(agent);
        context.Add(TestData.ShieldCapability());
        await context.SaveChangesAsync();
        return agent;
    }
}
