using System.Diagnostics;

namespace Gateway.Setup.Services;

internal interface IBootstrapProcessRunner
{
    Task<BootstrapProcessResult> RunAsync(
        BootstrapCommandSpec command,
        Func<BootstrapProgressEvent, ValueTask> onProgress,
        CancellationToken cancellationToken);
}

internal sealed class BootstrapProcessRunner : IBootstrapProcessRunner
{
    public async Task<BootstrapProcessResult> RunAsync(
        BootstrapCommandSpec command,
        Func<BootstrapProgressEvent, ValueTask> onProgress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(command);
        ArgumentNullException.ThrowIfNull(onProgress);

        using var process = new Process { StartInfo = command.ToStartInfo(), EnableRaisingEvents = true };
        try
        {
            if (!process.Start())
            {
                await onProgress(new BootstrapProgressEvent(
                    DateTimeOffset.UtcNow,
                    BootstrapProgressKind.Error,
                    "PowerShell could not be started. Run gateway doctor or install PowerShell 7."));
                return new BootstrapProcessResult(-1, false);
            }

        }
        catch (Exception exception) when (
            exception is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            await onProgress(new BootstrapProgressEvent(
                DateTimeOffset.UtcNow,
                BootstrapProgressKind.Error,
                "PowerShell 7 is unavailable. Install pwsh, then return here; no bootstrap command was started."));
            return new BootstrapProcessResult(-1, false);
        }

        var outputBudget = new BootstrapProcessOutputBudget();
        var standardOutput = BoundedProcessOutputReader.ConsumeAsync(
            process.StandardOutput,
            false,
            outputBudget,
            onProgress,
            cancellationToken);
        var standardError = BoundedProcessOutputReader.ConsumeAsync(
            process.StandardError,
            true,
            outputBudget,
            onProgress,
            cancellationToken);

        try
        {
            await process.WaitForExitAsync(cancellationToken);
            await Task.WhenAll(standardOutput, standardError);
            return new BootstrapProcessResult(process.ExitCode, false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                    await process.WaitForExitAsync(CancellationToken.None);
                }
            }
            catch (InvalidOperationException)
            {
                // The process exited between the check and cancellation handling.
            }

            return new BootstrapProcessResult(-1, true);
        }
    }
}
