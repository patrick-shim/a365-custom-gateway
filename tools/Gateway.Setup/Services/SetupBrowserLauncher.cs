using System.Diagnostics;

namespace Gateway.Setup.Services;

internal interface ISetupBrowserLauncher
{
    bool TryOpen(Uri address);
}

internal sealed class SetupBrowserLauncher : ISetupBrowserLauncher
{
    private readonly Action<ProcessStartInfo> startProcess;

    public SetupBrowserLauncher() : this(startInfo =>
    {
        using var process = Process.Start(startInfo);
    })
    {
    }

    internal SetupBrowserLauncher(Action<ProcessStartInfo> startProcess)
    {
        this.startProcess = startProcess ?? throw new ArgumentNullException(nameof(startProcess));
    }

    internal static bool OpenIfRequested(
        SetupHostArguments arguments,
        ISetupBrowserLauncher launcher,
        Uri address) =>
        arguments.OpenBrowser && !arguments.ShowHelp && launcher.TryOpen(address);

    public bool TryOpen(Uri address)
    {
        ArgumentNullException.ThrowIfNull(address);
        if (!address.IsAbsoluteUri || !address.IsLoopback || address.Scheme != Uri.UriSchemeHttp)
        {
            return false;
        }

        try
        {
            startProcess(new ProcessStartInfo
            {
                FileName = address.AbsoluteUri,
                UseShellExecute = true
            });
            return true;
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }
}
