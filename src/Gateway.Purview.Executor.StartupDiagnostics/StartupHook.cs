using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

// The CLR requires this exact global type name for a startup hook.
public static class StartupHook
{
    private static Stream? error;
    private static int emittedStages;
    private static int writing;

    public static void Initialize()
    {
        if (!OperatingSystem.IsWindows()) return;
        error = Console.OpenStandardError();
        Emit("ENTRY", "None", 0);
        using (var console = CreateFileW("CONOUT$", 0xC0000000, 2, IntPtr.Zero, 3, 0, IntPtr.Zero))
        {
            int nativeError = console.IsInvalid ? Marshal.GetLastWin32Error() : 0;
            Emit(console.IsInvalid ? "CONOUT_FAILED" : "CONOUT_OK",
                console.IsInvalid ? "Win32Exception" : "None", nativeError);
        }
        AppDomain.CurrentDomain.FirstChanceException += (_, args) =>
        {
            if (args.Exception.GetType().FullName != "System.Management.Automation.Host.HostException")
                return;
            string stage = "HOST_OTHER";
            int bit = 1;
            foreach (var frame in new StackTrace(false).GetFrames())
            {
                var method = frame.GetMethod();
                string? type = method?.DeclaringType?.FullName;
                if (type == "Microsoft.PowerShell.ConsoleHostRawUserInterface" && method!.Name == ".ctor")
                {
                    stage = "RAW_UI";
                    bit = 2;
                    break;
                }
                if (type == "Microsoft.PowerShell.ConsoleControl" && method!.Name == "AddBreakHandler")
                {
                    stage = "BREAK_HANDLER";
                    bit = 4;
                    break;
                }
                if (type == "Microsoft.PowerShell.ConsoleHost" && method!.Name == "Start")
                {
                    stage = "HOST_START";
                    bit = 8;
                }
            }
            if ((Interlocked.Or(ref emittedStages, bit) & bit) != 0) return;
            Emit(stage, "HostException",
                (args.Exception.InnerException as Win32Exception)?.NativeErrorCode ?? 0);
        };
    }

    private static void Emit(string stage, string type, int nativeError)
    {
        if (Interlocked.Exchange(ref writing, 1) != 0) return;
        try
        {
            byte[] bytes = Encoding.ASCII.GetBytes(
                "GWDIAG|" + stage + "|" + type + "|" +
                nativeError.ToString(CultureInfo.InvariantCulture) + "\n");
            error?.Write(bytes);
            error?.Flush();
        }
        catch { }
        finally { Volatile.Write(ref writing, 0); }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr template);
}
