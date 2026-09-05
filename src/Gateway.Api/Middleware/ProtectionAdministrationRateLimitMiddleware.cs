using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Gateway.Contracts;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Middleware;

public sealed class ProtectionAdministrationRateLimitStore
{
    private static readonly TimeSpan Window = TimeSpan.FromMinutes(1);
    private readonly object _gate = new();
    private readonly Dictionary<string, Counter> _partitions =
        new(StringComparer.Ordinal);
    private readonly TimeProvider _timeProvider;
    private readonly int _userLimit;
    private readonly int _ipLimit;
    private readonly int _maximumPartitions;

    public ProtectionAdministrationRateLimitStore(
        TimeProvider timeProvider,
        int userLimit = 20,
        int ipLimit = 60,
        int maximumPartitions = 4096)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(userLimit);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(ipLimit);
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumPartitions, 2);
        _timeProvider = timeProvider;
        _userLimit = userLimit;
        _ipLimit = ipLimit;
        _maximumPartitions = maximumPartitions;
    }

    public int PartitionCount
    {
        get
        {
            lock (_gate)
                return _partitions.Count;
        }
    }

    public ProtectionAdministrationRateLimitDecision TryAcquire(
        string userObjectId,
        string remoteIpAddress)
    {
        var now = _timeProvider.GetUtcNow();
        var userKey = OpaqueKey("user", userObjectId);
        var ipKey = OpaqueKey("ip", remoteIpAddress);
        lock (_gate)
        {
            RemoveExpired(now);
            var missingPartitions = new[] { userKey, ipKey }
                .Distinct(StringComparer.Ordinal)
                .Count(key => !_partitions.ContainsKey(key));
            if (_partitions.Count + missingPartitions >
                _maximumPartitions)
            {
                return new(false, now.Add(Window));
            }

            var user = GetOrCreate(userKey, now);
            var ip = GetOrCreate(ipKey, now);
            if (user.Count >= _userLimit || ip.Count >= _ipLimit)
            {
                return new(
                    false,
                    user.ResetAtUtc > ip.ResetAtUtc
                        ? user.ResetAtUtc
                        : ip.ResetAtUtc);
            }

            user.Count++;
            ip.Count++;
            return new(
                true,
                user.ResetAtUtc < ip.ResetAtUtc
                    ? user.ResetAtUtc
                    : ip.ResetAtUtc);
        }
    }

    private Counter GetOrCreate(string key, DateTimeOffset now)
    {
        if (_partitions.TryGetValue(key, out var counter))
            return counter;
        counter = new Counter(now.Add(Window));
        _partitions.Add(key, counter);
        return counter;
    }

    private void RemoveExpired(DateTimeOffset now)
    {
        foreach (var key in _partitions
                     .Where(pair => pair.Value.ResetAtUtc <= now)
                     .Select(pair => pair.Key)
                     .ToArray())
        {
            _partitions.Remove(key);
        }
    }

    private static string OpaqueKey(string scope, string value)
    {
        var bytes = Encoding.UTF8.GetBytes($"{scope}\n{value}");
        try
        {
            return Convert.ToHexString(SHA256.HashData(bytes));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    private sealed class Counter
    {
        public Counter(DateTimeOffset resetAtUtc)
        {
            ResetAtUtc = resetAtUtc;
        }

        public int Count { get; set; }
        public DateTimeOffset ResetAtUtc { get; }
    }
}

public readonly record struct ProtectionAdministrationRateLimitDecision(
    bool Allowed,
    DateTimeOffset ResetAtUtc);

public sealed class ProtectionAdministrationRateLimitMiddleware
{
    private static readonly JsonSerializerOptions JsonOptions =
        new(JsonSerializerDefaults.Web);
    private readonly RequestDelegate _next;

    public ProtectionAdministrationRateLimitMiddleware(RequestDelegate next)
    {
        _next = next;
    }

    public async Task InvokeAsync(
        HttpContext context,
        ProtectionAdministrationRateLimitStore store)
    {
        if (!RequiresProtection(context.Request))
        {
            await _next(context);
            return;
        }

        var objectId = context.User.FindFirst(
                "http://schemas.microsoft.com/identity/claims/objectidentifier")
            ?.Value ?? context.User.FindFirst("oid")?.Value ?? "missing";
        var tenantId = context.User.FindFirst(
                "http://schemas.microsoft.com/identity/claims/tenantid")
            ?.Value ?? context.User.FindFirst("tid")?.Value ?? "missing";
        var remoteIp = context.Connection.RemoteIpAddress?.ToString() ??
            "unavailable";
        var decision = store.TryAcquire(
            $"{tenantId}:{objectId}",
            remoteIp);
        if (decision.Allowed)
        {
            await _next(context);
            return;
        }

        var retryAfter = Math.Max(
            1,
            (int)Math.Ceiling(
                (decision.ResetAtUtc - DateTimeOffset.UtcNow).TotalSeconds));
        context.Response.Headers.RetryAfter = retryAfter.ToString();
        context.Response.Headers.CacheControl = "no-store";
        var problem = new ProblemDetails
        {
            Status = StatusCodes.Status429TooManyRequests,
            Title = "Rate limit exceeded.",
            Detail =
                "The protection administration request limit was reached. Retry after the current window resets.",
            Type =
                "https://gateway.example.com/problems/rate-limit-exceeded",
            Instance = context.Request.Path
        };
        problem.Extensions["errorCode"] = ErrorCodes.RATE_LIMIT_EXCEEDED;
        if (context.Items["CorrelationId"] is string correlationId)
            problem.Extensions["correlationId"] = correlationId;
        context.Response.StatusCode = StatusCodes.Status429TooManyRequests;
        await context.Response.WriteAsJsonAsync(
            problem,
            JsonOptions,
            contentType: "application/problem+json",
            cancellationToken: context.RequestAborted);
    }

    private static bool RequiresProtection(HttpRequest request)
    {
        if (HttpMethods.IsPost(request.Method) &&
            request.Path.StartsWithSegments(
                "/api/v1/protection",
                StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        if (!HttpMethods.IsPatch(request.Method))
            return false;
        var path = request.Path.Value;
        return string.Equals(
                path?.TrimEnd('/'),
                "/api/v1/system/config",
                StringComparison.OrdinalIgnoreCase) ||
            NormalizeAgentFeaturesPath(path) is not null;
    }

    private static string? NormalizeAgentFeaturesPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return null;
        var segments = path.Trim('/').Split(
            '/',
            StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length != 5 ||
            !string.Equals(segments[0], "api", StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(segments[1], "v1", StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(segments[2], "agents", StringComparison.OrdinalIgnoreCase) ||
            !Guid.TryParse(segments[3], out var agentId) ||
            agentId == Guid.Empty ||
            !string.Equals(segments[4], "features", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        return $"/api/v1/agents/{agentId:D}/features";
    }
}
