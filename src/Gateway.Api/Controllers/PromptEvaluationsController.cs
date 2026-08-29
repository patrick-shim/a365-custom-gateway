using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Api.Filters;
using Gateway.Application.Prompts.Commands;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using MediatR;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/prompts:evaluate")]
public sealed class PromptEvaluationsController : ControllerBase
{
    private readonly ISender _sender;

    public PromptEvaluationsController(ISender sender)
    {
        _sender = sender;
    }

    [HttpPost]
    [RequestBodySizeLimit(32_768)]
    [Authorize(Policy = AuthorizationPolicies.ExternalAgentOnly)]
    [ProducesResponseType(typeof(PromptEvaluationResultDto), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> Evaluate(
        [FromBody] EvaluatePromptRequest request,
        [FromHeader(Name = "Idempotency-Key")] string? idempotencyKey,
        CancellationToken cancellationToken)
    {
        if (!IdempotencyKeyValidation.TryNormalizeUuidV4(idempotencyKey, out var normalizedIdempotencyKey))
        {
            return Problem(
                statusCode: StatusCodes.Status400BadRequest,
                title: "Invalid Idempotency Key",
                detail: "The Idempotency-Key header is required and must be a canonical UUID version 4 value.",
                type: "https://tools.ietf.org/html/rfc9457");
        }

        var result = await _sender.Send(new EvaluatePromptCommand(
            request.ExternalAgentId,
            request.InteractionId,
            request.OccurredAtUtc,
            request.UserContext,
            request.Prompt,
            User.GetAgentRegistrationId(),
            normalizedIdempotencyKey!), cancellationToken);
        if (result.Allowed)
            return Ok(result);

        var problem = new ProblemDetails
        {
            Status = StatusCodes.Status403Forbidden,
            Title = "Prompt blocked",
            Detail = result.UserMessage,
            Type = "https://tools.ietf.org/html/rfc9457",
            Instance = Request.Path
        };
        problem.Extensions["errorCode"] = result.Decision;
        problem.Extensions["evaluationId"] = result.EvaluationId;
        problem.Extensions["promptShieldProcessing"] = result.PromptShieldProcessing;
        problem.Extensions["purviewProcessing"] = result.PurviewProcessing;
        problem.Extensions["correlationId"] = result.CorrelationId;
        Response.Headers.CacheControl = "no-store";
        return new ObjectResult(problem)
        {
            StatusCode = StatusCodes.Status403Forbidden,
            ContentTypes = { "application/problem+json" }
        };
    }
}
