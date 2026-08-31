using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Api.Options;
using Gateway.Application.Agents.Commands;
using Gateway.Application.Agents.Queries;
using Gateway.Application.Audit.Queries;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using MediatR;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/agents")]
public class AgentsController : ControllerBase
{
    private readonly ISender _sender;
    private readonly ProvisioningAdmissionGate _provisioningAdmissionGate;

    public AgentsController(
        ISender sender,
        ProvisioningAdmissionGate provisioningAdmissionGate)
    {
        _sender = sender;
        _provisioningAdmissionGate = provisioningAdmissionGate;
    }

    [HttpPost]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(RegisterAgentResponse), StatusCodes.Status202Accepted)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status422UnprocessableEntity)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status502BadGateway)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> RegisterAgent(
        [FromBody] RegisterAgentRequest request,
        CancellationToken cancellationToken)
    {
        _provisioningAdmissionGate.EnsureRegistrationOpen();

        var command = new RegisterAgentCommand(
            request.ExternalAgentId,
            request.Name,
            request.Description,
            request.OwnerObjectId,
            request.Environment,
            request.Features,
            User.GetObjectId(),
            request.Blueprint,
            request.PurviewPolicyProfile);

        var result = await _sender.Send(command, cancellationToken);

        Response.Headers.CacheControl = "no-store";
        Response.Headers.Pragma = "no-cache";

        return AcceptedAtAction(
            nameof(GetAgent),
            new { agentId = result.AgentId },
            result);
    }

    [HttpGet]
    [Authorize(Policy = AuthorizationPolicies.AllControlPlane)]
    [ProducesResponseType(typeof(AgentListResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> ListAgents(
        [FromQuery] string? status,
        [FromQuery] string? environment,
        [FromQuery] string? search,
        [FromQuery] int limit = 50,
        [FromQuery] string? cursor = null,
        CancellationToken cancellationToken = default)
    {
        var query = new ListAgentsQuery(status, environment, search, limit, cursor);
        var result = await _sender.Send(query, cancellationToken);

        return Ok(result);
    }

    [HttpGet("{agentId:guid}")]
    [Authorize(Policy = AuthorizationPolicies.AllControlPlane)]
    [ProducesResponseType(typeof(AgentDetailDto), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetAgent(
        Guid agentId,
        CancellationToken cancellationToken)
    {
        var query = new GetAgentQuery(agentId);
        var result = await _sender.Send(query, cancellationToken);

        if (result.RowVersion is { Length: > 0 })
        {
            Response.Headers.ETag = Convert.ToBase64String(result.RowVersion);
        }

        return Ok(result);
    }

    [HttpGet("{agentId:guid}/credentials")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(AgentIngressCredentialListResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> ListAgentIngressCredentials(
        Guid agentId,
        CancellationToken cancellationToken)
    {
        var result = await _sender.Send(
            new ListAgentIngressCredentialsQuery(agentId),
            cancellationToken);

        return Ok(result);
    }

    [HttpPost("{agentId:guid}/credentials")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(IssueAgentIngressCredentialResponse), StatusCodes.Status201Created)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status404NotFound)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> IssueAgentIngressCredential(
        Guid agentId,
        CancellationToken cancellationToken)
    {
        var result = await _sender.Send(
            new IssueAgentIngressCredentialCommand(agentId, User.GetObjectId()),
            cancellationToken);

        Response.Headers.CacheControl = "no-store";
        Response.Headers.Pragma = "no-cache";

        return StatusCode(StatusCodes.Status201Created, result);
    }

    [HttpDelete("{agentId:guid}/credentials/{credentialId:guid}")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(RevokeAgentIngressCredentialResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status404NotFound)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> RevokeAgentIngressCredential(
        Guid agentId,
        Guid credentialId,
        CancellationToken cancellationToken)
    {
        var result = await _sender.Send(
            new RevokeAgentIngressCredentialCommand(
                agentId,
                credentialId,
                User.GetObjectId()),
            cancellationToken);

        return Ok(result);
    }

    [HttpPatch("{agentId:guid}/features")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(UpdateFeaturesResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> UpdateFeatures(
        Guid agentId,
        [FromBody] UpdateFeaturesRequest request,
        CancellationToken cancellationToken)
    {
        var command = new UpdateFeaturesCommand(
            agentId,
            request.ObservabilityMode,
            request.PurviewEnabled,
            request.PurviewMode,
            User.GetObjectId(),
            request.Agent365ObservabilityEnabled,
            request.AzureMonitorExportEnabled,
            request.PromptShieldEnabled);

        var result = await _sender.Send(command, cancellationToken);

        return Ok(result);
    }

    [HttpPost("{agentId:guid}:enable")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOrOperator)]
    [ProducesResponseType(typeof(AgentStateChangeResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status404NotFound)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> EnableAgent(
        Guid agentId,
        CancellationToken cancellationToken)
    {
        var command = new EnableAgentCommand(agentId, User.GetObjectId());
        var result = await _sender.Send(command, cancellationToken);

        return Ok(result);
    }

    [HttpPost("{agentId:guid}:disable")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOrOperator)]
    [ProducesResponseType(typeof(AgentStateChangeResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status404NotFound)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> DisableAgent(
        Guid agentId,
        CancellationToken cancellationToken)
    {
        var command = new DisableAgentCommand(agentId, User.GetObjectId());
        var result = await _sender.Send(command, cancellationToken);

        return Ok(result);
    }

    [HttpDelete("{agentId:guid}")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(DeleteAgentResponse), StatusCodes.Status202Accepted)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> DeleteAgent(
        Guid agentId,
        CancellationToken cancellationToken = default)
    {
        var command = new DeleteAgentCommand(agentId, User.GetObjectId());
        var result = await _sender.Send(command, cancellationToken);

        return Accepted(result);
    }

    [HttpPost("{agentId:guid}:retry-provisioning")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(AsyncOperationResponse), StatusCodes.Status202Accepted)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status404NotFound)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> RetryProvisioning(
        Guid agentId,
        CancellationToken cancellationToken)
    {
        _provisioningAdmissionGate.EnsureRetryOpen();

        var command = new RetryProvisioningCommand(agentId, User.GetObjectId());
        var result = await _sender.Send(command, cancellationToken);

        return Accepted(result);
    }

    [HttpGet("{agentId:guid}/audit-events")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOrAuditor)]
    [ProducesResponseType(typeof(AuditEventListResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetAuditEvents(
        Guid agentId,
        [FromQuery] int limit = 50,
        [FromQuery] string? cursor = null,
        CancellationToken cancellationToken = default)
    {
        var query = new GetAuditEventsQuery(agentId, limit, cursor);
        var result = await _sender.Send(query, cancellationToken);

        return Ok(result);
    }

    [HttpGet("{agentId:guid}/provisioning-history")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOrOperator)]
    [ProducesResponseType(typeof(ProvisioningHistoryResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetProvisioningHistory(
        Guid agentId,
        CancellationToken cancellationToken)
    {
        var query = new GetProvisioningHistoryQuery(agentId);
        var result = await _sender.Send(query, cancellationToken);

        return Ok(result);
    }
}
