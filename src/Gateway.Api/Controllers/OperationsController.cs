using Gateway.Api.Authorization;
using Gateway.Application.Agents.Queries;
using Gateway.Contracts.Responses;
using MediatR;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/operations")]
public class OperationsController : ControllerBase
{
    private readonly ISender _sender;

    public OperationsController(ISender sender)
    {
        _sender = sender;
    }

    [HttpGet("{operationId:guid}")]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOrOperator)]
    [ProducesResponseType(typeof(OperationStatusDto), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetOperationStatus(
        Guid operationId,
        CancellationToken cancellationToken)
    {
        var query = new GetOperationStatusQuery(operationId);
        var result = await _sender.Send(query, cancellationToken);

        return Ok(result);
    }
}
