using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.Loader;
using Gateway.Purview;

namespace Gateway.Purview.PowerShellHost;

internal static class Program
{
    public static int Main(string[] args)
    {
        var failure = 65;
        try
        {
            if (!OperatingSystem.IsWindows() || !Environment.Is64BitProcess ||
                args.Length < 3 || args[0] != "--manifest" || !PurviewChildInvocation.IsDigest(args[1]))
                return Fail(64);
            var root = Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
            PurviewRuntimeManifest.VerifyAsync(root, args[1], null, default).GetAwaiter().GetResult();
            failure = 66;
            var invocation = args[2..];
            var command = PurviewChildInvocation.CreateCommand(root, invocation);
            var engineRoot = Path.Combine(root, "PowerShell");
            failure = 67;
            Environment.SetEnvironmentVariable("PSModulePath", PurviewChildInvocation.ModulePath(root));
            AssemblyLoadContext.Default.Resolving += (_, name) =>
            {
                if (name.Name is null || Path.GetFileName(name.Name) != name.Name) return null;
                var path = Path.Combine(engineRoot, name.Name + ".dll");
                return File.Exists(path) ? AssemblyLoadContext.Default.LoadFromAssemblyPath(path) : null;
            };
            var engine = Path.Combine(engineRoot, "System.Management.Automation.dll");
            AssemblyLoadContext.Default.LoadFromAssemblyPath(engine);
            failure = 68;
            return InvokeEngine(engine, command, invocation[0] == "--diagnostic-probe");
        }
        catch (Exception) { return Fail(failure); }
    }

    // Load the attested engine before the JIT resolves any SMA types.
    [MethodImpl(MethodImplOptions.NoInlining)]
    private static int InvokeEngine(string enginePath, string command, bool diagnostic) =>
        RunspaceEngine.Execute(enginePath, command, diagnostic);

    internal static int Fail(int code)
    {
        Console.Error.WriteLine("PURVIEW_CHILD_FAILED");
        return code;
    }
}
