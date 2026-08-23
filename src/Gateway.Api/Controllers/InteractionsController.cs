using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Application.Interactions.Commands;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using MediatR;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/ai-interactions")]
public class InteractionsController : ControllerBase
{
    private readonly ISender _sender;

    public InteractionsController(ISender sender)
    {
        _sender = sender;
    }

    [HttpPost]
    [Authorize(Policy = AuthorizationPolicies.ExternalAgentOnly)]
    [ProducesResponseType(typeof(InteractionReceiptDto), StatusCodes.Status202Accepted)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> SubmitInteraction(
        [FromBody] SubmitInteractionRequest request,
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

        var command = new SubmitInteractionCommand(
            request.ExternalAgentId,
            request.InteractionId,
            request.SessionId,
            request.OccurredAtUtc,
            request.UserContext,
            request.Prompt,
            request.Response,
            request.Model,
            request.Metadata,
            User.GetClientId(),
            idempotencyKey);

        var result = await _sender.Send(command, cancellationToken);

        return Accepted(result);
    }
}
