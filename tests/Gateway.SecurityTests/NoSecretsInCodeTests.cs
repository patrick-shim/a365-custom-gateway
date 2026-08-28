using System.Diagnostics;
using System.Text.RegularExpressions;
using FluentAssertions;

namespace Gateway.SecurityTests;

/// <summary>
/// Scans the source code for patterns that indicate potential secret leakage:
/// hardcoded connection strings, passwords, API keys, sensitive data in log
/// statements, and real secrets in appsettings files.
/// </summary>
public class NoSecretsInCodeTests
{
    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    private static string GetSrcDirectory()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "src")))
            dir = dir.Parent;
        return Path.Combine(dir!.FullName, "src");
    }

    private static IEnumerable<string> GetCSharpSourceFiles()
    {
        var srcDir = GetSrcDirectory();
        return Directory.GetFiles(srcDir, "*.cs", SearchOption.AllDirectories)
            .Where(f => !f.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
                     && !f.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}"));
    }

    private static IEnumerable<string> GetAppSettingsFiles()
    {
        var srcDir = GetSrcDirectory();
        return Directory.GetFiles(srcDir, "appsettings*.json", SearchOption.AllDirectories)
            .Where(f => !f.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
                     && !f.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}"))
            // Local private overrides are deliberately ignored by Git and may contain
            // developer-only values. The source-leakage gate must scan every tracked or
            // otherwise committable appsettings file without treating an ignored local
            // workstation override as repository content.
            .Where(f => !IsGitIgnored(f));
    }

    private static bool IsGitIgnored(string file)
    {
        var repositoryRoot = Directory.GetParent(GetSrcDirectory())!.FullName;
        var startInfo = new ProcessStartInfo
        {
            FileName = "git",
            WorkingDirectory = repositoryRoot,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        startInfo.ArgumentList.Add("check-ignore");
        startInfo.ArgumentList.Add("--quiet");
        startInfo.ArgumentList.Add("--");
        startInfo.ArgumentList.Add(Path.GetRelativePath(repositoryRoot, file));

        try
        {
            using var process = Process.Start(startInfo);
            if (process is null || !process.WaitForExit(5_000))
            {
                process?.Kill(entireProcessTree: true);
                return false;
            }

            return process.ExitCode == 0;
        }
        catch
        {
            // If Git is unavailable, fail safely by scanning the file.
            return false;
        }
    }

    // ---------------------------------------------------------------
    // No hardcoded connection strings
    // ---------------------------------------------------------------

    [Fact]
    public void SourceCode_Should_NotContainHardcodedConnectionStrings()
    {
        var patterns = new[]
        {
            @"""Server=\w",
            @"""Data Source=\w",
            @"""mongodb://\w",
            @"""AccountKey=\w",
            @"""Server=tcp:\w"
        };

        var violations = new List<string>();

        foreach (var file in GetCSharpSourceFiles())
        {
            var content = File.ReadAllText(file);
            foreach (var pattern in patterns)
            {
                if (Regex.IsMatch(content, pattern, RegexOptions.IgnoreCase))
                {
                    var relativePath = Path.GetRelativePath(GetSrcDirectory(), file);
                    violations.Add($"{relativePath}: matches pattern '{pattern}'");
                }
            }
        }

        violations.Should().BeEmpty(
            "no source files should contain hardcoded connection strings. Found: {0}",
            string.Join("; ", violations));
    }

    // ---------------------------------------------------------------
    // No hardcoded passwords
    // ---------------------------------------------------------------

    [Fact]
    public void SourceCode_Should_NotContainHardcodedPasswords()
    {
        var patterns = new[]
        {
            @"[Pp]assword\s*=\s*""[^""]{3,}""",
            @"[Pp]assword\s*:\s*""[^""]{3,}"""
        };

        var violations = new List<string>();

        foreach (var file in GetCSharpSourceFiles())
        {
            var fileName = Path.GetFileName(file);

            // Skip validators that reference "password" as a field name for validation rules
            if (fileName.Contains("Validator", StringComparison.OrdinalIgnoreCase))
                continue;

            var content = File.ReadAllText(file);

            // Skip files that define error codes or validation messages about passwords
            if (content.Contains("const string") && content.Contains("password", StringComparison.OrdinalIgnoreCase)
                && (content.Contains("ErrorCodes") || content.Contains("ValidationMessage")))
                continue;

            foreach (var pattern in patterns)
            {
                var matches = Regex.Matches(content, pattern);
                foreach (Match match in matches)
                {
                    // Exclude known non-secret patterns
                    if (match.Value.Contains("Password=\"\"") ||
                        match.Value.Contains("Password=''") ||
                        match.Value.Contains("password_hash") ||
                        match.Value.Contains("PasswordValidator") ||
                        match.Value.Contains("password_field"))
                        continue;

                    var relativePath = Path.GetRelativePath(GetSrcDirectory(), file);
                    violations.Add($"{relativePath}: {match.Value.Trim()}");
                }
            }
        }

        violations.Should().BeEmpty(
            "no source files should contain hardcoded passwords. Found: {0}",
            string.Join("; ", violations));
    }

    // ---------------------------------------------------------------
    // No hardcoded API keys
    // ---------------------------------------------------------------

    [Fact]
    public void SourceCode_Should_NotContainHardcodedApiKeys()
    {
        var patterns = new[]
        {
            @"""Bearer\s+[A-Za-z0-9+/=]{20,}""",
            @"ApiKey\s*=\s*""[A-Za-z0-9+/=]{10,}""",
            @"api[_-]?key\s*=\s*""[A-Za-z0-9]{10,}"""
        };

        var violations = new List<string>();

        foreach (var file in GetCSharpSourceFiles())
        {
            var content = File.ReadAllText(file);
            foreach (var pattern in patterns)
            {
                if (Regex.IsMatch(content, pattern, RegexOptions.IgnoreCase))
                {
                    var relativePath = Path.GetRelativePath(GetSrcDirectory(), file);
                    violations.Add($"{relativePath}: matches pattern '{pattern}'");
                }
            }
        }

        violations.Should().BeEmpty(
            "no source files should contain hardcoded API keys. Found: {0}",
            string.Join("; ", violations));
    }

    // ---------------------------------------------------------------
    // No logging of sensitive data
    // ---------------------------------------------------------------

    [Fact]
    public void LoggingStatements_Should_NotReferenceSensitiveDataInTemplates()
    {
        var sensitiveTerms = new[] { "token", "secret", "password", "credential", "clientsecret" };
        var logMethods = new[] { "LogInformation", "LogWarning", "LogError", "LogDebug", "LogTrace", "LogCritical" };

        var violations = new List<string>();

        foreach (var file in GetCSharpSourceFiles())
        {
            var lines = File.ReadAllLines(file);
            for (int i = 0; i < lines.Length; i++)
            {
                var line = lines[i];
                var trimmed = line.TrimStart();

                // Skip comments
                if (trimmed.StartsWith("//") || trimmed.StartsWith("*") || trimmed.StartsWith("/*"))
                    continue;

                // Check if line contains a logging method call
                bool hasLogCall = logMethods.Any(m =>
                    line.Contains(m, StringComparison.OrdinalIgnoreCase));
                if (!hasLogCall)
                    continue;

                // Check if log message template references sensitive terms
                // Look for interpolation or structured logging patterns: {token}, {secret}, etc.
                bool hasSensitiveTerm = sensitiveTerms.Any(term =>
                    Regex.IsMatch(line, $@"\{{{term}\}}", RegexOptions.IgnoreCase) ||
                    Regex.IsMatch(line, $@"""\s*\+\s*{term}", RegexOptions.IgnoreCase));

                // Exclude lines that explicitly deal with redaction or sensitivity detection
                if (hasSensitiveTerm &&
                    !line.Contains("REDACTED", StringComparison.OrdinalIgnoreCase) &&
                    !line.Contains("redact", StringComparison.OrdinalIgnoreCase) &&
                    !line.Contains("Sensitive", StringComparison.OrdinalIgnoreCase) &&
                    !line.Contains("sanitiz", StringComparison.OrdinalIgnoreCase))
                {
                    var relativePath = Path.GetRelativePath(GetSrcDirectory(), file);
                    violations.Add($"{relativePath}:{i + 1}: {trimmed.Trim()}");
                }
            }
        }

        violations.Should().BeEmpty(
            "logger calls should not reference sensitive data in message templates. " +
            "Use redaction or structured logging without sensitive values. Found: {0}",
            string.Join("; ", violations));
    }

    // ---------------------------------------------------------------
    // appsettings.json has no real secrets
    // ---------------------------------------------------------------

    [Fact]
    public void AppSettings_Should_NotContainRealSecrets()
    {
        var violations = new List<string>();

        foreach (var file in GetAppSettingsFiles())
        {
            var content = File.ReadAllText(file);
            var fileName = Path.GetFileName(file);

            // Check that GatewayDb connection string is empty or placeholder
            var dbMatch = Regex.Match(content, @"""GatewayDb""\s*:\s*""([^""]*)""");
            if (dbMatch.Success && !string.IsNullOrWhiteSpace(dbMatch.Groups[1].Value))
            {
                violations.Add($"{fileName}: GatewayDb connection string is not empty");
            }

            // Check that ServiceBus connection string is empty
            var sbMatch = Regex.Match(content, @"""ConnectionString""\s*:\s*""([^""]+)""");
            if (sbMatch.Success && !string.IsNullOrWhiteSpace(sbMatch.Groups[1].Value))
            {
                // Only flag if it looks like a real connection string
                var val = sbMatch.Groups[1].Value;
                if (val.Contains("Endpoint=") || val.Contains("SharedAccessKey="))
                    violations.Add($"{fileName}: ServiceBus connection string contains real value");
            }

            // Check that TenantId and ClientId are empty (not real GUIDs)
            foreach (var key in new[] { "TenantId", "ClientId" })
            {
                var match = Regex.Match(content, $@"""{key}""\s*:\s*""([^""]*)""");
                if (match.Success && !string.IsNullOrWhiteSpace(match.Groups[1].Value))
                {
                    var val = match.Groups[1].Value;
                    // Flag only if it looks like an actual GUID
                    if (Regex.IsMatch(val,
                        @"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                        RegexOptions.IgnoreCase))
                    {
                        violations.Add($"{fileName}: {key} contains a real GUID value");
                    }
                }
            }

            // Check for ApplicationInsights connection string with real values
            var aiMatch = Regex.Match(content,
                @"""ApplicationInsightsConnectionString""\s*:\s*""([^""]*)""");
            if (aiMatch.Success && !string.IsNullOrWhiteSpace(aiMatch.Groups[1].Value))
            {
                var val = aiMatch.Groups[1].Value;
                if (val.Contains("InstrumentationKey="))
                    violations.Add($"{fileName}: ApplicationInsights connection string contains real value");
            }
        }

        violations.Should().BeEmpty(
            "appsettings files should not contain real secrets or connection details. " +
            "Use empty strings, placeholders, or environment-specific config. Found: {0}",
            string.Join("; ", violations));
    }

    // ---------------------------------------------------------------
    // Source directory is resolvable
    // ---------------------------------------------------------------

    [Fact]
    public void SrcDirectory_Should_Exist()
    {
        var srcDir = GetSrcDirectory();
        Directory.Exists(srcDir).Should().BeTrue(
            $"the src/ directory must be resolvable from test output. Resolved: {srcDir}");
    }

    [Fact]
    public void SrcDirectory_Should_ContainCSharpFiles()
    {
        var files = GetCSharpSourceFiles().ToList();
        files.Should().NotBeEmpty(
            "there should be .cs source files to scan in the src/ directory");
    }
}
