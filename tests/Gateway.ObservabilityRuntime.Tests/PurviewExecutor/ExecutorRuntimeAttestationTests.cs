using System.Security.Cryptography;
using System.Text.Json;
using Gateway.Purview;
using Gateway.Purview.Executor;

namespace Gateway.ObservabilityRuntime.Tests.PurviewExecutor;

public sealed class ExecutorRuntimeAttestationTests
{
    [Theory]
    [InlineData("valid")]
    [InlineData("modified-binary")]
    [InlineData("extra-file")]
    [InlineData("wrong-manifest")]
    [InlineData("old-powershell")]
    [InlineData("different-source")]
    [InlineData("path-escape")]
    [InlineData("duplicate-path")]
    public async Task RuntimeRequiresExactImmutableManifest(string variant)
    {
        var root = Path.Combine(Path.GetTempPath(), "a365gw-executor-attestation-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var paths = new[] { "Gateway.Purview.Executor.dll", "Gateway.Purview.dll",
                "Gateway.Provisioning.Worker.dll", "PowerShell/pwsh.exe",
                "Automation/Verify-PurviewTenantConnection.ps1", "Automation/Invoke-PurviewSettingsOperation.ps1",
                "PowerShellModules/ExchangeOnlineManagement/3.10.1/ExchangeOnlineManagement.psd1" };
            var files = new List<ExecutorRuntimeFile>();
            foreach (var relative in paths)
            {
                var path = Path.Combine(root, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                await File.WriteAllTextAsync(path, "offline fixture");
                files.Add(new(relative, Convert.ToHexStringLower(SHA256.HashData(await File.ReadAllBytesAsync(path)))));
            }
            if (variant == "path-escape") files[0] = files[0] with { Path = "../escape.dll" };
            if (variant == "duplicate-path") files.Add(files[0]);
            var source = "sha256:" + new string('a', 64);
            var manifest = new ExecutorRuntimeManifest(1,
                variant == "different-source" ? "sha256:" + new string('b', 64) : source,
                variant == "old-powershell" ? "7.5.0" : ExecutorRuntimeAttestation.PowerShellVersion,
                ExecutorRuntimeAttestation.ExchangeOnlineManagementVersion, files.ToArray());
            var bytes = JsonSerializer.SerializeToUtf8Bytes(manifest, PurviewExecutorJson.Options);
            await File.WriteAllBytesAsync(Path.Combine(root, ExecutorRuntimeAttestation.ManifestName), bytes);
            var digest = "sha256:" + Convert.ToHexStringLower(SHA256.HashData(bytes));
            if (variant == "modified-binary") await File.AppendAllTextAsync(Path.Combine(root, paths[0]), "changed");
            if (variant == "extra-file") await File.WriteAllTextAsync(Path.Combine(root, "unlisted.dll"), "extra");
            if (variant == "wrong-manifest") digest = "sha256:" + new string('0', 64);
            if (variant == "valid") await ExecutorRuntimeAttestation.VerifyFilesAsync(root, digest, source, default);
            else await Assert.ThrowsAsync<InvalidOperationException>(() =>
                ExecutorRuntimeAttestation.VerifyFilesAsync(root, digest, source, default));
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}
