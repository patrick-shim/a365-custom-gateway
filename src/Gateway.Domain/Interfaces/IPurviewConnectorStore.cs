using Gateway.Domain.Entities;
using Gateway.Domain.Enums;

namespace Gateway.Domain.Interfaces;

public sealed record PurviewConnectorSubmission(
    Guid TenantId,
    Guid ConnectorInstanceId,
    string ConnectorProfile,
    PurviewConnectorOperationType Type,
    string IdempotencyKey,
    string RequestHash,
    string ExpectedRowVersion,
    string RequestedByObjectId,
    string CorrelationId,
    DateTime RequestedAtUtc,
    DateTime ExpiresAtUtc);

public sealed record PurviewConnectorSubmissionResult(
    PurviewConnectorStateRecord State,
    PurviewConnectorOperation Operation,
    bool Existing);

public interface IPurviewConnectorStore
{
    Task<PurviewConnectorStateRecord?> GetStateAsync(Guid tenantId, CancellationToken ct);
    Task<PurviewConnectorOperation?> GetOperationAsync(Guid operationId, CancellationToken ct);
    Task<PurviewCatalogSnapshot?> GetAcceptedCatalogAsync(
        Guid tenantId,
        Guid connectorInstanceId,
        CancellationToken ct);
    Task<PurviewConnectorSubmissionResult> SubmitAsync(PurviewConnectorSubmission submission, CancellationToken ct);
}
