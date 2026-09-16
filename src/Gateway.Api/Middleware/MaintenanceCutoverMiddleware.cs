using Gateway.Api.Options;
using Gateway.Infrastructure.Persistence;

namespace Gateway.Api.Middleware;

public sealed class MaintenanceCutoverMiddleware(
    RequestDelegate next, MaintenanceCutoverOptions options)
{
    public async Task InvokeAsync(HttpContext context)
    {
        if (options.Phase == MaintenanceCutoverPhase.Open)
        {
            await next(context);
            return;
        }

        context.Response.Headers.CacheControl = "no-store";
        if (!string.Equals(context.Request.Method, HttpMethods.Get, StringComparison.Ordinal) ||
            !string.Equals(context.Request.Path.Value, "/health/maintenance", StringComparison.Ordinal) ||
            context.Request.PathBase.HasValue)
        {
            context.Response.StatusCode = StatusCodes.Status503ServiceUnavailable;
            await context.Response.WriteAsJsonAsync(new { status = "MaintenanceClosed" }, context.RequestAborted);
            return;
        }

        var schemaAssessment = "NotPerformed";
        if (options.Phase == MaintenanceCutoverPhase.PostSchemaClosed)
        {
            var attested = await context.RequestServices.GetRequiredService<IDatabaseBootstrapAttestationService>()
                .AttestAsync(context.RequestAborted);
            schemaAssessment = attested ? "Attested" : "NotAttested";
            if (!attested)
                context.Response.StatusCode = StatusCodes.Status503ServiceUnavailable;
        }

        await context.Response.WriteAsJsonAsync(new
        {
            contractVersion = 1,
            phase = options.Phase.ToString(),
            options.CutoverId,
            options.PlanFingerprint,
            options.CandidateSourceFingerprint,
            operationalReady = false,
            schemaAssessment
        }, context.RequestAborted);
    }
}
