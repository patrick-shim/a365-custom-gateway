using System.Text.Json;
using Gateway.Contracts;
using Microsoft.AspNetCore.Mvc;
using ValidationException = Gateway.Application.Exceptions.ValidationException;

namespace Gateway.Api.Middleware;

public sealed class ProblemDetailsMiddleware
{
    private readonly RequestDelegate _next;
    private readonly ILogger<ProblemDetailsMiddleware> _logger;
    private readonly IHostEnvironment _environment;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    public ProblemDetailsMiddleware(
        RequestDelegate next,
        ILogger<ProblemDetailsMiddleware> logger,
        IHostEnvironment environment)
    {
        _next = next;
        _logger = logger;
        _environment = environment;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        try
        {
            await _next(context);
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
            await WriteProblemDetailsAsync(context, new ProblemDetails
            {
                Status = StatusCodes.Status404NotFound,
                Title = "Resource Not Found",
                Type = "https://tools.ietf.org/html/rfc9457",
                Detail = ex.Message,
                Extensions =
                {
                    ["errorCode"] = ErrorCodes.AGENT_NOT_FOUND
                }
            });
        }
        catch (Application.Exceptions.ConflictException ex)
        {
            var problemDetails = new ProblemDetails
            {
                Status = StatusCodes.Status409Conflict,
                Title = "Conflict",
                Type = "https://tools.ietf.org/html/rfc9457",
                Detail = ex.Message
            };

            if (!string.IsNullOrEmpty(ex.ErrorCode))
            {
                problemDetails.Extensions["errorCode"] = ex.ErrorCode;
            }

            await WriteProblemDetailsAsync(context, problemDetails);
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
                _ => StatusCodes.Status422UnprocessableEntity
            };

            await WriteProblemDetailsAsync(context, new ProblemDetails
            {
                Status = statusCode,
                Title = "Domain Error",
                Type = "https://tools.ietf.org/html/rfc9457",
                Detail = ex.Message,
                Extensions =
                {
                    ["errorCode"] = ex.ErrorCode
                }
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "An unhandled exception occurred while processing the request");

            var problemDetails = new ProblemDetails
            {
                Status = StatusCodes.Status500InternalServerError,
                Title = "Internal Server Error",
                Type = "https://tools.ietf.org/html/rfc9457"
            };

            if (_environment.IsDevelopment())
            {
                problemDetails.Detail = ex.Message;
            }

            await WriteProblemDetailsAsync(context, problemDetails);
        }
    }

    private static async Task WriteProblemDetailsAsync(HttpContext context, ProblemDetails problemDetails)
    {
        context.Response.StatusCode = problemDetails.Status ?? StatusCodes.Status500InternalServerError;
        context.Response.ContentType = "application/problem+json";

        var correlationId = context.Items["CorrelationId"] as string;
        if (!string.IsNullOrEmpty(correlationId))
        {
            problemDetails.Extensions["correlationId"] = correlationId;
        }

        problemDetails.Instance = context.Request.Path;

        await context.Response.WriteAsJsonAsync(problemDetails, JsonOptions);
    }
}
