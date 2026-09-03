using Gateway.Domain.Interfaces;

namespace Gateway.Application.Agents;

/// <summary>
/// Resolves when each agent was last actually used.
/// </summary>
/// <remarks>
/// An agent is "used" when an external caller either submits an AI interaction or
/// reports an activity, so the answer is the later of the two per agent. Both
/// lookups are batched, because the agent list renders this column for every row
/// and a per-row query would turn one page into hundreds of round trips.
/// </remarks>
internal static class AgentLastActivity
{
    public static async Task<IReadOnlyDictionary<Guid, DateTime>> ResolveAsync(
        IAiInteractionRepository interactionRepository,
        IActivityReceiptRepository activityReceiptRepository,
        IReadOnlyCollection<Guid> agentRegistrationIds,
        CancellationToken cancellationToken)
    {
        if (agentRegistrationIds.Count == 0)
        {
            return new Dictionary<Guid, DateTime>();
        }

        var interactions = await interactionRepository.GetLatestReceivedAtUtcAsync(
            agentRegistrationIds,
            cancellationToken);

        var activities = await activityReceiptRepository.GetLatestReceivedAtUtcAsync(
            agentRegistrationIds,
            cancellationToken);

        var latest = new Dictionary<Guid, DateTime>(interactions.Count + activities.Count);

        foreach (var source in new[] { interactions, activities })
        {
            foreach (var (agentRegistrationId, receivedAtUtc) in source)
            {
                if (!latest.TryGetValue(agentRegistrationId, out var current)
                    || receivedAtUtc > current)
                {
                    latest[agentRegistrationId] = receivedAtUtc;
                }
            }
        }

        return latest;
    }

    public static DateTime? For(
        IReadOnlyDictionary<Guid, DateTime> latest,
        Guid agentRegistrationId)
    {
        // Absent means the agent has never been called. Report null so the UI can
        // say "Never" rather than showing a misleading default date.
        return latest.TryGetValue(agentRegistrationId, out var receivedAtUtc)
            ? receivedAtUtc
            : null;
    }
}
