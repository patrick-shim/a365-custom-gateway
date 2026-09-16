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

        if (IsStaticAssetRequest(context.Request))
        {
            await next(context);
            return;
        }

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

    internal static bool IsStaticAssetRequest(HttpRequest request)
    {
        if (!HttpMethods.IsGet(request.Method) && !HttpMethods.IsHead(request.Method))
        {
            return false;
        }

        var path = request.Path.Value ?? string.Empty;
        if (path.StartsWith("/_framework/", StringComparison.Ordinal) ||
            path.StartsWith("/_content/Microsoft.FluentUI.AspNetCore.Components/", StringComparison.Ordinal))
        {
            return HasAllowedStaticExtension(path);
        }

        return path.IndexOf('/', 1) < 0 && HasAllowedStaticExtension(path);
    }

    private static bool HasAllowedStaticExtension(string path) =>
        path.EndsWith(".css", StringComparison.OrdinalIgnoreCase) ||
        path.EndsWith(".js", StringComparison.OrdinalIgnoreCase) ||
        path.EndsWith(".map", StringComparison.OrdinalIgnoreCase) ||
        path.EndsWith(".woff2", StringComparison.OrdinalIgnoreCase) ||
        path.EndsWith(".wasm", StringComparison.OrdinalIgnoreCase);
}
