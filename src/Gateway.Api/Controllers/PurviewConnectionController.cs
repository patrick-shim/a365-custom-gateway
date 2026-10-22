using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Application.Exceptions;
using Gateway.Application.Purview.Commands;
using Gateway.Application.Purview.Queries;
using Gateway.Contracts;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.Domain.Enums;
using Gateway.Purview;
using MediatR;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/protection/purview/connection")]
[Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
public sealed class PurviewConnectionController(
    ISender sender,
    IOptions<PurviewConnectorOptions> connectorOptions) : ControllerBase
{
    [HttpGet]
    [ProducesResponseType(typeof(PurviewConnectionResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> Get(CancellationToken cancellationToken)
    {
        Response.Headers.CacheControl = "no-store";
        var actor = User.GetProtectionActor();
        var configured = GetConfiguredConnector(actor.TenantId, required: false);
        var result = await sender.Send(new GetPurviewConnectionQuery(
            actor.TenantId,
            configured?.ConnectorInstanceId,
            configured is null ? null : "LocalWindows"), cancellationToken);
        Response.Headers.ETag = $"\"{result.RowVersion}\"";
        return Ok(result);
    }

    [HttpPost]
    [ProducesResponseType(typeof(PurviewConnectorOperationAcceptedResponse), StatusCodes.Status202Accepted)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status412PreconditionFailed)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status503ServiceUnavailable)]
    public Task<IActionResult> Connect(
        [FromBody] ConnectPurviewRequest request,
        CancellationToken cancellationToken) =>
        SubmitAsync(PurviewConnectorOperationType.Connect, request.ConfirmConnection, cancellationToken);

    [HttpPost("refresh")]
    [ProducesResponseType(typeof(PurviewConnectorOperationAcceptedResponse), StatusCodes.Status202Accepted)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status412PreconditionFailed)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status503ServiceUnavailable)]
    public Task<IActionResult> Refresh(
        [FromBody] RefreshPurviewCatalogRequest request,
        CancellationToken cancellationToken) =>
        SubmitAsync(PurviewConnectorOperationType.RefreshCatalog, confirmConnection: false, cancellationToken);

    private async Task<IActionResult> SubmitAsync(
        PurviewConnectorOperationType type,
        bool confirmConnection,
        CancellationToken cancellationToken)
    {
        Response.Headers.CacheControl = "no-store";
        var actor = User.GetProtectionActor();
        var configured = GetConfiguredConnector(actor.TenantId, required: true)!;
        var (idempotencyKey, rowVersion) = ReadMutationHeaders();
        var correlationId = HttpContext.Items["CorrelationId"] as string ?? HttpContext.TraceIdentifier;
        var result = await sender.Send(new SubmitPurviewConnectorOperation(
            actor.TenantId,
            configured.ConnectorInstanceId,
            "LocalWindows",
            type,
            idempotencyKey,
            rowVersion,
            actor.ObjectId,
            correlationId,
            confirmConnection), cancellationToken);
        return Accepted($"/api/v1/operations/{result.OperationId:D}", result);
    }

    private PurviewConnectorOptions? GetConfiguredConnector(Guid tenantId, bool required)
    {
        var configured = connectorOptions.Value;
        var valid = configured.TenantId == tenantId &&
            configured.ConnectorInstanceId != Guid.Empty &&
            HasValidQueueDirectory(configured.QueueDirectory) &&
            HasValidAuthenticationKey(configured.AuthenticationKey);
        if (valid)
            return configured;
        if (!required)
            return null;
        throw new DomainException(
            "The bootstrap-owned Purview connector is not configured for this tenant.",
            ErrorCodes.PURVIEW_CONNECTOR_SETUP_REQUIRED);
    }

    private static bool HasValidAuthenticationKey(string value)
    {
        try { return Convert.FromBase64String(value).Length == 32; }
        catch (FormatException) { return false; }
    }

    private static bool HasValidQueueDirectory(string value)
    {
        try { return !string.IsNullOrWhiteSpace(value) && Path.IsPathFullyQualified(value); }
        catch (Exception failure) when (failure is ArgumentException or NotSupportedException) { return false; }
    }

    private (string IdempotencyKey, string RowVersion) ReadMutationHeaders()
    {
        var idempotencyValues = Request.Headers["Idempotency-Key"];
        var rowVersionValues = Request.Headers.IfMatch;
        var idempotencyKey = idempotencyValues.Count == 1 ? idempotencyValues[0] : null;
        var rowVersion = rowVersionValues.Count == 1 ? rowVersionValues[0] : null;
        if (!IdempotencyKeyValidation.TryNormalizeUuidV4(
                idempotencyKey,
                out var normalizedKey) ||
            !string.Equals(idempotencyKey, normalizedKey, StringComparison.Ordinal))
        {
            throw new ValidationException(new Dictionary<string, string[]>
            {
                ["Idempotency-Key"] =
                ["Idempotency-Key must be one canonical lowercase UUID version 4 value."]
            });
        }

        if (rowVersion is null ||
            rowVersion != "*" && !RowVersionValidation.IsCanonical(rowVersion))
        {
            throw new PreconditionFailedException(
                "If-Match must contain the exact row version returned by the Gateway.",
                ErrorCodes.CONCURRENCY_CONFLICT);
        }

        return (normalizedKey, rowVersion);
    }
}
