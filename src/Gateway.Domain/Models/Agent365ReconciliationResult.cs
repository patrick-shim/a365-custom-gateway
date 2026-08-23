namespace Gateway.Domain.Models;

public sealed record Agent365ReconciliationResult(
    bool InSync,
    bool AppRegistrationExists,
    bool ServicePrincipalExists,
    bool BlueprintExists,
    bool AgentExists,
    bool PermissionsCorrect,
    IReadOnlyList<string> Drifts);
