using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Api.Infrastructure;
using Gateway.Application.Protection;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Services;
using MediatR;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/protection")]
public sealed class ProtectionController : ControllerBase
{
    private readonly ISender _sender;
    private readonly IProtectionAdminOperationLockProvider _locks;

    public ProtectionController(
        ISender sender,
        IProtectionAdminOperationLockProvider locks)
    {
        _sender = sender;
        _locks = locks;
    }

    [HttpGet("capabilities")]
    [Authorize(Policy = AuthorizationPolicies.AllControlPlane)]
    [ProducesResponseType(typeof(ProtectionCapabilitiesResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetCapabilities(
        CancellationToken cancellationToken)
    {
        var actor = User.GetProtectionActor();
        return Ok(await _sender.Send(
            new GetProtectionCapabilitiesQuery(actor),
            cancellationToken));
    }

    [HttpGet("purview/connection")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOrOperator)]
    [ProducesResponseType(typeof(PurviewTenantConnectionResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetPurviewConnection(
        CancellationToken cancellationToken)
    {
        var actor = User.GetProtectionActor();
        var result = await _sender.Send(
            new GetPurviewTenantConnectionQuery(actor),
            cancellationToken);
        if (result.Connection is not null)
            Response.Headers.ETag = result.Connection.RowVersion;
        return Ok(result);
    }

    [HttpPost("purview/connection-operations:review")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(ProtectionOperationReviewResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> ReviewPurviewConnection(
        [FromBody] ReviewPurviewTenantConnectionRequest request,
        CancellationToken cancellationToken)
    {
        ProtectionRequestHeaderValidation.RequireReviewHeaders(
            Request,
            request.ExpectedRowVersion);
        var actor = User.GetProtectionActor();
        var result = await _sender.Send(
            new ReviewPurviewTenantConnectionCommand(
                actor,
                request,
                GetOperationCorrelationId()),
            cancellationToken);
        SetOneTimeResponseHeaders();
        return Ok(result);
    }

    [HttpPost("operation-reviews:confirm")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(ProtectionOperationConfirmationResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> ConfirmOperationReview(
        [FromBody] ConfirmProtectionOperationReviewRequest request,
        CancellationToken cancellationToken)
    {
        var actor = User.GetProtectionActor();
        var result = await _sender.Send(
            new ConfirmProtectionOperationReviewCommand(actor, request),
            cancellationToken);
        SetOneTimeResponseHeaders();
        return Ok(result);
    }

    [HttpPost("purview/connection-operations")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(ProtectionOperationAcceptedResponse), StatusCodes.Status202Accepted)]
    public Task<IActionResult> StartPurviewConnection(
        [FromBody] StartPurviewTenantConnectionOperationRequest request,
        CancellationToken cancellationToken) =>
        ExecuteMutationAsync(
            request.ConfirmationTokenId,
            request.IdempotencyKey,
            request.ExpectedRowVersion,
            actor => new StartPurviewTenantConnectionCommand(actor, request),
            cancellationToken);

    [HttpPost("purview/connection-operations/{operationId:guid}:complete")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(ProtectionOperationAcceptedResponse), StatusCodes.Status202Accepted)]
    public Task<IActionResult> CompletePurviewConnection(
        Guid operationId,
        [FromBody] CompletePurviewTenantConnectionOperationRequest request,
        CancellationToken cancellationToken) =>
        ExecuteMutationAsync(
            request.ConfirmationTokenId,
            request.IdempotencyKey,
            request.ExpectedRowVersion,
            actor => new CompletePurviewTenantConnectionCommand(
                actor,
                operationId,
                request),
            cancellationToken,
            operationId);

    [HttpPost("purview/connection-operations/{operationId:guid}:review-completion")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(ProtectionOperationReviewResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> ReviewPurviewConnectionCompletion(
        Guid operationId,
        [FromBody] ReviewPurviewTenantConnectionCompletionRequest request,
        CancellationToken cancellationToken)
    {
        ProtectionRequestHeaderValidation.RequireReviewHeaders(
            Request,
            request.ExpectedRowVersion);
        var actor = User.GetProtectionActor();
        var result = await _sender.Send(
            new ReviewPurviewTenantConnectionCompletionCommand(
                actor,
                operationId,
                request,
                GetOperationCorrelationId()),
            cancellationToken);
        SetOneTimeResponseHeaders();
        return Ok(result);
    }

    [HttpGet("purview/sensitive-information-types")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(
        typeof(PurviewSensitiveInformationTypeListResponse),
        StatusCodes.Status200OK)]
    public async Task<IActionResult> GetSensitiveInformationTypes(
        CancellationToken cancellationToken)
    {
        var actor = User.GetProtectionActor();
        return Ok(await _sender.Send(
            new GetPurviewSensitiveInformationTypesQuery(actor),
            cancellationToken));
    }

    [HttpGet("purview/know-your-data")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOrOperator)]
    [ProducesResponseType(typeof(PurviewKnowYourDataResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetKnowYourData(
        CancellationToken cancellationToken)
    {
        var actor = User.GetProtectionActor();
        var result = await _sender.Send(
            new GetPurviewKnowYourDataQuery(actor),
            cancellationToken);
        if (result.Configuration is not null)
            Response.Headers.ETag = result.Configuration.RowVersion;
        return Ok(result);
    }

    [HttpPost("purview/know-your-data-operations:review")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(ProtectionOperationReviewResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> ReviewKnowYourData(
        [FromBody] ReviewPurviewKnowYourDataOperationRequest request,
        CancellationToken cancellationToken)
    {
        ProtectionRequestHeaderValidation.RequireReviewHeaders(
            Request,
            request.ExpectedRowVersion);
        var actor = User.GetProtectionActor();
        var result = await _sender.Send(
            new ReviewPurviewKnowYourDataCommand(
                actor,
                request,
                GetOperationCorrelationId()),
            cancellationToken);
        SetOneTimeResponseHeaders();
        return Ok(result);
    }

    [HttpPost("purview/know-your-data-operations")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(ProtectionOperationAcceptedResponse), StatusCodes.Status202Accepted)]
    public Task<IActionResult> StartKnowYourData(
        [FromBody] StartPurviewKnowYourDataOperationRequest request,
        CancellationToken cancellationToken) =>
        ExecuteMutationAsync(
            request.ConfirmationTokenId,
            request.IdempotencyKey,
            request.ExpectedRowVersion,
            actor => new StartPurviewKnowYourDataCommand(actor, request),
            cancellationToken);

    [HttpGet("purview/dlp-profiles")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOrOperator)]
    [ProducesResponseType(typeof(PurviewDlpProfileListResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetDlpProfiles(
        CancellationToken cancellationToken)
    {
        var actor = User.GetProtectionActor();
        return Ok(await _sender.Send(
            new ListPurviewDlpProfilesQuery(actor),
            cancellationToken));
    }

    [HttpPost("purview/dlp-profile-operations:review")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(ProtectionOperationReviewResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> ReviewDlpProfile(
        [FromBody] ReviewPurviewDlpProfileOperationRequest request,
        CancellationToken cancellationToken)
    {
        ProtectionRequestHeaderValidation.RequireReviewHeaders(
            Request,
            request.ExpectedRowVersion);
        var actor = User.GetProtectionActor();
        var result = await _sender.Send(
            new ReviewPurviewDlpProfileCommand(
                actor,
                request,
                GetOperationCorrelationId()),
            cancellationToken);
        SetOneTimeResponseHeaders();
        return Ok(result);
    }

    [HttpPost("purview/dlp-profile-operations")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(ProtectionOperationAcceptedResponse), StatusCodes.Status202Accepted)]
    public Task<IActionResult> StartDlpProfile(
        [FromBody] StartPurviewDlpProfileOperationRequest request,
        CancellationToken cancellationToken) =>
        ExecuteMutationAsync(
            request.ConfirmationTokenId,
            request.IdempotencyKey,
            request.ExpectedRowVersion,
            actor => new StartPurviewDlpProfileCommand(actor, request),
            cancellationToken);

    [HttpPost("purview/dlp-profiles/{profileId:guid}:reconcile")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(ProtectionOperationAcceptedResponse), StatusCodes.Status202Accepted)]
    public Task<IActionResult> ReconcileDlpProfile(
        Guid profileId,
        [FromBody] ReconcilePurviewDlpProfileRequest request,
        CancellationToken cancellationToken) =>
        ExecuteMutationAsync(
            request.ConfirmationTokenId,
            request.IdempotencyKey,
            request.ExpectedRowVersion,
            actor => new ReconcilePurviewDlpProfileCommand(
                actor,
                profileId,
                request),
            cancellationToken);

    [HttpPost("purview/dlp-profiles/{profileId:guid}:review-reconcile")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(ProtectionOperationReviewResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> ReviewReconcileDlpProfile(
        Guid profileId,
        [FromBody] ReviewReconcilePurviewDlpProfileRequest request,
        CancellationToken cancellationToken)
    {
        ProtectionRequestHeaderValidation.RequireReviewHeaders(
            Request,
            request.ExpectedRowVersion);
        var actor = User.GetProtectionActor();
        var result = await _sender.Send(
            new ReviewReconcilePurviewDlpProfileCommand(
                actor,
                profileId,
                request,
                GetOperationCorrelationId()),
            cancellationToken);
        SetOneTimeResponseHeaders();
        return Ok(result);
    }

    [HttpPost("purview/dlp-profiles/{profileId:guid}:validate-runtime")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(ProtectionOperationAcceptedResponse), StatusCodes.Status202Accepted)]
    public Task<IActionResult> ValidateDlpProfileRuntime(
        Guid profileId,
        [FromBody] ValidatePurviewDlpProfileRuntimeRequest request,
        CancellationToken cancellationToken) =>
        ExecuteMutationAsync(
            request.ConfirmationTokenId,
            request.IdempotencyKey,
            request.ExpectedRowVersion,
            actor => new ValidatePurviewDlpProfileRuntimeCommand(
                actor,
                profileId,
                request),
            cancellationToken);

    [HttpPost("purview/dlp-profiles/{profileId:guid}:review-runtime-validation")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(ProtectionOperationReviewResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> ReviewValidateDlpProfileRuntime(
        Guid profileId,
        [FromBody] ReviewValidatePurviewDlpRuntimeRequest request,
        CancellationToken cancellationToken)
    {
        ProtectionRequestHeaderValidation.RequireReviewHeaders(
            Request,
            request.ExpectedRowVersion);
        var actor = User.GetProtectionActor();
        var result = await _sender.Send(
            new ReviewValidatePurviewDlpRuntimeCommand(
                actor,
                profileId,
                request,
                GetOperationCorrelationId()),
            cancellationToken);
        SetOneTimeResponseHeaders();
        return Ok(result);
    }

    [HttpGet("operations/{operationId:guid}")]
    [Authorize(Policy = AuthorizationPolicies.AllControlPlane)]
    [ProducesResponseType(typeof(ProtectionAdminOperationResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetOperation(
        Guid operationId,
        CancellationToken cancellationToken)
    {
        var actor = User.GetProtectionActor();
        var result = await _sender.Send(
            new GetProtectionAdminOperationQuery(actor, operationId),
            cancellationToken);
        Response.Headers.ETag = result.Operation.RowVersion;
        return Ok(result);
    }

    private async Task<IActionResult> ExecuteMutationAsync<TCommand>(
        Guid confirmationTokenId,
        Guid idempotencyKeyValue,
        string expectedRowVersion,
        Func<ProtectionActor, TCommand> createCommand,
        CancellationToken cancellationToken,
        params Guid[] additionalOperationIds)
        where TCommand : IRequest<ProtectionOperationAcceptedResponse>
    {
        ProtectionRequestHeaderValidation.RequireMutationHeaders(
            Request,
            idempotencyKeyValue,
            expectedRowVersion);
        var actor = User.GetProtectionActor();
        var operationIds = additionalOperationIds
            .Append(confirmationTokenId)
            .Where(value => value != Guid.Empty)
            .Distinct()
            .OrderBy(value => value)
            .ToArray();
        await using var executionLocks = await AcquireExecutionLocksAsync(
            operationIds,
            cancellationToken);
        var idempotencyKey = new ProtectionIdempotencyKey(
            idempotencyKeyValue);
        await using var idempotencyLease =
            await _locks.AcquireIdempotencyAsync(
                new EntraTenantId(actor.TenantId),
                idempotencyKey,
                cancellationToken);
        var result = await _sender.Send(
            createCommand(actor),
            cancellationToken);
        await idempotencyLease.CompleteAsync(cancellationToken);
        return AcceptedAtAction(
            nameof(GetOperation),
            new { operationId = result.OperationId },
            result);
    }

    private async Task<IAsyncDisposable> AcquireExecutionLocksAsync(
        IReadOnlyList<Guid> operationIds,
        CancellationToken cancellationToken)
    {
        var leases = new List<IAsyncDisposable>(operationIds.Count);
        try
        {
            foreach (var operationId in operationIds)
            {
                leases.Add(await _locks.AcquireExecutionAsync(
                    operationId,
                    cancellationToken));
            }

            return new CompositeAsyncDisposable(leases);
        }
        catch
        {
            for (var index = leases.Count - 1; index >= 0; index--)
                await leases[index].DisposeAsync();
            throw;
        }
    }

    private Guid GetOperationCorrelationId()
    {
        var correlation = HttpContext.Items["CorrelationId"] as string;
        return Guid.TryParse(correlation, out var parsed) &&
            parsed != Guid.Empty
            ? parsed
            : Guid.NewGuid();
    }

    private void SetOneTimeResponseHeaders()
    {
        Response.Headers.CacheControl = "no-store";
        Response.Headers.Pragma = "no-cache";
    }

}
