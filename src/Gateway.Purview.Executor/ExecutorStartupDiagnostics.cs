using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using Capture = Gateway.Purview.PowerShellPurviewPolicyProvisioningClient.BoundedTextCapture;

namespace Gateway.Purview.Executor;

internal enum StartupDiagnosticStatus { Captured, Unavailable, TimedOut, Failed, TerminationUnproven }
internal sealed record StartupDiagnosticResult(StartupDiagnosticStatus Status,
    Capture? Output = null, Capture? Error = null);

internal static class ExecutorStartupDiagnostics
{
    internal const string HookFileName = "Gateway.Purview.Executor.StartupDiagnostics.dll";
    internal const int CaptureLimit = 1024;
    internal static readonly TimeSpan Timeout = TimeSpan.FromSeconds(20);

    internal static bool ShouldRun(int exitCode, Capture output, Capture error) =>
        exitCode == 0 && output is { Text.Length: 0, TotalCharacters: 0, Truncated: false } &&
        error is { Text.Length: 0, TotalCharacters: 0, Truncated: false };

    internal static async Task<StartupDiagnosticResult> RunAsync(string root, string? attestedHookHash,
        ProcessStartInfo original, CancellationToken cancellationToken, TimeSpan? timeout = null)
    {
        var duration = timeout ?? Timeout;
        if (duration <= TimeSpan.Zero || duration > Timeout)
            return new(StartupDiagnosticStatus.Unavailable);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(duration);
        var safety = new PurviewProcessSafety();
        try
        {
            var start = await CreateStartInfoAsync(root, attestedHookHash, original, deadline.Token);
            using var process = new Process { StartInfo = start };
            if (!process.Start()) return new(StartupDiagnosticStatus.Failed);
            StartupDiagnosticResult result;
            await using (var lease = new PurviewProcessLease(process, safety))
            {
                var output = PowerShellPurviewPolicyProvisioningClient.ReadBoundedAsync(
                    process.StandardOutput, CaptureLimit, deadline.Token);
                var error = PowerShellPurviewPolicyProvisioningClient.ReadBoundedAsync(
                    process.StandardError, CaptureLimit, deadline.Token);
                var completion = Task.WhenAll(output, error, process.WaitForExitAsync(deadline.Token));
                try
                {
                    await completion.WaitAsync(deadline.Token);
                    result = new(StartupDiagnosticStatus.Captured, await output, await error);
                }
                catch (OperationCanceledException)
                {
                    result = new(StartupDiagnosticStatus.TimedOut);
                }
                catch (Exception)
                {
                    result = new(StartupDiagnosticStatus.Failed);
                }
                finally
                {
                    // Observe failures from a cancelled reader without waiting past the hard deadline.
                    _ = completion.ContinueWith(task => _ = task.Exception,
                        CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted |
                        TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
                }
            }
            return safety.CanMutate ? result : new(StartupDiagnosticStatus.TerminationUnproven);
        }
        catch (OperationCanceledException) { return new(StartupDiagnosticStatus.TimedOut); }
        catch (Exception) { return new(StartupDiagnosticStatus.Unavailable); }
    }

    internal static async Task<ProcessStartInfo> CreateStartInfoAsync(string root, string? attestedHookHash,
        ProcessStartInfo original, CancellationToken cancellationToken)
    {
        if (!Path.IsPathFullyQualified(root) || root.Contains(Path.PathSeparator) ||
            attestedHookHash is not { Length: 64 } || !attestedHookHash.All(char.IsAsciiHexDigitLower))
            throw Invalid();
        root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        var hookPath = Path.Combine(root, HookFileName);
        var executable = Path.Combine(root, PurviewPowerShellProcess.HostFileName);
        var childHost = original.FileName == executable && original.ArgumentList.Count == 3 &&
            original.ArgumentList[0] == "--manifest" && PurviewChildInvocation.IsDigest(original.ArgumentList[1]) &&
            original.ArgumentList[2] == "--probe";
        var legacyProbe = original.FileName == Path.Combine(root, "PowerShell", "pwsh.exe") &&
            original.ArgumentList.Count == 5 &&
            original.ArgumentList.Take(4).SequenceEqual(["-NoLogo", "-NoProfile", "-NonInteractive", "-Command"]);
        if (legacyProbe) executable = original.FileName;
        if (original.FileName != executable || original.WorkingDirectory != root ||
            original.UseShellExecute || !original.CreateNoWindow || original.RedirectStandardInput ||
            !original.RedirectStandardOutput || !original.RedirectStandardError ||
            !string.IsNullOrEmpty(original.Arguments) || !(childHost || legacyProbe) ||
            !File.Exists(hookPath) || (File.GetAttributes(hookPath) & FileAttributes.ReparsePoint) != 0)
            throw Invalid();
        await using (var file = File.OpenRead(hookPath))
            if (Convert.ToHexStringLower(await SHA256.HashDataAsync(file, cancellationToken)) != attestedHookHash)
                throw Invalid();

        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = root
        };
        start.Environment.Clear();
        foreach (var pair in original.Environment) start.Environment[pair.Key] = pair.Value;
        // Never inherit or concatenate caller/ambient hooks into the diagnostic child.
        start.Environment["DOTNET_STARTUP_HOOKS"] = hookPath;
        foreach (var argument in original.ArgumentList) start.ArgumentList.Add(argument);
        if (childHost) start.ArgumentList[2] = "--diagnostic-probe";
        else start.ArgumentList[4] =
                "[Console]::Error.WriteLine('GWDIAG|COMMAND_ENTRY|None|0'); " + original.ArgumentList[4] +
                "; [Console]::Error.WriteLine('GWDIAG|COMMAND_COMPLETE|None|0')";
        return start;
    }

    internal static string Summarize(StartupDiagnosticResult result)
    {
        if (result.Status != StartupDiagnosticStatus.Captured)
            return Marker(result.Status switch
            {
                StartupDiagnosticStatus.TimedOut => "TIMED_OUT",
                StartupDiagnosticStatus.TerminationUnproven => "TERMINATION_UNPROVEN",
                StartupDiagnosticStatus.Failed => "FAILED",
                _ => "UNAVAILABLE"
            });
        if (!ValidCapture(result.Output) || !ValidCapture(result.Error))
            return Marker("CAPTURE_REJECTED");
        var lines = result.Error!.Text.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        if (lines.Length is 0 or > 8) return Marker("CAPTURE_REJECTED");
        var stages = new HashSet<string>(StringComparer.Ordinal);
        var markers = new List<string>();
        foreach (var raw in lines)
        {
            var line = raw.TrimEnd('\r');
            var parts = line.Split('|');
            if (parts.Length != 4 || parts[0] != "GWDIAG" || !stages.Add(parts[1]) ||
                !int.TryParse(parts[3], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var native) ||
                parts[3] != native.ToString(CultureInfo.InvariantCulture))
                return Marker("CAPTURE_REJECTED");
            var valid = parts[1] switch
            {
                "ENTRY" or "CONOUT_OK" or "COMMAND_ENTRY" or "COMMAND_COMPLETE" => parts[2] == "None" && native == 0,
                "CONOUT_FAILED" => parts[2] == "Win32Exception" && native > 0,
                "RAW_UI" or "BREAK_HANDLER" or "HOST_START" or "HOST_OTHER" => parts[2] == "HostException" && native >= 0,
                _ => false
            };
            if (!valid) return Marker("CAPTURE_REJECTED");
            markers.Add(line);
        }
        return string.Join(";", markers);
    }

    private static bool ValidCapture(Capture? capture) => capture is not null && !capture.Truncated &&
        capture.TotalCharacters == capture.Text.Length && capture.TotalCharacters <= CaptureLimit;
    private static string Marker(string stage) => $"GWDIAG|{stage}|None|0";
    private static InvalidOperationException Invalid() => new("Purview startup diagnostic binding is invalid.");
}
