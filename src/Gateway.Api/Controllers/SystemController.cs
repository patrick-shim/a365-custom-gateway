using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Api.Options;
using Gateway.Application.Configuration.Commands;
using Gateway.Application.Configuration.Queries;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using MediatR;
using Gateway.Domain.Interfaces;
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

    public SystemController(
        ISender sender,
        ProvisioningAdmissionGate provisioningAdmissionGate,
        IPurviewPolicyProvisioningClient purviewPolicyProvisioningClient,
        IPromptShieldClient promptShieldClient)
    {
        _sender = sender;
        _provisioningAdmissionGate = provisioningAdmissionGate;
        _purviewPolicyProvisioningClient = purviewPolicyProvisioningClient;
        _promptShieldClient = promptShieldClient;
    }

    [HttpGet("config")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(SystemConfigDto), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetSystemConfig(CancellationToken cancellationToken)
    {
        var query = new GetSystemConfigQuery();
        var result = await _sender.Send(query, cancellationToken);

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
            request.DefaultPromptShieldEnabled);

        var result = await _sender.Send(command, cancellationToken);

        return Ok(WithDeploymentCapabilities(result));
    }

    private SystemConfigDto WithDeploymentCapabilities(SystemConfigDto config) =>
        config with
        {
            ProvisioningExecutionEnabled = _provisioningAdmissionGate.IsRegistrationOpen,
            AuthorizedRegistrationExternalAgentId =
                _provisioningAdmissionGate.AuthorizedRegistrationExternalAgentId,
            PurviewPolicyProvisioningEnabled = _purviewPolicyProvisioningClient.IsEnabled,
            PromptShieldAvailable = _promptShieldClient.IsEnabled
        };
}
