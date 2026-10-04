namespace Gateway.Setup.Security;

internal sealed class SetupBoundaryMiddleware(RequestDelegate next)
{
    public async Task InvokeAsync(
        HttpContext context,
        SessionNonceGate gate,
        SetupActivityTracker activity)
    {
        if (!LoopbackBindingPolicy.IsAllowedRequest(context))
        {
            context.Response.StatusCode = StatusCodes.Status404NotFound;
            return;
        }

        context.Response.Headers.CacheControl = "no-store, max-age=0";
        context.Response.Headers.Pragma = "no-cache";
        context.Response.Headers.XContentTypeOptions = "nosniff";
        context.Response.Headers.XFrameOptions = "DENY";
        context.Response.Headers["Referrer-Policy"] = "no-referrer";

        var decision = SetupSessionPolicy.Evaluate(
            string.Equals(context.Session.GetString(SetupSessionPolicy.SessionKey), "1", StringComparison.Ordinal),
            context.Request.Method,
            context.Request.Path.Value ?? string.Empty,
            context.Request.Query["nonce"].FirstOrDefault(),
            gate);

        if (decision == SessionDecision.Deny)
        {
            context.Response.StatusCode = StatusCodes.Status404NotFound;
            return;
        }

        if (decision == SessionDecision.Establish)
        {
            context.Session.SetString(SetupSessionPolicy.SessionKey, "1");
            await context.Session.CommitAsync(context.RequestAborted);
            context.Response.Redirect("/setup/welcome", permanent: false);
            return;
        }

        activity.Touch();
        await next(context);
    }

}
