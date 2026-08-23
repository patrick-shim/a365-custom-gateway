using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Application.Configuration.Commands;
using Gateway.Application.Configuration.Queries;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using MediatR;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/system")]
public class SystemController : ControllerBase
{
    private readonly ISender _sender;

    public SystemController(ISender sender)
    {
        _sender = sender;
    }

    [HttpGet("config")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(SystemConfigDto), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetSystemConfig(CancellationToken cancellationToken)
    {
        var query = new GetSystemConfigQuery();
        var result = await _sender.Send(query, cancellationToken);

        return Ok(result);
    }

    [HttpPatch("config")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(SystemConfigDto), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    public async Task<IActionResult> UpdateSystemConfig(
        [FromBody] UpdateSystemConfigRequest request,
        CancellationToken cancellationToken)
    {
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
            User.GetObjectId());

        var result = await _sender.Send(command, cancellationToken);

        return Ok(result);
    }
}
