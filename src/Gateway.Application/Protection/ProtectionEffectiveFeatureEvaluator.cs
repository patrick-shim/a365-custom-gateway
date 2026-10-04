using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;

namespace Gateway.Application.Protection;

internal sealed class ProtectionEffectiveFeatureEvaluator(
    IBootstrapPromptShieldRuntimeBinding? promptShieldBinding = null,
    IAgentPolicyBindingReader? individualPolicies = null)
{
    public Task EnsurePromptShieldReadyAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (promptShieldBinding?.IsRuntimeReady() != true)
            throw new DomainException("Prompt Shields requires verified Content Safety setup.", ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE);
        return Task.CompletedTask;
    }

    public async Task EnsureRuntimeReadyAsync(AgentRegistration agent, CancellationToken ct)
    {
        if (!agent.FeatureConfiguration.PurviewEnabled) return;
        if (agent.PurviewPolicySelectionMode != "ExistingPolicy" || individualPolicies is null ||
            await individualPolicies.ReadAsync(agent, ct) is null)
            throw new DomainException("The individual policy assignment needs a current Purview scope readback.",
                ErrorCodes.PURVIEW_ASSIGNMENT_NOT_READY);
    }

    public Task<PurviewPolicyMode> GetRuntimePolicyModeAsync(AgentRegistration agent, CancellationToken ct) =>
        Task.FromResult(agent.FeatureConfiguration.PurviewEnabled ? PurviewPolicyMode.Enforce : PurviewPolicyMode.Disabled);

    public async Task<AgentFeaturesDto> ToDtoAsync(AgentRegistration agent, CancellationToken ct)
    {
        var destinations = agent.FeatureConfiguration.ObservabilityMode.ToDestinations();
        var binding = agent.FeatureConfiguration.PurviewEnabled && individualPolicies is not null
            ? await individualPolicies.ReadAsync(agent, ct) : null;
        return new AgentFeaturesDto(
            agent.FeatureConfiguration.ObservabilityMode.ToString(),
            agent.FeatureConfiguration.PurviewEnabled,
            agent.FeatureConfiguration.PurviewEnabled ? PurviewMode.Enforce.ToString() : null,
            destinations.Agent365ObservabilityEnabled, destinations.AzureMonitorExportEnabled,
            agent.FeatureConfiguration.PromptShieldEnabled,
            PurviewEffectivelyEnabled: binding is not null,
            PromptShieldEffectivelyEnabled: agent.FeatureConfiguration.PromptShieldEnabled && promptShieldBinding?.IsRuntimeReady() == true,
            PurviewPolicyMode: (await GetRuntimePolicyModeAsync(agent, ct)).ToString());
    }

}
