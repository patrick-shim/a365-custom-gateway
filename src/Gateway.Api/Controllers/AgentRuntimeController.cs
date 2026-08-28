using Gateway.Api.Authorization;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/agent-runtime")]
public sealed class AgentRuntimeController : ControllerBase
{
    [HttpGet("readiness")]
    [Authorize(Policy = AuthorizationPolicies.ExternalAgentOnly)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status401Unauthorized)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status403Forbidden)]
    public IActionResult GetReadiness() => NoContent();
}
