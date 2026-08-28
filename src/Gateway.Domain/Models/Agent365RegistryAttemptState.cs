namespace Gateway.Domain.Models;

/// <summary>
/// Safe interim state persisted before the one permitted Registry POST. It never
/// contains a token, assertion, authorization header, or dependency response body.
/// </summary>
public sealed record Agent365RegistryAttemptState(
    int SchemaVersion,
    string AuthenticationMode,
    string CreatedByObjectId,
    DateTimeOffset StartedAtUtc,
    string PlannedAgent365RegistrationId,
    string? ReturnedAgent365RegistrationId)
{
    public const int CurrentSchemaVersion = 2;
}
