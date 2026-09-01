using System.Diagnostics;
using System.Text;

namespace Gateway.Setup.Services;

internal enum PurviewSensitiveInformationTypeInvocationStatus
{
    Completed,
    Unavailable,
    TimedOut,
    OutputRejected
}

internal sealed record PurviewSensitiveInformationTypeInvocationResult(
    PurviewSensitiveInformationTypeInvocationStatus Status,
    int ExitCode,
    string StandardOutput);

internal interface IPurviewSensitiveInformationTypeRunner
{
    bool IsSupported { get; }

    Task<PurviewSensitiveInformationTypeInvocationResult> RunAsync(
        Guid tenantId,
        string userPrincipalName,
        TimeSpan timeout,
        CancellationToken cancellationToken);
}

internal interface IPurviewPowerShellExecutableResolver
{
    string? Resolve();
}

internal sealed class PurviewPowerShellExecutableResolver : IPurviewPowerShellExecutableResolver
{
    public string? Resolve() => "pwsh";
}

internal enum PurviewHostPlatform
{
    Windows,
    Linux,
    MacOS,
    Other
}

internal interface IPurviewSensitiveInformationTypePlatformSupport
{
    bool IsSupported { get; }
}

internal sealed class PurviewSensitiveInformationTypePlatformSupport
    : IPurviewSensitiveInformationTypePlatformSupport
{
    public bool IsSupported => IsSupportedPlatform(CurrentPlatform);

    internal static bool IsSupportedPlatform(PurviewHostPlatform platform) =>
        platform == PurviewHostPlatform.Windows;

    private static PurviewHostPlatform CurrentPlatform =>
        OperatingSystem.IsWindows()
            ? PurviewHostPlatform.Windows
            : OperatingSystem.IsLinux()
                ? PurviewHostPlatform.Linux
                : OperatingSystem.IsMacOS()
                    ? PurviewHostPlatform.MacOS
                    : PurviewHostPlatform.Other;
}

internal sealed class PurviewSensitiveInformationTypeRunner : IPurviewSensitiveInformationTypeRunner
{
    private const int MaximumOutputCharacters = 2 * 1024 * 1024;
    private readonly RepositoryLayout repository;
    private readonly IPurviewPowerShellExecutableResolver executableResolver;
    private readonly IPurviewSensitiveInformationTypePlatformSupport platformSupport;

    public PurviewSensitiveInformationTypeRunner(
        RepositoryLayout repository,
        IPurviewPowerShellExecutableResolver executableResolver,
        IPurviewSensitiveInformationTypePlatformSupport platformSupport)
    {
        this.repository = repository ?? throw new ArgumentNullException(nameof(repository));
        this.executableResolver = executableResolver ??
            throw new ArgumentNullException(nameof(executableResolver));
        this.platformSupport = platformSupport ??
            throw new ArgumentNullException(nameof(platformSupport));
    }

    public bool IsSupported => platformSupport.IsSupported;

    public async Task<PurviewSensitiveInformationTypeInvocationResult> RunAsync(
        Guid tenantId,
        string userPrincipalName,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!IsSupported)
        {
            return Unavailable();
        }

        if (tenantId == Guid.Empty ||
            !IsExactUserPrincipalName(userPrincipalName) ||
            timeout <= TimeSpan.Zero)
        {
            return Rejected();
        }

        var executable = executableResolver.Resolve();
        if (string.IsNullOrWhiteSpace(executable))
        {
            return Unavailable();
        }

        var scriptPath = Path.GetFullPath(repository.PurviewSensitiveInformationTypeScriptPath);
        var expectedScriptPath = Path.GetFullPath(Path.Combine(
            repository.RootPath,
            "bootstrap",
            "get-purview-sensitive-information-types.ps1"));
        if (!string.Equals(scriptPath, expectedScriptPath, PathComparison) ||
            !File.Exists(scriptPath))
        {
            return Unavailable();
        }

        var startInfo = CreateStartInfo(
            executable,
            Path.GetFullPath(repository.RootPath),
            scriptPath,
            tenantId,
            userPrincipalName);
        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start())
            {
                return Unavailable();
            }
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return Unavailable();
        }

        using var boundedCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        boundedCancellation.CancelAfter(timeout);
        var outputTask = ReadBoundedAsync(
            process.StandardOutput,
            capture: true,
            boundedCancellation.Token);
        var errorTask = ReadBoundedAsync(
            process.StandardError,
            capture: false,
            boundedCancellation.Token);

        try
        {
            await process.WaitForExitAsync(boundedCancellation.Token);
            var output = await outputTask;
            var error = await errorTask;
            if (output.Rejected || error.Rejected)
            {
                return Rejected();
            }

            return new PurviewSensitiveInformationTypeInvocationResult(
                PurviewSensitiveInformationTypeInvocationStatus.Completed,
                process.ExitCode,
                output.Value);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            TryKill(process);
            await ObserveReadTasksAsync(outputTask, errorTask);
            return new PurviewSensitiveInformationTypeInvocationResult(
                PurviewSensitiveInformationTypeInvocationStatus.TimedOut,
                -1,
                string.Empty);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            await ObserveReadTasksAsync(outputTask, errorTask);
            cancellationToken.ThrowIfCancellationRequested();
            throw;
        }
        catch (Exception exception) when (
            exception is IOException or InvalidOperationException or ObjectDisposedException)
        {
            TryKill(process);
            await ObserveReadTasksAsync(outputTask, errorTask);
            return Rejected();
        }
    }

    internal static ProcessStartInfo CreateStartInfo(
        string executable,
        string workingDirectory,
        string scriptPath,
        Guid tenantId,
        string userPrincipalName)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = false,
            CreateNoWindow = false,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        foreach (var argument in new[]
        {
            "-NoLogo",
            "-NoProfile",
            "-File",
            scriptPath,
            "-TenantId",
            tenantId.ToString("D"),
            "-UserPrincipalName",
            userPrincipalName
        })
        {
            startInfo.ArgumentList.Add(argument);
        }

        startInfo.Environment["NO_COLOR"] = "1";
        return startInfo;
    }

    private static async Task<BoundedReadResult> ReadBoundedAsync(
        StreamReader reader,
        bool capture,
        CancellationToken cancellationToken)
    {
        var buffer = new char[8 * 1024];
        var builder = capture ? new StringBuilder() : null;
        var charactersRead = 0;
        var rejected = false;
        while (true)
        {
            var count = await reader.ReadAsync(buffer.AsMemory(), cancellationToken);
            if (count == 0)
            {
                return new BoundedReadResult(
                    rejected,
                    rejected ? string.Empty : builder?.ToString() ?? string.Empty);
            }

            charactersRead += count;
            if (charactersRead > MaximumOutputCharacters)
            {
                rejected = true;
                builder?.Clear();
                continue;
            }

            if (capture && !rejected)
            {
                builder!.Append(buffer, 0, count);
            }
        }
    }

    private static async Task ObserveReadTasksAsync(params Task[] tasks)
    {
        try
        {
            await Task.WhenAll(tasks);
        }
        catch (Exception exception) when (
            exception is OperationCanceledException or IOException or ObjectDisposedException)
        {
            // The process was already terminated and no captured content is retained.
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            // Process already exited or cannot be observed further.
        }
    }

    private static bool IsExactUserPrincipalName(string? value) =>
        value is { Length: > 0 and <= 254 } &&
        string.Equals(value, value.Trim(), StringComparison.Ordinal) &&
        !value.Any(char.IsControl);

    private static PurviewSensitiveInformationTypeInvocationResult Unavailable() => new(
        PurviewSensitiveInformationTypeInvocationStatus.Unavailable,
        -1,
        string.Empty);

    private static PurviewSensitiveInformationTypeInvocationResult Rejected() => new(
        PurviewSensitiveInformationTypeInvocationStatus.OutputRejected,
        -1,
        string.Empty);

    private static StringComparison PathComparison =>
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    private sealed record BoundedReadResult(bool Rejected, string Value);
}
