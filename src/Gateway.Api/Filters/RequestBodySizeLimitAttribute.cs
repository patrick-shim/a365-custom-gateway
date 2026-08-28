using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;
using Gateway.Contracts;

namespace Gateway.Api.Filters;

[AttributeUsage(AttributeTargets.Method)]
internal sealed class RequestBodySizeLimitAttribute(long maximumBytes)
    : Attribute, IAsyncResourceFilter, IOrderedFilter
{
    public int Order => int.MinValue;

    public Task OnResourceExecutionAsync(
        ResourceExecutingContext context,
        ResourceExecutionDelegate next)
    {
        var maximumBodySizeFeature = context.HttpContext.Features
            .Get<IHttpMaxRequestBodySizeFeature>();
        if (maximumBodySizeFeature is { IsReadOnly: false })
            maximumBodySizeFeature.MaxRequestBodySize = maximumBytes;

        if (context.HttpContext.Request.ContentLength > maximumBytes)
        {
            var problem = new ProblemDetails
            {
                Status = StatusCodes.Status413PayloadTooLarge,
                Title = "Payload Too Large",
                Type = "https://tools.ietf.org/html/rfc9457",
                Detail = $"The request body must not exceed {maximumBytes} bytes.",
                Instance = context.HttpContext.Request.Path
            };
            problem.Extensions["errorCode"] = ErrorCodes.PAYLOAD_TOO_LARGE;
            if (context.HttpContext.Items["CorrelationId"] is string correlationId &&
                !string.IsNullOrWhiteSpace(correlationId))
            {
                problem.Extensions["correlationId"] = correlationId;
            }

            var result = new ObjectResult(problem)
            {
                StatusCode = StatusCodes.Status413PayloadTooLarge
            };
            result.ContentTypes.Add("application/problem+json");
            context.Result = result;
            return Task.CompletedTask;
        }

        return next();
    }
}
