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

    public const string InvalidVerificationMessage =
        "Bootstrap emitted an invalid deployment verification result. Endpoint proof was rejected.";

    public const string InvalidPlanResultMessage =
        "Bootstrap emitted an invalid Plan decision result. Mutation authorization was rejected.";

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

            var data = root.TryGetProperty("data", out var dataElement) &&
                dataElement.ValueKind == JsonValueKind.Object
                    ? dataElement
                    : default;
            var discriminator = ReadBoundedString(root, "type");
            var category = data.ValueKind == JsonValueKind.Object
                ? ReadBoundedString(data, "category")
                : null;
            var step = data.ValueKind == JsonValueKind.Object
                ? ReadBoundedString(data, "step")
                : null;
            var deploymentVerificationClaimObserved = IsDeploymentVerificationClaim(
                discriminator,
                step,
                category);
            var planResultClaimObserved = IsPlanResultClaim(discriminator, step, category);
            if (!TryMapKind(discriminator, out var kind))
            {
                return true;
            }

            var message = ReadBoundedString(root, "message");
            if (string.IsNullOrWhiteSpace(message) ||
                !TrySanitizeRecognizedMessage(message, out var safeMessage))
            {
                if (deploymentVerificationClaimObserved || planResultClaimObserved)
                {
                    progressEvent = new BootstrapProgressEvent(
                        TimestampUtc: fallbackTimestamp,
                        Kind: BootstrapProgressKind.Error,
                        Message: deploymentVerificationClaimObserved
                            ? InvalidVerificationMessage
                            : InvalidPlanResultMessage,
                        Step: step,
                        DeploymentVerificationClaimObserved: deploymentVerificationClaimObserved,
                        PlanResultClaimObserved: planResultClaimObserved);
                }

                return true;
            }

            if (step is not null && !TrySanitizeRecognizedMessage(step, out step))
            {
                step = null;
            }

            var progress = data.ValueKind == JsonValueKind.Object
                ? CalculateProgress(discriminator!, data, step, category)
                : null;

            BootstrapVerifiedEndpoints? verifiedEndpoints = null;
            if (deploymentVerificationClaimObserved &&
                TryReadVerifiedEndpoints(root, data, out var parsedEndpoints))
            {
                verifiedEndpoints = parsedEndpoints;
            }
            else if (deploymentVerificationClaimObserved)
            {
                kind = BootstrapProgressKind.Error;
                safeMessage = InvalidVerificationMessage;
            }

            var timestamp = fallbackTimestamp;
            var timestampText = ReadBoundedString(root, "timestampUtc");
            if (DateTimeOffset.TryParse(timestampText, out var parsedTimestamp))
            {
                timestamp = parsedTimestamp.ToUniversalTime();
            }

            string? planFingerprint = null;
            bool? planApplyReady = null;
            if (planResultClaimObserved &&
                TryReadPlanResult(root, data, safeMessage, out var parsedFingerprint, out var parsedApplyReady))
            {
                planFingerprint = parsedFingerprint;
                planApplyReady = parsedApplyReady;
            }
            else if (planResultClaimObserved)
            {
                kind = BootstrapProgressKind.Error;
                safeMessage = InvalidPlanResultMessage;
            }

            progressEvent = new BootstrapProgressEvent(
                TimestampUtc: timestamp,
                Kind: kind,
                Message: safeMessage,
                Step: step,
                ProgressPercent: progress,
                PlanFingerprint: planFingerprint,
                PlanApplyReady: planApplyReady,
                DisplayLabel: string.Equals(step, "Plan review", StringComparison.Ordinal)
                    ? MapPlanReviewLabel(category)
                    : null,
                VerifiedEndpoints: verifiedEndpoints,
                DeploymentVerificationClaimObserved: deploymentVerificationClaimObserved,
                PlanResultClaimObserved: planResultClaimObserved);
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

    private static int? CalculateProgress(
        string type,
        JsonElement data,
        string? step,
        string? category)
    {
        if (string.Equals(step, "Plan review", StringComparison.Ordinal))
        {
            return string.Equals(category, "planResult", StringComparison.Ordinal)
                ? 100
                : null;
        }

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
        "localPrerequisites" => "Local prerequisites",
        "planFailure" => "Plan stopped here",
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

    private static bool IsDeploymentVerificationClaim(
        string? type,
        string? step,
        string? category) =>
        string.Equals(type, "Result", StringComparison.Ordinal) &&
        string.Equals(step, "End-to-end deployment verification", StringComparison.Ordinal) &&
        string.Equals(category, "deploymentVerified", StringComparison.Ordinal);

    private static bool IsPlanResultClaim(
        string? type,
        string? step,
        string? category) =>
        string.Equals(type, "Result", StringComparison.Ordinal) &&
        string.Equals(step, "Plan review", StringComparison.Ordinal) &&
        string.Equals(category, "planResult", StringComparison.Ordinal);

    private static bool TryReadPlanResult(
        JsonElement root,
        JsonElement data,
        string safeMessage,
        out string planFingerprint,
        out bool applyReady)
    {
        planFingerprint = string.Empty;
        applyReady = false;
        if (!HasExactlyOneProperty(root, "schemaVersion") ||
            !HasExactlyOneProperty(root, "type") ||
            !HasExactlyOneProperty(root, "message") ||
            !HasExactlyOneProperty(root, "data") ||
            data.ValueKind != JsonValueKind.Object ||
            !HasExactlyOneProperty(data, "step") ||
            !HasExactlyOneProperty(data, "category") ||
            !HasExactlyOneProperty(data, "index") ||
            !HasExactlyOneProperty(data, "total") ||
            !HasExactlyOneProperty(data, "planFingerprint") ||
            !HasExactlyOneProperty(data, "applyReady") ||
            !data.TryGetProperty("index", out var indexElement) ||
            !indexElement.TryGetInt32(out var index) ||
            index != 1 ||
            !data.TryGetProperty("total", out var totalElement) ||
            !totalElement.TryGetInt32(out var total) ||
            total is < 1 or > 10_000 ||
            !data.TryGetProperty("applyReady", out var applyReadyElement) ||
            applyReadyElement.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            return false;
        }

        applyReady = applyReadyElement.GetBoolean();
        var expectedMessage = applyReady
            ? "Plan is ready for explicit acceptance."
            : "Plan is not apply-ready.";
        var candidate = ReadBoundedString(data, "planFingerprint");
        if (!string.Equals(safeMessage, expectedMessage, StringComparison.Ordinal) ||
            !PlanFingerprintPolicy.IsCanonical(candidate))
        {
            applyReady = false;
            return false;
        }

        planFingerprint = candidate!;
        return true;
    }

    private static bool TryReadVerifiedEndpoints(
        JsonElement root,
        JsonElement data,
        out BootstrapVerifiedEndpoints endpoints)
    {
        endpoints = null!;
        if (!HasExactlyOneProperty(root, "schemaVersion") ||
            !HasExactlyOneProperty(root, "type") ||
            !HasExactlyOneProperty(root, "message") ||
            !HasExactlyOneProperty(root, "data") ||
            data.ValueKind != JsonValueKind.Object ||
            !HasExactlyOneProperty(data, "step") ||
            !HasExactlyOneProperty(data, "category") ||
            !HasExactlyOneProperty(data, "verified") ||
            !HasExactlyOneProperty(data, "verificationMode") ||
            !HasExactlyOneProperty(data, "index") ||
            !HasExactlyOneProperty(data, "total") ||
            !HasExactlyOneProperty(data, "adminUiUrl") ||
            !HasExactlyOneProperty(data, "apiUrl") ||
            !HasExactlyOneProperty(data, "apiHealthUrl") ||
            !data.TryGetProperty("verified", out var verifiedElement) ||
            verifiedElement.ValueKind != JsonValueKind.True ||
            !data.TryGetProperty("index", out var indexElement) ||
            !indexElement.TryGetInt32(out var index) ||
            !data.TryGetProperty("total", out var totalElement) ||
            !totalElement.TryGetInt32(out var total) ||
            total is < 1 or > 10_000 ||
            index != total ||
            !TryReadVerificationMode(ReadBoundedString(data, "verificationMode"), out var verificationMode) ||
            !TryCreateHttpsBaseAddress(ReadBoundedString(data, "adminUiUrl"), out var adminUiBaseAddress) ||
            !TryCreateHttpsBaseAddress(ReadBoundedString(data, "apiUrl"), out var apiBaseAddress) ||
            !TryCreateApiHealthAddress(ReadBoundedString(data, "apiHealthUrl"), out var apiHealthAddress) ||
            !TryReadGatewayContainerAppsAddress(
                adminUiBaseAddress,
                "ca-gateway-admin-",
                out var adminEnvironment,
                out var adminEnvironmentDomain) ||
            !TryReadGatewayContainerAppsAddress(
                apiBaseAddress,
                "ca-gateway-api-",
                out var apiEnvironment,
                out var apiEnvironmentDomain) ||
            !string.Equals(adminEnvironment, apiEnvironment, StringComparison.Ordinal) ||
            !string.Equals(adminEnvironmentDomain, apiEnvironmentDomain, StringComparison.OrdinalIgnoreCase) ||
            Uri.Compare(
                apiBaseAddress,
                apiHealthAddress,
                UriComponents.SchemeAndServer,
                UriFormat.SafeUnescaped,
                StringComparison.OrdinalIgnoreCase) != 0)
        {
            return false;
        }

        endpoints = new BootstrapVerifiedEndpoints(
            verificationMode,
            adminUiBaseAddress,
            apiBaseAddress,
            apiHealthAddress);
        return true;
    }

    private static bool TryReadGatewayContainerAppsAddress(
        Uri address,
        string expectedAppNamePrefix,
        out string deploymentEnvironment,
        out string environmentDomain)
    {
        deploymentEnvironment = string.Empty;
        environmentDomain = string.Empty;
        var host = address.IdnHost;
        var firstSeparator = host.IndexOf('.');
        if (firstSeparator <= expectedAppNamePrefix.Length ||
            !host.EndsWith(".azurecontainerapps.io", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var appName = host[..firstSeparator];
        if (!appName.StartsWith(expectedAppNamePrefix, StringComparison.Ordinal))
        {
            return false;
        }

        deploymentEnvironment = appName[expectedAppNamePrefix.Length..];
        if (deploymentEnvironment is not ("dev" or "staging" or "prod"))
        {
            deploymentEnvironment = string.Empty;
            return false;
        }

        environmentDomain = host[(firstSeparator + 1)..];
        return true;
    }

    private static bool HasExactlyOneProperty(JsonElement element, string propertyName)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        var count = 0;
        foreach (var property in element.EnumerateObject())
        {
            if (string.Equals(property.Name, propertyName, StringComparison.Ordinal) &&
                ++count > 1)
            {
                return false;
            }
        }

        return count == 1;
    }

    private static bool TryReadVerificationMode(
        string? value,
        out BootstrapVerificationMode mode)
    {
        switch (value)
        {
            case "Apply":
                mode = BootstrapVerificationMode.Apply;
                return true;
            case "Verify":
                mode = BootstrapVerificationMode.Verify;
                return true;
            default:
                mode = default;
                return false;
        }
    }

    private static bool TryCreateHttpsBaseAddress(string? value, out Uri address)
    {
        address = null!;
        if (!TryCreateSafeHttpsAddress(value, out var parsedAddress) ||
            !string.Equals(parsedAddress.AbsolutePath, "/", StringComparison.Ordinal))
        {
            return false;
        }

        address = new UriBuilder(parsedAddress)
        {
            Path = "/",
            Query = string.Empty,
            Fragment = string.Empty
        }.Uri;
        return true;
    }

    private static bool TryCreateApiHealthAddress(string? value, out Uri address)
    {
        address = null!;
        if (!TryCreateSafeHttpsAddress(value, out var parsedAddress) ||
            !string.Equals(parsedAddress.AbsolutePath, "/health/checks", StringComparison.Ordinal))
        {
            return false;
        }

        address = parsedAddress;
        return true;
    }

    private static bool TryCreateSafeHttpsAddress(string? value, out Uri address)
    {
        address = null!;
        if (!Uri.TryCreate(value, UriKind.Absolute, out var parsedAddress) ||
            !string.Equals(parsedAddress.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            parsedAddress.HostNameType != UriHostNameType.Dns ||
            !parsedAddress.IsDefaultPort ||
            parsedAddress.IsLoopback ||
            !string.IsNullOrEmpty(parsedAddress.UserInfo) ||
            !string.IsNullOrEmpty(parsedAddress.Query) ||
            !string.IsNullOrEmpty(parsedAddress.Fragment))
        {
            return false;
        }

        address = parsedAddress;
        return true;
    }

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
