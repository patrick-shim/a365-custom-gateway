using System.Security.Cryptography;
using System.Text.Json;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;

namespace Gateway.Domain.Models;

// Only immutable digests and scalar decisions escape the snapshot reader. No prompt or response is included.
public sealed record PromptProtectionContext(
    Guid AgentRegistrationId,
    Guid ProtectionRevision,
    string AgentConfigurationHash,
    string Hash,
    bool PromptShieldRequired,
    PurviewPolicyMode PurviewMode,
    DateTime? ValidUntilUtc,
    bool AgentActive)
{
    public AgentPolicyBinding? IndividualPolicyBinding { get; init; }
    public bool RequiresReceipt => PromptShieldRequired || PurviewMode == PurviewPolicyMode.Enforce;

    public bool MatchesAgent(AgentRegistration agent) =>
        AgentRegistrationId == agent.Id &&
        string.Equals(AgentConfigurationHash, ComputeAgentConfigurationHash(agent), StringComparison.Ordinal);

    public bool IsCurrentAt(DateTime utcNow) =>
        AgentActive && ProtectionRevision != Guid.Empty &&
        (ValidUntilUtc is null || utcNow < ValidUntilUtc);

    public bool MatchesReceipt(PromptEvaluationRecord receipt, DateTime utcNow) =>
        IsCurrentAt(utcNow) &&
        receipt.AgentRegistrationId == AgentRegistrationId &&
        receipt.ProtectionRevision == ProtectionRevision &&
        receipt.ProtectionContextHash == Hash &&
        receipt.PromptShieldRequired == PromptShieldRequired &&
        receipt.EvaluatedPurviewPolicyMode == PurviewMode &&
        receipt.Outcome == PromptEvaluationOutcome.Allowed &&
        (!PromptShieldRequired || receipt.PromptShieldDecision == PromptShieldDecisionType.Allowed) &&
        (PurviewMode != PurviewPolicyMode.Enforce || receipt.PurviewDecision == PurviewDecisionType.Allowed) &&
        receipt.ConsumedAtUtc is null && utcNow < receipt.ExpiresAtUtc;

    public static string ComputeAgentConfigurationHash(AgentRegistration agent) => Digest(new
    {
        agent.Id,
        ExternalAgentId = agent.ExternalAgentId.Value,
        agent.ProtectionRevision,
        agent.Status,
        agent.IsDeleted,
        agent.Agent365AgentId,
        agent.BlueprintId,
        agent.FeatureConfiguration.PromptShieldEnabled,
        agent.FeatureConfiguration.PurviewEnabled,
        agent.FeatureConfiguration.PurviewMode,
        agent.PurviewPolicySelectionMode,
        agent.RequestedPurviewPolicyMode
    });

    public static PromptProtectionContext Capture(
        AgentRegistration agent,
        AgentPolicyBinding? individualPolicyBinding = null)
    {
        var mode = agent.FeatureConfiguration.PurviewEnabled ? PurviewPolicyMode.Enforce : PurviewPolicyMode.Disabled;
        if (mode == PurviewPolicyMode.Enforce && individualPolicyBinding is null)
            throw new InvalidOperationException("A current individual policy binding is required to capture protected content.");
        var agentHash = ComputeAgentConfigurationHash(agent);
        var hash = Digest(new
        {
            Version = 3,
            IndividualPolicyBinding = individualPolicyBinding,
            Agent = agentHash,
            Mode = mode
        });
        return new(agent.Id, agent.ProtectionRevision, agentHash, hash,
            agent.FeatureConfiguration.PromptShieldEnabled, mode,
            mode == PurviewPolicyMode.Enforce ? individualPolicyBinding!.ValidUntilUtc : null,
            agent.Status == AgentStatus.Active && !agent.IsDeleted)
        { IndividualPolicyBinding = individualPolicyBinding };
    }

    private static string Digest<T>(T value) =>
        Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(value)));
}
