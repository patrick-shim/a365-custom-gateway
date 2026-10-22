using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;

static class ProtectionContextRefreshChecks
{
    public static void Run()
    {
        var now = DateTime.UtcNow;
        var agent = new AgentRegistration
        {
            Id = Guid.NewGuid(),
            ExternalAgentId = new ExternalAgentId("catalog-refresh-receipt"),
            Name = "Catalog refresh receipt",
            OwnerObjectId = Guid.NewGuid().ToString(),
            Status = AgentStatus.Active,
            Agent365AgentId = Guid.NewGuid().ToString(),
            BlueprintId = Guid.NewGuid().ToString(),
            CreatedAtUtc = now,
            UpdatedAtUtc = now,
            FeatureConfiguration = new AgentFeatureConfiguration
            {
                PromptShieldEnabled = false,
                PurviewEnabled = true,
                PurviewMode = PurviewMode.Enforce
            },
            PurviewPolicySelectionMode = "ExistingPolicy",
            RequestedPurviewPolicyMode = PurviewPolicyMode.Enforce
        };
        agent.FeatureConfiguration.AgentRegistrationId = agent.Id;

        var bindingDigest = new string('a', 64);
        var original = PromptProtectionContext.Capture(
            agent,
            new AgentPolicyBinding(bindingDigest));
        var refreshed = PromptProtectionContext.Capture(
            agent,
            new AgentPolicyBinding(bindingDigest));

        Check(original.Hash == refreshed.Hash,
            "A timestamp-only catalog refresh invalidated stable assignment evidence.");
        Check(original.ValidUntilUtc is null && refreshed.ValidUntilUtc is null,
            "Display-catalog age leaked into durable runtime assignment evidence.");

        var receipt = new PromptEvaluationRecord
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            Agent365AgentId = Guid.Parse(agent.Agent365AgentId),
            BlueprintId = Guid.Parse(agent.BlueprintId),
            ExternalInteractionId = $"refresh-{Guid.NewGuid():N}",
            TenantUserObjectId = Guid.NewGuid().ToString(),
            PromptHashSalt = new byte[32],
            PromptHash = new byte[32],
            Outcome = PromptEvaluationOutcome.Allowed,
            PromptShieldDecision = PromptShieldDecisionType.Allowed,
            PurviewDecision = PurviewDecisionType.Allowed,
            ProtectionRevision = original.ProtectionRevision,
            ProtectionContextHash = original.Hash,
            PromptShieldRequired = original.PromptShieldRequired,
            EvaluatedPurviewPolicyMode = original.PurviewMode,
            CorrelationId = Guid.NewGuid().ToString(),
            CreatedAtUtc = now,
            ExpiresAtUtc = now.AddMinutes(5)
        };

        Check(refreshed.MatchesReceipt(receipt, now.AddSeconds(1)),
            "An identical refreshed catalog did not preserve an in-flight receipt.");

        var changed = PromptProtectionContext.Capture(
            agent,
            new AgentPolicyBinding(new string('b', 64)));
        Check(changed.Hash != original.Hash,
            "A semantic assignment digest change retained the old protection context.");

        var expired = PromptProtectionContext.Capture(
            agent,
            new AgentPolicyBinding(bindingDigest, now.AddSeconds(-1)));
        Check(!expired.MatchesReceipt(receipt, now),
            "An expired catalog binding authorized receipt consumption.");

        Console.WriteLine("Protection-context durable assignment identity and optional deadline checks passed.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }
}
