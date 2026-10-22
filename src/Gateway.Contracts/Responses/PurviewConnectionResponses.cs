namespace Gateway.Contracts.Responses;

public sealed record PurviewConnectionResponse(
    Guid TenantId,
    Guid? ConnectorInstanceId,
    string State,
    string? ConnectorProfile,
    string RefreshMode,
    DateTime? LastHeartbeatAtUtc,
    DateTime? LastAttemptedRefreshAtUtc,
    DateTime? LastSuccessfulRefreshAtUtc,
    DateTime? CatalogRetrievedAtUtc,
    int PolicyCount,
    int CompatiblePolicyCount,
    int IncompatiblePolicyCount,
    string CatalogVerificationStatus,
    Guid? CurrentOperationId,
    string? LastFailureCode,
    string? CorrelationId,
    string RowVersion);

public sealed record PurviewConnectorOperationAcceptedResponse(
    Guid OperationId,
    string Status,
    string ConnectionState,
    DateTime ExpiresAtUtc);
