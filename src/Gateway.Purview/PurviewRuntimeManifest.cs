using System.Security.Cryptography;
using System.Text.Json;

namespace Gateway.Purview;

internal sealed record ExecutorRuntimeFile(string Path, string Sha256);
internal sealed record ExecutorRuntimeManifest(int SchemaVersion, string SourceFingerprint,
    string PowerShellVersion, string ExchangeOnlineManagementVersion, ExecutorRuntimeFile[] Files);

internal static class PurviewRuntimeManifest
{
    internal const string FileName = "executor-runtime.json";
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    internal static async Task<ExecutorRuntimeManifest> VerifyAsync(string root, string? digest,
        string? sourceFingerprint, CancellationToken cancellationToken)
    {
        if (!Path.IsPathFullyQualified(root) || !PurviewChildInvocation.IsDigest(digest)) throw Invalid();
        root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        var manifestPath = Path.Combine(root, FileName);
        PurviewChildInvocation.RequireRegularFile(manifestPath, root);
        if (new FileInfo(manifestPath).Length > 4 * 1024 * 1024) throw Invalid();
        var bytes = await File.ReadAllBytesAsync(manifestPath, cancellationToken);
        if ("sha256:" + Convert.ToHexStringLower(SHA256.HashData(bytes)) != digest) throw Invalid();
        var manifest = JsonSerializer.Deserialize<ExecutorRuntimeManifest>(bytes, JsonOptions);
        if (manifest is null || manifest.SchemaVersion != 1 ||
            !PurviewChildInvocation.IsDigest(manifest.SourceFingerprint) ||
            sourceFingerprint is not null && manifest.SourceFingerprint != sourceFingerprint ||
            manifest.PowerShellVersion != PurviewChildInvocation.PowerShellVersion ||
            manifest.ExchangeOnlineManagementVersion != PurviewChildInvocation.ModuleVersion ||
            manifest.Files is not { Length: > 0 and <= 20000 })
            throw Invalid();
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var prefix = root + Path.DirectorySeparatorChar;
        foreach (var item in manifest.Files)
        {
            if (item is null || string.IsNullOrEmpty(item.Path) || item.Path.Contains('\\') ||
                item.Path.Split('/').Any(part => part is "" or "." or ".." || part.Contains(':')) ||
                !names.Add(item.Path) || item.Sha256 is not { Length: 64 } ||
                !item.Sha256.All(char.IsAsciiHexDigitLower))
                throw Invalid();
            var path = Path.GetFullPath(Path.Combine(root, item.Path));
            if (!path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw Invalid();
            PurviewChildInvocation.RequireRegularFile(path, root);
            await using var file = File.OpenRead(path);
            if (Convert.ToHexStringLower(await SHA256.HashDataAsync(file, cancellationToken)) != item.Sha256)
                throw Invalid();
        }
        foreach (var required in new[] { "Gateway.Purview.Executor.dll", "Gateway.Purview.dll",
            "Gateway.Provisioning.Worker.dll", "PowerShell/pwsh.exe", "PowerShell/System.Management.Automation.dll",
            "ref/System.Runtime.dll",
            PurviewChildInvocation.HostFileName, PurviewChildInvocation.HostName + ".dll",
            PurviewChildInvocation.HostName + ".deps.json", PurviewChildInvocation.HostName + ".runtimeconfig.json",
            "Automation/Verify-PurviewTenantConnection.ps1", "Automation/Invoke-PurviewSettingsOperation.ps1",
            $"PowerShellModules/ExchangeOnlineManagement/{PurviewChildInvocation.ModuleVersion}/ExchangeOnlineManagement.psd1" })
            if (!names.Contains(required)) throw Invalid();
        var pending = new Stack<string>();
        pending.Push(root);
        var entries = 0;
        while (pending.TryPop(out var directory))
        {
            foreach (var path in Directory.EnumerateFileSystemEntries(directory))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (++entries > 40000) throw Invalid();
                var attributes = File.GetAttributes(path);
                if ((attributes & FileAttributes.ReparsePoint) != 0) throw Invalid();
                if ((attributes & FileAttributes.Directory) != 0) pending.Push(path);
                else
                {
                    var relative = Path.GetRelativePath(root, path).Replace('\\', '/');
                    if (relative != FileName && !names.Contains(relative)) throw Invalid();
                }
            }
        }
        return manifest;
    }

    private static InvalidOperationException Invalid() => new("Purview executor runtime attestation failed.");
}
