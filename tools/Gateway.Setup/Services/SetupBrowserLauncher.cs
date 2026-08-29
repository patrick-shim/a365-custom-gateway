using System.Diagnostics;

namespace Gateway.Setup.Services;

internal interface ISetupBrowserLauncher
{
    bool TryOpen(Uri address);
}

internal sealed class SetupBrowserLauncher : ISetupBrowserLauncher
{
    public bool TryOpen(Uri address)
    {
        if (!address.IsLoopback || address.Scheme != Uri.UriSchemeHttp)
        {
            return false;
        }

        try
        {
            Process.Start(new ProcessStartInfo
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
