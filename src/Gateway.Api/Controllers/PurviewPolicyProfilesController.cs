using Gateway.Api.Authorization;
using Gateway.Application.Agents.Queries;
using Gateway.Contracts.Responses;
using MediatR;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/purview-policy-profiles")]
public sealed class PurviewPolicyProfilesController : ControllerBase
{
    private readonly ISender _sender;

    public PurviewPolicyProfilesController(ISender sender)
    {
        _sender = sender;
    }

    [HttpGet]
    [Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
    [ProducesResponseType(typeof(PurviewPolicyProfileListResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> List(CancellationToken cancellationToken) =>
        Ok(await _sender.Send(new ListPurviewPolicyProfilesQuery(), cancellationToken));
}
