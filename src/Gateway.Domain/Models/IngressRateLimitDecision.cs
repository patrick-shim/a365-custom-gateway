namespace Gateway.Domain.Models;

public sealed record IngressRateLimitDecision(
    bool Allowed,
    string Scope,
    int Limit,
    int Remaining,
    DateTime ResetAtUtc);
