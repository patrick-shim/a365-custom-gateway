using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Api.Filters;
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
    [RequestBodySizeLimit(65_536)]
    [Authorize(Policy = AuthorizationPolicies.ExternalAgentOnly)]
    [ProducesResponseType(typeof(ActivityReceiptDto), StatusCodes.Status202Accepted)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status413PayloadTooLarge)]
    public async Task<IActionResult> SubmitActivity(
        [FromBody] SubmitActivityRequest request,
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

        var command = new SubmitActivityCommand(
            request.ExternalAgentId,
            request.ActivityId,
            request.SessionId,
            request.ActivityType,
            request.OccurredAtUtc,
            request.Actor,
            request.Tool,
            request.Attributes,
            User.GetAgentRegistrationId(),
            normalizedIdempotencyKey);

        var result = await _sender.Send(command, cancellationToken);

        return Accepted(result);
    }

    [HttpPost("/api/v1/agent-activities:batch")]
    [RequestBodySizeLimit(1_048_576)]
    [Authorize(Policy = AuthorizationPolicies.ExternalAgentOnly)]
    [ProducesResponseType(typeof(BatchActivityResponse), StatusCodes.Status202Accepted)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status413PayloadTooLarge)]
    public async Task<IActionResult> SubmitBatchActivities(
        [FromBody] BatchActivityRequest request,
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

        var command = new SubmitBatchActivityCommand(
            request.ExternalAgentId,
            request.Activities,
            User.GetAgentRegistrationId(),
            normalizedIdempotencyKey);

        var result = await _sender.Send(command, cancellationToken);

        return Accepted(result);
    }
}
