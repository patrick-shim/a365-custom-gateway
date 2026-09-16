using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;
using System.Security;

namespace Gateway.Purview.PowerShellHost;

internal static class RunspaceEngine
{
    internal static int Execute(string enginePath, string command, bool diagnostic)
    {
        if (!typeof(PowerShell).Assembly.Location.Equals(enginePath, StringComparison.OrdinalIgnoreCase))
            return Program.Fail(70);
        var host = new NonInteractiveHost();
        using var runspace = RunspaceFactory.CreateRunspace(host, InitialSessionState.CreateDefault2());
        runspace.Open();
        using var shell = PowerShell.Create();
        shell.Runspace = runspace;
        if (diagnostic) Console.Error.WriteLine("GWDIAG|COMMAND_ENTRY|None|0");
        shell.AddScript(command, useLocalScope: false);
        shell.Invoke<PSObject>(input: null, output: new RejectingPipelineOutput());
        if (shell.HadErrors) return Program.Fail(71);
        if (shell.InvocationStateInfo.State != PSInvocationState.Completed) return Program.Fail(72);
        if (host.UiOutputKind != 0) return Program.Fail(80 + host.UiOutputKind);
        if (host.ExitCode is { } code) return code;
        if (diagnostic) Console.Error.WriteLine("GWDIAG|COMMAND_COMPLETE|None|0");
        return 0;
    }
}

internal sealed class RejectingPipelineOutput : Collection<PSObject>
{
    // The three scripts write their bounded protocol directly to Console.Out.
    protected override void InsertItem(int index, PSObject item) =>
        throw new InvalidOperationException("PURVIEW_CHILD_UNEXPECTED_PIPELINE_OUTPUT");
}

internal sealed class NonInteractiveHost : PSHost
{
    private readonly NonInteractiveUi ui = new();
    public int? ExitCode { get; private set; }
    public int UiOutputKind => ui.OutputKind;
    public override Guid InstanceId { get; } = Guid.NewGuid();
    public override string Name => "Gateway.Purview.PowerShellHost";
    public override Version Version => new(1, 0);
    public override PSHostUserInterface UI => ui;
    public override CultureInfo CurrentCulture => CultureInfo.CurrentCulture;
    public override CultureInfo CurrentUICulture => CultureInfo.CurrentUICulture;
    public override void SetShouldExit(int exitCode) => ExitCode = exitCode;
    public override void EnterNestedPrompt() => throw NonInteractiveUi.Blocked();
    public override void ExitNestedPrompt() => throw NonInteractiveUi.Blocked();
    public override void NotifyBeginApplication() { }
    public override void NotifyEndApplication() { }
}

internal sealed class NonInteractiveUi : PSHostUserInterface
{
    public int OutputKind { get; private set; }
    // SMA explicitly accepts null RawUI and supplies its noninteractive wrapper.
    public override PSHostRawUserInterface RawUI => null!;
    public override string ReadLine() => throw Blocked();
    public override SecureString ReadLineAsSecureString() => throw Blocked();
    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) => throw Blocked();
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice) => throw Blocked();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) => throw Blocked();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName,
        PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options) => throw Blocked();
    public override void Write(string value) { if (!string.IsNullOrEmpty(value)) OutputKind = 1; }
    public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value) { if (!string.IsNullOrEmpty(value)) OutputKind = 2; }
    public override void WriteLine(string value) => OutputKind = 3;
    public override void WriteErrorLine(string value) => OutputKind = 4;
    public override void WriteDebugLine(string message) => OutputKind = 5;
    public override void WriteVerboseLine(string message) => OutputKind = 6;
    public override void WriteWarningLine(string message) => OutputKind = 7;
    // Progress has no textual transport in a noninteractive host.
    public override void WriteProgress(long sourceId, ProgressRecord record) { }
    internal static NotSupportedException Blocked() => new("PURVIEW_CHILD_INTERACTIVE_UI_UNAVAILABLE");
}
