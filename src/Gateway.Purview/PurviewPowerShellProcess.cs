using System.Diagnostics;

namespace Gateway.Purview;

public static class PurviewPowerShellProcess
{
    public const string PowerShellVersion = PurviewChildInvocation.PowerShellVersion;
    public const string ExchangeOnlineManagementVersion = PurviewChildInvocation.ModuleVersion;
    public const string HostFileName = PurviewChildInvocation.HostFileName;
    public const string ProbeCommand = PurviewChildInvocation.ProbeCommand;

    // The digest is the executor's configured, already-attested manifest binding, never a request field.
    public static void ApplyVerifiedPackageIsolation(ProcessStartInfo start, string packageRoot, string? manifestDigest)
    {
        if (!Path.IsPathFullyQualified(packageRoot) || !Path.IsPathFullyQualified(start.FileName) ||
            !PurviewChildInvocation.IsDigest(manifestDigest) || start.UseShellExecute ||
            !start.RedirectStandardOutput || !start.RedirectStandardError || !string.IsNullOrEmpty(start.Arguments))
            throw PurviewChildInvocation.Invalid();
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(packageRoot));
        var powerShell = Path.Combine(root, "PowerShell", "pwsh.exe");
        if (!Path.GetFullPath(start.FileName).Equals(powerShell, StringComparison.OrdinalIgnoreCase))
            throw PurviewChildInvocation.Invalid();
        PurviewChildInvocation.RequireRegularFile(powerShell, root);
        var host = Path.Combine(root, HostFileName);
        PurviewChildInvocation.RequireRegularFile(host, root);
        var arguments = start.ArgumentList.ToArray();
        if (arguments.Length < 5 || !arguments.Take(3).SequenceEqual(["-NoLogo", "-NoProfile", "-NonInteractive"]))
            throw PurviewChildInvocation.Invalid();
        string[] invocation;
        if (arguments.Length == 5 && arguments[3] == "-Command" && arguments[4] == ProbeCommand && !start.RedirectStandardInput)
            invocation = ["--probe"];
        else if (arguments[3] == "-File" && start.RedirectStandardInput)
        {
            var script = Path.GetFullPath(arguments[4]);
            var name = Path.GetFileName(script);
            if (!script.Equals(Path.Combine(root, "Automation", name), StringComparison.OrdinalIgnoreCase))
                throw PurviewChildInvocation.Invalid();
            invocation = ["--script", name, .. arguments.Skip(5)];
        }
        else throw PurviewChildInvocation.Invalid();
        _ = PurviewChildInvocation.CreateCommand(root, invocation);
        start.FileName = host;
        start.WorkingDirectory = root;
        start.Environment["PSModulePath"] = PurviewChildInvocation.ModulePath(root);
        foreach (var key in new[] { "DOTNET_STARTUP_HOOKS", "DOTNET_ADDITIONAL_DEPS", "DOTNET_SHARED_STORE" })
            start.Environment.Remove(key);
        start.ArgumentList.Clear();
        foreach (var argument in new[] { "--manifest", manifestDigest! }.Concat(invocation))
            start.ArgumentList.Add(argument);
    }
}
