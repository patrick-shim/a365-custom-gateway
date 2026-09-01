using System.Diagnostics;

namespace Gateway.Setup.Services;

internal enum BootstrapCommand
{
    Plan,
    Apply,
    Resume,
    ResumeReview
}

internal sealed record BootstrapCommandSpec(
    BootstrapCommand Command,
    string FileName,
    string WorkingDirectory,
    IReadOnlyList<string> Arguments)
{
    public ProcessStartInfo ToStartInfo()
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = FileName,
            WorkingDirectory = WorkingDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = false,
            CreateNoWindow = false
        };

        foreach (var argument in Arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        startInfo.Environment["NO_COLOR"] = "1";
        startInfo.Environment["AZURE_CORE_NO_COLOR"] = "1";
        return startInfo;
    }
}

internal interface IBootstrapCommandFactory
{
    BootstrapCommandSpec Create(
        BootstrapCommand command,
        string? expectedPlanFingerprint = null,
        string? expectedConfigurationFileFingerprint = null,
        string? expectedResumeAuthorizationFingerprint = null);
}

internal sealed class BootstrapCommandFactory(RepositoryLayout repository) : IBootstrapCommandFactory
{
    public BootstrapCommandSpec Create(
        BootstrapCommand command,
        string? expectedPlanFingerprint = null,
        string? expectedConfigurationFileFingerprint = null,
        string? expectedResumeAuthorizationFingerprint = null)
    {
        if (!Enum.IsDefined(command))
        {
            throw new ArgumentOutOfRangeException(nameof(command), command, "Unsupported bootstrap command.");
        }

        if (command == BootstrapCommand.Plan && expectedPlanFingerprint is not null)
        {
            throw new ArgumentException(
                "The wizard never supplies an expected fingerprint to its read-only Plan command.",
                nameof(expectedPlanFingerprint));
        }

        if (command == BootstrapCommand.Plan &&
            !PlanFingerprintPolicy.IsCanonical(expectedConfigurationFileFingerprint))
        {
            throw new ArgumentException(
                "Plan requires the exact lowercase SHA-256 fingerprint of the published configuration file.",
                nameof(expectedConfigurationFileFingerprint));
        }

        if (command == BootstrapCommand.ResumeReview && expectedPlanFingerprint is not null)
        {
            throw new ArgumentException(
                "The wizard never supplies an expected fingerprint to its read-only Resume review command.",
                nameof(expectedPlanFingerprint));
        }

        if (command == BootstrapCommand.ResumeReview && expectedConfigurationFileFingerprint is not null)
        {
            throw new ArgumentException(
                "The Setup configuration-file fingerprint is accepted only by its prepared Plan command.",
                nameof(expectedConfigurationFileFingerprint));
        }

        if (command is BootstrapCommand.Apply or BootstrapCommand.Resume &&
            !PlanFingerprintPolicy.IsCanonical(expectedPlanFingerprint))
        {
            throw new ArgumentException(
                "Apply and Resume require the exact canonical fingerprint emitted by the reviewed Plan.",
                nameof(expectedPlanFingerprint));
        }

        if (command is BootstrapCommand.Apply or BootstrapCommand.Resume &&
            expectedConfigurationFileFingerprint is not null)
        {
            throw new ArgumentException(
                "The Setup configuration-file fingerprint is accepted only by its prepared Plan command.",
                nameof(expectedConfigurationFileFingerprint));
        }

        if (command == BootstrapCommand.Resume &&
            !PlanFingerprintPolicy.IsCanonical(expectedResumeAuthorizationFingerprint))
        {
            throw new ArgumentException(
                "Resume requires the exact canonical authorization fingerprint emitted by its read-only review.",
                nameof(expectedResumeAuthorizationFingerprint));
        }

        if (command != BootstrapCommand.Resume && expectedResumeAuthorizationFingerprint is not null)
        {
            throw new ArgumentException(
                "The Resume authorization fingerprint is accepted only by its confirmed Resume command.",
                nameof(expectedResumeAuthorizationFingerprint));
        }

        var scriptPath = Path.GetFullPath(repository.BootstrapScriptPath);
        var configPath = Path.GetFullPath(repository.BootstrapConfigPath);
        EnsureExactRepositoryPath(
            scriptPath,
            Path.Combine(repository.RootPath, "bootstrap", "bootstrap.ps1"),
            "bootstrap script");
        EnsureExactRepositoryPath(
            configPath,
            Path.Combine(repository.RootPath, "bootstrap", "config.json"),
            "bootstrap configuration");

        var arguments = new List<string>
        {
            "-NoLogo",
            "-NoProfile",
            "-File",
            scriptPath,
            "-Mode",
            MapMode(command),
            "-Config",
            configPath,
            "-OutputFormat",
            "Json",
            "-EventStreamOnly"
        };

        if (command == BootstrapCommand.Plan)
        {
            arguments.Add("-ExpectedConfigurationFileFingerprint");
            arguments.Add(expectedConfigurationFileFingerprint!);
            arguments.Add("-NonInteractive");
        }
        else if (command == BootstrapCommand.ResumeReview)
        {
            // The review only reads canonical checkpoints, so it must not inherit the
            // engine's default local-prerequisite installation. Only the colon form binds
            // a [bool] parameter when pwsh is invoked with -File.
            arguments.Add("-InstallPrerequisites:$false");
            arguments.Add("-NonInteractive");
        }
        else
        {
            arguments.Add("-ExpectedPlanFingerprint");
            arguments.Add(expectedPlanFingerprint!);
            if (command == BootstrapCommand.Resume)
            {
                arguments.Add("-ExpectedResumeAuthorizationFingerprint");
                arguments.Add(expectedResumeAuthorizationFingerprint!);
            }

            arguments.Add("-Yes");
        }

        return new BootstrapCommandSpec(
            command,
            "pwsh",
            Path.GetFullPath(repository.RootPath),
            arguments);
    }

    private static string MapMode(BootstrapCommand command) => command switch
    {
        BootstrapCommand.Plan => "Plan",
        BootstrapCommand.Apply => "Up",
        BootstrapCommand.Resume or BootstrapCommand.ResumeReview => "Resume",
        _ => throw new ArgumentOutOfRangeException(nameof(command), command, "Unsupported bootstrap command.")
    };

    private static void EnsureExactRepositoryPath(string actual, string expected, string label)
    {
        if (!string.Equals(Path.GetFullPath(actual), Path.GetFullPath(expected), PathComparison))
        {
            throw new InvalidOperationException($"The {label} resolved outside the repository's canonical path.");
        }
    }

    private static StringComparison PathComparison =>
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
}
