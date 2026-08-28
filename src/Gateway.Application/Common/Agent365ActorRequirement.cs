using Gateway.Application.Exceptions;
using Gateway.Domain.Enums;

namespace Gateway.Application.Common;

internal static class Agent365ActorRequirement
{
    internal const string UnsupportedActorErrorMessage =
        "Actor.Type must be User when Agent 365 observability is enabled.";

    public static bool IsSupported(ObservabilityMode mode, string? actorType)
    {
        return !mode.ToDestinations().Agent365ObservabilityEnabled ||
               string.Equals(actorType, ActorType.User.ToString(), StringComparison.Ordinal);
    }

    public static void EnsureSupported(
        ObservabilityMode mode,
        string? actorType,
        string propertyName)
    {
        if (IsSupported(mode, actorType))
            return;

        throw new ValidationException(new Dictionary<string, string[]>
        {
            [propertyName] = [UnsupportedActorErrorMessage]
        });
    }
}
