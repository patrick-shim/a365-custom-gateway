using System.Text;

namespace Gateway.Purview;

internal static class PurviewChildInvocation
{
    internal const string HostName = "Gateway.Purview.PowerShellHost";
    internal const string HostFileName = HostName + ".exe";
    internal const string PowerShellVersion = "7.6.5";
    internal const string ModuleVersion = "3.10.1";
    internal const string ProbeCommand =
        "$ErrorActionPreference='Stop'; $m=@(Get-Module -ListAvailable ExchangeOnlineManagement); if($m.Count -ne 1){exit 2}; Import-Module -FullyQualifiedName @{ModuleName='ExchangeOnlineManagement';RequiredVersion='3.10.1'} -ErrorAction Stop; $c=Get-Command Connect-IPPSSession -Module ExchangeOnlineManagement -ErrorAction Stop; if($null -eq $c){exit 3}; [Console]::Write(($PSVersionTable.PSVersion.ToString()+'|'+$m[0].Version.ToString()))";

    private static readonly HashSet<string> ScriptNames = new(StringComparer.Ordinal)
    {
        "Verify-PurviewTenantConnection.ps1", "Invoke-PurviewSettingsOperation.ps1", "Ensure-PurviewPolicyProfile.ps1"
    };
    private static readonly HashSet<string> ParameterNames = new(StringComparer.Ordinal)
    {
        "InputPath", "CertificatePath", "AutomationApplicationId", "Organization",
        "AutomationServicePrincipalObjectId", "Operation"
    };

    internal static bool IsDigest(string? value) => value is { Length: 71 } &&
        value.StartsWith("sha256:", StringComparison.Ordinal) && value[7..].All(char.IsAsciiHexDigitLower);

    internal static string ModulePath(string root) => string.Join(Path.PathSeparator,
        Path.Combine(root, "PowerShellModules"), Path.Combine(root, "PowerShell", "Modules"));

    internal static string CreateCommand(string root, IReadOnlyList<string> invocation)
    {
        if (!Path.IsPathFullyQualified(root) || invocation.Count is < 1 or > 16 ||
            invocation.Any(value => value.Length > 16384))
            throw Invalid();
        root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        var moduleRoot = Path.Combine(root, "PowerShellModules", "ExchangeOnlineManagement", ModuleVersion);
        var manifest = Path.Combine(moduleRoot, "ExchangeOnlineManagement.psd1");
        RequireRegularFile(manifest, root);
        string command;
        if (invocation.Count == 1 && invocation[0] is "--probe" or "--diagnostic-probe")
        {
            command = ProbeCommand;
        }
        else if (invocation.Count >= 2 && invocation[0] == "--script" && ScriptNames.Contains(invocation[1]))
        {
            var script = Path.Combine(root, "Automation", invocation[1]);
            RequireRegularFile(script, root);
            var parameters = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            for (var i = 2; i < invocation.Count; i++)
            {
                var parameter = invocation[i];
                if (!parameter.StartsWith('-') || !seen.Add(parameter))
                    throw Invalid();
                var key = parameter[1..];
                if (key == "VerifyOnly" && invocation[1] == "Ensure-PurviewPolicyProfile.ps1")
                    parameters.Add($"'{key}'=$true");
                else if (ParameterNames.Contains(key) && ++i < invocation.Count)
                    parameters.Add($"'{key}'={Data(invocation[i])}");
                else
                    throw Invalid();
            }
            command = $"$__gatewayArguments=@{{{string.Join(";", parameters)}}}; " +
                $"& {Data(script)} @__gatewayArguments; if (-not $?) {{ exit 1 }}";
        }
        else throw Invalid();

        return "$ErrorActionPreference='Stop'; " +
            $"$env:PSModulePath={Data(ModulePath(root))}; " +
            "$__gatewayModules=@(Get-Module -ListAvailable ExchangeOnlineManagement); " +
            "if ($__gatewayModules.Count -ne 1 -or " +
            $"$__gatewayModules[0].Version.ToString() -cne '{ModuleVersion}' -or " +
            $"-not [IO.Path]::GetFullPath($__gatewayModules[0].ModuleBase).Equals({Data(moduleRoot)}, " +
            "[StringComparison]::OrdinalIgnoreCase)) { throw 'PURVIEW_EXECUTOR_PACKAGED_MODULE_INVALID' }; " +
            $"Import-Module -FullyQualifiedName @{{ModuleName={Data(manifest)};" +
            $"RequiredVersion='{ModuleVersion}'}} -ErrorAction Stop; " + command;
    }

    internal static void RequireRegularFile(string path, string root)
    {
        if (!File.Exists(path) || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw Invalid();
        for (var directory = Path.GetDirectoryName(path);
             directory is not null && !directory.Equals(root, StringComparison.OrdinalIgnoreCase);
             directory = Path.GetDirectoryName(directory))
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
                throw Invalid();
    }

    private static string Data(string value)
    {
        try
        {
            return $"([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{Convert.ToBase64String(new UTF8Encoding(false, true).GetBytes(value))}')))";
        }
        catch (EncoderFallbackException) { throw Invalid(); }
    }

    internal static InvalidOperationException Invalid() => new("Purview packaged PowerShell launch is invalid.");
}
