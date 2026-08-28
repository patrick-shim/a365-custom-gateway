using System.Net.Http.Headers;
using System.Security.Claims;
using System.Text.Json;
using System.Text.Encodings.Web;
using Gateway.Contracts;
using Gateway.Domain.Interfaces;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Authentication;

internal sealed class GatewayAgentApiKeyAuthenticationHandler
    : AuthenticationHandler<AuthenticationSchemeOptions>
{
    private static readonly JsonSerializerOptions ProblemJsonOptions = new(JsonSerializerDefaults.Web);
    private readonly IAgentIngressCredentialService _credentialService;

    public GatewayAgentApiKeyAuthenticationHandler(
        IOptionsMonitor<AuthenticationSchemeOptions> options,
        ILoggerFactory logger,
        UrlEncoder encoder,
        IAgentIngressCredentialService credentialService)
        : base(options, logger, encoder)
    {
        _credentialService = credentialService;
    }

    protected override async Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (!Request.Headers.TryGetValue("Authorization", out var values))
            return AuthenticateResult.NoResult();

        if (values.Count != 1 ||
            !AuthenticationHeaderValue.TryParse(values[0], out var header) ||
            !string.Equals(header.Scheme, "Bearer", StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(header.Parameter))
        {
            return AuthenticateResult.Fail("A valid Gateway agent credential is required.");
        }

        var credentialIdentity = await _credentialService.ValidateAsync(
            header.Parameter,
            DateTime.UtcNow,
            Context.RequestAborted);

        if (credentialIdentity is null)
            return AuthenticateResult.Fail("A valid Gateway agent credential is required.");

        var claims = new[]
        {
            new Claim(
                GatewayAgentClaimTypes.AgentRegistrationId,
                credentialIdentity.AgentRegistrationId.ToString("D")),
            new Claim(
                GatewayAgentClaimTypes.ExternalAgentId,
                credentialIdentity.ExternalAgentId),
            new Claim(
                GatewayAgentClaimTypes.CredentialId,
                credentialIdentity.CredentialId.ToString("D")),
            new Claim(ClaimTypes.Role, "ExternalAgent")
        };

        var identity = new ClaimsIdentity(
            claims,
            GatewayAgentApiKeyDefaults.AuthenticationScheme);
        var principal = new ClaimsPrincipal(identity);
        var ticket = new AuthenticationTicket(
            principal,
            GatewayAgentApiKeyDefaults.AuthenticationScheme);

        return AuthenticateResult.Success(ticket);
    }

    protected override async Task HandleChallengeAsync(
        AuthenticationProperties properties)
    {
        Response.StatusCode = StatusCodes.Status401Unauthorized;
        Response.Headers.WWWAuthenticate = "Bearer realm=\"A365 Gateway\"";
        Response.ContentType = "application/problem+json";

        var problem = new ProblemDetails
        {
            Type = "https://gateway.example.com/problems/authentication-required",
            Title = "Authentication is required.",
            Status = StatusCodes.Status401Unauthorized,
            Detail = "A valid registration-bound Gateway credential is required.",
            Instance = Request.Path
        };
        problem.Extensions["errorCode"] = ErrorCodes.AUTHENTICATION_REQUIRED;

        if (Context.Items["CorrelationId"] is string correlationId &&
            !string.IsNullOrWhiteSpace(correlationId))
        {
            problem.Extensions["correlationId"] = correlationId;
        }

        await Response.WriteAsJsonAsync(
            problem,
            ProblemJsonOptions,
            contentType: "application/problem+json",
            cancellationToken: Context.RequestAborted);
    }
}
