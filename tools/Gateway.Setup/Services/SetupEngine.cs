using System.Diagnostics;
using System.Text.Json;
using Gateway.Setup.Security;

namespace Gateway.Setup.Services;

internal sealed class SetupEngine(RepositoryLayout repository, SetupActivityTracker activity, IHostApplicationLifetime lifetime)
{
    private readonly object sync = new();
    private readonly List<JsonElement> events = [];
    private bool running;
    private int? exitCode;
    private string action = "";
    private string? reviewedPlan;
    public object Snapshot() { lock(sync) return new { running, exitCode, action, events = events.ToArray(), reviewedPlan }; }

    public bool Start(string command, JsonElement? input, string? fingerprint)
    {
        if (command is not ("Inspect" or "Save" or "SignIn" or "Doctor" or "Plan" or "Apply" or "Verify"))
            throw new ArgumentException("Unsupported setup action.");
        lock(sync)
        {
            if (running) return false;
            if (command == "Apply" && (reviewedPlan is null || fingerprint != reviewedPlan))
                throw new ArgumentException("Review the current plan before starting installation.");
            if (command is "Save" or "SignIn" or "Plan") reviewedPlan = null;
            running = true; exitCode = null; action = command; events.Clear();
        }
        activity.SetOperationActive(true);
        _ = RunAsync(command, input?.GetRawText() ?? "{}", fingerprint);
        return true;
    }

    private async Task RunAsync(string command, string input, string? fingerprint)
    {
        var code = 1;
        try
        {
            var bridge = command is "Inspect" or "Save" or "SignIn";
            var start = new ProcessStartInfo("pwsh") {
                WorkingDirectory=repository.RootPath, UseShellExecute=false, CreateNoWindow=true,
                RedirectStandardInput=true, RedirectStandardOutput=true, RedirectStandardError=true
            };
            foreach(var argument in new[] {"-NoLogo","-NoProfile","-File", bridge ? Path.Combine(repository.RootPath,"bootstrap","setup-bridge.ps1") : repository.BootstrapScriptPath})
                start.ArgumentList.Add(argument);
            if (bridge) { start.ArgumentList.Add("-Action"); start.ArgumentList.Add(command); }
            else
            {
                foreach(var argument in new[] {"-Mode", command == "Apply" ? "Up" : command, "-OutputFormat","Json","-InstallPrerequisites:$false"}) start.ArgumentList.Add(argument);
                if(command != "Apply") start.ArgumentList.Add("-NonInteractive");
                if(command is "Apply" or "Plan") start.ArgumentList.Add("-EventStreamOnly");
                if(command == "Apply") {
                    start.ArgumentList.Add("-Yes"); start.ArgumentList.Add("-ExpectedPlanFingerprint"); start.ArgumentList.Add(fingerprint!);
                }
            }
            using var process = new Process { StartInfo=start };
            if(!process.Start()) throw new InvalidOperationException();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.ApplicationStopping);
            timeout.CancelAfter(TimeSpan.FromMinutes(45));
            using var registration = timeout.Token.Register(() => { try { process.Kill(entireProcessTree:true); } catch (InvalidOperationException) { } });
            await process.StandardInput.WriteAsync(input);
            process.StandardInput.Close();
            var stderr = DrainAsync(process.StandardError, false, timeout.Token);
            await DrainAsync(process.StandardOutput, true, timeout.Token);
            await stderr;
            await process.WaitForExitAsync(timeout.Token);
            code = process.ExitCode;
        }
        catch(Exception exception) when (exception is not OutOfMemoryException)
        {
            Add(JsonSerializer.SerializeToElement(new {type="Warning",message="The setup process stopped. Check gateway doctor before retrying. Saved resource checkpoints are retained."}));
        }
        finally
        {
            lock(sync) {
                if (command == "Plan" && code != 0) reviewedPlan=null;
                exitCode=code; running=false;
            }
            activity.SetOperationActive(false);
        }
    }

    private async Task DrainAsync(StreamReader reader, bool publish, CancellationToken token)
    {
        // Bound each line even if a provider unexpectedly emits an enormous body.
        var buffer = new char[4096];
        var line = new System.Text.StringBuilder();
        var overflow = false;
        int count;
        while((count=await reader.ReadAsync(buffer.AsMemory(),token)) != 0)
            for(var i=0;i<count;i++) {
                if(buffer[i]=='\n') {
                    if(publish && !overflow) Parse(line.ToString());
                    line.Clear(); overflow=false;
                } else if(line.Length<65536) line.Append(buffer[i]); else overflow=true;
            }
        if(publish && !overflow && line.Length>0) Parse(line.ToString());
    }
    private void Parse(string line)
    {
        try {
            using var document=JsonDocument.Parse(line);
            var root=document.RootElement;
            if(root.ValueKind!=JsonValueKind.Object) return;
            if(root.TryGetProperty("type",out var type) && type.GetString() is "Setup" or "PhaseStarted" or "PhaseCompleted" or "Info" or "Warning" or "Result") {
                Add(root.Clone());
                if(action=="Plan" && root.TryGetProperty("data",out var data) && data.TryGetProperty("planFingerprint",out var plan)) {
                    var value=plan.GetString();
                    if(value is not null && System.Text.RegularExpressions.Regex.IsMatch(value,"^sha256:[a-f0-9]{64}$")) lock(sync) reviewedPlan=value;
                }
            } else if(action is "Doctor" or "Verify") Add(JsonSerializer.SerializeToElement(new { type="Setup",data=root.Clone() }));
        } catch(JsonException) { /* Never display raw provider output. */ }
    }
    private void Add(JsonElement item) { lock(sync) { if(events.Count==500) events.RemoveAt(0); events.Add(item); } }
}
