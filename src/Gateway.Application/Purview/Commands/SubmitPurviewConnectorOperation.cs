using System.Security.Cryptography;
using System.Text;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Responses;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using MediatR;

namespace Gateway.Application.Purview.Commands;

public sealed record SubmitPurviewConnectorOperation(
    Guid TenantId,
    Guid ConnectorInstanceId,
    string ConnectorProfile,
    PurviewConnectorOperationType Type,
    string IdempotencyKey,
    string ExpectedRowVersion,
    string RequestedByObjectId,
    string CorrelationId,
    bool ConfirmConnection = false) : IRequest<PurviewConnectorOperationAcceptedResponse>;

internal sealed class SubmitPurviewConnectorOperationHandler(
    IPurviewConnectorStore store,
    TimeProvider timeProvider)
    : IRequestHandler<SubmitPurviewConnectorOperation, PurviewConnectorOperationAcceptedResponse>
{
    public async Task<PurviewConnectorOperationAcceptedResponse> Handle(
        SubmitPurviewConnectorOperation request,
        CancellationToken cancellationToken)
    {
        if (request.TenantId == Guid.Empty || request.ConnectorInstanceId == Guid.Empty)
            throw new DomainException(
                "Bootstrap-owned Purview connector configuration is unavailable.",
                ErrorCodes.PURVIEW_CONNECTOR_SETUP_REQUIRED);
        if (!Guid.TryParseExact(request.IdempotencyKey, "D", out var key) || key.Version != 4 ||
            !string.Equals(request.IdempotencyKey, key.ToString("D"), StringComparison.Ordinal))
            throw new ValidationException(new()
            {
                ["Idempotency-Key"] = ["Idempotency-Key must be a canonical UUID version 4 value."]
            });
        if (!Guid.TryParseExact(request.RequestedByObjectId, "D", out var actorId) ||
            actorId == Guid.Empty ||
            !string.Equals(request.RequestedByObjectId, actorId.ToString("D"), StringComparison.Ordinal))
            throw new ValidationException(new()
            {
                ["actor"] = ["A canonical delegated administrator object identifier is required."]
            });
        if (!string.Equals(request.ConnectorProfile, "LocalWindows", StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(request.CorrelationId) || request.CorrelationId.Length > 128 ||
            request.CorrelationId.Any(char.IsControl))
            throw new DomainException(
                "Bootstrap-owned Purview connector configuration is invalid.",
                ErrorCodes.PURVIEW_CONNECTOR_SETUP_REQUIRED);
        if (request.Type == PurviewConnectorOperationType.Connect && !request.ConfirmConnection)
            throw new ValidationException(new()
            {
                ["confirmConnection"] = ["Explicit connection confirmation is required."]
            });
        if (string.IsNullOrWhiteSpace(request.ExpectedRowVersion) ||
            request.ExpectedRowVersion != "*" && !RowVersionValidation.IsCanonical(request.ExpectedRowVersion))
            throw new PreconditionFailedException(
                "If-Match must contain the exact row version returned by the Gateway.",
                ErrorCodes.CONCURRENCY_CONFLICT);

        var now = timeProvider.GetUtcNow().UtcDateTime;
        var canonical = string.Join('\n',
            request.Type,
            request.TenantId.ToString("D"),
            request.ConnectorInstanceId.ToString("D"),
            request.ConnectorProfile,
            request.ExpectedRowVersion,
            request.RequestedByObjectId,
            request.ConfirmConnection ? "true" : "false");
        var requestHash = Convert.ToHexStringLower(
            SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
        var result = await store.SubmitAsync(new PurviewConnectorSubmission(
            request.TenantId,
            request.ConnectorInstanceId,
            request.ConnectorProfile,
            request.Type,
            request.IdempotencyKey,
            requestHash,
            request.ExpectedRowVersion,
            request.RequestedByObjectId,
            request.CorrelationId,
            now,
            now.AddMinutes(10)), cancellationToken);

        return new PurviewConnectorOperationAcceptedResponse(
            result.Operation.Id,
            result.Operation.Status.ToString(),
            result.State.State.ToString(),
            result.Operation.ExpiresAtUtc);
    }
}
