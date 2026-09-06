using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;

namespace Gateway.Purview.Executor;

internal sealed record ExecutorRuntimeFile(string Path, string Sha256);
internal sealed record ExecutorRuntimeManifest(int SchemaVersion, string SourceFingerprint,
    string PowerShellVersion, string ExchangeOnlineManagementVersion, ExecutorRuntimeFile[] Files);

internal static class ExecutorRuntimeAttestation
{
    internal const string ManifestName = "executor-runtime.json";
    internal const string PowerShellVersion = "7.6.5";
    internal const string ExchangeOnlineManagementVersion = "3.10.1";

    public static async Task VerifyAsync(string root, ExecutorHostOptions options,
        PurviewOptions purview, CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsWindows() || !Environment.Is64BitProcess ||
            options.Binding is null || options.OperationTimeoutSeconds != 195 ||
            purview.ManagedIdentityClientId is not null ||
            !purview.PolicyProvisioningEnabled ||
            purview.PolicyProvisioningTimeoutSeconds != 180)
            throw Invalid();
        options.Binding.Validate(purview);
        await VerifyFilesAsync(root, options.RuntimeManifestDigest,
            options.Binding.ExecutionSourceFingerprint, cancellationToken);

        var powerShellPath = Path.Combine(root, "PowerShell", "pwsh.exe");
        if (!string.Equals(Path.GetFullPath(purview.PolicyProvisioningPowerShellPath),
                powerShellPath, StringComparison.OrdinalIgnoreCase))
            throw Invalid();
        Environment.SetEnvironmentVariable("PSModulePath", string.Join(Path.PathSeparator,
            Path.Combine(root, "PowerShellModules"), Path.Combine(root, "PowerShell", "Modules")));

        var start = new ProcessStartInfo(powerShellPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = root
        };
        foreach (var value in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
            "$ErrorActionPreference='Stop'; $m=@(Get-Module -ListAvailable ExchangeOnlineManagement); if($m.Count -ne 1){exit 2}; Import-Module -FullyQualifiedName @{ModuleName='ExchangeOnlineManagement';RequiredVersion='3.10.1'} -ErrorAction Stop; $c=Get-Command Connect-IPPSSession -Module ExchangeOnlineManagement -ErrorAction Stop; if($null -eq $c){exit 3}; [Console]::Write(($PSVersionTable.PSVersion.ToString()+'|'+$m[0].Version.ToString()))" })
            start.ArgumentList.Add(value);
        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw Invalid();
        await using var lease = new PurviewProcessLease(process, new PurviewProcessSafety());
        var output = PowerShellPurviewPolicyProvisioningClient.ReadBoundedAsync(
            process.StandardOutput, 256, cancellationToken);
        var error = PowerShellPurviewPolicyProvisioningClient.ReadBoundedAsync(
            process.StandardError, 256, cancellationToken);
        await process.WaitForExitAsync(cancellationToken);
        var stdout = await output;
        var stderr = await error;
        if (process.ExitCode != 0 || stdout.Truncated || stderr.Truncated ||
            stderr.TotalCharacters != 0 ||
            stdout.Text != $"{PowerShellVersion}|{ExchangeOnlineManagementVersion}")
            throw Invalid();
    }

    internal static async Task VerifyFilesAsync(string root, string? manifestDigest,
        string sourceFingerprint, CancellationToken cancellationToken)
    {
        var manifestPath = Path.Combine(root, ManifestName);
        if (!File.Exists(manifestPath) || new FileInfo(manifestPath).Length > 4 * 1024 * 1024)
            throw Invalid();
        var bytes = await File.ReadAllBytesAsync(manifestPath, cancellationToken);
        if ("sha256:" + Convert.ToHexStringLower(SHA256.HashData(bytes)) != manifestDigest)
            throw Invalid();
        var manifest = JsonSerializer.Deserialize<ExecutorRuntimeManifest>(bytes, PurviewExecutorJson.Options);
        if (manifest is null || manifest.SchemaVersion != 1 ||
            manifest.SourceFingerprint != sourceFingerprint ||
            manifest.PowerShellVersion != PowerShellVersion ||
            manifest.ExchangeOnlineManagementVersion != ExchangeOnlineManagementVersion ||
            manifest.Files is not { Length: > 0 and <= 20000 })
            throw Invalid();

        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var absoluteRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        foreach (var item in manifest.Files)
        {
            if (item is null || string.IsNullOrEmpty(item.Path) || item.Path.Contains('\\') ||
                item.Path.Split('/').Any(part => part is "" or "." or ".." || part.Contains(':')) ||
                !names.Add(item.Path) || item.Sha256 is not { Length: 64 } ||
                !item.Sha256.All(char.IsAsciiHexDigitLower))
                throw Invalid();
            var path = Path.GetFullPath(Path.Combine(root, item.Path));
            if (!path.StartsWith(absoluteRoot, StringComparison.OrdinalIgnoreCase) ||
                !File.Exists(path) || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw Invalid();
            await using var file = File.OpenRead(path);
            if (Convert.ToHexStringLower(await SHA256.HashDataAsync(file, cancellationToken)) != item.Sha256)
                throw Invalid();
        }
        foreach (var required in new[] { "Gateway.Purview.Executor.dll", "Gateway.Purview.dll",
            "Gateway.Provisioning.Worker.dll", "PowerShell/pwsh.exe",
            "Automation/Verify-PurviewTenantConnection.ps1", "Automation/Invoke-PurviewSettingsOperation.ps1",
            $"PowerShellModules/ExchangeOnlineManagement/{ExchangeOnlineManagementVersion}/ExchangeOnlineManagement.psd1" })
            if (!names.Contains(required)) throw Invalid();
        foreach (var path in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            var relative = Path.GetRelativePath(root, path).Replace('\\', '/');
            if (relative != ManifestName && !names.Contains(relative)) throw Invalid();
        }
    }

    private static InvalidOperationException Invalid() =>
        new("Purview executor runtime attestation failed.");
}
