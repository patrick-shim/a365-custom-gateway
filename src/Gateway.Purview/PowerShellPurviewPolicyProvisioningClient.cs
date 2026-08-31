using System.Diagnostics;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Purview;

internal sealed class PowerShellPurviewPolicyProvisioningClient : IPurviewPolicyProvisioningClient
{
    private const string ResultPrefix = "A365GW_RESULT:";
    private const int StandardOutputCharacterLimit = 64 * 1024;
    private const int StandardErrorCharacterLimit = 32 * 1024;
    private readonly PurviewOptions _options;
    private readonly ILogger<PowerShellPurviewPolicyProvisioningClient> _logger;

    public PowerShellPurviewPolicyProvisioningClient(
        IOptions<PurviewOptions> options,
        ILogger<PowerShellPurviewPolicyProvisioningClient> logger)
    {
        _options = options.Value;
        _logger = logger;
    }

    public bool IsEnabled => _options.Enabled && _options.PolicyProvisioningEnabled;

    public async Task<PurviewPolicyProvisioningResult> EnsureProfileAssignmentAsync(
        PurviewPolicyProvisioningRequest request,
        CancellationToken ct) => await ExecuteAsync(request, verifyOnly: false, ct);

    public async Task<PurviewPolicyProvisioningResult> VerifyProfileAssignmentAsync(
        PurviewPolicyProvisioningRequest request,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.ExpectedCollectionPolicyId) ||
            string.IsNullOrWhiteSpace(request.ExpectedDlpPolicyId) ||
            string.IsNullOrWhiteSpace(request.ExpectedDlpRuleId))
        {
            throw Failure(
                "PURVIEW_POLICY_EXPECTED_IDS_MISSING",
                "Read-only Purview verification requires every persisted profile identifier.");
        }

        return await ExecuteAsync(request, verifyOnly: true, ct);
    }

    private async Task<PurviewPolicyProvisioningResult> ExecuteAsync(
        PurviewPolicyProvisioningRequest request,
        bool verifyOnly,
        CancellationToken ct)
    {
        if (!IsEnabled)
        {
            throw Failure("PURVIEW_POLICY_PROVISIONING_DISABLED", "Purview policy provisioning is not configured.");
        }
        ValidateExpectedScope(request);

        var workingDirectory = Path.Combine(Path.GetTempPath(), $"a365gw-purview-{Guid.NewGuid():N}");
        var inputPath = Path.Combine(workingDirectory, "request.json");
        var certificatePath = Path.Combine(workingDirectory, "automation.pfx");
        var certificatePassword = Convert.ToBase64String(RandomNumberGenerator.GetBytes(48));

        try
        {
            CreatePrivateWorkingDirectory(workingDirectory);
            byte[]? certificateBytes = null;
            byte[]? exportedCertificate = null;
            try
            {
                certificateBytes = await DownloadCertificateAsync(ct);
                using (var certificate = X509CertificateLoader.LoadPkcs12(
                    certificateBytes,
                    (string?)null,
                    X509KeyStorageFlags.EphemeralKeySet | X509KeyStorageFlags.Exportable))
                {
                    if (!certificate.HasPrivateKey)
                        throw Failure("PURVIEW_POLICY_CERTIFICATE_INVALID", "The Purview automation certificate has no private key.");
                    exportedCertificate = certificate.Export(X509ContentType.Pkcs12, certificatePassword);
                    await File.WriteAllBytesAsync(certificatePath, exportedCertificate, ct);
                    if (OperatingSystem.IsWindows())
                    {
                        ApplyCurrentUserOnlyFileAcl(certificatePath);
                    }
                    else
                    {
                        File.SetUnixFileMode(
                            certificatePath,
                            UnixFileMode.UserRead | UnixFileMode.UserWrite);
                    }
                }
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
                JsonSerializer.Serialize(new
                {
                    request.CollectionPolicyName,
                    request.DlpPolicyName,
                    request.DlpRuleName,
                    request.Mode,
                    request.BlueprintApplicationId,
                    request.BlueprintDisplayName,
                    request.ExpectedCollectionPolicyId,
                    request.ExpectedDlpPolicyId,
                    request.ExpectedDlpRuleId,
                    request.ExpectedPriorDlpBlueprintApplicationIds,
                    request.ExpectedDlpBlueprintApplicationIds,
                    sensitiveInformationType = _options.DefaultSensitiveInformationType
                }),
                Encoding.UTF8,
                ct);
            if (OperatingSystem.IsWindows())
                ApplyCurrentUserOnlyFileAcl(inputPath);
            else
                File.SetUnixFileMode(inputPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);

            var scriptPath = Path.Combine(AppContext.BaseDirectory, "Automation", "Ensure-PurviewPolicyProfile.ps1");
            if (!File.Exists(scriptPath))
                throw Failure("PURVIEW_POLICY_AUTOMATION_MISSING", "The Purview policy automation script is unavailable.");

            using var process = new Process
            {
                StartInfo = CreateStartInfo(scriptPath, inputPath, certificatePath, verifyOnly)
            };
            if (!process.Start())
                throw Failure("PURVIEW_POLICY_AUTOMATION_START_FAILED", "Purview policy automation could not start.");

            await process.StandardInput.WriteLineAsync(certificatePassword);
            process.StandardInput.Close();

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(_options.PolicyProvisioningTimeoutSeconds));
            BoundedTextCapture standardOutput;
            BoundedTextCapture standardError;
            try
            {
                var outputTask = ReadBoundedAsync(
                    process.StandardOutput,
                    StandardOutputCharacterLimit,
                    timeout.Token);
                var errorTask = ReadBoundedAsync(
                    process.StandardError,
                    StandardErrorCharacterLimit,
                    timeout.Token);
                await process.WaitForExitAsync(timeout.Token);
                standardOutput = await outputTask;
                standardError = await errorTask;
            }
            catch (OperationCanceledException)
            {
                TryKill(process);
                if (ct.IsCancellationRequested)
                    throw;
                throw Failure("PURVIEW_POLICY_AUTOMATION_TIMEOUT", "Purview policy automation timed out.", true);
            }

            if (standardOutput.Truncated || standardError.Truncated)
            {
                _logger.LogWarning(
                    "Purview policy automation exceeded a bounded output limit. ExitCode: {ExitCode}; StdoutCharacters: {StdoutCharacters}; StderrCharacters: {StderrCharacters}; StdoutTruncated: {StdoutTruncated}; StderrTruncated: {StderrTruncated}",
                    process.ExitCode,
                    standardOutput.TotalCharacters,
                    standardError.TotalCharacters,
                    standardOutput.Truncated,
                    standardError.Truncated);
                throw Failure(
                    "PURVIEW_POLICY_AUTOMATION_OUTPUT_LIMIT",
                    "Purview policy automation exceeded its safe output limit.");
            }

            if (process.ExitCode != 0)
            {
                _logger.LogWarning(
                    "Purview policy automation failed. ExitCode: {ExitCode}; StdoutCharacters: {StdoutCharacters}; StderrCharacters: {StderrCharacters}",
                    process.ExitCode,
                    standardOutput.TotalCharacters,
                    standardError.TotalCharacters);
                throw Failure("PURVIEW_POLICY_AUTOMATION_FAILED", "Purview policy automation failed closed.");
            }

            return ParseResult(
                standardOutput.Text,
                request,
                _options.DefaultSensitiveInformationType);
        }
        catch (PurviewPolicyException)
        {
            throw;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw Failure(
                "PURVIEW_POLICY_AUTOMATION_FAILED",
                "Purview policy automation failed closed.",
                false,
                exception);
        }
        finally
        {
            certificatePassword = string.Empty;
            EnsureCleanupProven(await DeleteDirectoryAndVerifyAsync(workingDirectory));
        }
    }

    private ProcessStartInfo CreateStartInfo(
        string scriptPath,
        string inputPath,
        string certificatePath,
        bool verifyOnly)
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
        info.ArgumentList.Add("-NoLogo");
        info.ArgumentList.Add("-NoProfile");
        info.ArgumentList.Add("-NonInteractive");
        info.ArgumentList.Add("-File");
        info.ArgumentList.Add(scriptPath);
        AddArgument(info, "-InputPath", inputPath);
        AddArgument(info, "-CertificatePath", certificatePath);
        AddArgument(info, "-AutomationApplicationId", _options.PolicyProvisioningApplicationId!);
        AddArgument(info, "-Organization", _options.PolicyProvisioningOrganization!);
        if (verifyOnly)
            info.ArgumentList.Add("-VerifyOnly");
        return info;
    }

    private async Task<byte[]> DownloadCertificateAsync(CancellationToken ct)
    {
        var secretUri = new Uri(_options.PolicyProvisioningCertificateSecretUri!);
        var segments = secretUri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length != 2 || !string.Equals(segments[0], "secrets", StringComparison.Ordinal))
            throw Failure("PURVIEW_POLICY_CERTIFICATE_URI_INVALID", "The Purview automation certificate reference is invalid.");

        var credentialOptions = new DefaultAzureCredentialOptions();
        if (!string.IsNullOrWhiteSpace(_options.ManagedIdentityClientId))
            credentialOptions.ManagedIdentityClientId = _options.ManagedIdentityClientId;
        var client = new SecretClient(
            new Uri($"{secretUri.Scheme}://{secretUri.Host}"),
            new DefaultAzureCredential(credentialOptions));
        var secret = await client.GetSecretAsync(segments[1], cancellationToken: ct);

        try
        {
            return Convert.FromBase64String(secret.Value.Value);
        }
        catch (FormatException exception)
        {
            throw Failure(
                "PURVIEW_POLICY_CERTIFICATE_INVALID",
                "The Purview automation certificate could not be loaded.",
                false,
                exception);
        }
    }

    internal static PurviewPolicyProvisioningResult ParseResult(
        string output,
        PurviewPolicyProvisioningRequest request,
        string sensitiveInformationType)
    {
        var encoded = output.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.Trim())
            .LastOrDefault(line => line.StartsWith(ResultPrefix, StringComparison.Ordinal));
        if (encoded is null)
            throw Failure("PURVIEW_POLICY_READBACK_MISSING", "Purview policy automation did not return verified readback evidence.");

        try
        {
            var json = Encoding.UTF8.GetString(Convert.FromBase64String(encoded[ResultPrefix.Length..]));
            var result = JsonSerializer.Deserialize<AutomationResult>(json, new JsonSerializerOptions(JsonSerializerDefaults.Web));
            var expectedDlpMode = request.Mode switch
            {
                "Enforce" => "Enable",
                "AuditOnly" => "TestWithoutNotifications",
                _ => throw new JsonException("Unsupported requested policy mode.")
            };
            if (result is null ||
                string.IsNullOrWhiteSpace(result.CollectionPolicyId) ||
                string.IsNullOrWhiteSpace(result.DlpPolicyId) ||
                string.IsNullOrWhiteSpace(result.DlpRuleId) ||
                result.DlpBlueprintApplicationIds is null ||
                result.CollectionActivities is null ||
                result.CollectionEnforcementPlanes is null ||
                result.CollectionSensitiveTypeIds is null ||
                result.CollectionLocation is null ||
                result.CollectionLocation.LocationIds is null ||
                result.DlpEnforcementPlanes is null ||
                result.DlpLocation is null ||
                result.DlpLocation.LocationIds is null ||
                result.ClassifierNames is null ||
                result.RuleActions is null ||
                result.VerifiedAtUtc == default ||
                result.VerifiedAtUtc < DateTimeOffset.UtcNow.AddMinutes(-30) ||
                result.VerifiedAtUtc > DateTimeOffset.UtcNow.AddMinutes(5))
                throw new JsonException("Incomplete automation result.");

            if (!MatchesExpectedId(request.ExpectedCollectionPolicyId, result.CollectionPolicyId) ||
                !MatchesExpectedId(request.ExpectedDlpPolicyId, result.DlpPolicyId) ||
                !MatchesExpectedId(request.ExpectedDlpRuleId, result.DlpRuleId))
                throw new JsonException("Provider identifiers do not match persisted profile identifiers.");

            if (result.DlpBlueprintApplicationIds.Length !=
                    result.DlpBlueprintApplicationIds.Distinct(StringComparer.OrdinalIgnoreCase).Count() ||
                result.DlpBlueprintApplicationIds.Count(value => string.Equals(
                    value,
                    request.BlueprintApplicationId,
                    StringComparison.OrdinalIgnoreCase)) != 1 ||
                result.DlpBlueprintApplicationIds.Any(value =>
                    !Guid.TryParse(value, out var parsed) || parsed == Guid.Empty) ||
                !ExactGuidSet(
                    result.DlpBlueprintApplicationIds,
                    request.ExpectedDlpBlueprintApplicationIds!))
                throw new JsonException("DLP blueprint Application scope evidence is invalid.");

            if (!ExactLocation(
                    result.CollectionLocation,
                    PurviewPolicyLocationContract.CollectionLocationType,
                    [PurviewPolicyLocationContract.EnterpriseAiAppsCollectionLocationId]) ||
                !ExactLocation(
                    result.DlpLocation,
                    PurviewPolicyLocationContract.DlpLocationType,
                    result.DlpBlueprintApplicationIds))
                throw new JsonException("Purview collection and DLP location evidence is invalid.");

            if (!string.Equals(result.CollectionMode, "Enable", StringComparison.Ordinal) ||
                !ExactSet(result.CollectionActivities, ["UploadText", "DownloadText"]) ||
                !ExactSet(
                    result.CollectionEnforcementPlanes,
                    [PurviewPolicyLocationContract.ApplicationEnforcementPlane]) ||
                !ExactSet(result.CollectionSensitiveTypeIds, ["All"]) ||
                !result.CollectionIngestionEnabled ||
                !string.Equals(result.DlpMode, expectedDlpMode, StringComparison.Ordinal) ||
                !ExactSet(
                    result.DlpEnforcementPlanes,
                    [PurviewPolicyLocationContract.ApplicationEnforcementPlane]) ||
                !ExactSet(result.ClassifierNames, [sensitiveInformationType]) ||
                result.RuleActions.Length != 1 ||
                result.RuleActions[0] is null ||
                !string.Equals(result.RuleActions[0].Setting, "UploadText", StringComparison.Ordinal) ||
                !string.Equals(result.RuleActions[0].Value, "Block", StringComparison.Ordinal) ||
                result.HasExclusions ||
                result.HasBypass ||
                result.HasExtraConditions ||
                result.HasExtraActions)
                throw new JsonException("Typed policy evidence does not match the reviewed Gateway template.");

            var evidence = new PurviewPolicyReadbackEvidence(
                result.CollectionMode,
                result.CollectionActivities,
                result.CollectionEnforcementPlanes,
                result.CollectionSensitiveTypeIds,
                result.CollectionIngestionEnabled,
                new PurviewPolicyLocationReadbackEvidence(
                    result.CollectionLocation.Workload,
                    result.CollectionLocation.LocationSource,
                    result.CollectionLocation.LocationType,
                    result.CollectionLocation.LocationIds),
                result.DlpMode,
                result.DlpEnforcementPlanes,
                new PurviewPolicyLocationReadbackEvidence(
                    result.DlpLocation.Workload,
                    result.DlpLocation.LocationSource,
                    result.DlpLocation.LocationType,
                    result.DlpLocation.LocationIds),
                result.ClassifierNames,
                result.RuleActions.Select(action =>
                    new PurviewPolicyRuleActionEvidence(action.Setting, action.Value)).ToArray(),
                result.HasExclusions,
                result.HasBypass,
                result.HasExtraConditions,
                result.HasExtraActions);

            return new PurviewPolicyProvisioningResult(
                result.CollectionPolicyId,
                result.DlpPolicyId,
                result.DlpRuleId,
                result.DlpBlueprintApplicationIds,
                evidence,
                result.VerifiedAtUtc);
        }
        catch (Exception exception) when (exception is FormatException or JsonException)
        {
            throw Failure(
                "PURVIEW_POLICY_READBACK_INVALID",
                "Purview policy automation returned invalid readback evidence.",
                false,
                exception);
        }
    }

    private static bool MatchesExpectedId(string? expected, string actual) =>
        string.IsNullOrWhiteSpace(expected) ||
        string.Equals(expected, actual, StringComparison.Ordinal);

    private static bool ExactSet(IReadOnlyList<string> actual, IReadOnlyList<string> expected) =>
        actual.Count == expected.Count &&
        actual.OrderBy(value => value, StringComparer.Ordinal).SequenceEqual(
            expected.OrderBy(value => value, StringComparer.Ordinal),
            StringComparer.Ordinal);

    private static bool ExactGuidSet(
        IReadOnlyList<string> actual,
        IReadOnlyList<string> expected)
    {
        var normalizedActual = NormalizeGuidSet(actual);
        var normalizedExpected = NormalizeGuidSet(expected);
        return normalizedActual is not null &&
               normalizedExpected is not null &&
               normalizedActual.SequenceEqual(normalizedExpected, StringComparer.Ordinal);
    }

    private static bool ExactLocation(
        AutomationLocation result,
        string expectedLocationType,
        IReadOnlyList<string> expectedLocationIds) =>
        string.Equals(
            result.Workload,
            PurviewPolicyLocationContract.ApplicationWorkload,
            StringComparison.Ordinal) &&
        string.Equals(
            result.LocationSource,
            PurviewPolicyLocationContract.EntraLocationSource,
            StringComparison.Ordinal) &&
        string.Equals(result.LocationType, expectedLocationType, StringComparison.Ordinal) &&
        ExactGuidSet(result.LocationIds, expectedLocationIds);

    private static string[]? NormalizeGuidSet(IReadOnlyList<string> values)
    {
        if (values.Count > 512)
            return null;
        var normalized = new List<string>(values.Count);
        foreach (var value in values)
        {
            if (!Guid.TryParse(value, out var parsed) || parsed == Guid.Empty)
                return null;
            var canonical = parsed.ToString("D");
            if (normalized.Contains(canonical, StringComparer.Ordinal))
                return null;
            normalized.Add(canonical);
        }
        return normalized.OrderBy(value => value, StringComparer.Ordinal).ToArray();
    }

    internal static void ValidateExpectedScope(PurviewPolicyProvisioningRequest request)
    {
        if (request.ExpectedPriorDlpBlueprintApplicationIds is null ||
            request.ExpectedDlpBlueprintApplicationIds is null ||
            !Guid.TryParse(request.BlueprintApplicationId, out var current) ||
            current == Guid.Empty)
        {
            throw Failure(
                "PURVIEW_POLICY_EXPECTED_SCOPE_INVALID",
                "Purview policy provisioning requires an exact persisted DLP Application scope.");
        }

        var prior = NormalizeGuidSet(request.ExpectedPriorDlpBlueprintApplicationIds);
        var expected = NormalizeGuidSet(request.ExpectedDlpBlueprintApplicationIds);
        if (prior is null || expected is null)
        {
            throw Failure(
                "PURVIEW_POLICY_EXPECTED_SCOPE_INVALID",
                "Purview policy provisioning requires a bounded set of unique DLP Application IDs.");
        }

        var union = prior
            .Append(current.ToString("D"))
            .Distinct(StringComparer.Ordinal)
            .OrderBy(value => value, StringComparer.Ordinal)
            .ToArray();
        if (!union.SequenceEqual(expected, StringComparer.Ordinal))
        {
            throw Failure(
                "PURVIEW_POLICY_EXPECTED_SCOPE_INVALID",
                "The expected Purview DLP Application scope is not the exact authorized union.");
        }
    }

    private static void AddArgument(ProcessStartInfo info, string name, string value)
    {
        info.ArgumentList.Add(name);
        info.ArgumentList.Add(value);
    }

    private static void CreatePrivateWorkingDirectory(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            Directory.CreateDirectory(
                path,
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            return;
        }

        Directory.CreateDirectory(path);
        ApplyCurrentUserOnlyDirectoryAcl(path);
    }

    [SupportedOSPlatform("windows")]
    private static void ApplyCurrentUserOnlyDirectoryAcl(string path)
    {
        using var identity = WindowsIdentity.GetCurrent();
        var user = identity.User ?? throw Failure(
            "PURVIEW_POLICY_TEMPORARY_FILE_PERMISSIONS_FAILED",
            "The current Windows user could not be resolved for Purview temporary-file protection.");
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            user,
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(security);
    }

    [SupportedOSPlatform("windows")]
    private static void ApplyCurrentUserOnlyFileAcl(string path)
    {
        using var identity = WindowsIdentity.GetCurrent();
        var user = identity.User ?? throw Failure(
            "PURVIEW_POLICY_TEMPORARY_FILE_PERMISSIONS_FAILED",
            "The current Windows user could not be resolved for Purview temporary-file protection.");
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            user,
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
    }

    internal static async Task<BoundedTextCapture> ReadBoundedAsync(
        TextReader reader,
        int characterLimit,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(reader);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(characterLimit);

        var retained = new StringBuilder(Math.Min(characterLimit, 4096));
        var buffer = new char[4096];
        long totalCharacters = 0;
        int read;
        while ((read = await reader.ReadAsync(buffer.AsMemory(), ct)) > 0)
        {
            totalCharacters = totalCharacters > long.MaxValue - read
                ? long.MaxValue
                : totalCharacters + read;
            var remaining = characterLimit - retained.Length;
            if (remaining > 0)
                retained.Append(buffer, 0, Math.Min(remaining, read));
        }

        return new BoundedTextCapture(
            retained.ToString(),
            totalCharacters,
            totalCharacters > characterLimit);
    }

    private static void TryKill(Process process)
    {
        try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
    }

    internal static async Task<bool> DeleteDirectoryAndVerifyAsync(string path)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            if (IsPathProvenAbsent(path))
                return true;
            try
            {
                Directory.Delete(path, recursive: true);
            }
            catch (IOException)
            {
                // A short bounded retry handles process/file-handle release races.
            }
            catch (UnauthorizedAccessException)
            {
                // The final existence probe below keeps this failure fail-closed.
            }

            if (IsPathProvenAbsent(path))
                return true;
            if (attempt < 2)
                await Task.Delay(TimeSpan.FromMilliseconds(50 * (attempt + 1)));
        }

        return false;
    }

    internal static void EnsureCleanupProven(bool cleanupProven)
    {
        if (!cleanupProven)
        {
            throw Failure(
                "PURVIEW_POLICY_TEMPORARY_FILE_CLEANUP_FAILED",
                "Purview temporary automation material could not be proven removed.");
        }
    }

    private static bool IsPathProvenAbsent(string path)
    {
        try
        {
            _ = File.GetAttributes(path);
            return false;
        }
        catch (FileNotFoundException)
        {
            return true;
        }
        catch (DirectoryNotFoundException)
        {
            return true;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static PurviewPolicyException Failure(
        string code,
        string message,
        bool transient = false,
        Exception? exception = null) => new(code, message, transient, exception);

    internal sealed record BoundedTextCapture(
        string Text,
        long TotalCharacters,
        bool Truncated);

    private sealed record AutomationResult(
        string CollectionPolicyId,
        string DlpPolicyId,
        string DlpRuleId,
        string[] DlpBlueprintApplicationIds,
        string CollectionMode,
        string[] CollectionActivities,
        string[] CollectionEnforcementPlanes,
        string[] CollectionSensitiveTypeIds,
        bool CollectionIngestionEnabled,
        AutomationLocation CollectionLocation,
        string DlpMode,
        string[] DlpEnforcementPlanes,
        AutomationLocation DlpLocation,
        string[] ClassifierNames,
        AutomationRuleAction[] RuleActions,
        bool HasExclusions,
        bool HasBypass,
        bool HasExtraConditions,
        bool HasExtraActions,
        DateTimeOffset VerifiedAtUtc);

    private sealed record AutomationLocation(
        string Workload,
        string LocationSource,
        string LocationType,
        string[] LocationIds);

    private sealed record AutomationRuleAction(
        string Setting,
        string Value);
}
