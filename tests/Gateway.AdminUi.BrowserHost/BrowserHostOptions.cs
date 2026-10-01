namespace Gateway.AdminUi.BrowserHost;

internal sealed record BrowserHostOptions(
    int Port = 0,
    string Scenario = "fleet",
    string Role = "Administrator",
    int MutationDelayMs = 250,
    bool SelfTest = false,
    bool Help = false,
    bool Https = false)
{
    public static BrowserHostOptions Parse(string[] args)
    {
        var options = new BrowserHostOptions();
        for (var index = 0; index < args.Length; index++)
        {
            var argument = args[index];
            string Value() => ++index < args.Length
                ? args[index]
                : throw new ArgumentException($"A value is required for {argument}.");
            options = argument switch
            {
                "--port" => options with { Port = ParseNumber(Value(), 0, 65535) },
                "--scenario" => options with { Scenario = Value() },
                "--role" => options with { Role = Value() },
                "--mutation-delay-ms" => options with { MutationDelayMs = ParseNumber(Value(), 0, 5000) },
                "--self-test" => options with { SelfTest = true },
                "--https" => options with { Https = true },
                "--help" or "-h" => options with { Help = true },
                _ => throw new ArgumentException($"Unknown option: {argument}. Use --help.")
            };
        }
        FixtureCatalog.Get(options.Scenario);
        FixtureIdentity.NormalizeRole(options.Role);
        return options;
    }

    private static int ParseNumber(string value, int minimum, int maximum) =>
        int.TryParse(value, out var number) && number >= minimum && number <= maximum
            ? number
            : throw new ArgumentException($"Expected an integer from {minimum} through {maximum}.");

    public const string HelpText = """
        Gateway.AdminUi.BrowserHost — synthetic, loopback-only production component host

        Build from fresh inputs:
          pwsh -NoProfile -File .\tests\Gateway.AdminUi.BrowserHost\Build-BrowserHost.ps1
        Run the DLL printed by that script (do not use production launch profiles):
          dotnet <fresh Gateway.AdminUi.BrowserHost.dll> --port 0 --scenario fleet --role Administrator
          dotnet <fresh Gateway.AdminUi.BrowserHost.dll> --self-test
        Options: --port 0..65535 (default 0); --scenario <catalog name>;
                 --role Administrator|Operator|Auditor|SupportReader;
                 --mutation-delay-ms 0..5000 (default 250); --https; --help.
        --https generates a process-owned loopback test certificate. No private-key
        file is authored; READY prints the public PEM path for a single test process's
        NODE_EXTRA_CA_CERTS. No machine/user trust store is changed.
        No URL, host, configuration, token, credential, or provider option exists.
        Read the BROWSER_FIXTURE_READY JSON line to obtain the allocated 127.0.0.1 URL.

        Driver API (single harness / one synthetic world per process):
          GET  /__fixture/health       readiness, assembly identity, isolation guards
          GET  /__fixture/catalog      finite scenarios, roles and operation controls
          GET  /__fixture/state        non-secret counters, fixture IDs, status and metadata
          POST /__fixture/reset        {"scenario":"empty","role":"Administrator","mutationDelayMs":250}
          POST /__fixture/operation    {"status":"Completed","completion":"success","available":false}
          POST /__fixture/read-errors  {"methods":[]} to clear failures without resetting data
        All POST controls require Content-Type: application/json and X-Browser-Fixture: 1.
        /operation optionally takes operationId (otherwise the newest operation).
        /read-errors accepts only supported read method names from /catalog.
        Reset clears data/counters, revokes old fixture leases and creates a new identity
        on the next HTTP request. Close the old page/circuit BEFORE reset, then navigate
        a fresh document. Never use reset while an action is in flight. Role changes
        are fixture setup, not evidence of production server authorization.

        Counters count actual IGatewayApiClient invocations, including prerender reads;
        browser double-submit assertions should count mutation methods, not read totals.
        Assert unexpectedCalls is empty and guard attempts are zero before each reset.
        Read fixture.primaryAgentId, primaryOperationId and newestOperationId from
        /state rather than hardcoding generated IDs. /state wraps these in fixture.
        fleet seeds 237 rows (100/100/37); Active + Development + invoice-eu yields
        137 matches (100/37), including name-only/external-ID-only matches and timestamp
        ties. Search Auxiliary alone yields exactly 100, with no final Next cursor.
        Overview totals: registered=237, active=177, action-required=30 (10 per state).
        Ordering is ascending creation time then SQL Server GUID; the cursor uses
        the unmodified, source-linked production codec. cursor-error rejects only
        continuation reads with HTTP 400 and ValidationErrors["Cursor"]; restarting
        without a cursor succeeds and keeps the selected filters.
        No counter/state endpoint returns a one-time key, token, request body or samples.
        Only the mutation response exposes an intentionally INVALID synthetic key once.
        Accepted-then-interrupted scenarios persist metadata before throwing; recover by
        production readback, never a second create. Completion defaults to Completed;
        operation-verifying retains Running until /operation advances it.

        The real Gateway.AdminUi App, Routes, layout, pages, CSS and JS are used.
        The production Program, configuration and authentication endpoints are NOT run.
        A sign-in/consent link terminates locally with 409; no Entra flow is available.
        M4 catalog scenarios simulate finite protection API responses and runtime
        observations. The actual HTTPS portal/antiforgery endpoints call a bounded
        synthetic execution client, never a provider. Every unscripted method fails.
        Registered HttpClient, IHttpClientFactory and token acquisition are terminal
        deny transports. A same-origin CSP blocks browser subresource egress. This is
        not an OS network sandbox; a browser harness must also reject nonlocal requests
        and top-level navigation, and must use an isolated Chrome profile.
        Stop with Ctrl+C. Delete only the uniquely owned .work directory printed by the
        build script after stopping its process. No milestone acceptance is implied.
        """;
}
