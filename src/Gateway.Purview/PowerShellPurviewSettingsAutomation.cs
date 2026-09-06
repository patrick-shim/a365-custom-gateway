using System.Diagnostics;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Azure.Core;
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Purview;

internal sealed class PowerShellPurviewSettingsAutomation : IPurviewSettingsAutomation
{
    private const string ResultPrefix = "A365GW_SETTINGS_RESULT:";
    private const int StandardOutputCharacterLimit = 256 * 1024;
    private const int StandardErrorCharacterLimit = 32 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    private readonly PurviewOptions _options;
    private readonly ILogger<PowerShellPurviewSettingsAutomation> _logger;
    private readonly PurviewProcessSafety _processSafety;

    public PowerShellPurviewSettingsAutomation(
        IOptions<PurviewOptions> options,
        ILogger<PowerShellPurviewSettingsAutomation> logger,
        PurviewProcessSafety? processSafety = null)
    {
        _options = options.Value;
        _logger = logger;
        _processSafety = processSafety ?? new PurviewProcessSafety();
    }

    public async Task<PurviewProviderReadback<PurviewKnowYourDataReadback>>
        ReadKnowYourDataAsync(
            PurviewKnowYourDataIntent intent,
            CancellationToken cancellationToken)
    {
        var result = await ExecuteAsync(
            "ReadKnowYourData",
            KydInput(intent),
            isMutation: false,
            cancellationToken);
        return ParseKnowYourData(result);
    }

    public Task CreateKnowYourDataAsync(
        PurviewKnowYourDataIntent intent,
        CancellationToken cancellationToken) =>
        ExecuteMutationAsync("CreateKnowYourData", KydInput(intent), cancellationToken);

    public async Task<PurviewProviderReadback<PurviewDlpProfileReadback>>
        ReadDlpProfileAsync(
            PurviewDlpProfileIntent intent,
            CancellationToken cancellationToken)
    {
        var result = await ExecuteAsync(
            "ReadDlpProfile",
            DlpInput(intent),
            isMutation: false,
            cancellationToken);
        return ParseDlpProfile(result);
    }

    public Task CreateDlpPolicyAsync(
        PurviewDlpProfileIntent intent,
        CancellationToken cancellationToken) =>
        ExecuteMutationAsync("CreateDlpPolicy", DlpInput(intent), cancellationToken);

    public Task CreateDlpRuleAsync(
        PurviewDlpProfileIntent intent,
        CancellationToken cancellationToken) =>
        ExecuteMutationAsync("CreateDlpRule", DlpInput(intent), cancellationToken);

    private async Task ExecuteMutationAsync(
        string command,
        object input,
        CancellationToken cancellationToken)
    {
        _ = await ExecuteAsync(command, input, isMutation: true, cancellationToken);
    }

    private async Task<string> ExecuteAsync(
        string command,
        object input,
        bool isMutation,
        CancellationToken cancellationToken)
    {
        if (!_options.PolicyProvisioningEnabled)
        {
            throw Failure(
                "PURVIEW_SETTINGS_AUTOMATION_DISABLED",
                "Purview Settings automation is not configured.");
        }

        var workingDirectory = Path.Combine(
            Path.GetTempPath(),
            $"a365gw-purview-settings-{Guid.NewGuid():N}");
        var inputPath = Path.Combine(workingDirectory, "request.json");
        var certificatePath = Path.Combine(workingDirectory, "automation.pfx");
        var certificatePassword = Convert.ToBase64String(RandomNumberGenerator.GetBytes(48));

        try
        {
            Directory.CreateDirectory(workingDirectory);
            if (OperatingSystem.IsWindows())
            {
                PowerShellPurviewPolicyProvisioningClient
                    .ApplyCurrentUserOnlyDirectoryAcl(workingDirectory);
            }
            else
            {
                File.SetUnixFileMode(
                    workingDirectory,
                    UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }

            byte[]? certificateBytes = null;
            byte[]? exportedCertificate = null;
            try
            {
                certificateBytes = await DownloadCertificateAsync(cancellationToken);
                using var certificate = X509CertificateLoader.LoadPkcs12(
                    certificateBytes,
                    (string?)null,
                    X509KeyStorageFlags.EphemeralKeySet | X509KeyStorageFlags.Exportable);
                if (!certificate.HasPrivateKey)
                {
                    throw Failure(
                        "PURVIEW_SETTINGS_CERTIFICATE_INVALID",
                        "The Purview Settings automation certificate has no private key.");
                }

                exportedCertificate = certificate.Export(
                    X509ContentType.Pkcs12,
                    certificatePassword);
                await File.WriteAllBytesAsync(
                    certificatePath,
                    exportedCertificate,
                    cancellationToken);
                RestrictFile(certificatePath);
            }
            finally
            {
                if (certificateBytes is not null)
                    CryptographicOperations.ZeroMemory(certificateBytes);
                if (exportedCertificate is not null)
                    CryptographicOperations.ZeroMemory(exportedCertificate);
            }

            await File.WriteAllTextAsync(
                inputPath,
                JsonSerializer.Serialize(input, JsonOptions),
                Encoding.UTF8,
                cancellationToken);
            RestrictFile(inputPath);

            var scriptPath = Path.Combine(
                AppContext.BaseDirectory,
                "Automation",
                "Invoke-PurviewSettingsOperation.ps1");
            if (!File.Exists(scriptPath))
            {
                throw Failure(
                    "PURVIEW_SETTINGS_AUTOMATION_MISSING",
                    "The Purview Settings automation script is unavailable.");
            }

            using var process = new Process
            {
                StartInfo = CreateStartInfo(
                    scriptPath,
                    inputPath,
                    certificatePath,
                    command)
            };
            if (!process.Start())
            {
                throw Failure(
                    "PURVIEW_SETTINGS_AUTOMATION_START_FAILED",
                    "Purview Settings automation could not start.");
            }

            await using var processLease = new PurviewProcessLease(process, _processSafety);
            await process.StandardInput.WriteLineAsync(certificatePassword.AsMemory(), cancellationToken);
            process.StandardInput.Close();

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(_options.PolicyProvisioningTimeoutSeconds));
            PowerShellPurviewPolicyProvisioningClient.BoundedTextCapture standardOutput;
            PowerShellPurviewPolicyProvisioningClient.BoundedTextCapture standardError;
            try
            {
                var outputTask = PowerShellPurviewPolicyProvisioningClient.ReadBoundedAsync(
                    process.StandardOutput,
                    StandardOutputCharacterLimit,
                    timeout.Token);
                var errorTask = PowerShellPurviewPolicyProvisioningClient.ReadBoundedAsync(
                    process.StandardError,
                    StandardErrorCharacterLimit,
                    timeout.Token);
                await WaitForExitOrTerminateAsync(process, timeout.Token, _processSafety);
                standardOutput = await outputTask;
                standardError = await errorTask;
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                if (isMutation)
                {
                    throw new PurviewMutationOutcomeUnknownException(
                        "PURVIEW_SETTINGS_MUTATION_TIMEOUT");
                }

                throw Failure(
                    "PURVIEW_SETTINGS_READ_TIMEOUT",
                    "Purview Settings readback timed out.",
                    transient: true);
            }

            if (standardOutput.Truncated || standardError.Truncated)
            {
                _logger.LogWarning(
                    "Purview Settings automation exceeded a bounded output limit. ExitCode: {ExitCode}; StdoutCharacters: {StdoutCharacters}; StderrCharacters: {StderrCharacters}",
                    process.ExitCode,
                    standardOutput.TotalCharacters,
                    standardError.TotalCharacters);
                if (isMutation)
                {
                    throw new PurviewMutationOutcomeUnknownException(
                        "PURVIEW_SETTINGS_MUTATION_OUTPUT_UNVERIFIABLE");
                }

                throw Failure(
                    "PURVIEW_SETTINGS_READ_OUTPUT_LIMIT",
                    "Purview Settings readback exceeded its safe output limit.");
            }

            if (process.ExitCode != 0)
            {
                _logger.LogWarning(
                    "Purview Settings automation failed. ExitCode: {ExitCode}; StdoutCharacters: {StdoutCharacters}; StderrCharacters: {StderrCharacters}",
                    process.ExitCode,
                    standardOutput.TotalCharacters,
                    standardError.TotalCharacters);
                if (isMutation)
                {
                    throw new PurviewMutationOutcomeUnknownException(
                        "PURVIEW_SETTINGS_MUTATION_RESULT_UNKNOWN");
                }

                throw Failure(
                    "PURVIEW_SETTINGS_READ_FAILED",
                    "Purview Settings readback failed closed.");
            }

            return ExtractTypedResult(standardOutput.Text);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (PurviewMutationOutcomeUnknownException)
        {
            throw;
        }
        catch (PurviewPolicyException exception) when (isMutation)
        {
            throw new PurviewMutationOutcomeUnknownException(
                "PURVIEW_SETTINGS_MUTATION_RESULT_UNKNOWN",
                exception);
        }
        catch (PurviewPolicyException)
        {
            throw;
        }
        catch (Exception exception)
        {
            if (isMutation)
            {
                throw new PurviewMutationOutcomeUnknownException(
                    "PURVIEW_SETTINGS_MUTATION_RESULT_UNKNOWN",
                    exception);
            }

            throw Failure(
                "PURVIEW_SETTINGS_READ_FAILED",
                "Purview Settings readback failed closed.",
                innerException: exception);
        }
        finally
        {
            certificatePassword = string.Empty;
            var cleanupProven = await PowerShellPurviewPolicyProvisioningClient
                .DeleteDirectoryAndVerifyAsync(workingDirectory);
            if (!cleanupProven && isMutation)
            {
                throw new PurviewMutationOutcomeUnknownException(
                    "PURVIEW_SETTINGS_MUTATION_CLEANUP_UNVERIFIABLE");
            }

            PowerShellPurviewPolicyProvisioningClient.EnsureCleanupProven(cleanupProven);
        }
    }

    private ProcessStartInfo CreateStartInfo(
        string scriptPath,
        string inputPath,
        string certificatePath,
        string command)
    {
        var info = new ProcessStartInfo
        {
            FileName = _options.PolicyProvisioningPowerShellPath,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        foreach (var argument in new[]
                 {
                     "-NoLogo",
                     "-NoProfile",
                     "-NonInteractive",
                     "-File",
                     scriptPath,
                     "-InputPath",
                     inputPath,
                     "-CertificatePath",
                     certificatePath,
                     "-AutomationApplicationId",
                     _options.PolicyProvisioningApplicationId!,
                     "-Organization",
                     _options.PolicyProvisioningOrganization!,
                     "-Operation",
                     command
                 })
        {
            info.ArgumentList.Add(argument);
        }

        return info;
    }

    private async Task<byte[]> DownloadCertificateAsync(CancellationToken cancellationToken)
    {
        var secretUri = ParseApprovedCertificateSecretUri(
            _options.PolicyProvisioningCertificateSecretUri);
        var credential = CreateManagedIdentityCredential(
            _options.ManagedIdentityClientId);
        var client = new SecretClient(
            new Uri($"{secretUri.Scheme}://{secretUri.Host}"),
            credential);
        var secret = await client.GetSecretAsync(
            secretUri.Segments[2].TrimEnd('/'),
            cancellationToken: cancellationToken);
        try
        {
            return Convert.FromBase64String(secret.Value.Value);
        }
        catch (FormatException exception)
        {
            throw Failure(
                "PURVIEW_SETTINGS_CERTIFICATE_INVALID",
                "The Purview Settings automation certificate could not be loaded.",
                innerException: exception);
        }
    }

    internal static Uri ParseApprovedCertificateSecretUri(string? value)
        => PurviewAutomationCapabilityBindingValidator
            .ParseVersionlessCertificateSecretUri(value);

    internal static TokenCredential CreateManagedIdentityCredential(string? clientId) =>
        string.IsNullOrWhiteSpace(clientId)
            ? new ManagedIdentityCredential()
            : new ManagedIdentityCredential(clientId);

    private static object KydInput(PurviewKnowYourDataIntent intent) => new
    {
        operationId = intent.OperationId.ToString("D"),
        tenantId = intent.TenantId.ToString("D"),
        inventoryGenerationId = intent.InventoryGenerationId.ToString("D"),
        inventoryExpiresAtUtc = intent.InventoryExpiresAtUtc,
        sensitiveInformationTypeId = intent.SensitiveInformationTypeId.ToString("D"),
        sensitiveInformationTypeName = intent.SensitiveInformationTypeName,
        sensitiveInformationTypePublisher = intent.SensitiveInformationTypePublisher,
        policyName = intent.PolicyName,
        mode = intent.Mode.ToString(),
        activities = intent.Activities.Select(value => value.ToString()).ToArray(),
        ingestionEnabled = intent.IngestionEnabled,
        expectedPolicyProviderId = intent.ExpectedPolicyProviderId,
        priorCreateOutcomeUnknown = intent.PriorCreateOutcomeUnknown
    };

    private static object DlpInput(PurviewDlpProfileIntent intent) => new
    {
        operationId = intent.OperationId.ToString("D"),
        tenantId = intent.TenantId.ToString("D"),
        inventoryGenerationId = intent.InventoryGenerationId.ToString("D"),
        inventoryExpiresAtUtc = intent.InventoryExpiresAtUtc,
        sensitiveInformationTypeId = intent.SensitiveInformationTypeId.ToString("D"),
        sensitiveInformationTypeName = intent.SensitiveInformationTypeName,
        sensitiveInformationTypePublisher = intent.SensitiveInformationTypePublisher,
        blueprintApplicationId = intent.BlueprintApplicationId.ToString("D"),
        policyName = intent.PolicyName,
        ruleName = intent.RuleName,
        mode = intent.Mode.ToString(),
        activities = intent.Activities.Select(value => value.ToString()).ToArray(),
        actions = intent.Actions.Select(action => new
        {
            activity = action.Activity.ToString(),
            action = action.Action.ToString()
        }).ToArray(),
        expectedPolicyProviderId = intent.ExpectedPolicyProviderId,
        expectedRuleProviderId = intent.ExpectedRuleProviderId,
        recoveryPoint = intent.RecoveryPoint.ToString()
    };

    private static PurviewProviderReadback<PurviewKnowYourDataReadback>
        ParseKnowYourData(string encodedJson)
    {
        var result = Deserialize(encodedJson);
        var state = ParseState(result.State);
        if (state != PurviewProviderObjectState.Exact)
            return new(state, null);

        return PurviewProviderReadback.Exact(new PurviewKnowYourDataReadback(
            RequiredText(result.PolicyProviderId),
            ParseCanonicalGuid(result.TenantId),
            ParseCanonicalGuid(result.GroupId),
            ParseEnum<PurviewPolicyScopeType>(result.ScopeType),
            ParseEnum<PurviewEnforcementPlane>(result.EnforcementPlane),
            ParseCanonicalGuid(result.SensitiveInformationTypeId),
            RequiredText(result.SensitiveInformationTypeName),
            RequiredText(result.SensitiveInformationTypePublisher),
            ParseEnum<PurviewMode>(result.Mode),
            ParseEnums<PurviewPolicyActivity>(result.Activities),
            result.IngestionEnabled ??
                throw InvalidResult(),
            ParseTimestamp(result.ObservedAtUtc)));
    }

    private static PurviewProviderReadback<PurviewDlpProfileReadback>
        ParseDlpProfile(string encodedJson)
    {
        var result = Deserialize(encodedJson);
        var state = ParseState(result.State);
        if (state is not (PurviewProviderObjectState.Exact or
            PurviewProviderObjectState.PolicyOnlyExact))
        {
            return new(state, null);
        }

        return new(state, new PurviewDlpProfileReadback(
            RequiredText(result.PolicyProviderId),
            OptionalText(result.RuleProviderId),
            ParseCanonicalGuid(result.TenantId),
            ParseGuids(result.BlueprintApplicationIds),
            ParseEnum<PurviewPolicyScopeType>(result.ScopeType),
            ParseEnum<PurviewEnforcementPlane>(result.EnforcementPlane),
            ParseCanonicalGuid(result.SensitiveInformationTypeId),
            RequiredText(result.SensitiveInformationTypeName),
            RequiredText(result.SensitiveInformationTypePublisher),
            ParseEnum<PurviewMode>(result.Mode),
            ParseEnums<PurviewPolicyActivity>(result.Activities),
            ParseActions(result.Actions),
            result.HasExclusions ??
                throw InvalidResult(),
            result.HasBypass ??
                throw InvalidResult(),
            ParseTimestamp(result.ObservedAtUtc)));
    }

    private static AutomationResult Deserialize(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<AutomationResult>(json, JsonOptions) ??
                throw InvalidResult();
        }
        catch (JsonException exception)
        {
            throw Failure(
                "PURVIEW_SETTINGS_READBACK_INVALID",
                "Purview Settings automation returned invalid typed readback.",
                innerException: exception);
        }
    }

    private static string ExtractTypedResult(string output)
    {
        var matches = output.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.Trim())
            .Where(line => line.StartsWith(ResultPrefix, StringComparison.Ordinal))
            .ToArray();
        if (matches.Length != 1)
            throw InvalidResult();

        try
        {
            return Encoding.UTF8.GetString(
                Convert.FromBase64String(matches[0][ResultPrefix.Length..]));
        }
        catch (FormatException exception)
        {
            throw Failure(
                "PURVIEW_SETTINGS_READBACK_INVALID",
                "Purview Settings automation returned invalid typed readback.",
                innerException: exception);
        }
    }

    private static PurviewProviderObjectState ParseState(string? value) =>
        value switch
        {
            "Absent" => PurviewProviderObjectState.Absent,
            "PolicyOnlyExact" => PurviewProviderObjectState.PolicyOnlyExact,
            "Exact" => PurviewProviderObjectState.Exact,
            "Mismatch" => PurviewProviderObjectState.Mismatch,
            "Unknown" => PurviewProviderObjectState.Unknown,
            "MutationAccepted" => PurviewProviderObjectState.Unknown,
            _ => throw InvalidResult()
        };

    private static Guid ParseCanonicalGuid(string? value)
    {
        if (!Guid.TryParse(value, out var parsed) ||
            parsed == Guid.Empty ||
            !string.Equals(value, parsed.ToString("D"), StringComparison.Ordinal))
        {
            throw InvalidResult();
        }

        return parsed;
    }

    private static IReadOnlyList<Guid> ParseGuids(string[]? values)
    {
        if (values is null || values.Length is < 1 or > 1)
            throw InvalidResult();
        return values.Select(ParseCanonicalGuid).ToArray();
    }

    private static IReadOnlyList<T> ParseEnums<T>(string[]? values)
        where T : struct, Enum
    {
        if (values is null || values.Length is < 1 or > 2)
            throw InvalidResult();
        var parsed = values.Select(ParseEnum<T>).ToArray();
        if (parsed.Distinct().Count() != parsed.Length)
            throw InvalidResult();
        return parsed;
    }

    private static IReadOnlyList<PurviewDlpRuleAction> ParseActions(
        AutomationAction[]? values)
    {
        if (values is null || values.Length is < 1 or > 2)
            throw InvalidResult();
        var parsed = values.Select(value => new PurviewDlpRuleAction(
            ParseEnum<PurviewPolicyActivity>(value.Activity),
            ParseEnum<PurviewDlpAction>(value.Action))).ToArray();
        if (parsed.Distinct().Count() != parsed.Length)
            throw InvalidResult();
        return parsed;
    }

    private static T ParseEnum<T>(string? value)
        where T : struct, Enum =>
        Enum.TryParse<T>(value, ignoreCase: false, out var parsed) &&
        string.Equals(value, parsed.ToString(), StringComparison.Ordinal)
            ? parsed
            : throw InvalidResult();

    private static DateTimeOffset ParseTimestamp(DateTimeOffset? value) =>
        value is not null && value.Value.Offset == TimeSpan.Zero
            ? value.Value
            : throw InvalidResult();

    private static string RequiredText(string? value) =>
        PurviewTenantConnectionEvidenceValidator.IsBoundedText(value, 256)
            ? value!
            : throw InvalidResult();

    private static string? OptionalText(string? value) =>
        value is null
            ? null
            : RequiredText(value);

    private static void RestrictFile(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            return;
        }

        PowerShellPurviewPolicyProvisioningClient.ApplyCurrentUserOnlyFileAcl(path);
    }

    internal static async Task WaitForExitOrTerminateAsync(
        Process process,
        CancellationToken cancellationToken,
        PurviewProcessSafety? safety = null)
    {
        ArgumentNullException.ThrowIfNull(process);
        try
        {
            await process.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            if (!await PurviewProcessTermination.TryTerminateAsync(
                new PurviewOwnedProcess(process), safety ?? new PurviewProcessSafety(),
                TimeSpan.FromSeconds(5)))
            {
                throw new InvalidOperationException(
                    "The Purview Settings automation process termination is unverified.");
            }

            throw;
        }
    }

    private static PurviewPolicyException InvalidResult() =>
        Failure(
            "PURVIEW_SETTINGS_READBACK_INVALID",
            "Purview Settings automation returned invalid typed readback.");

    private static PurviewPolicyException Failure(
        string code,
        string message,
        bool transient = false,
        Exception? innerException = null) =>
        new(code, message, transient, innerException);

    private sealed record AutomationResult(
        string State,
        string? PolicyProviderId,
        string? RuleProviderId,
        string? TenantId,
        string? GroupId,
        string? ScopeType,
        string? EnforcementPlane,
        string? SensitiveInformationTypeId,
        string? SensitiveInformationTypeName,
        string? SensitiveInformationTypePublisher,
        string? Mode,
        string[]? Activities,
        AutomationAction[]? Actions,
        string[]? BlueprintApplicationIds,
        bool? IngestionEnabled,
        bool? HasExclusions,
        bool? HasBypass,
        DateTimeOffset? ObservedAtUtc);

    private sealed record AutomationAction(
        string Activity,
        string Action);
}
