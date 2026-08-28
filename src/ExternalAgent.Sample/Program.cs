using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.RegularExpressions;

if (!Arguments.TryParse(args, out var options, out var argumentError))
{
    Console.Error.WriteLine(argumentError);
    Arguments.PrintUsage();
    return 2;
}

var gatewayKey = ReadSecret("Gateway one-time access key: ");
try
{
    if (!Regex.IsMatch(
            gatewayKey,
            "^a365gw_v1_[0-9a-f]{32}\\.[A-Za-z0-9_-]{43}$",
            RegexOptions.CultureInvariant))
    {
        Console.Error.WriteLine("The supplied value is not a valid Gateway v1 access key.");
        return 2;
    }

    using var handler = new HttpClientHandler { AllowAutoRedirect = false };
    using var client = new HttpClient(handler)
    {
        BaseAddress = options.ApiBaseUrl,
        Timeout = TimeSpan.FromSeconds(30)
    };
    client.DefaultRequestHeaders.Authorization =
        new AuthenticationHeaderValue("Bearer", gatewayKey);

    var suffix = Guid.NewGuid().ToString("N");
    var occurredAtUtc = DateTimeOffset.UtcNow;
    var sessionId = $"sample-session-{suffix}";

    await SendAsync(
        client,
        "api/v1/agent-activities",
        new
        {
            externalAgentId = options.ExternalAgentId,
            activityId = $"sample-activity-{suffix}",
            sessionId,
            activityType = "Chat",
            occurredAtUtc,
            actor = new
            {
                type = "User",
                tenantUserObjectId = options.TenantUserObjectId
            },
            tool = (object?)null,
            attributes = new Dictionary<string, string>
            {
                ["sample"] = "external-agent",
                ["transport"] = "gateway"
            }
        },
        "activity/OTel ingestion");

    await SendAsync(
        client,
        "api/v1/ai-interactions",
        new
        {
            externalAgentId = options.ExternalAgentId,
            interactionId = $"sample-interaction-{suffix}",
            sessionId,
            occurredAtUtc,
            userContext = new { tenantUserObjectId = options.TenantUserObjectId },
            prompt = new
            {
                contentType = "text/plain",
                content = options.Message
            },
            response = new
            {
                contentType = "text/plain",
                content = "The sample external agent received the message."
            },
            model = (object?)null,
            metadata = new Dictionary<string, string>
            {
                ["sample"] = "external-agent",
                ["transport"] = "gateway"
            }
        },
        "message ingestion");

    Console.WriteLine("[PASS] The Gateway accepted the sample message and telemetry.");
    return 0;
}
finally
{
    gatewayKey = string.Empty;
    GC.Collect();
}

static async Task SendAsync(HttpClient client, string path, object body, string label)
{
    using var request = new HttpRequestMessage(HttpMethod.Post, path)
    {
        Content = JsonContent.Create(body)
    };
    request.Headers.TryAddWithoutValidation("Idempotency-Key", Guid.NewGuid().ToString("D"));

    using var response = await client.SendAsync(request);
    if (response.StatusCode != HttpStatusCode.Accepted)
    {
        throw new InvalidOperationException(
            $"{label} returned HTTP {(int)response.StatusCode}; expected 202. " +
            "The response body was deliberately not rendered.");
    }

    var correlationId = response.Headers.TryGetValues("X-Correlation-ID", out var values)
        ? values.FirstOrDefault()
        : null;
    Console.WriteLine(string.IsNullOrWhiteSpace(correlationId)
        ? $"[PASS] {label}: HTTP 202"
        : $"[PASS] {label}: HTTP 202 correlation {correlationId}");
}

static string ReadSecret(string prompt)
{
    Console.Write(prompt);
    if (Console.IsInputRedirected)
    {
        var redirected = Console.ReadLine()?.Trim() ?? string.Empty;
        Console.WriteLine();
        return redirected;
    }

    var characters = new List<char>();
    while (true)
    {
        var key = Console.ReadKey(intercept: true);
        if (key.Key == ConsoleKey.Enter)
        {
            Console.WriteLine();
            return new string(characters.ToArray()).Trim();
        }

        if (key.Key == ConsoleKey.Backspace)
        {
            if (characters.Count > 0)
                characters.RemoveAt(characters.Count - 1);
            continue;
        }

        if (!char.IsControl(key.KeyChar))
            characters.Add(key.KeyChar);
    }
}

internal sealed record Arguments(
    Uri ApiBaseUrl,
    string ExternalAgentId,
    Guid TenantUserObjectId,
    string Message)
{
    public static bool TryParse(string[] args, out Arguments result, out string error)
    {
        result = null!;
        error = string.Empty;
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 0; index < args.Length; index += 2)
        {
            if (index + 1 >= args.Length || !args[index].StartsWith("--", StringComparison.Ordinal))
            {
                error = "Arguments must be provided as --name value pairs.";
                return false;
            }

            if (!values.TryAdd(args[index], args[index + 1]))
            {
                error = $"Duplicate argument: {args[index]}";
                return false;
            }
        }

        if (!values.TryGetValue("--api-base-url", out var apiText) ||
            !Uri.TryCreate(apiText, UriKind.Absolute, out var apiBaseUrl) ||
            apiBaseUrl.Scheme != Uri.UriSchemeHttps ||
            !string.IsNullOrEmpty(apiBaseUrl.Query) ||
            !string.IsNullOrEmpty(apiBaseUrl.Fragment))
        {
            error = "--api-base-url must be a plain HTTPS absolute URI.";
            return false;
        }

        if (!values.TryGetValue("--external-agent-id", out var externalAgentId) ||
            !Regex.IsMatch(
                externalAgentId,
                "^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$",
                RegexOptions.CultureInvariant))
        {
            error = "--external-agent-id is missing or invalid.";
            return false;
        }

        if (!values.TryGetValue("--tenant-user-object-id", out var userText) ||
            !Guid.TryParse(userText, out var tenantUserObjectId) ||
            tenantUserObjectId == Guid.Empty)
        {
            error = "--tenant-user-object-id must be a non-empty GUID.";
            return false;
        }

        var known = new HashSet<string>(StringComparer.Ordinal)
        {
            "--api-base-url",
            "--external-agent-id",
            "--tenant-user-object-id",
            "--message"
        };
        var unknown = values.Keys.FirstOrDefault(key => !known.Contains(key));
        if (unknown is not null)
        {
            error = $"Unknown argument: {unknown}";
            return false;
        }

        var message = values.GetValueOrDefault(
            "--message",
            "Hello from the automated external-agent sample.");
        if (string.IsNullOrWhiteSpace(message) || message.Length > 4000)
        {
            error = "--message must contain between 1 and 4,000 characters.";
            return false;
        }

        result = new Arguments(
            EnsureTrailingSlash(apiBaseUrl),
            externalAgentId,
            tenantUserObjectId,
            message);
        return true;
    }

    public static void PrintUsage() => Console.Error.WriteLine(
        "Usage: dotnet run --project src/ExternalAgent.Sample -- " +
        "--api-base-url https://gateway-api.example/ " +
        "--external-agent-id agent-example " +
        "--tenant-user-object-id 00000000-0000-0000-0000-000000000000 " +
        "[--message \"Hello\"]\n" +
        "The Gateway key is read from stdin or from a non-echoing interactive prompt; " +
        "never pass it as a command-line argument.");

    private static Uri EnsureTrailingSlash(Uri uri)
    {
        var builder = new UriBuilder(uri);
        if (!builder.Path.EndsWith("/", StringComparison.Ordinal))
            builder.Path += "/";
        return builder.Uri;
    }
}
