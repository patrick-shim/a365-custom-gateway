using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Domain.Enums;
using Gateway.IntegrationTests.Fixtures;
using Gateway.TestSupport;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests;

[Collection(SqlServerCollection.Name)]
[Trait("Category", "SqlServer")]
public sealed class ProtectionReadinessTests(SqlServerFixture fixture)
{
    [Theory]
    [InlineData("missing")]
    [InlineData("unavailable")]
    [InlineData("unverified")]
    [InlineData("wrong-identity")]
    [InlineData("exact")]
    public async Task Requested_Prompt_Shields_are_effective_only_with_real_exact_installed_binding(string state)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var context = database.CreateContext();
        var agent = TestData.Agent(promptShield: true);
        context.Add(agent);
        if (state != "missing")
        {
            var capability = TestData.ShieldCapability();
            if (state == "unavailable") capability.Status = ProtectionCapabilityStatus.Unavailable;
            if (state == "unverified") capability.LastReadbackAtUtc = null;
            if (state == "wrong-identity")
                capability.ResourceIdentifiers = capability.ResourceIdentifiers with
                {
                    GatewayApiManagedIdentityPrincipalObjectId = new(Guid.NewGuid())
                };
            context.Add(capability);
        }
        await context.SaveChangesAsync();
        var provider = new OfflinePromptShield { IsEnabled = true };
        var harness = new GatewaySqlHarness(context, provider);
        var features = await harness.Protection.ToDtoAsync(agent, default);
        Assert.Equal(true, features.PromptShieldEnabled);
        Assert.Equal(state == "exact", features.PromptShieldEffectivelyEnabled);
        if (state == "exact")
            await harness.Protection.EnsurePromptShieldReadyAsync(default);
        else
        {
            var error = await Assert.ThrowsAsync<DomainException>(() =>
                harness.Evaluate().Handle(GatewaySqlHarness.Evaluation(agent), default));
            Assert.Equal(ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE, error.ErrorCode);
        }
        Assert.Equal(0, provider.Calls);
        Assert.Equal(0, await context.PromptEvaluationRecords.CountAsync());
    }

    [Fact]
    public async Task Missing_Purview_readiness_neither_claims_effective_enforcement_nor_silently_turns_requested_enforcement_off()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var context = database.CreateContext();
        var agent = TestData.Agent(purview: true);
        context.Add(agent);
        await context.SaveChangesAsync();
        var harness = new GatewaySqlHarness(context);
        var features = await harness.Protection.ToDtoAsync(agent, default);
        Assert.Equal(true, features.PurviewEnabled);
        Assert.False(features.PurviewEffectivelyEnabled);
        Assert.Equal(PurviewPolicyMode.Enforce, await harness.Protection.GetRuntimePolicyModeAsync(agent, default));
        var error = await Assert.ThrowsAsync<DomainException>(() => harness.Protection.EnsureRuntimeReadyAsync(agent, default));
        Assert.Equal(ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE, error.ErrorCode);
    }

    [Fact]
    public async Task Updating_shared_blueprint_policy_invalidates_proof_for_each_child_without_rewriting_their_requests()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var profile = await PersistenceInvariantTests.SeedProfileAsync(database);
        var first = TestData.Agent(promptShield: true, purview: true);
        var sibling = TestData.Agent(promptShield: true, purview: true);
        first.BlueprintId = sibling.BlueprintId = profile.BlueprintApplicationId.Value.ToString("D");
        first.RequestedPurviewPolicyMode = sibling.RequestedPurviewPolicyMode = PurviewPolicyMode.SimulationWithTips;
        await using (var seed = database.CreateContext())
        {
            var saved = await seed.PurviewDlpProfiles.SingleAsync();
            saved.PolicyMode = PurviewPolicyMode.SimulationWithTips;
            saved.Mode = PurviewMode.AuditOnly;
            saved.Status = PurviewDlpProfileStatus.SimulationReady;
            seed.AddRange(first, sibling, TestData.ShieldCapability());
            await seed.SaveChangesAsync();
        }
        var receipts = new Dictionary<Guid, Guid>();
        foreach (var agent in new[] { first, sibling })
        {
            await using var evaluate = database.CreateContext();
            var result = await new GatewaySqlHarness(evaluate, GatewaySqlHarness.AllowingShield()).Evaluate()
                .Handle(GatewaySqlHarness.Evaluation(agent), default);
            Assert.True(result.Allowed);
            Assert.Equal("SimulationUnavailable", result.PurviewProcessing);
            receipts[agent.Id] = result.EvaluationReceiptId!.Value;
        }
        await using (var change = database.CreateContext())
        {
            (await change.PurviewDlpProfiles.SingleAsync()).PolicyMode = PurviewPolicyMode.SimulationWithoutTips;
            await change.SaveChangesAsync();
        }
        foreach (var agent in new[] { first, sibling })
        {
            await using var submit = database.CreateContext();
            var store = new OfflineContentStore { AllowStaging = true };
            var harness = new GatewaySqlHarness(submit, content: store);
            Assert.Equal(PurviewPolicyMode.SimulationWithoutTips, await harness.Protection.GetRuntimePolicyModeAsync(agent, default));
            var error = await Assert.ThrowsAsync<DomainException>(() => harness.Submit().Handle(
                GatewaySqlHarness.Interaction(agent, receipts[agent.Id]), default));
            Assert.Equal(ErrorCodes.PROMPT_EVALUATION_INVALID, error.ErrorCode);
            Assert.Equal(0, store.Stores);
        }
    }
}
