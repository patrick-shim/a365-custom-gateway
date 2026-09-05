extern alias AzureIdentity;

using System.Diagnostics;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Azure.Core;
using Azure.Security.KeyVault.Secrets;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Purview;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using ManagedIdentityCredential =
    AzureIdentity::Azure.Identity.ManagedIdentityCredential;

namespace Gateway.Provisioning.Worker;

internal interface IPurviewVerifierProcessControl
{
    bool HasExited { get; }
    void Kill(bool entireProcessTree);
    Task WaitForExitAsync(CancellationToken cancellationToken);
}

internal sealed class PurviewVerifierProcessControl(Process process)
    : IPurviewVerifierProcessControl
{
    public bool HasExited => process.HasExited;

    public void Kill(bool entireProcessTree) =>
        process.Kill(entireProcessTree);

    public Task WaitForExitAsync(CancellationToken cancellationToken) =>
        process.WaitForExitAsync(cancellationToken);
}

internal sealed class PowerShellPurviewConnectionVerificationProvider
    : IPurviewConnectionVerificationProvider
{
    private const string ResultPrefix = "A365GW_CONNECTION_VERIFICATION:";
    private const int StandardOutputLimit = 256 * 1024;
    private const int StandardErrorLimit = 32 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(
        JsonSerializerDefaults.Web)
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    private readonly PurviewOptions _options;
    private readonly ILogger<PowerShellPurviewConnectionVerificationProvider> _logger;

    public PowerShellPurviewConnectionVerificationProvider(
        IOptions<PurviewOptions> options,
        ILogger<PowerShellPurviewConnectionVerificationProvider> logger)
    {
        _options = options.Value;
        _logger = logger;
    }

    public async Task<PurviewConnectionVerificationEvidence> VerifyAsync(
        PurviewConnectionVerificationRequest request,
        CancellationToken ct)
    {
        var binding = ValidateConfiguration(request);
        var workingDirectory = Path.Combine(
            Path.GetTempPath(),
            $"a365gw-purview-connection-{Guid.NewGuid():N}");
        var inputPath = Path.Combine(workingDirectory, "request.json");
        var certificatePath = Path.Combine(workingDirectory, "automation.pfx");
        var certificatePassword = Convert.ToBase64String(
            RandomNumberGenerator.GetBytes(48));

        try
        {
            CreatePrivateDirectory(workingDirectory);
            await File.WriteAllTextAsync(
                inputPath,
                JsonSerializer.Serialize(new
                {
                    operationId = request.OperationId.ToString("D"),
                    tenantId = request.TenantId.ToString("D"),
                    administratorObjectId =
                        request.AdministratorObjectId.ToString("D")
                }, JsonOptions),
                Encoding.UTF8,
                ct);
            RestrictFile(inputPath);

            byte[]? sourceCertificate = null;
            byte[]? exportedCertificate = null;
            Uri? providerCertificateSecretId = null;
            try
            {
                var downloadedCertificate = await DownloadCertificateAsync(
                    binding,
                    ct);
                sourceCertificate = downloadedCertificate.Bytes;
                providerCertificateSecretId =
                    downloadedCertificate.ProviderSecretId;
                using var certificate = X509CertificateLoader.LoadPkcs12(
                    sourceCertificate,
                    (string?)null,
                    X509KeyStorageFlags.EphemeralKeySet |
                    X509KeyStorageFlags.Exportable);
                if (!certificate.HasPrivateKey)
                {
                    throw Failure(
                        "PURVIEW_CONNECTION_CERTIFICATE_INVALID");
                }

                exportedCertificate = certificate.Export(
                    X509ContentType.Pkcs12,
                    certificatePassword);
                await File.WriteAllBytesAsync(
                    certificatePath,
                    exportedCertificate,
                    ct);
                RestrictFile(certificatePath);
            }
            finally
            {
                if (sourceCertificate is not null)
                    CryptographicOperations.ZeroMemory(sourceCertificate);
                if (exportedCertificate is not null)
                    CryptographicOperations.ZeroMemory(exportedCertificate);
            }

            using var process = new Process
            {
                StartInfo = CreateStartInfo(
                    inputPath,
                    certificatePath,
                    request)
            };
            if (!process.Start())
                throw Failure("PURVIEW_CONNECTION_VERIFIER_START_FAILED");

            await process.StandardInput.WriteLineAsync(certificatePassword);
            process.StandardInput.Close();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(
                TimeSpan.FromSeconds(_options.PolicyProvisioningTimeoutSeconds));
            var outputTask = ReadBoundedAsync(
                process.StandardOutput,
                StandardOutputLimit,
                timeout.Token);
            var errorTask = ReadBoundedAsync(
                process.StandardError,
                StandardErrorLimit,
                timeout.Token);
            await WaitForExitOrCancelAsync(
                new PurviewVerifierProcessControl(process),
                workingDirectory,
                timeout.Token,
                ct);
            var standardOutput = await outputTask;
            var standardError = await errorTask;

            if (standardOutput.Truncated ||
                standardError.Truncated ||
                process.ExitCode != 0)
            {
                _logger.LogWarning(
                    "Independent Purview connection verification failed its bounded process contract. ExitCode: {ExitCode}; OutputCharacters: {OutputCharacters}; ErrorCharacters: {ErrorCharacters}",
                    process.ExitCode,
                    standardOutput.TotalCharacters,
                    standardError.TotalCharacters);
                throw Failure("PURVIEW_CONNECTION_PROVIDER_UNVERIFIED");
            }

            return ParseEvidence(
                ExtractResult(standardOutput.Text),
                request,
                providerCertificateSecretId ??
                    throw Failure(
                        "PURVIEW_CONNECTION_CERTIFICATE_READBACK_MISSING"));
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (PurviewConnectionVerificationException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw Failure(
                "PURVIEW_CONNECTION_PROVIDER_UNVERIFIED",
                innerException: exception);
        }
        finally
        {
            TryDeleteDirectory(workingDirectory);
        }
    }

    private PurviewAutomationCapabilityBinding ValidateConfiguration(
        PurviewConnectionVerificationRequest request)
    {
        if (request.OperationId == Guid.Empty ||
            request.TenantId == Guid.Empty ||
            request.AdministratorObjectId == Guid.Empty ||
            request.ExpectedAuthorityApplicationId == Guid.Empty ||
            request.ExpectedAuthorityServicePrincipalObjectId == Guid.Empty)
        {
            throw Failure("PURVIEW_CONNECTION_REQUEST_INVALID");
        }
        if (!_options.PolicyProvisioningEnabled ||
            string.IsNullOrWhiteSpace(_options.PolicyProvisioningOrganization) ||
            string.IsNullOrWhiteSpace(_options.PolicyProvisioningPowerShellPath) ||
            _options.PolicyProvisioningTimeoutSeconds < 1)
        {
            throw Failure("PURVIEW_CONNECTION_VERIFIER_NOT_CONFIGURED");
        }

        PurviewAutomationCapabilityBinding binding;
        try
        {
            binding = PurviewAutomationCapabilityBindingValidator.Bind(
                new ProtectionCapabilityResourceIdentifiers(
                    PurviewAutomationApplicationId:
                        new ApplicationClientId(
                            request.ExpectedAuthorityApplicationId),
                    PurviewAutomationServicePrincipalObjectId:
                        new ServicePrincipalObjectId(
                            request.ExpectedAuthorityServicePrincipalObjectId),
                    KeyVaultResourceId: request.ExpectedKeyVaultResourceId,
                    CertificateName: request.ExpectedCertificateName),
                _options);
        }
        catch (Gateway.Domain.Models.PurviewPolicyException exception)
        {
            throw Failure(exception.FailureCode, innerException: exception);
        }

        if (!string.Equals(
                binding.KeyVaultHost,
                request.ExpectedKeyVaultHost,
                StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(
                binding.CertificateSecretUri.AbsoluteUri,
                request.ExpectedCertificateSecretUri.AbsoluteUri,
                StringComparison.Ordinal))
        {
            throw Failure("PURVIEW_CONNECTION_CAPABILITY_BINDING_MISMATCH");
        }

        return binding;
    }

    private ProcessStartInfo CreateStartInfo(
        string inputPath,
        string certificatePath,
        PurviewConnectionVerificationRequest request)
    {
        var scriptPath = Path.Combine(
            AppContext.BaseDirectory,
            "Automation",
            "Verify-PurviewTenantConnection.ps1");
        if (!File.Exists(scriptPath))
            throw Failure("PURVIEW_CONNECTION_VERIFIER_MISSING");

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
                     "-Organization",
                     _options.PolicyProvisioningOrganization!,
                     "-AutomationApplicationId",
                     _options.PolicyProvisioningApplicationId!,
                     "-AutomationServicePrincipalObjectId",
                     request.ExpectedAuthorityServicePrincipalObjectId.ToString("D")
                 })
        {
            info.ArgumentList.Add(argument);
        }

        return info;
    }

    private async Task<DownloadedCertificate> DownloadCertificateAsync(
        PurviewAutomationCapabilityBinding binding,
        CancellationToken ct)
    {
        var credential = CreateManagedIdentityCredential(
            _options.ManagedIdentityClientId);
        var client = new SecretClient(
            new Uri($"https://{binding.KeyVaultHost}"),
            credential);
        var secret = await client.GetSecretAsync(
            binding.CertificateName,
            cancellationToken: ct);
        var providerSecretId = secret.Value.Properties.Id;
        if (!IsExactProviderCertificateId(providerSecretId, binding))
        {
            throw Failure(
                "PURVIEW_CONNECTION_CERTIFICATE_READBACK_MISMATCH");
        }
        try
        {
            return new(
                Convert.FromBase64String(secret.Value.Value),
                providerSecretId);
        }
        catch (FormatException exception)
        {
            throw Failure(
                "PURVIEW_CONNECTION_CERTIFICATE_INVALID",
                innerException: exception);
        }
    }

    internal static TokenCredential CreateManagedIdentityCredential(string? clientId) =>
        string.IsNullOrWhiteSpace(clientId)
            ? new ManagedIdentityCredential()
            : new ManagedIdentityCredential(clientId);

    private static PurviewConnectionVerificationEvidence ParseEvidence(
        string encodedResult,
        PurviewConnectionVerificationRequest request,
        Uri providerCertificateSecretId)
    {
        byte[] bytes;
        try
        {
            bytes = Convert.FromBase64String(encodedResult);
        }
        catch (FormatException exception)
        {
            throw Failure(
                "PURVIEW_CONNECTION_RESULT_INVALID",
                innerException: exception);
        }

        try
        {
            var result = JsonSerializer.Deserialize<ProviderResult>(
                bytes,
                JsonOptions) ?? throw Failure("PURVIEW_CONNECTION_RESULT_INVALID");
            if (!TryParseCanonicalGuid(result.OperationId, out var operationId) ||
                !TryParseCanonicalGuid(result.TenantId, out var tenantId) ||
                !TryParseCanonicalGuid(
                    result.AdministratorObjectId,
                    out var administratorObjectId) ||
                !TryParseCanonicalGuid(
                    result.AuthorityApplicationId,
                    out var authorityApplicationId) ||
                !TryParseCanonicalGuid(
                    result.AuthorityServicePrincipalObjectId,
                    out var servicePrincipalId) ||
                result.Items is null ||
                result.Items.Any(item =>
                    !TryParseCanonicalGuid(item.Id, out _)))
            {
                throw Failure("PURVIEW_CONNECTION_RESULT_INVALID");
            }

            if (authorityApplicationId !=
                    request.ExpectedAuthorityApplicationId ||
                servicePrincipalId !=
                    request.ExpectedAuthorityServicePrincipalObjectId)
            {
                throw Failure(
                    "PURVIEW_CONNECTION_CAPABILITY_BINDING_MISMATCH");
            }
            return PurviewConnectionVerificationEvidence.Create(
                operationId,
                tenantId,
                administratorObjectId,
                authorityApplicationId,
                servicePrincipalId,
                request.ExpectedKeyVaultResourceId,
                request.ExpectedKeyVaultHost,
                request.ExpectedCertificateName,
                request.ExpectedCertificateSecretUri,
                providerCertificateSecretId,
                result.ObservedAtUtc,
                result.ExpiresAtUtc,
                result.Items.Select((item, index) =>
                    new PurviewConnectionInventoryItem(
                        Guid.Parse(item.Id),
                        item.ExactName,
                        item.Publisher,
                        index)).ToArray());
        }
        catch (Exception exception) when (
            exception is JsonException or
                FormatException or
                ArgumentException)
        {
            throw Failure(
                "PURVIEW_CONNECTION_RESULT_INVALID",
                innerException: exception);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    private static string ExtractResult(string output)
    {
        var lines = output.Split(
            ['\r', '\n'],
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (lines.Length != 1 ||
            !lines[0].StartsWith(ResultPrefix, StringComparison.Ordinal) ||
            lines[0].Length == ResultPrefix.Length)
        {
            throw Failure("PURVIEW_CONNECTION_RESULT_INVALID");
        }

        return lines[0][ResultPrefix.Length..];
    }

    private static bool TryParseCanonicalGuid(string? value, out Guid parsed) =>
        Guid.TryParse(value, out parsed) &&
        parsed != Guid.Empty &&
        string.Equals(value, parsed.ToString("D"), StringComparison.Ordinal);

    private static bool IsExactProviderCertificateId(
        Uri? providerSecretId,
        PurviewAutomationCapabilityBinding binding)
    {
        if (providerSecretId is null ||
            !providerSecretId.IsAbsoluteUri ||
            !string.Equals(
                providerSecretId.Scheme,
                Uri.UriSchemeHttps,
                StringComparison.OrdinalIgnoreCase) ||
            !providerSecretId.IsDefaultPort ||
            !string.Equals(
                providerSecretId.Host,
                binding.KeyVaultHost,
                StringComparison.OrdinalIgnoreCase) ||
            !string.IsNullOrEmpty(providerSecretId.UserInfo) ||
            !string.IsNullOrEmpty(providerSecretId.Query) ||
            !string.IsNullOrEmpty(providerSecretId.Fragment))
        {
            return false;
        }

        var segments = providerSecretId.AbsolutePath.Split(
            '/',
            StringSplitOptions.RemoveEmptyEntries);
        return segments is ["secrets", var certificateName, var version] &&
            string.Equals(
                certificateName,
                binding.CertificateName,
                StringComparison.Ordinal) &&
            !string.IsNullOrWhiteSpace(version) &&
            version.Length <= 128 &&
            version.All(character =>
                char.IsAsciiLetterOrDigit(character) || character == '-');
    }

    private static async Task<BoundedText> ReadBoundedAsync(
        TextReader reader,
        int characterLimit,
        CancellationToken ct)
    {
        var retained = new StringBuilder(Math.Min(characterLimit, 4096));
        var buffer = new char[4096];
        long total = 0;
        int read;
        while ((read = await reader.ReadAsync(buffer.AsMemory(), ct)) > 0)
        {
            total = total > long.MaxValue - read
                ? long.MaxValue
                : total + read;
            var remaining = characterLimit - retained.Length;
            if (remaining > 0)
                retained.Append(buffer, 0, Math.Min(read, remaining));
        }

        return new(retained.ToString(), total, total > characterLimit);
    }

    private static void CreatePrivateDirectory(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            Directory.CreateDirectory(path);
            ApplyCurrentUserDirectoryAcl(path);
            return;
        }

        Directory.CreateDirectory(
            path,
            UnixFileMode.UserRead |
            UnixFileMode.UserWrite |
            UnixFileMode.UserExecute);
    }

    private static void RestrictFile(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            ApplyCurrentUserFileAcl(path);
            return;
        }

        File.SetUnixFileMode(
            path,
            UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }

    [SupportedOSPlatform("windows")]
    private static void ApplyCurrentUserDirectoryAcl(string path)
    {
        using var identity = WindowsIdentity.GetCurrent();
        var user = identity.User ??
            throw Failure("PURVIEW_CONNECTION_TEMPORARY_PATH_UNAVAILABLE");
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
    private static void ApplyCurrentUserFileAcl(string path)
    {
        using var identity = WindowsIdentity.GetCurrent();
        var user = identity.User ??
            throw Failure("PURVIEW_CONNECTION_TEMPORARY_PATH_UNAVAILABLE");
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            user,
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
    }

    internal static async Task WaitForExitOrCancelAsync(
        IPurviewVerifierProcessControl process,
        string workingDirectory,
        CancellationToken waitToken,
        CancellationToken callerCancellationToken)
    {
        try
        {
            await process.WaitForExitAsync(waitToken);
        }
        catch (OperationCanceledException)
        {
            await StopProcessAndCleanupAsync(process, workingDirectory);
            if (callerCancellationToken.IsCancellationRequested)
                throw new OperationCanceledException(callerCancellationToken);

            throw Failure(
                "PURVIEW_CONNECTION_READ_TIMEOUT",
                isTransient: true);
        }
    }

    private static async Task StopProcessAndCleanupAsync(
        IPurviewVerifierProcessControl process,
        string workingDirectory)
    {
        TryKill(process);
        using var exitWait = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        try
        {
            await process.WaitForExitAsync(exitWait.Token);
        }
        catch (OperationCanceledException)
        {
        }
        catch (InvalidOperationException)
        {
        }
        catch (System.ComponentModel.Win32Exception)
        {
        }
        finally
        {
            await DeleteDirectoryWithRetryAsync(workingDirectory);
        }
    }

    private static void TryKill(IPurviewVerifierProcessControl process)
    {
        try
        {
            if (!process.HasExited)
                process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException)
        {
        }
        catch (System.ComponentModel.Win32Exception)
        {
        }
        catch (NotSupportedException)
        {
        }
    }

    private static async Task DeleteDirectoryWithRetryAsync(string path)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            TryDeleteDirectory(path);
            if (!Directory.Exists(path))
                return;
            if (attempt < 2)
                await Task.Delay(TimeSpan.FromMilliseconds(50 * (attempt + 1)));
        }
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
                Directory.Delete(path, recursive: true);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
        catch (System.Security.SecurityException)
        {
        }
    }

    private static PurviewConnectionVerificationException Failure(
        string failureCode,
        bool isTransient = false,
        Exception? innerException = null) =>
        new(failureCode, isTransient, innerException);

    private sealed record ProviderResult(
        string OperationId,
        string TenantId,
        string AdministratorObjectId,
        string AuthorityApplicationId,
        string? AuthorityServicePrincipalObjectId,
        DateTimeOffset ObservedAtUtc,
        DateTimeOffset ExpiresAtUtc,
        IReadOnlyList<ProviderInventoryItem> Items);

    private sealed record ProviderInventoryItem(
        string Id,
        string ExactName,
        string Publisher);

    private sealed record DownloadedCertificate(
        byte[] Bytes,
        Uri ProviderSecretId);

    private sealed record BoundedText(
        string Text,
        long TotalCharacters,
        bool Truncated);
}
