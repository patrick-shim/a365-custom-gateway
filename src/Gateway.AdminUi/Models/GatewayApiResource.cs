namespace Gateway.AdminUi.Models;

public sealed record GatewayApiResource<T>(
    T Value,
    string? ETag,
    string? CorrelationId);
