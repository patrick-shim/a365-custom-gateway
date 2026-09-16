using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Models;
using Gateway.Contracts.Requests;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.HttpLogging;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.AdminUi.Services;

public static class PurviewRuntimePortalEndpoints
{
    public const int MaximumRequestBytes = 1_048_576;
    public const string Prefix = "/portal/protection/runtime-tests";
    private static readonly UTF8Encoding ExactUtf8 = new(false, true);
    private static readonly JsonSerializerOptions InputOptions = new(JsonSerializerDefaults.Web)
    {
        MaxDepth = 12,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public static void MapPurviewRuntimePortalEndpoints(this IEndpointRouteBuilder endpoints)
    {
        var group = endpoints.MapGroup(Prefix)
            .RequireAuthorization(GatewayPolicies.AdministratorOnly)
            .WithMetadata(new HttpLoggingAttribute(HttpLoggingFields.None));
        group.MapGet("/antiforgery", Antiforgery);
        group.MapPost("/{profileId:guid}/execute", ExecuteAsync)
            .WithMetadata(new RequestSizeLimitAttribute(MaximumRequestBytes));
    }

    internal static IResult Antiforgery(HttpContext context, IAntiforgery antiforgery)
    {
        NoStore(context);
        if (!Authorized(context)) return Denied(context);
        if (!context.Request.IsHttps) return Results.Json(new { code = "HttpsRequired" }, statusCode: StatusCodes.Status400BadRequest);
        var tokens = antiforgery.GetAndStoreTokens(context);
        return Results.Json(new { requestToken = tokens.RequestToken, headerName = tokens.HeaderName });
    }

    internal static async Task<IResult> ExecuteAsync(HttpContext context, Guid profileId,
        IAntiforgery antiforgery, IPurviewRuntimeExecutionClient client)
    {
        NoStore(context);
        if (!Authorized(context)) return Denied(context);
        if (!context.Request.IsHttps) return Results.Json(new { code = "HttpsRequired" }, statusCode: StatusCodes.Status400BadRequest);
        if (context.Features.Get<IHttpMaxRequestBodySizeFeature>() is { IsReadOnly: false } limit)
            limit.MaxRequestBodySize = MaximumRequestBytes;
        RuntimePortalExecutionRequest? request = null;
        byte[]? buffer = null;
        try
        {
            await antiforgery.ValidateRequestAsync(context);
            if (profileId == Guid.Empty || context.Request.ContentLength > MaximumRequestBytes ||
                !string.Equals(context.Request.ContentType?.Split(';')[0].Trim(), "application/json", StringComparison.OrdinalIgnoreCase))
                return Invalid();
            buffer = new byte[MaximumRequestBytes + 1];
            var total = 0;
            while (total < buffer.Length)
            {
                var read = await context.Request.Body.ReadAsync(buffer.AsMemory(total), context.RequestAborted);
                if (read == 0) break;
                total += read;
            }
            if (total > MaximumRequestBytes) return Invalid();
            request = JsonSerializer.Deserialize<RuntimePortalExecutionRequest>(buffer.AsSpan(0, total), InputOptions);
            if (!ValidRequest(request)) return Invalid();
            var report = await client.ExecuteAsync(context.User, profileId, request!, context.RequestAborted);
            if (!RuntimeTestUiProtocol.IsSafeReport(report, request!.ReviewTokenId))
                throw new InvalidOperationException();
            return Results.Json(report);
        }
        catch (AntiforgeryValidationException)
        {
            return Results.Json(new { code = "AntiforgeryRequired" }, statusCode: StatusCodes.Status400BadRequest);
        }
        catch (Exception exception) when (exception is JsonException or ArgumentException)
        {
            return Invalid();
        }
        catch (Exception)
        {
            // No exception, body, ModelState, or provider details are logged or echoed.
            return Results.Json(new { code = "OutcomeUnknown", operationId = request?.ReviewTokenId },
                statusCode: StatusCodes.Status502BadGateway);
        }
        finally
        {
            request = null;
            if (buffer is not null) CryptographicOperations.ZeroMemory(buffer);
        }
    }

    internal static bool ValidRequest(RuntimePortalExecutionRequest? request)
    {
        if (request is null || request.ReviewTokenId == Guid.Empty || request.IdempotencyKey == Guid.Empty ||
            !Guid.TryParseExact(request.IdempotencyKey.ToString("D"), "D", out _) ||
            request.IdempotencyKey.ToString("D")[14] != '4' ||
            string.IsNullOrWhiteSpace(request.ReviewToken) || request.ReviewToken.Length > 32768 ||
            string.IsNullOrWhiteSpace(request.ExpectedRowVersion) || request.ExpectedRowVersion.Length > 128 ||
            request.ExpectedRowVersion.Contains('\r') || request.ExpectedRowVersion.Contains('\n') ||
            request.Samples is null || request.Samples.Count is < 2 or > RuntimeTestUiProtocol.MaximumBatchPositives + 1 ||
            request.Samples.Any(item => item is null || item.CaseId == Guid.Empty || item.Content is null) ||
            request.Samples.Select(item => item.CaseId).Distinct().Count() != request.Samples.Count)
            return false;
        try
        {
            var sizes = request.Samples.Select(item => ExactUtf8.GetByteCount(item.Content)).ToArray();
            return sizes.All(size => size is > 0 and <= RuntimeTestUiProtocol.MaximumSampleBytes) &&
                sizes.Sum() <= RuntimeTestUiProtocol.MaximumBatchBytes;
        }
        catch (EncoderFallbackException) { return false; }
    }

    private static bool Authorized(HttpContext context) =>
        context.User.Identity?.IsAuthenticated == true && context.User.IsInRole(GatewayRoles.Administrator);
    private static IResult Denied(HttpContext context) => Results.Json(new { code = "AdministratorRequired" },
        statusCode: context.User.Identity?.IsAuthenticated == true ? StatusCodes.Status403Forbidden : StatusCodes.Status401Unauthorized);
    private static IResult Invalid() => Results.Json(new { code = "InvalidRuntimeTestRequest" }, statusCode: StatusCodes.Status400BadRequest);
    private static void NoStore(HttpContext context)
    {
        context.Response.Headers.CacheControl = "no-store";
        context.Response.Headers.Pragma = "no-cache";
        if (context.Features.Get<IStatusCodePagesFeature>() is { } pages) pages.Enabled = false;
    }
}
