using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Api.Filters;
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
    [RequestBodySizeLimit(65_536)]
    [Authorize(Policy = AuthorizationPolicies.ExternalAgentOnly)]
    [ProducesResponseType(typeof(InteractionReceiptDto), StatusCodes.Status202Accepted)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status413PayloadTooLarge)]
    public async Task<IActionResult> SubmitInteraction(
        [FromBody] SubmitInteractionRequest request,
        [FromHeader(Name = "Idempotency-Key")] string? idempotencyKey,
        CancellationToken cancellationToken)
    {
        if (!IdempotencyKeyValidation.TryNormalizeUuidV4(
                idempotencyKey,
                out var normalizedIdempotencyKey))
        {
            return Problem(
                statusCode: StatusCodes.Status400BadRequest,
                title: "Invalid Idempotency Key",
                detail: "The Idempotency-Key header is required and must be a canonical UUID version 4 value.",
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
            User.GetAgentRegistrationId(),
            normalizedIdempotencyKey);

        var result = await _sender.Send(command, cancellationToken);

        return Accepted(result);
    }
}
