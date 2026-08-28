using System.Text.Json;
using Gateway.Api.Authentication;
using Gateway.Contracts;
using Gateway.Domain.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Middleware;

public sealed class IngressRateLimitMiddleware
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly RequestDelegate _next;
    private readonly ILogger<IngressRateLimitMiddleware> _logger;

    public IngressRateLimitMiddleware(
        RequestDelegate next,
        ILogger<IngressRateLimitMiddleware> logger)
    {
        _next = next;
        _logger = logger;
    }

    public async Task InvokeAsync(
        HttpContext context,
        IIngressRateLimiter rateLimiter)
    {
        var gatewayIdentity = context.User.Identities.FirstOrDefault(identity =>
            identity.IsAuthenticated &&
            string.Equals(
                identity.AuthenticationType,
                GatewayAgentApiKeyDefaults.AuthenticationScheme,
                StringComparison.Ordinal));

        if (gatewayIdentity is null)
        {
            await _next(context);
            return;
        }

        var registrationClaim = gatewayIdentity.FindFirst(
            GatewayAgentClaimTypes.AgentRegistrationId)?.Value;
        var credentialClaim = gatewayIdentity.FindFirst(
            GatewayAgentClaimTypes.CredentialId)?.Value;

        if (!Guid.TryParse(registrationClaim, out var registrationId) ||
            !Guid.TryParse(credentialClaim, out var credentialId))
        {
            await WriteProblemAsync(
                context,
                StatusCodes.Status401Unauthorized,
                "Authentication is required.",
                "A valid registration-bound Gateway credential is required.",
                ErrorCodes.AUTHENTICATION_REQUIRED,
                "https://gateway.example.com/problems/authentication-required");
            return;
        }

        try
        {
            var decision = await rateLimiter.TryAcquireAsync(
                registrationId,
                credentialId,
                context.RequestAborted);

            SetRateLimitHeaders(context.Response, decision);

            if (!decision.Allowed)
            {
                var retryAfter = Math.Max(
                    1,
                    (int)Math.Ceiling((decision.ResetAtUtc - DateTime.UtcNow).TotalSeconds));
                context.Response.Headers.RetryAfter = retryAfter.ToString();
                context.Response.Headers.CacheControl = "no-store";

                await WriteProblemAsync(
                    context,
                    StatusCodes.Status429TooManyRequests,
                    "Rate limit exceeded.",
                    "The Gateway request limit was reached. Retry after the current window resets.",
                    ErrorCodes.RATE_LIMIT_EXCEEDED,
                    "https://gateway.example.com/problems/rate-limit-exceeded");
                return;
            }
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            _logger.LogError(
                exception,
                "Distributed ingress rate-limit enforcement failed closed");
            context.Response.Headers.CacheControl = "no-store";

            await WriteProblemAsync(
                context,
                StatusCodes.Status503ServiceUnavailable,
                "Ingress protection unavailable.",
                "The Gateway cannot safely admit this request right now. Retry later.",
                ErrorCodes.SERVICE_UNAVAILABLE,
                "https://gateway.example.com/problems/service-unavailable");
            return;
        }

        await _next(context);
    }

    private static void SetRateLimitHeaders(
        HttpResponse response,
        Domain.Models.IngressRateLimitDecision decision)
    {
        response.Headers["X-RateLimit-Limit"] = decision.Limit.ToString();
        response.Headers["X-RateLimit-Remaining"] = decision.Remaining.ToString();
        response.Headers["X-RateLimit-Reset"] = new DateTimeOffset(decision.ResetAtUtc)
            .ToUnixTimeSeconds()
            .ToString();
        response.Headers["X-RateLimit-Scope"] = decision.Scope;
    }

    private static async Task WriteProblemAsync(
        HttpContext context,
        int status,
        string title,
        string detail,
        string errorCode,
        string type)
    {
        var problem = new ProblemDetails
        {
            Status = status,
            Title = title,
            Detail = detail,
            Type = type,
            Instance = context.Request.Path
        };
        problem.Extensions["errorCode"] = errorCode;

        if (context.Items["CorrelationId"] is string correlationId &&
            !string.IsNullOrWhiteSpace(correlationId))
        {
            problem.Extensions["correlationId"] = correlationId;
        }

        context.Response.StatusCode = status;
        context.Response.ContentType = "application/problem+json";
        await context.Response.WriteAsJsonAsync(
            problem,
            JsonOptions,
            contentType: "application/problem+json",
            cancellationToken: context.RequestAborted);
    }
}
