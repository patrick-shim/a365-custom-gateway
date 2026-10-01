using System.Diagnostics;
using Gateway.Infrastructure.Persistence;

namespace Gateway.Tooling.Tests;

public sealed class ToolingCommandTests
{
    private const string Migrator = "Gateway.DatabaseMigrator";
    private const string Verifier = "Gateway.LiveVerification";
    private const string Intent = "77777777-7777-4777-8777-777777777777";

    [Theory]
    [InlineData(Migrator)]
    [InlineData(Verifier)]
    public async Task NativeHelpNeedsNoConfigurationOrAuthentication(string tool)
    {
        var result = await RunTool(tool, ["--help"]);
        Assert.Equal(0, result.ExitCode);
        Assert.Contains("--validate-only true", result.Output);
        Assert.DoesNotContain("[PASS]", result.Output);
    }

    [Fact]
    public async Task NativeModelAndReviewedRolePlannersAreOffline()
    {
        var model = await RunTool(Migrator, BasicArguments("upgrade-schema-plan"));
        Assert.Equal(0, model.ExitCode);
        Assert.Matches(@"\AA365GW_UPGRADE_SCHEMA:sha256:[0-9a-f]{64}\s*\z", model.Output);
        var role = await RunTool(Migrator, [.. BasicArguments("capability-graph-role-id"), "--graph-role-name", "ContentActivity.Write"]);
        Assert.Equal(0, role.ExitCode);
        Assert.Equal("A365GW_GRAPH_APPLICATION_ROLE:2932e07a-3c29-44e4-bb36-6d0fc176387f", role.Output.Trim());
        var unknown = await RunTool(Migrator, [.. BasicArguments("capability-graph-role-id"), "--graph-role-name", "UnknownFixtureRole"]);
        Assert.NotEqual(0, unknown.ExitCode);
    }

    [Theory]
    [InlineData("upgrade-schema-plan")]
    [InlineData("capability-graph-role-id")]
    public async Task OfflineValidationDoesNotEmitPlanningArtifacts(string phase)
    {
        var arguments = BasicArguments(phase).ToList();
        if (phase == "capability-graph-role-id")
            arguments.AddRange(["--graph-role-name", "ContentActivity.Write"]);
        var result = await RunTool(Migrator, [.. arguments, "--validate-only", "true"]);
        Assert.Equal(0, result.ExitCode);
        Assert.Contains("no provider access or completion evidence", result.Output);
        Assert.DoesNotContain("A365GW_", result.Output);
    }

    [Fact]
    public async Task OfflinePlanningRejectsIgnoredDatabaseSwitches()
    {
        var result = await RunTool(Migrator,
            [.. BasicArguments("upgrade-schema-plan"), "--validate-only", "true", "--stay-alive", "true"]);
        Assert.NotEqual(0, result.ExitCode);
        Assert.Contains("unsupported offline planning argument", result.Output);
    }

    [Theory]
    [InlineData("initialize")]
    [InlineData("bootstrap")]
    [InlineData("principal")]
    [InlineData("prepare")]
    [InlineData("finalize")]
    [InlineData("verify")]
    public async Task CurrentMigratorArgumentsCanBeValidatedWithoutExecuting(string phase)
    {
        var arguments = BoundArguments(phase).ToList();
        if (phase == "bootstrap")
            arguments.AddRange(["--execution-intent-id", Intent, "--expected-private-endpoint-ip", "10.20.0.4"]);
        if (phase == "principal")
            arguments.AddRange(["--principal-name", "api-fixture", "--principal-client-id", ToolingFixture.ApiPrincipal]);
        arguments.AddRange(["--validate-only", "true"]);
        var result = await RunTool(Migrator, arguments);
        Assert.Equal(0, result.ExitCode);
        Assert.Contains("no provider access, database mutation, or completion evidence", result.Output);
        Assert.DoesNotContain("A365GW_DB_EVIDENCE|", result.Output);
    }

    [Fact]
    public async Task RetainedSourceOnlyEnvironmentManifestMatchesNativeEntryPoint()
    {
        var model = await RunTool(Migrator, BasicArguments("upgrade-schema-plan"));
        Assert.Equal(0, model.ExitCode);
        var manifest = ToolingFixture.Manifest() with { TargetModelFingerprint = model.Output.Trim().Split(':', 2)[1] };
        var json = ToolingFixture.ManifestJson(manifest);
        var result = await RunTool(Migrator,
            [.. BoundArguments("upgrade"), "--execution-intent-id", Intent,
                "--expected-private-endpoint-ip", "10.20.0.4", "--upgrade-plan-fingerprint", manifest.PlanFingerprint,
                "--validate-only", "true"],
            new()
            {
                ["DATABASE_MIGRATOR_UPGRADE_MANIFEST_JSON"] = json,
                ["DATABASE_MIGRATOR_UPGRADE_MANIFEST_FINGERPRINT"] = DatabaseUpgradeAttestation.Fingerprint(json)
            });
        Assert.Equal(0, result.ExitCode);
        Assert.Contains("no provider access", result.Output);
        Assert.DoesNotContain("A365GW_UPGRADE_EVIDENCE|", result.Output);
        var changedJson = ToolingFixture.ManifestJson(manifest with
        {
            TargetModelFingerprint = manifest.TargetModelFingerprint == ToolingFixture.Hash('0')
                ? ToolingFixture.Hash('1') : ToolingFixture.Hash('0')
        });
        var rejected = await RunTool(Migrator,
            [.. BoundArguments("upgrade"), "--execution-intent-id", Intent,
                "--expected-private-endpoint-ip", "10.20.0.4", "--upgrade-plan-fingerprint", manifest.PlanFingerprint,
                "--validate-only", "true"],
            new()
            {
                ["DATABASE_MIGRATOR_UPGRADE_MANIFEST_JSON"] = changedJson,
                ["DATABASE_MIGRATOR_UPGRADE_MANIFEST_FINGERPRINT"] = DatabaseUpgradeAttestation.Fingerprint(changedJson)
            });
        Assert.NotEqual(0, rejected.ExitCode);
        Assert.Contains("target EF-model fingerprint differs", rejected.Output);
    }

    [Fact]
    public async Task BootstrapEnvironmentIntentAndRecoveryModeRemainBound()
    {
        string[] arguments = [.. BoundArguments("bootstrap"), "--expected-private-endpoint-ip", "10.20.0.4",
            "--required-recovery-mode", "ResumeAfterSchemaCompleted", "--validate-only", "true"];
        var environment = new Dictionary<string, string> { ["DATABASE_MIGRATOR_EXECUTION_INTENT_ID"] = Intent };
        var accepted = await RunTool(Migrator, arguments, environment);
        Assert.Equal(0, accepted.ExitCode);
        var rejected = await RunTool(Migrator,
            [.. arguments, "--execution-intent-id", ToolingFixture.Ownership], environment);
        Assert.NotEqual(0, rejected.ExitCode);
        Assert.Contains("must match exactly", rejected.Output);
    }

    [Theory]
    [InlineData("--unknown", "true")]
    [InlineData("--SERVER", "sql-other-fixture.database.windows.net")]
    [InlineData("--stay-alive", "not-a-boolean")]
    [InlineData("--evidence-stdout", "not-a-boolean")]
    public async Task InvalidMigratorArgumentsFailBeforeProviders(string name, string value)
    {
        var result = await RunTool(Migrator, [.. BasicArguments("verify"), "--validate-only", "true", name, value]);
        Assert.NotEqual(0, result.ExitCode);
        Assert.DoesNotContain("Arguments and local SQL/manifest inputs validated", result.Output);
    }

    [Fact]
    public async Task ExplicitValidationCannotSilentlyFallThroughToLiveExecution()
    {
        var migrator = await RunTool(Migrator, [.. BasicArguments("verify"), "--validate-only", "false"]);
        Assert.NotEqual(0, migrator.ExitCode);
        Assert.Contains("--validate-only", migrator.Output);
        var verifier = await RunTool(Verifier, [.. LiveArguments(), "--validate-only", "false"]);
        Assert.NotEqual(0, verifier.ExitCode);
        Assert.Contains("--validate-only", verifier.Output);
    }

    [Fact]
    public async Task PrincipalMutationRequiresTheExactExpectedIdentityBeforeProviderAccess()
    {
        var result = await RunTool(Migrator, [.. BoundArguments("principal"),
            "--principal-name", "api-fixture", "--principal-client-id", ToolingFixture.Ownership,
            "--validate-only", "true"]);
        Assert.NotEqual(0, result.ExitCode);
        Assert.Contains("must match one exact expected runtime principal", result.Output);
    }

    [Fact]
    public async Task VerifierSupportsExactWrapperArgumentsWithoutLiveVerification()
    {
        var result = await RunTool(Verifier, [.. LiveArguments(), "--validate-only", "true"]);
        Assert.Equal(0, result.ExitCode);
        Assert.Contains("no authentication, HTTP requests, credential changes, or live verification", result.Output);
        Assert.DoesNotContain("[PASS]", result.Output);
        var revokeArguments = LiveArguments();
        revokeArguments[Array.IndexOf(revokeArguments, "--operation-mode") + 1] = "RevokeOnly";
        var revoke = await RunTool(Verifier,
            [.. revokeArguments, "--recovery-credential-id", Intent, "--validate-only", "true"]);
        Assert.Equal(0, revoke.ExitCode);
        var missing = await RunTool(Verifier, [.. revokeArguments, "--validate-only", "true"]);
        Assert.NotEqual(0, missing.ExitCode);
    }

    [Fact]
    public void VerifierArgumentParsingRetainsAuthenticationAndBooleanRestrictions()
    {
        Assert.True(global::Options.Parse([.. LiveArguments(), "--validate-only", "true"]).ValidateOnly);
        Assert.Throws<ArgumentException>(() => global::Options.Parse(
            [.. LiveArguments(), "--api-base-url", "https://example.invalid/"]));
        var arguments = LiveArguments();
        arguments[Array.IndexOf(arguments, "--expect-purview-enabled") + 1] = "True";
        Assert.Throws<ArgumentException>(() => global::Options.Parse(arguments));
        arguments = LiveArguments();
        arguments[Array.IndexOf(arguments, "--authentication-mode") + 1] = "ManagedIdentityApplication";
        Assert.Throws<ArgumentException>(() => global::Options.Parse(arguments));
    }

    [Fact]
    public async Task PowerShellMigrationValidationNeverReplaysRecoveryOrCallsAzure()
    {
        var result = await RunProcess("pwsh",
            ["-NoProfile", "-NonInteractive", "-File", Path.Combine(ToolingFixture.Root, "tools", "apply-migrations.ps1"),
                "-SqlServerFqdn", "sql-tooling-fixture.database.windows.net", "-DatabaseName", "ToolingFixture",
                "-ResourceGroup", "rg-tooling-fixture", "-ExpectedClientIpv4", "192.0.2.10",
                "-NetworkOperationId", Intent, "-ValidateOnly"],
            new() { ["A365GW_BOOTSTRAP_SUBSCRIPTION_ID"] = ToolingFixture.Subscription });
        Assert.Equal(0, result.ExitCode);
        Assert.Contains("no Azure access, recovery replay, evidence writes, or SQL execution", result.Output);
    }

    [Fact]
    public async Task PowerShellEntraValidationIsDistinctFromProviderReadOnlyPlanning()
    {
        string[] arguments = ["-NoProfile", "-NonInteractive", "-File",
            Path.Combine(ToolingFixture.Root, "tools", "configure-workflow-v3-entra.ps1"),
            "-ExpectedSubscriptionId", ToolingFixture.Subscription, "-ExpectedTenantId", ToolingFixture.Ownership,
            "-GatewayApiApplicationClientId", ToolingFixture.AutomationClient,
            "-GatewayApiManagedIdentityPrincipalId", ToolingFixture.ApiPrincipal,
            "-WorkerManagedIdentityPrincipalId", ToolingFixture.RuntimePrincipal, "-ValidateOnly"];
        var accepted = await RunProcess("pwsh", arguments);
        Assert.Equal(0, accepted.ExitCode);
        Assert.Contains("no authentication or Azure/Graph calls", accepted.Output);
        var rejected = await RunProcess("pwsh", [.. arguments, "-Apply"]);
        Assert.NotEqual(0, rejected.ExitCode);
        Assert.Contains("cannot be combined", rejected.Output);
    }

    [Fact]
    public async Task CommonHelperPinsExactSubscriptionWithoutInvokingAzure()
    {
        var result = await RunProcess("pwsh", ["-NoProfile", "-NonInteractive", "-Command", """
            $ErrorActionPreference = 'Stop'
            function az { throw 'Unexpected live CLI call.' }
            . (Join-Path $PWD 'tools\_common.ps1')
            $pinned = @(Add-A365GatewayAzureSubscriptionPin -Arguments @('account', 'show') -Required)
            if ($pinned.Count -ne 4 -or $pinned[-1] -cne $env:A365GW_BOOTSTRAP_SUBSCRIPTION_ID) {
                throw 'Subscription pin was not appended exactly.'
            }
            $rejected = $false
            try { Add-A365GatewayAzureSubscriptionPin -Arguments @('account', 'show', '--subscription', 'other') -Required }
            catch { $rejected = $true }
            if (-not $rejected) { throw 'A conflicting subscription was accepted.' }
            Write-Output 'Exact offline subscription pin passed.'
            """], new() { ["A365GW_BOOTSTRAP_SUBSCRIPTION_ID"] = ToolingFixture.Subscription });
        Assert.Equal(0, result.ExitCode);
        Assert.Contains("Exact offline subscription pin passed.", result.Output);
    }

    [Fact]
    public void ChildProcessesDoNotInheritProviderConfiguration()
    {
        var start = new ProcessStartInfo("dotnet");
        start.Environment["AZURE_CONFIG_DIR"] = "unexpected-provider-profile";
        start.Environment["IDENTITY_ENDPOINT"] = "https://example.invalid/";
        start.Environment["DATABASE_MIGRATOR_SERVER"] = "unexpected.database.windows.net";
        start.Environment["A365GW_BOOTSTRAP_SUBSCRIPTION_ID"] = ToolingFixture.Subscription;
        IsolateProcessEnvironment(start);
        Assert.DoesNotContain("AZURE_CONFIG_DIR", start.Environment.Keys);
        Assert.DoesNotContain("IDENTITY_ENDPOINT", start.Environment.Keys);
        Assert.DoesNotContain("DATABASE_MIGRATOR_SERVER", start.Environment.Keys);
        Assert.DoesNotContain("A365GW_BOOTSTRAP_SUBSCRIPTION_ID", start.Environment.Keys);
        Assert.Equal("1", start.Environment["POWERSHELL_TELEMETRY_OPTOUT"]);
    }

    private static string[] BasicArguments(string phase) =>
        ["--server", "sql-tooling-fixture.database.windows.net", "--database", "GatewayDb", "--phase", phase,
            "--repository-root", ToolingFixture.Root];

    private static string[] BoundArguments(string phase) =>
        [.. BasicArguments(phase), "--deployment-ownership-id", ToolingFixture.Ownership,
            "--accepted-source-fingerprint", ToolingFixture.OriginalSource,
            "--expected-api-principal-name", "api-fixture", "--expected-api-principal-client-id", ToolingFixture.ApiPrincipal,
            "--expected-worker-principal-name", "worker-fixture", "--expected-worker-principal-client-id", ToolingFixture.RuntimePrincipal];

    private static string[] LiveArguments() =>
        ["--api-base-url", "https://example.invalid/", "--api-application-client-id", ToolingFixture.AutomationClient,
            "--api-scope-base-uri", "api://tooling-fixture", "--tenant-id", ToolingFixture.Ownership,
            "--authentication-mode", "InteractiveBrowserUser", "--authentication-client-id", ToolingFixture.RegistryClient,
            "--operation-mode", "Full", "--agent-registration-id", ToolingFixture.RuntimePrincipal,
            "--external-agent-id", "offline-fixture", "--tenant-user-object-id", ToolingFixture.ApiPrincipal,
            "--expect-prompt-shield-enabled", "true", "--expect-purview-enabled", "false"];

    private static Task<CommandResult> RunTool(string tool, IEnumerable<string> arguments, Dictionary<string, string>? environment = null)
    {
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var assembly = Path.Combine(ToolingFixture.Root, "tools", tool, "bin", configuration, "net10.0", tool + ".dll");
        Assert.True(File.Exists(assembly), "The scoped test build must produce the tool assembly.");
        return RunProcess("dotnet", [assembly, .. arguments], environment);
    }

    private static async Task<CommandResult> RunProcess(
        string command, IEnumerable<string> arguments, Dictionary<string, string>? environment = null)
    {
        var start = new ProcessStartInfo(command)
        {
            WorkingDirectory = ToolingFixture.Root, UseShellExecute = false,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        IsolateProcessEnvironment(start);
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        if (environment is not null)
            foreach (var pair in environment) start.Environment[pair.Key] = pair.Value;
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start the offline tool.");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try { await process.WaitForExitAsync(deadline.Token); }
        catch (OperationCanceledException)
        {
            process.Kill(entireProcessTree: true);
            throw new InvalidOperationException("The offline tool did not exit within its bounded validation window.");
        }
        return new(process.ExitCode, await output + await error);
    }

    private static void IsolateProcessEnvironment(ProcessStartInfo start)
    {
        var runtimeNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "PATH", "PATHEXT", "SystemRoot", "WINDIR", "COMSPEC", "ProgramFiles", "ProgramFiles(x86)",
            "ProgramW6432", "DOTNET_ROOT", "DOTNET_ROOT_X64", "DOTNET_ROOT_ARM64", "DOTNET_HOST_PATH",
            "TEMP", "TMP", "LANG", "LC_ALL", "TZ"
        };
        var runtime = start.Environment.Where(pair => runtimeNames.Contains(pair.Key)).ToArray();
        start.Environment.Clear();
        foreach (var pair in runtime) start.Environment[pair.Key] = pair.Value;
        start.Environment["DOTNET_CLI_UI_LANGUAGE"] = "en-US";
        start.Environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1";
        start.Environment["POWERSHELL_TELEMETRY_OPTOUT"] = "1";
        start.Environment["POWERSHELL_UPDATECHECK"] = "Off";
    }

    private sealed record CommandResult(int ExitCode, string Output);
}
