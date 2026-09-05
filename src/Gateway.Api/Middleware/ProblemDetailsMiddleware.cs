using System.Text.Json;
using Gateway.Contracts;
using Microsoft.AspNetCore.Mvc;
using ValidationException = Gateway.Application.Exceptions.ValidationException;

namespace Gateway.Api.Middleware;

public sealed class ProblemDetailsMiddleware
{
    private readonly RequestDelegate _next;
    private readonly ILogger<ProblemDetailsMiddleware> _logger;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    public ProblemDetailsMiddleware(
        RequestDelegate next,
        ILogger<ProblemDetailsMiddleware> logger)
    {
        _next = next;
        _logger = logger;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        try
        {
            await _next(context);
            if (!context.Response.HasStarted &&
                context.Response.ContentLength is null &&
                context.Response.StatusCode is
                    StatusCodes.Status401Unauthorized or
                    StatusCodes.Status403Forbidden)
            {
                var forbidden =
                    context.Response.StatusCode ==
                    StatusCodes.Status403Forbidden;
                await WriteProblemDetailsAsync(context, new ProblemDetails
                {
                    Status = context.Response.StatusCode,
                    Title = forbidden
                        ? "Forbidden"
                        : "Authentication Required",
                    Type = "https://tools.ietf.org/html/rfc9457",
                    Detail = forbidden
                        ? "The authenticated caller is not authorized to perform this action."
                        : "Authentication is required to perform this action.",
                    Extensions =
                    {
                        ["errorCode"] =
                            ErrorCodes.AUTHENTICATION_REQUIRED
                    }
                });
            }
        }
        catch (ValidationException ex)
        {
            await WriteProblemDetailsAsync(context, new ProblemDetails
            {
                Status = StatusCodes.Status400BadRequest,
                Title = "Validation Failed",
                Type = "https://tools.ietf.org/html/rfc9457",
                Detail = ex.Message,
                Extensions =
                {
                    ["errorCode"] = ErrorCodes.VALIDATION_FAILED,
                    ["errors"] = ex.Errors
                }
            });
        }
        catch (Application.Exceptions.NotFoundException ex)
        {
            var errorCode = ex.Entity switch
            {
                "AgentIngressCredential" =>
                    ErrorCodes.AGENT_INGRESS_CREDENTIAL_NOT_FOUND,
                "ProtectionAdminOperation" =>
                    ErrorCodes.OPERATION_NOT_FOUND,
                "PurviewDlpProfile" =>
                    ErrorCodes.OPERATION_NOT_FOUND,
                _ => ErrorCodes.AGENT_NOT_FOUND
            };

            await WriteProblemDetailsAsync(context, new ProblemDetails
            {
                Status = StatusCodes.Status404NotFound,
                Title = "Resource Not Found",
                Type = "https://tools.ietf.org/html/rfc9457",
                Detail = ex.Message,
                Extensions =
                {
                    ["errorCode"] = errorCode
                }
            });
        }
        catch (Application.Exceptions.ConflictException ex)
        {
            var statusCode = string.Equals(
                ex.ErrorCode,
                ErrorCodes.CONCURRENCY_CONFLICT,
                StringComparison.Ordinal)
                ? StatusCodes.Status412PreconditionFailed
                : StatusCodes.Status409Conflict;
            var problemDetails = new ProblemDetails
            {
                Status = statusCode,
                Title = statusCode == StatusCodes.Status412PreconditionFailed
                    ? "Precondition Failed"
                    : "Conflict",
                Type = "https://tools.ietf.org/html/rfc9457",
                Detail = ex.Message
            };

            if (!string.IsNullOrEmpty(ex.ErrorCode))
            {
                problemDetails.Extensions["errorCode"] = ex.ErrorCode;
            }

            await WriteProblemDetailsAsync(context, problemDetails);
        }
        catch (Application.Exceptions.PreconditionFailedException ex)
        {
            await WriteProblemDetailsAsync(context, new ProblemDetails
            {
                Status = StatusCodes.Status412PreconditionFailed,
                Title = "Precondition Failed",
                Type = "https://tools.ietf.org/html/rfc9457",
                Detail = ex.Message,
                Extensions =
                {
                    ["errorCode"] = ex.ErrorCode
                }
            });
        }
        catch (Application.Exceptions.ProtectionAccessDeniedException ex)
        {
            await WriteProblemDetailsAsync(context, new ProblemDetails
            {
                Status = StatusCodes.Status403Forbidden,
                Title = "Forbidden",
                Type = "https://tools.ietf.org/html/rfc9457",
                Detail = ex.Message,
                Extensions =
                {
                    ["errorCode"] = ErrorCodes.AUTHENTICATION_REQUIRED
                }
            });
        }
        catch (Application.Exceptions.InvalidStateTransitionException ex)
        {
            await WriteProblemDetailsAsync(context, new ProblemDetails
            {
                Status = StatusCodes.Status409Conflict,
                Title = "Invalid State Transition",
                Type = "https://tools.ietf.org/html/rfc9457",
                Detail = ex.Message,
                Extensions =
                {
                    ["errorCode"] = ErrorCodes.INVALID_STATE_TRANSITION,
                    ["currentState"] = ex.CurrentState,
                    ["attemptedAction"] = ex.AttemptedAction
                }
            });
        }
        catch (Application.Exceptions.DomainException ex)
        {
            var statusCode = ex.ErrorCode switch
            {
                ErrorCodes.AGENT_IDENTITY_MISMATCH => StatusCodes.Status403Forbidden,
                ErrorCodes.AGENT_DISABLED => StatusCodes.Status403Forbidden,
                ErrorCodes.PROVISIONING_DISABLED => StatusCodes.Status503ServiceUnavailable,
                ErrorCodes.AGENT365_DEPENDENCY_UNAVAILABLE => StatusCodes.Status503ServiceUnavailable,
                ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE => StatusCodes.Status503ServiceUnavailable,
                ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_UNAVAILABLE => StatusCodes.Status503ServiceUnavailable,
                ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_INVALID_RESPONSE => StatusCodes.Status502BadGateway,
                ErrorCodes.PURVIEW_DEPENDENCY_UNAVAILABLE => StatusCodes.Status503ServiceUnavailable,
                ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE => StatusCodes.Status503ServiceUnavailable,
                ErrorCodes.PURVIEW_TENANT_NOT_CONNECTED => StatusCodes.Status409Conflict,
                ErrorCodes.PURVIEW_INVENTORY_STALE => StatusCodes.Status409Conflict,
                ErrorCodes.PURVIEW_DLP_PROFILE_NOT_READY => StatusCodes.Status409Conflict,
                ErrorCodes.PROTECTION_REVIEW_EXPIRED => StatusCodes.Status410Gone,
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID => StatusCodes.Status403Forbidden,
                ErrorCodes.PROMPT_EVALUATION_UNAVAILABLE => StatusCodes.Status503ServiceUnavailable,
                ErrorCodes.PROMPT_EVALUATION_REQUIRED => StatusCodes.Status403Forbidden,
                ErrorCodes.PROMPT_EVALUATION_INVALID => StatusCodes.Status403Forbidden,
                _ => StatusCodes.Status422UnprocessableEntity
            };

            var title = ex.ErrorCode switch
            {
                ErrorCodes.PROVISIONING_DISABLED => "Provisioning Unavailable",
                ErrorCodes.AGENT365_DEPENDENCY_UNAVAILABLE => "Agent 365 Unavailable",
                ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE => "Provisioning Dependency Unavailable",
                ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_UNAVAILABLE => "Blueprint Catalog Unavailable",
                ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_INVALID_RESPONSE => "Blueprint Catalog Invalid Response",
                ErrorCodes.AGENT_IDENTITY_BLUEPRINT_INCOMPATIBLE => "Blueprint Not Compatible",
                ErrorCodes.PURVIEW_DEPENDENCY_UNAVAILABLE => "Purview Unavailable",
                ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE => "Protection Capability Unavailable",
                ErrorCodes.PURVIEW_TENANT_NOT_CONNECTED => "Purview Tenant Not Connected",
                ErrorCodes.PURVIEW_INVENTORY_STALE => "Purview Inventory Stale",
                ErrorCodes.PURVIEW_DLP_PROFILE_NOT_READY => "Purview DLP Profile Not Ready",
                ErrorCodes.PROTECTION_REVIEW_EXPIRED => "Protection Review Expired",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID => "Protection Confirmation Invalid",
                ErrorCodes.PROMPT_EVALUATION_UNAVAILABLE => "Prompt Evaluation Unavailable",
                ErrorCodes.PROMPT_EVALUATION_REQUIRED => "Prompt Evaluation Required",
                ErrorCodes.PROMPT_EVALUATION_INVALID => "Prompt Evaluation Invalid",
                _ => "Domain Error"
            };

            await WriteProblemDetailsAsync(context, new ProblemDetails
            {
                Status = statusCode,
                Title = title,
                Type = "https://tools.ietf.org/html/rfc9457",
                Detail = ex.Message,
                Extensions =
                {
                    ["errorCode"] = ex.ErrorCode
                }
            });
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
        {
            // The caller disconnected or cancelled the request. Let the host record the
            // cancellation instead of manufacturing a misleading 500 response.
            throw;
        }
        catch (Exception ex)
        {
            var correlationId = context.Items["CorrelationId"] as string;
            _logger.LogError(
                ex,
                "Unhandled request failure. CorrelationId: {CorrelationId}; Method: {Method}; Path: {Path}",
                correlationId ?? "unavailable",
                context.Request.Method,
                context.Request.Path.Value ?? "/");

            if (context.Response.HasStarted)
            {
                throw;
            }

            var problemDetails = new ProblemDetails
            {
                Status = StatusCodes.Status500InternalServerError,
                Title = "Internal Server Error",
                Type = "https://tools.ietf.org/html/rfc9457",
                Detail = "The Gateway could not complete the request. Use the correlation ID when investigating the failure."
            };

            await WriteProblemDetailsAsync(context, problemDetails);
        }
    }

    private static async Task WriteProblemDetailsAsync(HttpContext context, ProblemDetails problemDetails)
    {
        context.Response.StatusCode = problemDetails.Status ?? StatusCodes.Status500InternalServerError;
        context.Response.Headers.CacheControl = "no-store";
        var correlationId = context.Items["CorrelationId"] as string;
        if (!string.IsNullOrEmpty(correlationId))
        {
            problemDetails.Extensions["correlationId"] = correlationId;
        }

        problemDetails.Instance = context.Request.Path;

        await context.Response.WriteAsJsonAsync(
            problemDetails,
            JsonOptions,
            contentType: "application/problem+json",
            cancellationToken: context.RequestAborted);
    }
}
