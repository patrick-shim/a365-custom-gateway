using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Application.Activities.Commands;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using MediatR;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/agent-activities")]
public class ActivitiesController : ControllerBase
{
    private readonly ISender _sender;

    public ActivitiesController(ISender sender)
    {
        _sender = sender;
    }

    [HttpPost]
    [Authorize(Policy = AuthorizationPolicies.ExternalAgentOnly)]
    [ProducesResponseType(typeof(ActivityReceiptDto), StatusCodes.Status202Accepted)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> SubmitActivity(
        [FromBody] SubmitActivityRequest request,
        [FromHeader(Name = "Idempotency-Key")] string? idempotencyKey,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(idempotencyKey))
        {
            return Problem(
                statusCode: StatusCodes.Status400BadRequest,
                title: "Missing Required Header",
                detail: "The Idempotency-Key header is required for this operation.",
                type: "https://tools.ietf.org/html/rfc9457");
        }

        var command = new SubmitActivityCommand(
            request.ExternalAgentId,
            request.ActivityId,
            request.SessionId,
            request.ActivityType,
            request.OccurredAtUtc,
            request.Actor,
            request.Tool,
            request.Attributes,
            User.GetClientId(),
            idempotencyKey);

        var result = await _sender.Send(command, cancellationToken);

        return Accepted(result);
    }

    [HttpPost(":batch")]
    [Authorize(Policy = AuthorizationPolicies.ExternalAgentOnly)]
    [ProducesResponseType(typeof(BatchActivityResponse), StatusCodes.Status202Accepted)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> SubmitBatchActivities(
        [FromBody] BatchActivityRequest request,
        CancellationToken cancellationToken)
    {
        var command = new SubmitBatchActivityCommand(
            request.ExternalAgentId,
            request.Activities,
            User.GetClientId());

        var result = await _sender.Send(command, cancellationToken);

        return Accepted(result);
    }
}
