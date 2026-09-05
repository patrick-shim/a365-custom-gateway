using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Api.Options;
using Gateway.Application.Configuration.Commands;
using Gateway.Application.Configuration.Queries;
using Gateway.Application.Protection;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using MediatR;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/system")]
public class SystemController : ControllerBase
{
    private readonly ISender _sender;
    private readonly ProvisioningAdmissionGate _provisioningAdmissionGate;
    private readonly IPurviewPolicyProvisioningClient _purviewPolicyProvisioningClient;
    private readonly IPromptShieldClient _promptShieldClient;
    private readonly IProtectionAdminOperationLockProvider _protectionLocks;

    public SystemController(
        ISender sender,
        ProvisioningAdmissionGate provisioningAdmissionGate,
        IPurviewPolicyProvisioningClient purviewPolicyProvisioningClient,
        IPromptShieldClient promptShieldClient,
        IProtectionAdminOperationLockProvider protectionLocks)
    {
        _sender = sender;
        _provisioningAdmissionGate = provisioningAdmissionGate;
        _purviewPolicyProvisioningClient = purviewPolicyProvisioningClient;
        _promptShieldClient = promptShieldClient;
        _protectionLocks = protectionLocks;
    }

    [HttpGet("config")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(SystemConfigDto), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetSystemConfig(CancellationToken cancellationToken)
    {
        var query = new GetSystemConfigQuery();
        var result = await _sender.Send(query, cancellationToken);
        if (!string.IsNullOrWhiteSpace(result.RowVersion))
            Response.Headers.ETag = result.RowVersion;

        return Ok(WithDeploymentCapabilities(result));
    }

    [HttpPatch("config")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(SystemConfigDto), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    public async Task<IActionResult> UpdateSystemConfig(
        [FromBody] UpdateSystemConfigRequest request,
        CancellationToken cancellationToken)
    {
        var isProtectionMutation =
            request.DefaultPurviewEnabled is not null ||
            request.DefaultPurviewMode is not null ||
            request.DefaultPromptShieldEnabled is not null ||
            request.IdempotencyKey is not null ||
            request.ExpectedRowVersion is not null;
        ProtectionActor? protectionActor = null;
        if (isProtectionMutation)
        {
            protectionActor = User.GetProtectionActor();
            if (request.IdempotencyKey is null ||
                request.ExpectedRowVersion is null)
            {
                throw new Gateway.Application.Exceptions.ValidationException(
                    new Dictionary<string, string[]>
                    {
                        ["Idempotency-Key"] =
                        ["Protection default mutations require Idempotency-Key and If-Match."]
                    });
            }

            ProtectionRequestHeaderValidation.RequireMutationHeaders(
                Request,
                request.IdempotencyKey.Value,
                request.ExpectedRowVersion);
        }

        // Forward compatibility-only members so application validation rejects any
        // non-null write explicitly instead of silently accepting a false control.
        var command = new UpdateSystemConfigCommand(
            request.ProvisioningMode,
            request.DefaultObservabilityMode,
            request.DefaultPurviewEnabled,
            request.DefaultPurviewMode,
            request.RetentionDaysActivityReceipts,
            request.RetentionDaysAuditEvents,
            request.RetentionDaysIdempotencyRecords,
            request.RetentionDaysOutboxMessages,
            request.RateLimitPerClient,
            request.RateLimitPerAgent,
            request.RateLimitGlobal,
            request.ReconciliationEnabled,
            request.ReconciliationIntervalHours,
            request.StuckTransitionTimeoutDays,
            request.UseGraphAgentRegistration,
            request.UseCliProvisioningFallback,
            User.GetObjectId(),
            request.DefaultAgent365ObservabilityEnabled,
            request.DefaultAzureMonitorExportEnabled,
            request.DefaultPromptShieldEnabled,
            request.IdempotencyKey,
            request.ExpectedRowVersion,
            protectionActor?.TenantId,
            GetOperationCorrelationId());

        SystemConfigDto result;
        if (protectionActor is not null)
        {
            await using var idempotencyLease =
                await _protectionLocks.AcquireIdempotencyAsync(
                    new EntraTenantId(protectionActor.TenantId),
                    new ProtectionIdempotencyKey(
                        request.IdempotencyKey!.Value),
                    cancellationToken);
            result = await _sender.Send(command, cancellationToken);
            await idempotencyLease.CompleteAsync(cancellationToken);
        }
        else
        {
            result = await _sender.Send(command, cancellationToken);
        }
        if (!string.IsNullOrWhiteSpace(result.RowVersion))
            Response.Headers.ETag = result.RowVersion;

        return Ok(WithDeploymentCapabilities(result));
    }

    private SystemConfigDto WithDeploymentCapabilities(SystemConfigDto config) =>
        config with
        {
            ProvisioningExecutionEnabled = _provisioningAdmissionGate.IsRegistrationOpen,
            PurviewPolicyProvisioningEnabled = _purviewPolicyProvisioningClient.IsEnabled,
            PromptShieldAvailable = _promptShieldClient.IsEnabled
        };

    private Guid GetOperationCorrelationId()
    {
        var correlation = HttpContext.Items["CorrelationId"] as string;
        return Guid.TryParse(correlation, out var parsed) &&
            parsed != Guid.Empty
            ? parsed
            : Guid.NewGuid();
    }
}
