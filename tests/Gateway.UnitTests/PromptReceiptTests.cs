using Gateway.Application.Common;
using Gateway.Application.Interactions.Commands;
using Gateway.Application.Prompts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.TestSupport;

namespace Gateway.UnitTests;

public sealed class PromptReceiptTests
{
    [Fact]
    public void Receipt_digest_is_salted_and_binds_exact_content_and_content_type()
    {
        const string content = "Synthetic café prompt\r\nsecond line";
        var first = PromptReceiptSecurity.Create("text/plain", content);
        var second = PromptReceiptSecurity.Create("text/plain", content);
        Assert.Equal(32, first.Salt.Length);
        Assert.Equal(32, first.Hash.Length);
        Assert.NotEqual(first.Salt, second.Salt);
        Assert.NotEqual(first.Hash, second.Hash);
        Assert.True(PromptReceiptSecurity.Verify(first.Salt, first.Hash, "text/plain", content));
        Assert.False(PromptReceiptSecurity.Verify(first.Salt, first.Hash, "text/markdown", content));
        Assert.False(PromptReceiptSecurity.Verify(first.Salt, first.Hash, "text/plain", content + " "));
        Assert.False(PromptReceiptSecurity.Verify(first.Salt, first.Hash, "text/plain", content.Replace("\r\n", "\n")));
        Assert.False(PromptReceiptSecurity.Verify(second.Salt, first.Hash, "text/plain", content));
    }

    [Theory]
    [InlineData(false, PurviewPolicyMode.Disabled, false)]
    [InlineData(false, PurviewPolicyMode.SimulationWithTips, false)]
    [InlineData(false, PurviewPolicyMode.SimulationWithoutTips, false)]
    [InlineData(false, PurviewPolicyMode.Enforce, true)]
    [InlineData(true, PurviewPolicyMode.Disabled, true)]
    [InlineData(true, PurviewPolicyMode.SimulationWithTips, true)]
    public void Enforcement_and_Prompt_Shields_independently_require_proof(
        bool shield, PurviewPolicyMode mode, bool required)
    {
        var agent = TestData.Agent(shield, mode != PurviewPolicyMode.Disabled);
        agent.RequestedPurviewPolicyMode = mode;
        Assert.Equal(required, PromptProtectionContext.Capture(agent).RequiresReceipt);
    }

    [Theory]
    [InlineData("expired")]
    [InlineData("consumed")]
    [InlineData("revision")]
    [InlineData("context")]
    [InlineData("other-agent")]
    [InlineData("blocked")]
    [InlineData("shield-not-allowed")]
    [InlineData("purview-not-allowed")]
    [InlineData("unbound")]
    public void Receipt_requires_current_unconsumed_allowed_exact_binding(string mutation)
    {
        var agent = TestData.Agent(promptShield: true, purview: true);
        var context = PromptProtectionContext.Capture(agent);
        var receipt = BoundReceipt(context);
        Assert.True(context.MatchesReceipt(receipt, TestData.Now));
        switch (mutation)
        {
            case "expired": receipt.ExpiresAtUtc = TestData.Now; break;
            case "consumed": receipt.ConsumedAtUtc = TestData.Now; break;
            case "revision": receipt.ProtectionRevision = Guid.NewGuid(); break;
            case "context": receipt.ProtectionContextHash = new string('b', 64); break;
            case "other-agent": receipt.AgentRegistrationId = Guid.NewGuid(); break;
            case "blocked": receipt.Outcome = PromptEvaluationOutcome.Blocked; break;
            case "shield-not-allowed": receipt.PromptShieldDecision = PromptShieldDecisionType.Disabled; break;
            case "purview-not-allowed": receipt.PurviewDecision = PurviewDecisionType.Blocked; break;
            case "unbound": receipt.ProtectionRevision = null; break;
        }
        Assert.False(context.MatchesReceipt(receipt, TestData.Now));
    }

    [Fact]
    public void Shared_blueprint_does_not_allow_another_child_to_use_proof()
    {
        var first = TestData.Agent(promptShield: true);
        var sibling = TestData.Agent(promptShield: true);
        sibling.BlueprintId = first.BlueprintId;
        var context = PromptProtectionContext.Capture(first);
        var otherContext = PromptProtectionContext.Capture(sibling);
        Assert.False(otherContext.MatchesReceipt(BoundReceipt(context), TestData.Now));
        Assert.False(context.MatchesAgent(sibling));
    }

    [Fact]
    public void Effective_policy_deadline_is_the_earliest_and_equality_is_expired()
    {
        var agent = TestData.Agent(purview: true);
        var profile = TestData.ReadyProfile();
        agent.BlueprintId = profile.BlueprintApplicationId.Value.ToString("D");
        profile.SensitiveInformationTypeSnapshotExpiresAtUtc = TestData.Now.AddMinutes(3);
        var context = PromptProtectionContext.Capture(agent, profile);
        Assert.Equal(TestData.Now.AddMinutes(3), context.ValidUntilUtc);
        Assert.True(context.IsCurrentAt(TestData.Now.AddMinutes(3).AddTicks(-1)));
        Assert.False(context.IsCurrentAt(TestData.Now.AddMinutes(3)));
    }

    [Fact]
    public void Identity_feature_status_and_revision_changes_invalidate_context()
    {
        Action<AgentRegistration>[] changes =
        [
            agent => agent.Agent365AgentId = Guid.NewGuid().ToString("D"),
            agent => agent.BlueprintId = Guid.NewGuid().ToString("D"),
            agent => agent.ProtectionRevision = Guid.NewGuid(),
            agent => agent.FeatureConfiguration.PromptShieldEnabled = true,
            agent => agent.FeatureConfiguration.PurviewEnabled = true,
            agent => agent.Status = AgentStatus.Disabled,
            agent => agent.IsDeleted = true
        ];
        foreach (var change in changes)
        {
            var agent = TestData.Agent();
            var context = PromptProtectionContext.Capture(agent);
            change(agent);
            Assert.False(context.MatchesAgent(agent));
        }
    }

    [Fact]
    public void Interaction_idempotency_hash_is_metadata_order_independent_but_includes_receipt_and_response()
    {
        var request = new SubmitInteractionCommand("agent-test", "interaction-1", null, TestData.Now,
            null, new("text/plain", "prompt"), new("text/plain", "response"), null,
            new() { ["b"] = "2", ["a"] = "1" }, Guid.NewGuid(), "key", Guid.NewGuid());
        var hash = IdempotencyRequestHasher.Compute(request);
        Assert.Equal(hash, IdempotencyRequestHasher.Compute(request with
        {
            Metadata = new() { ["a"] = "1", ["b"] = "2" }, IdempotencyKey = "another-key"
        }));
        Assert.NotEqual(hash, IdempotencyRequestHasher.Compute(request with { PromptEvaluationReceiptId = Guid.NewGuid() }));
        Assert.NotEqual(hash, IdempotencyRequestHasher.Compute(request with { Response = new("text/plain", "different") }));
    }

    private static PromptEvaluationRecord BoundReceipt(PromptProtectionContext context) => new()
    {
        Id = Guid.NewGuid(),
        AgentRegistrationId = context.AgentRegistrationId,
        ProtectionRevision = context.ProtectionRevision,
        ProtectionContextHash = context.Hash,
        PromptShieldRequired = context.PromptShieldRequired,
        EvaluatedPurviewPolicyMode = context.PurviewMode,
        Outcome = PromptEvaluationOutcome.Allowed,
        PromptShieldDecision = PromptShieldDecisionType.Allowed,
        PurviewDecision = PurviewDecisionType.Allowed,
        ExpiresAtUtc = TestData.Now.AddMinutes(5)
    };
}
