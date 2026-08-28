using Gateway.Api.Authorization;
using Gateway.Application.Agents.Queries;
using Gateway.Contracts.Responses;
using MediatR;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/agent-identity-blueprints")]
public sealed class AgentIdentityBlueprintsController : ControllerBase
{
    private readonly ISender _sender;

    public AgentIdentityBlueprintsController(ISender sender)
    {
        _sender = sender;
    }

    [HttpGet]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(AgentIdentityBlueprintListResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status401Unauthorized)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status502BadGateway)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> ListAgentIdentityBlueprints(
        CancellationToken cancellationToken)
    {
        var result = await _sender.Send(
            new ListAgentIdentityBlueprintsQuery(),
            cancellationToken);

        return Ok(result);
    }
}
