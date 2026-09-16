using System.ComponentModel;
using System.Security.Cryptography;

namespace Gateway.Provisioning.Worker;

internal enum PurviewVerificationStage
{
    Configuration, PrivateDirectory, RequestFile, CertificateDownload,
    CertificateImport, CertificateExport, CertificateFile, ChildBinding,
    ChildStart, ChildInput, ChildCompletion, EvidenceParsing
}

internal sealed record PurviewVerificationFailure(
    Guid OperationId, DateTimeOffset ObservedAtUtc, PurviewVerificationStage Stage,
    string FailureKind, int? ChildExitCode, int? ProviderStage,
    IReadOnlyList<PurviewProviderError> ProviderErrors);

internal sealed record PurviewProviderError(
    string Category, string ExceptionType, string HResult, string Code);

internal sealed class PurviewConnectionVerificationDiagnostics(TimeProvider timeProvider)
{
    private PurviewVerificationFailure? lastFailure;

    internal void Record(Guid operationId, PurviewVerificationStage stage,
        Exception exception, int? childExitCode = null, int? providerStage = null,
        string providerError = "")
    {
        if (operationId == Guid.Empty || !Enum.IsDefined(stage)) return;
        var kind = exception switch
        {
            CryptographicException => "Cryptography",
            UnauthorizedAccessException => "AccessDenied",
            Win32Exception => "Process",
            IOException => "FileOrPipe",
            OperationCanceledException => "Cancelled",
            PurviewConnectionVerificationException => "Verification",
            InvalidOperationException => "InvalidOperation",
            _ => "Other"
        };
        Interlocked.Exchange(ref lastFailure, new(operationId, timeProvider.GetUtcNow(),
            stage, kind, childExitCode, providerStage is >= 1 and <= 11 ? providerStage : null,
            ParseProviderFailure(providerError)?.Errors ?? []));
    }

    internal static int? ParseProviderStage(string error) => ParseProviderFailure(error)?.Stage;

    internal static (int Stage, IReadOnlyList<PurviewProviderError> Errors)? ParseProviderFailure(string error)
    {
        if (error.Length > 32 * 1024) return null;
        int? stage = null;
        var errors = new List<PurviewProviderError>();
        foreach (var line in error.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (line == "PURVIEW_CHILD_FAILED") continue;
            const string errorPrefix = "A365GW_VERIFIER_ERROR:";
            if (line.StartsWith(errorPrefix, StringComparison.Ordinal))
            {
                var fields = line[errorPrefix.Length..].Split(':');
                if (stage is null || errors.Count == 8 || fields.Length != 4 ||
                    !AllowedCategory.Contains(fields[0]) || !AllowedType.Contains(fields[1]) ||
                    !AllowedHResult.Contains(fields[2]) || !AllowedCode.Contains(fields[3]))
                    return null;
                var item = new PurviewProviderError(fields[0], fields[1], fields[2], fields[3]);
                if (errors.Contains(item)) return null;
                errors.Add(item);
                continue;
            }
            const string prefix = "A365GW_VERIFIER_STAGE:";
            if (stage is not null || !line.StartsWith(prefix, StringComparison.Ordinal)) return null;
            var value = line[prefix.Length..];
            if (!int.TryParse(value, out var parsed) || parsed is < 1 or > 11 ||
                value != parsed.ToString(System.Globalization.CultureInfo.InvariantCulture)) return null;
            stage = parsed;
        }
        return stage is { } valueStage ? (valueStage, errors.ToArray()) : null;
    }

    private static readonly HashSet<string> AllowedCategory = new(StringComparer.Ordinal)
    {
        "Other", "NotSpecified", "OpenError", "InvalidArgument", "InvalidOperation",
        "PermissionDenied", "ObjectNotFound", "AuthenticationError", "SecurityError",
        "ResourceUnavailable", "ConnectionError", "ProtocolError", "OperationTimeout",
        "NotImplemented", "InvalidData", "InvalidResult", "ReadError", "WriteError", "OperationStopped"
    };
    private static readonly HashSet<string> AllowedType = new(StringComparer.Ordinal)
    {
        "Other", "PowerShellRuntime", "CmdletInvocation", "MethodInvocation", "ParameterBinding",
        "CommandNotFound", "InvalidOperation", "NotSupported", "PlatformNotSupported", "Cryptography",
        "AccessDenied", "FileNotFound", "FileLoad", "TypeLoad", "HttpRequest", "WebRequest",
        "Authentication", "MsalService", "MsalClient", "MsalUiRequired", "Argument", "ArgumentNull", "NullReference"
    };
    private static readonly HashSet<string> AllowedHResult = new(StringComparer.Ordinal)
    {
        "00000000", "80004005", "80004001", "80070002", "80070005", "80070057",
        "80090003", "80090005", "80090008", "8009000B", "8009000D", "80090010",
        "80090014", "80090016", "8009001D", "80090020", "80090022", "80090029",
        "80131500", "80131509", "80131515", "80131522", "80131621", "80131501",
        "80131502", "80131505", "80131506"
    };
    private static readonly HashSet<string> AllowedCode = new(StringComparer.Ordinal)
    {
        "Other", "invalid_client", "invalid_grant", "unauthorized_client", "access_denied",
        "invalid_scope", "interaction_required", "consent_required", "temporarily_unavailable",
        "service_not_available", "unknown_error", "authentication_canceled", "http_request_failed",
        "client_assertion_signing_failed", "certificate_not_found", "cryptographic_exception",
        "unsupported_key_algorithm", "multiple_matching_tokens_detected",
        "Update-ModuleManifest", "Update-FormatData", "Get-FormatData", "Import-Module", "New-PSSession",
        "FileSystemCreateDirectory", "FileSystemCreateFile", "FileSystemOpenHandle", "FileSystemAccess", "RegistryAccess",
        "AmbiguousProperty", "MissingLocations", "MissingEnforcementPlanes", "MissingMode",
        "MissingSensitiveCondition", "MissingRestrictAccess", "MissingDistributionStatus",
        "MissingProviderIdentity", "MissingRequiredProperty", "InvalidTypedProperty",
        "UnknownMeaningfulProperty", "InvalidStructuredArray", "UnexpectedDistributionStatus",
        "UnexpectedDistributionResults", "UnexpectedLastStatusUpdateTime", "UnexpectedScenario",
        "UnexpectedType", "UnexpectedPolicyType", "UnexpectedPolicyVersion", "UnexpectedIsDefaultPolicy",
        "UnexpectedPolicyRBACScopes", "UnexpectedRules", "UnexpectedPolicyRulesMetaData",
        "UnexpectedDictionaryMetadata"
    };

    internal PurviewVerificationFailure? Read()
    {
        var value = Volatile.Read(ref lastFailure);
        return value is not null &&
            timeProvider.GetUtcNow() - value.ObservedAtUtc is var age &&
            age >= TimeSpan.Zero && age <= TimeSpan.FromMinutes(5) ? value : null;
    }
}
