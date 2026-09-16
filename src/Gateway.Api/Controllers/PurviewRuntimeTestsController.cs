using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Application.Exceptions;
using Gateway.Application.Protection;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Controllers;

[ApiController]
[RequireHttps]
[Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
[Route("api/v1/protection")]
[RequestSizeLimit(MaximumRequestBytes)]
public sealed class PurviewRuntimeTestsController(
    PurviewRuntimeTestService runtime,
    IProtectionAdminOperationLockProvider locks,
    IProtectionAdminOperationRepository operations,
    TimeProvider clock) : ControllerBase
{
    public const int MaximumRequestBytes = 1_048_576;
    private static readonly JsonSerializerOptions InputOptions = new(JsonSerializerDefaults.Web)
    {
        MaxDepth = 12,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    [HttpPost("purview/dlp-profiles/{profileId:guid}:review-runtime-test")]
    [ProducesResponseType(typeof(PurviewRuntimeTestReviewResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> Review(Guid profileId, CancellationToken cancellationToken)
    {
        NoStore();
        var request = await ReadAsync<ReviewPurviewDlpRuntimeTestRequest>(cancellationToken);
        ProtectionRequestHeaderValidation.RequireReviewHeaders(Request, request.ExpectedRowVersion);
        return Ok(await runtime.ReviewAsync(User.GetProtectionActor(), profileId, request, cancellationToken));
    }

    [HttpPost("purview/dlp-profiles/{profileId:guid}:test-runtime")]
    [ProducesResponseType(typeof(PurviewRuntimeTestResultResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> Execute(Guid profileId, CancellationToken cancellationToken)
    {
        NoStore();
        var request = await ReadAsync<ExecutePurviewDlpRuntimeTestRequest>(cancellationToken);
        ProtectionRequestHeaderValidation.RequireMutationHeaders(Request, request.IdempotencyKey, request.ExpectedRowVersion);
        var actor = User.GetProtectionActor();
        if (profileId == request.ConfirmationTokenId || profileId == Guid.Empty || request.ConfirmationTokenId == Guid.Empty)
            throw InvalidBody();
        await using var operationLock = await locks.AcquireExecutionAsync(request.ConfirmationTokenId, cancellationToken);
        IAsyncDisposable? profileLock = null;
        PurviewRuntimeTestAcceptance? accepted = null;
        try
        {
            await using (var idempotency = await locks.AcquireIdempotencyAsync(new(actor.TenantId), new(request.IdempotencyKey), cancellationToken))
            {
                var operation = await operations.GetByIdAsync(request.ConfirmationTokenId, cancellationToken);
                if (operation is null || operation.TenantId.Value != actor.TenantId || operation.ActorObjectId != actor.ObjectId ||
                    operation.TargetIdentifier != profileId.ToString("D"))
                    throw new NotFoundException("ProtectionAdminOperation", request.ConfirmationTokenId);
                if (operation.Status == Gateway.Domain.Enums.ProtectionAdminOperationStatus.AwaitingConfirmation)
                    profileLock = await locks.AcquireExecutionAsync(profileId, cancellationToken);
                accepted = await runtime.AcceptAsync(actor, profileId, request, cancellationToken);
                await idempotency.CompleteAsync(cancellationToken);
            }
            // No SQL acceptance transaction survives this boundary.
            return Ok(await runtime.ExecuteAcceptedAsync(actor, accepted, cancellationToken));
        }
        finally
        {
            accepted?.Dispose();
            if (profileLock is not null)
                await profileLock.DisposeAsync();
        }
    }

    [HttpGet("runtime-tests/{operationId:guid}")]
    [ProducesResponseType(typeof(PurviewRuntimeTestResultResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> Get(Guid operationId, CancellationToken cancellationToken)
    {
        NoStore();
        var actor = User.GetProtectionActor();
        var result = await runtime.GetAsync(actor, operationId, cancellationToken);
        if (result.Status != "Running")
            return Ok(result);
        var operation = await operations.GetByIdAsync(operationId, cancellationToken);
        if (operation?.StartedAtUtc is not { } started || started.AddSeconds(60) > clock.GetUtcNow().UtcDateTime)
            return Ok(result);
        await using var operationLock = await locks.AcquireExecutionAsync(operationId, cancellationToken);
        if (!Guid.TryParse(operation.TargetIdentifier, out var profileId) || profileId == operationId)
            throw InvalidBody();
        await using var profileLock = await locks.AcquireExecutionAsync(profileId, cancellationToken);
        return Ok(await runtime.RecoverAsync(actor, operationId, cancellationToken));
    }

    private async Task<T> ReadAsync<T>(CancellationToken ct)
    {
        if (Request.ContentType?.Split(';')[0].Trim().Equals("application/json", StringComparison.OrdinalIgnoreCase) != true)
            throw InvalidBody();
        using var buffer = new MemoryStream();
        var bytes = new byte[8192];
        try
        {
            int read;
            while ((read = await Request.Body.ReadAsync(bytes, ct)) != 0)
            {
                if (buffer.Length + read > MaximumRequestBytes)
                    throw InvalidBody();
                buffer.Write(bytes, 0, read);
            }
            return JsonSerializer.Deserialize<T>(buffer.GetBuffer().AsSpan(0, (int)buffer.Length), InputOptions) ?? throw InvalidBody();
        }
        catch (JsonException) { throw InvalidBody(); }
        catch (ArgumentException) { throw InvalidBody(); }
        finally
        {
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(bytes);
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(buffer.GetBuffer());
        }
    }

    private void NoStore()
    {
        Response.Headers.CacheControl = "no-store";
        Response.Headers.Pragma = "no-cache";
    }
    private static ValidationException InvalidBody() =>
        new(new Dictionary<string, string[]> { ["RuntimeTest"] = ["The bounded runtime-test request body is invalid."] });
}
