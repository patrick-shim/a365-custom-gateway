using System.Diagnostics;

namespace Gateway.Purview.Executor;

internal static class ExecutorRuntimeAttestation
{
    internal const string ManifestName = "executor-runtime.json";
    internal const string PowerShellVersion = PurviewPowerShellProcess.PowerShellVersion;
    internal const string ExchangeOnlineManagementVersion = PurviewPowerShellProcess.ExchangeOnlineManagementVersion;

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
        var diagnosticHookHash = await VerifyFilesAsync(root, options.RuntimeManifestDigest,
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
            PurviewPowerShellProcess.ProbeCommand })
            start.ArgumentList.Add(value);
        PurviewPowerShellProcess.ApplyVerifiedPackageIsolation(start, root, options.RuntimeManifestDigest);
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
        await ValidateProbeResultAsync(process.ExitCode, stdout, stderr,
            token => ExecutorStartupDiagnostics.RunAsync(root, diagnosticHookHash, start, token),
            cancellationToken);
    }

    internal static async Task ValidateProbeResultAsync(int exitCode,
        PowerShellPurviewPolicyProvisioningClient.BoundedTextCapture stdout,
        PowerShellPurviewPolicyProvisioningClient.BoundedTextCapture stderr,
        Func<CancellationToken, Task<StartupDiagnosticResult>> diagnose, CancellationToken cancellationToken)
    {
        if (!ExecutorStartupDiagnostics.ShouldRun(exitCode, stdout, stderr))
        {
            ValidateProbeResult(exitCode, stdout, stderr);
            return;
        }
        StartupDiagnosticResult diagnostic;
        try { diagnostic = await diagnose(cancellationToken); }
        catch (Exception) { diagnostic = new(StartupDiagnosticStatus.Failed); }
        try { ValidateProbeResult(exitCode, stdout, stderr); }
        catch (InvalidOperationException failure)
        {
            throw new InvalidOperationException(failure.Message + " Startup diagnostic: " +
                ExecutorStartupDiagnostics.Summarize(diagnostic));
        }
    }

    internal static void ValidateProbeResult(int exitCode,
        PowerShellPurviewPolicyProvisioningClient.BoundedTextCapture stdout,
        PowerShellPurviewPolicyProvisioningClient.BoundedTextCapture stderr)
    {
        if (exitCode != 0 || stdout.Truncated || stderr.Truncated ||
            stderr.TotalCharacters != 0 ||
            stdout.Text != $"{PowerShellVersion}|{ExchangeOnlineManagementVersion}")
            throw new InvalidOperationException(
                $"Purview executor PowerShell probe failed: exit={exitCode}; " +
                $"stdoutCharacters={stdout.TotalCharacters}; stderrCharacters={stderr.TotalCharacters}; " +
                $"stdoutTruncated={stdout.Truncated}; stderrTruncated={stderr.Truncated}; " +
                $"versionMatch={stdout.Text == $"{PowerShellVersion}|{ExchangeOnlineManagementVersion}"}.");
    }

    internal static async Task<string?> VerifyFilesAsync(string root, string? manifestDigest,
        string sourceFingerprint, CancellationToken cancellationToken)
    {
        var manifest = await PurviewRuntimeManifest.VerifyAsync(root, manifestDigest, sourceFingerprint, cancellationToken);
        return manifest.Files.SingleOrDefault(item =>
            item.Path == ExecutorStartupDiagnostics.HookFileName)?.Sha256;
    }

    private static InvalidOperationException Invalid() =>
        new("Purview executor runtime attestation failed.");
}
