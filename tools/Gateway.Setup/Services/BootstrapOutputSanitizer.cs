using System.Text.Json;
using System.Text.RegularExpressions;
using Gateway.Setup.Models;

namespace Gateway.Setup.Services;

internal static partial class BootstrapOutputSanitizer
{
    public const string WithheldMessage =
        "Bootstrap emitted diagnostic output that was withheld by the setup safety boundary.";

    public const string LegacyMessage =
        "Bootstrap is running with bounded legacy output; unstructured details are withheld.";

    public const string StreamBudgetMessage =
        "Bootstrap output exceeded the setup safety budget; additional child-process output was discarded.";

    public static BootstrapProgressEvent Parse(string? line, bool standardError)
    {
        var timestamp = DateTimeOffset.UtcNow;
        if (string.IsNullOrWhiteSpace(line))
        {
            return new BootstrapProgressEvent(timestamp, BootstrapProgressKind.Withheld, LegacyMessage);
        }

        var bounded = StripAnsi(line).Trim();
        if (bounded.Length > 4_096)
        {
            return new BootstrapProgressEvent(timestamp, BootstrapProgressKind.Withheld, WithheldMessage);
        }

        if (!standardError &&
            bounded.StartsWith('{') &&
            TryParseStructured(bounded, timestamp, out var structured))
        {
            return structured;
        }

        return new BootstrapProgressEvent(
            timestamp,
            standardError ? BootstrapProgressKind.Error : BootstrapProgressKind.Withheld,
            standardError
                ? "Bootstrap reported an error. Sensitive or unstructured details were withheld."
                : LegacyMessage);
    }

    private static bool TryParseStructured(
        string json,
        DateTimeOffset fallbackTimestamp,
        out BootstrapProgressEvent progressEvent)
    {
        progressEvent = new BootstrapProgressEvent(
            fallbackTimestamp,
            BootstrapProgressKind.Withheld,
            WithheldMessage);

        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 8
            });
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return true;
            }

            var root = document.RootElement;
            if (!root.TryGetProperty("schemaVersion", out var schemaVersion) ||
                schemaVersion.ValueKind != JsonValueKind.Number ||
                !schemaVersion.TryGetInt32(out var parsedSchemaVersion) ||
                parsedSchemaVersion != 1)
            {
                return true;
            }

            var discriminator = ReadBoundedString(root, "type");
            var message = ReadBoundedString(root, "message");
            if (!TryMapKind(discriminator, out var kind) ||
                string.IsNullOrWhiteSpace(message) ||
                !TrySanitizeRecognizedMessage(message, out var safeMessage))
            {
                return true;
            }

            var data = root.TryGetProperty("data", out var dataElement) &&
                dataElement.ValueKind == JsonValueKind.Object
                    ? dataElement
                    : default;
            var category = data.ValueKind == JsonValueKind.Object
                ? ReadBoundedString(data, "category")
                : null;
            var step = data.ValueKind == JsonValueKind.Object
                ? ReadBoundedString(data, "step")
                : null;
            if (step is not null && !TrySanitizeRecognizedMessage(step, out step))
            {
                step = null;
            }

            var progress = data.ValueKind == JsonValueKind.Object
                ? CalculateProgress(discriminator!, data)
                : null;

            Uri? adminUiAddress = null;
            var addressText = data.ValueKind == JsonValueKind.Object
                ? ReadBoundedString(data, "adminUiUrl")
                : null;
            if (IsVerifiedAdminResult(discriminator, step, data) &&
                Uri.TryCreate(addressText, UriKind.Absolute, out var parsedAddress) &&
                parsedAddress.Scheme == Uri.UriSchemeHttps &&
                string.IsNullOrEmpty(parsedAddress.UserInfo))
            {
                adminUiAddress = new UriBuilder(parsedAddress)
                {
                    Query = string.Empty,
                    Fragment = string.Empty
                }.Uri;
            }

            var timestamp = fallbackTimestamp;
            var timestampText = ReadBoundedString(root, "timestampUtc");
            if (DateTimeOffset.TryParse(timestampText, out var parsedTimestamp))
            {
                timestamp = parsedTimestamp.ToUniversalTime();
            }

            string? planFingerprint = null;
            bool? planApplyReady = null;
            if (string.Equals(discriminator, "Result", StringComparison.Ordinal) &&
                string.Equals(step, "Plan review", StringComparison.Ordinal) &&
                data.ValueKind == JsonValueKind.Object &&
                string.Equals(category, "planResult", StringComparison.Ordinal) &&
                data.TryGetProperty("applyReady", out var applyReadyElement) &&
                applyReadyElement.ValueKind is JsonValueKind.True or JsonValueKind.False)
            {
                var applyReady = applyReadyElement.GetBoolean();
                var expectedMessage = applyReady
                    ? "Plan is ready for explicit acceptance."
                    : "Plan is not apply-ready.";
                var candidate = ReadBoundedString(data, "planFingerprint");
                if (string.Equals(safeMessage, expectedMessage, StringComparison.Ordinal) &&
                    PlanFingerprintPolicy.IsCanonical(candidate))
                {
                    planFingerprint = candidate;
                    planApplyReady = applyReady;
                }
            }

            progressEvent = new BootstrapProgressEvent(
                timestamp,
                kind,
                safeMessage,
                step,
                progress,
                adminUiAddress,
                planFingerprint,
                planApplyReady,
                string.Equals(step, "Plan review", StringComparison.Ordinal)
                    ? MapPlanReviewLabel(category)
                    : null);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static string? ReadBoundedString(JsonElement root, string propertyName)
    {
        if (!root.TryGetProperty(propertyName, out var element) || element.ValueKind != JsonValueKind.String)
        {
            return null;
        }

        var value = element.GetString();
        return value is { Length: <= 1_024 } ? value : null;
    }

    private static bool TryMapKind(string? value, out BootstrapProgressKind kind)
    {
        kind = value switch
        {
            "PhaseStarted" => BootstrapProgressKind.Step,
            "PhaseCompleted" or "Result" => BootstrapProgressKind.Success,
            "Info" => BootstrapProgressKind.Information,
            "Warning" => BootstrapProgressKind.Warning,
            _ => BootstrapProgressKind.Withheld
        };
        return kind != BootstrapProgressKind.Withheld;
    }

    private static int? CalculateProgress(string type, JsonElement data)
    {
        if (!data.TryGetProperty("index", out var indexElement) ||
            !indexElement.TryGetInt32(out var index) ||
            !data.TryGetProperty("total", out var totalElement) ||
            !totalElement.TryGetInt32(out var total) ||
            total is < 1 or > 10_000 ||
            index is < 1 ||
            index > total)
        {
            return null;
        }

        var completedUnits = string.Equals(type, "PhaseStarted", StringComparison.Ordinal)
            ? index - 1
            : index;
        return Math.Clamp((int)Math.Round(completedUnits * 100d / total), 0, 100);
    }

    private static string? MapPlanReviewLabel(string? category) => category switch
    {
        "scope" => "Scope and fingerprint",
        "features" => "Feature flags",
        "resourceFamily" => "Azure resource family",
        "imperativeOperation" => "Imperative operation",
        "whatIf" => "Azure What-If summary",
        "whatIfChange" => "Sanitized What-If change",
        "boundaries" => "Deployment boundaries",
        "costBoundary" => "Cost boundary",
        "previewBoundary" => "Preview boundary",
        "administratorBoundary" => "Administrator boundary",
        "notChecked" => "Not checked by Plan",
        "planResult" => "Plan decision",
        _ => null
    };

    private static bool IsVerifiedAdminResult(
        string? type,
        string? step,
        JsonElement data) =>
        string.Equals(type, "Result", StringComparison.Ordinal) &&
        string.Equals(step, "End-to-end deployment verification", StringComparison.Ordinal) &&
        data.ValueKind == JsonValueKind.Object &&
        string.Equals(ReadBoundedString(data, "category"), "deploymentVerified", StringComparison.Ordinal) &&
        data.TryGetProperty("verified", out var verifiedElement) &&
        verifiedElement.ValueKind == JsonValueKind.True &&
        data.TryGetProperty("index", out var indexElement) &&
        indexElement.TryGetInt32(out var index) &&
        data.TryGetProperty("total", out var totalElement) &&
        totalElement.TryGetInt32(out var total) &&
        total is >= 1 and <= 10_000 &&
        index == total;

    private static bool TrySanitizeRecognizedMessage(string value, out string sanitized)
    {
        sanitized = string.Empty;
        if (value.Length is 0 or > 512 ||
            value.Any(character => char.IsControl(character) && character is not '\t') ||
            value.Contains('{', StringComparison.Ordinal) ||
            value.Contains('}', StringComparison.Ordinal) ||
            SensitiveLabelPattern().IsMatch(value) ||
            !SafePublicValuePolicy.IsAllowed(value))
        {
            return false;
        }

        sanitized = HomePathPattern().Replace(value, "[local-path]");
        sanitized = EmailPattern().Replace(sanitized, "[email]");
        sanitized = UrlQueryPattern().Replace(sanitized, "$1");
        return true;
    }

    private static string StripAnsi(string value) => AnsiPattern().Replace(value, string.Empty);

    [GeneratedRegex("\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])", RegexOptions.CultureInvariant)]
    private static partial Regex AnsiPattern();

    [GeneratedRegex("(?i)\\b(?:authorization|bearer|password|secret|token|assertion|gateway[ -]?key|connection[ -]?string|raw[ -]?(?:prompt|response)|prompt[ -]?content|response[ -]?body|provider[ -]?body)\\b", RegexOptions.CultureInvariant)]
    private static partial Regex SensitiveLabelPattern();

    [GeneratedRegex("(?i)(?:/Users/|/home/|[A-Z]:\\\\Users\\\\)[^\\s]+", RegexOptions.CultureInvariant)]
    private static partial Regex HomePathPattern();

    [GeneratedRegex("(?i)\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b", RegexOptions.CultureInvariant)]
    private static partial Regex EmailPattern();

    [GeneratedRegex("(https?://[^\\s?#]+)(?:[?#][^\\s]*)", RegexOptions.CultureInvariant)]
    private static partial Regex UrlQueryPattern();
}
