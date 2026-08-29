using System.Diagnostics;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
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
        CancellationToken ct)
    {
        if (!IsEnabled)
        {
            throw Failure("PURVIEW_POLICY_PROVISIONING_DISABLED", "Purview policy provisioning is not configured.");
        }

        var workingDirectory = Path.Combine(Path.GetTempPath(), $"a365gw-purview-{Guid.NewGuid():N}");
        if (OperatingSystem.IsWindows())
            Directory.CreateDirectory(workingDirectory);
        else
            Directory.CreateDirectory(
                workingDirectory,
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var inputPath = Path.Combine(workingDirectory, "request.json");
        var certificatePath = Path.Combine(workingDirectory, "automation.pfx");
        var certificatePassword = Convert.ToBase64String(RandomNumberGenerator.GetBytes(48));

        try
        {
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
                    if (!OperatingSystem.IsWindows())
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
                    sensitiveInformationType = _options.DefaultSensitiveInformationType
                }),
                Encoding.UTF8,
                ct);

            var scriptPath = Path.Combine(AppContext.BaseDirectory, "Automation", "Ensure-PurviewPolicyProfile.ps1");
            if (!File.Exists(scriptPath))
                throw Failure("PURVIEW_POLICY_AUTOMATION_MISSING", "The Purview policy automation script is unavailable.");

            using var process = new Process
            {
                StartInfo = CreateStartInfo(scriptPath, inputPath, certificatePath)
            };
            if (!process.Start())
                throw Failure("PURVIEW_POLICY_AUTOMATION_START_FAILED", "Purview policy automation could not start.");

            await process.StandardInput.WriteLineAsync(certificatePassword);
            process.StandardInput.Close();

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(_options.PolicyProvisioningTimeoutSeconds));
            string standardOutput;
            string standardError;
            try
            {
                var outputTask = process.StandardOutput.ReadToEndAsync(timeout.Token);
                var errorTask = process.StandardError.ReadToEndAsync(timeout.Token);
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

            if (process.ExitCode != 0)
            {
                _logger.LogWarning(
                    "Purview policy automation failed. ExitCode: {ExitCode}; DiagnosticLength: {DiagnosticLength}",
                    process.ExitCode,
                    standardError.Length);
                throw Failure("PURVIEW_POLICY_AUTOMATION_FAILED", "Purview policy automation failed closed.");
            }

            return ParseResult(standardOutput);
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
            TryDeleteDirectory(workingDirectory);
        }
    }

    private ProcessStartInfo CreateStartInfo(string scriptPath, string inputPath, string certificatePath)
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

    private static PurviewPolicyProvisioningResult ParseResult(string output)
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
            if (result is null ||
                string.IsNullOrWhiteSpace(result.CollectionPolicyId) ||
                string.IsNullOrWhiteSpace(result.DlpPolicyId) ||
                string.IsNullOrWhiteSpace(result.DlpRuleId) ||
                result.VerifiedAtUtc == default)
                throw new JsonException("Incomplete automation result.");

            return new PurviewPolicyProvisioningResult(
                result.CollectionPolicyId,
                result.DlpPolicyId,
                result.DlpRuleId,
                result.BlueprintApplicationIds?.Distinct(StringComparer.Ordinal).ToArray() ?? [],
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

    private static void AddArgument(ProcessStartInfo info, string name, string value)
    {
        info.ArgumentList.Add(name);
        info.ArgumentList.Add(value);
    }

    private static void TryKill(Process process)
    {
        try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
    }

    private static void TryDeleteDirectory(string path)
    {
        try { Directory.Delete(path, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private static PurviewPolicyException Failure(
        string code,
        string message,
        bool transient = false,
        Exception? exception = null) => new(code, message, transient, exception);

    private sealed record AutomationResult(
        string CollectionPolicyId,
        string DlpPolicyId,
        string DlpRuleId,
        string[]? BlueprintApplicationIds,
        DateTimeOffset VerifiedAtUtc);
}
