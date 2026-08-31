using System.Security.Claims;
using System.Text;
using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Api.Options;
using Gateway.Application.Agents.Commands;
using Gateway.Application.Agents.Queries;
using Gateway.Contracts;
using Gateway.Contracts.Responses;
using MediatR;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Identity.Web;
using Microsoft.Net.Http.Headers;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/operations")]
public class OperationsController : ControllerBase
{
    private readonly ISender _sender;
    private readonly DelegatedRegistryActionGate _actionGate;

    public OperationsController(
        ISender sender,
        DelegatedRegistryActionGate actionGate)
    {
        _sender = sender;
        _actionGate = actionGate;
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

        return Ok(result with
        {
            Agent365RegistrationCompletionAvailable =
                string.Equals(
                    result.RequiredAction,
                    "CompleteAgent365Registration",
                    StringComparison.Ordinal) &&
                _actionGate.IsOpen
        });
    }

    [HttpPost("{operationId:guid}:complete-agent365-registration")]
    [Authorize(Policy = AuthorizationPolicies.DelegatedAdministratorRegistry)]
    [ProducesResponseType(typeof(CompleteAgent365RegistrationResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status401Unauthorized)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> CompleteAgent365Registration(
        Guid operationId,
        CancellationToken cancellationToken)
    {
        _actionGate.EnsureOpen();

        CompleteAgent365RegistrationResponse result;
        try
        {
            result = await _sender.Send(
                new CompleteAgent365RegistrationCommand(
                    operationId,
                    Gateway.Api.Extensions.ClaimsPrincipalExtensions.GetObjectId(User)),
                cancellationToken);
        }
        catch (MicrosoftIdentityWebChallengeUserException exception)
        {
            return CreateDelegatedAuthorizationChallenge(exception);
        }

        return Ok(result);
    }

    private IActionResult CreateDelegatedAuthorizationChallenge(
        MicrosoftIdentityWebChallengeUserException exception)
    {
        var requiredScopes = exception.Scopes
            .Where(scope => !string.IsNullOrWhiteSpace(scope))
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        var claims = exception.MsalUiRequiredException.Claims;
        var hasClaimsChallenge = !string.IsNullOrWhiteSpace(claims);

        Response.Headers[HeaderNames.WWWAuthenticate] = BuildBearerChallenge(
            requiredScopes,
            hasClaimsChallenge ? claims : null);

        var problem = new ProblemDetails
        {
            Type = "https://gateway.example.com/problems/delegated-authorization-required",
            Title = "Additional Microsoft Entra authorization is required",
            Status = StatusCodes.Status401Unauthorized,
            Detail = hasClaimsChallenge
                ? "Conditional Access requires another Microsoft Entra interaction before Agent 365 registration can continue."
                : "Additional administrator consent or sign-in interaction is required before Agent 365 registration can continue.",
            Instance = Request.Path
        };
        problem.Extensions["errorCode"] =
            ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED;
        problem.Extensions["challengeType"] = hasClaimsChallenge
            ? "claims_challenge"
            : "consent_required";
        problem.Extensions["claimsChallenge"] = hasClaimsChallenge;
        problem.Extensions["requiredScopes"] = requiredScopes;

        if (HttpContext.Items["CorrelationId"] is string correlationId &&
            !string.IsNullOrWhiteSpace(correlationId))
        {
            problem.Extensions["correlationId"] = correlationId;
        }

        var response = new ObjectResult(problem)
        {
            StatusCode = StatusCodes.Status401Unauthorized
        };
        response.ContentTypes.Add("application/problem+json");
        return response;
    }

    private string BuildBearerChallenge(
        IReadOnlyList<string> requiredScopes,
        string? claims)
    {
        var tenantId = User.FindFirstValue("tid");
        var hasTenantId = Guid.TryParse(tenantId, out var parsedTenantId) &&
            parsedTenantId != Guid.Empty;
        var authorityTenant = hasTenantId ? parsedTenantId.ToString("D") : "common";
        var realm = hasTenantId ? authorityTenant : string.Empty;
        var authorizationUri =
            $"https://login.microsoftonline.com/{authorityTenant}/oauth2/v2.0/authorize";

        if (!string.IsNullOrWhiteSpace(claims))
        {
            var encodedClaims = Convert.ToBase64String(
                Encoding.UTF8.GetBytes(claims.Trim()));
            return string.Join(
                ", ",
                "Bearer realm=" + QuoteHeaderValue(realm),
                "authorization_uri=" + QuoteHeaderValue(authorizationUri),
                "error=\"insufficient_claims\"",
                "claims=" + QuoteHeaderValue(encodedClaims));
        }

        return string.Join(
            ", ",
            "Bearer realm=" + QuoteHeaderValue(realm),
            "authorization_uri=" + QuoteHeaderValue(authorizationUri),
            "error=\"insufficient_scope\"",
            "scope=" + QuoteHeaderValue(string.Join(' ', requiredScopes)));
    }

    private static string QuoteHeaderValue(string value) =>
        $"\"{value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal)}\"";
}
