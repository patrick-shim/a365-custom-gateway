using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using FluentAssertions;
using Gateway.DatabaseMigrator;
using Gateway.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Metadata;

namespace Gateway.UnitTests.Infrastructure;

[CollectionDefinition(nameof(DatabaseMigratorEnvironmentCollection), DisableParallelization = true)]
public sealed class DatabaseMigratorEnvironmentCollection;

[Collection(nameof(DatabaseMigratorEnvironmentCollection))]
public sealed class DatabaseMigratorBootstrapPhaseTests
{
    private const string OwnershipId = "11111111-1111-4111-8111-111111111111";
    private const string SourceFingerprint =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string ExecutionIntentId = "44444444-4444-4444-8444-444444444444";
    private const string ExpectedPrivateEndpointIp = "10.42.2.4";

    [Fact]
    public async Task Bootstrap_RequiresExactDeploymentAndSourceBinding()
    {
        var action = () => InvokeMigratorAsync(
            "--server", "sql-test.database.windows.net",
            "--database", "GatewayDb",
            "--phase", "bootstrap",
            "--execution-intent-id", ExecutionIntentId);

        await action.Should().ThrowAsync<ArgumentException>()
            .WithMessage("*bootstrap phase requires --deployment-ownership-id and --accepted-source-fingerprint*");
    }

    [Fact]
    public async Task Bootstrap_RequiresBothExpectedRuntimePrincipals()
    {
        var action = () => InvokeMigratorAsync(
            "--server", "sql-test.database.windows.net",
            "--database", "GatewayDb",
            "--phase", "bootstrap",
            "--execution-intent-id", ExecutionIntentId,
            "--deployment-ownership-id", OwnershipId,
            "--accepted-source-fingerprint", SourceFingerprint);

        await action.Should().ThrowAsync<ArgumentException>()
            .WithMessage("*requires both exact expected Gateway runtime principals*");
    }

    [Fact]
    public async Task Bootstrap_RequiresExecutionIntentId()
    {
        var action = () => InvokeMigratorAsync(
            "--server", "sql-test.database.windows.net",
            "--database", "GatewayDb",
            "--phase", "bootstrap",
            "--deployment-ownership-id", OwnershipId,
            "--accepted-source-fingerprint", SourceFingerprint,
            "--expected-api-principal-name", "ca-gateway-api-dev",
            "--expected-api-principal-client-id", "22222222-2222-4222-8222-222222222222",
            "--expected-worker-principal-name", "ca-gateway-worker-dev-v3",
            "--expected-worker-principal-client-id", "33333333-3333-4333-8333-333333333333");

        await action.Should().ThrowAsync<ArgumentException>()
            .WithMessage("*--execution-intent-id must be the canonical lowercase non-empty GUID*");
    }

    [Fact]
    public async Task Bootstrap_AcceptsExecutionIntentFromTheExactContainerAppsEnvironmentVariable()
    {
        const string variableName = "DATABASE_MIGRATOR_EXECUTION_INTENT_ID";
        var priorValue = Environment.GetEnvironmentVariable(variableName);
        try
        {
            Environment.SetEnvironmentVariable(variableName, ExecutionIntentId);
            var arguments = CreateBoundBootstrapArguments()
                .Where((_, index) => index is not 6 and not 7)
                .ToArray();

            var action = () => InvokeMigratorAsync(arguments);

            await action.Should().ThrowAsync<InvalidOperationException>()
                .WithMessage("*requires the Container Apps managed-identity endpoint*");
        }
        finally
        {
            Environment.SetEnvironmentVariable(variableName, priorValue);
        }
    }

    [Fact]
    public async Task Bootstrap_RejectsConflictingCommandLineAndEnvironmentExecutionIntents()
    {
        const string variableName = "DATABASE_MIGRATOR_EXECUTION_INTENT_ID";
        var priorValue = Environment.GetEnvironmentVariable(variableName);
        try
        {
            Environment.SetEnvironmentVariable(
                variableName,
                "55555555-5555-4555-8555-555555555555");
            var action = () => InvokeMigratorAsync(CreateBoundBootstrapArguments());

            await action.Should().ThrowAsync<ArgumentException>()
                .WithMessage("*--execution-intent-id and DATABASE_MIGRATOR_EXECUTION_INTENT_ID must match exactly*");
        }
        finally
        {
            Environment.SetEnvironmentVariable(variableName, priorValue);
        }
    }

    [Theory]
    [InlineData("")]
    [InlineData("00000000-0000-0000-0000-000000000000")]
    [InlineData("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")]
    [InlineData("{44444444-4444-4444-8444-444444444444}")]
    public async Task Bootstrap_RejectsMalformedExecutionIntentId(string executionIntentId)
    {
        var action = () => InvokeMigratorAsync(
            CreateBoundBootstrapArguments(executionIntentId));

        await action.Should().ThrowAsync<ArgumentException>()
            .WithMessage("*--execution-intent-id must be the canonical lowercase non-empty GUID*");
    }

    [Fact]
    public async Task NonBootstrapPhase_RejectsExecutionIntentId()
    {
        var action = () => InvokeMigratorAsync(
            "--server", "sql-test.database.windows.net",
            "--database", "GatewayDb",
            "--phase", "verify",
            "--execution-intent-id", ExecutionIntentId);

        await action.Should().ThrowAsync<ArgumentException>()
            .WithMessage("*--execution-intent-id is allowed only for the bootstrap phase*");
    }

    [Fact]
    public async Task Bootstrap_RejectsStandalonePrincipalArguments()
    {
        var action = () => InvokeMigratorAsync(
            CreateBoundBootstrapArguments()
                .Concat(["--principal-name", "ca-unreviewed"])
                .ToArray());

        await action.Should().ThrowAsync<ArgumentException>()
            .WithMessage("*standalone --principal-name and --principal-client-id are not allowed*");
    }

    [Fact]
    public async Task Bootstrap_RejectsRepeatTwo()
    {
        var action = () => InvokeMigratorAsync(
            CreateBoundBootstrapArguments()
                .Concat(["--repeat", "2"])
                .ToArray());

        await action.Should().ThrowAsync<ArgumentException>()
            .WithMessage("*bootstrap phase requires --repeat 1*");
    }

    [Fact]
    public async Task Bootstrap_RejectsStayAliveMode()
    {
        var action = () => InvokeMigratorAsync(
            CreateBoundBootstrapArguments()
                .Concat(["--stay-alive", "true"])
                .ToArray());

        await action.Should().ThrowAsync<ArgumentException>()
            .WithMessage("*one-shot bootstrap phase does not allow --stay-alive true*");
    }

    [Fact]
    public async Task Bootstrap_AcceptsExactPristineDiagnosticOnlyModeBeforeManagedIdentityAuthentication()
    {
        var action = () => InvokeMigratorAsync(
            CreateBoundBootstrapArguments()
                .Concat(["--pristine-diagnostic-only", "true"])
                .ToArray());

        await action.Should().ThrowAsync<InvalidOperationException>()
            .WithMessage("*requires the Container Apps managed-identity endpoint*");
    }

    [Theory]
    [InlineData("false")]
    [InlineData("True")]
    [InlineData("1")]
    public async Task Bootstrap_RejectsNonExactPristineDiagnosticOnlyValues(string value)
    {
        var action = () => InvokeMigratorAsync(
            CreateBoundBootstrapArguments()
                .Concat(["--pristine-diagnostic-only", value])
                .ToArray());

        await action.Should().ThrowAsync<ArgumentException>()
            .WithMessage("*--pristine-diagnostic-only must be the exact value true*");
    }

    [Fact]
    public async Task NonBootstrapPhase_RejectsPristineDiagnosticOnlyMode()
    {
        var action = () => InvokeMigratorAsync(
            "--server", "sql-test.database.windows.net",
            "--database", "GatewayDb",
            "--phase", "verify",
            "--pristine-diagnostic-only", "true");

        await action.Should().ThrowAsync<ArgumentException>()
            .WithMessage("*allowed only for the bootstrap phase*");
    }

    [Theory]
    [InlineData("true")]
    [InlineData("false")]
    public async Task Bootstrap_RejectsAmbientPristineDiagnosticOnlyMode(string value)
    {
        const string variableName = "DATABASE_MIGRATOR_PRISTINE_DIAGNOSTIC_ONLY";
        var priorValue = Environment.GetEnvironmentVariable(variableName);
        try
        {
            Environment.SetEnvironmentVariable(variableName, value);
            var action = () => InvokeMigratorAsync(CreateBoundBootstrapArguments());

            await action.Should().ThrowAsync<ArgumentException>()
                .WithMessage("*is forbidden; diagnostic mode requires the explicit command-line option*");
        }
        finally
        {
            Environment.SetEnvironmentVariable(variableName, priorValue);
        }
    }

    [Fact]
    public async Task Bootstrap_RequiresExpectedPrivateEndpointIp()
    {
        var arguments = CreateBoundBootstrapArguments()[..^2];
        var action = () => InvokeMigratorAsync(arguments);

        await action.Should().ThrowAsync<ArgumentException>()
            .WithMessage("--expected-private-endpoint-ip must be one canonical private IPv4 address*");
    }

    [Theory]
    [InlineData("203.0.113.7")]
    [InlineData("::1")]
    [InlineData("10.42.2.004")]
    public async Task Bootstrap_RejectsUnsafeExpectedPrivateEndpointIp(string value)
    {
        var arguments = CreateBoundBootstrapArguments();
        arguments[^1] = value;
        var action = () => InvokeMigratorAsync(arguments);

        await action.Should().ThrowAsync<ArgumentException>()
            .WithMessage("--expected-private-endpoint-ip must be one canonical private IPv4 address*");
    }

    [Fact]
    public async Task NonBootstrapPhase_RejectsExpectedPrivateEndpointIp()
    {
        var action = () => InvokeMigratorAsync(
            "--server", "sql-test.database.windows.net",
            "--database", "GatewayDb",
            "--phase", "verify",
            "--expected-private-endpoint-ip", ExpectedPrivateEndpointIp);

        await action.Should().ThrowAsync<ArgumentException>()
            .WithMessage("--expected-private-endpoint-ip is allowed only for the bootstrap phase.");
    }

    [Fact]
    public void Bootstrap_UsesOneLockAndEmitsOneThreeRecordChunkedPayload()
    {
        var source = File.ReadAllText(Path.Combine(
            FindRepositoryRoot(),
            "tools",
            "Gateway.DatabaseMigrator",
            "Program.cs"));
        var bootstrapBody = Regex.Match(
            source,
            @"static async Task<IReadOnlyList<MigrationEvidence>> BootstrapDatabaseAsync\([\s\S]*?(?=\nstatic async Task<MigrationEvidence>)",
            RegexOptions.CultureInvariant).Value;

        bootstrapBody.Should().NotBeEmpty();
        Regex.Matches(bootstrapBody, "AcquireDatabaseInitializationLockAsync", RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        Regex.Matches(bootstrapBody, "ReleaseDatabaseInitializationLockAsync", RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        Regex.Matches(bootstrapBody, "EnsureEmptyDatabaseInitializedUnderLockAsync", RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        Regex.Matches(bootstrapBody, "EnsureRuntimePrincipalAsync", RegexOptions.CultureInvariant)
            .Count.Should().Be(2);
        Regex.Matches(bootstrapBody, "evidence.Add", RegexOptions.CultureInvariant)
            .Count.Should().Be(3);
        Regex.Matches(bootstrapBody, "executionIntentId", RegexOptions.CultureInvariant)
            .Count.Should().Be(4);
        bootstrapBody.Should().Contain("\"initialize\"");
        Regex.Matches(bootstrapBody, "\"principal\"", RegexOptions.CultureInvariant)
            .Count.Should().Be(2);

        source.Should().Contain("bootstrapEvidence.Count != 3");
        Regex.Matches(source, "EVIDENCE_BASE64=", RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        source.Should().Contain("DatabaseBootstrapEvidenceChunkProtocol.Encode");
        source.Should().Contain("else if (evidenceStdoutRequested)");
        source.Should().NotContain("if (phase == \"bootstrap\" || evidenceStdoutRequested)");
        source.Should().MatchRegex(@"JsonSerializer\.Serialize\(\r?\n\s+bootstrapEvidence");
        source.Should().Contain("string? ExecutionIntentId");
        source.Should().Contain("phase == \"bootstrap\" && string.IsNullOrWhiteSpace(managedIdentityEndpoint)");
        source.Should().Contain("never falls back to Azure CLI credentials");
        var dnsConvergence = source.IndexOf(
            "SqlPrivateEndpointDnsConvergence.WaitForExactResolutionAsync",
            StringComparison.Ordinal);
        var tokenAcquisition = source.IndexOf("credential.GetTokenAsync", StringComparison.Ordinal);
        var sqlOpen = source.IndexOf("connection.OpenAsync", StringComparison.Ordinal);
        dnsConvergence.Should().BeGreaterThanOrEqualTo(0);
        dnsConvergence.Should().BeLessThan(tokenAcquisition);
        tokenAcquisition.Should().BeLessThan(sqlOpen);
    }

    [Fact]
    public void PristineDiagnosticOnlyMode_ReadsUnderTheInitializationLockAndReturnsBeforeMutation()
    {
        var source = File.ReadAllText(Path.Combine(
            FindRepositoryRoot(),
            "tools",
            "Gateway.DatabaseMigrator",
            "Program.cs"));
        source.Should().Contain(
            "options.TryGetValue(\"pristine-diagnostic-only\", out var pristineDiagnosticOnlyValue)");
        source.Should().Contain(
            "DATABASE_MIGRATOR_PRISTINE_DIAGNOSTIC_ONLY is forbidden");
        var diagnosticStart = source.IndexOf(
            "if (pristineDiagnosticOnly)\n{",
            StringComparison.Ordinal);
        var normalBootstrapStart = source.IndexOf(
            "RuntimePrincipalEvidence? runtimePrincipalEvidence",
            StringComparison.Ordinal);

        diagnosticStart.Should().BeGreaterThanOrEqualTo(0);
        normalBootstrapStart.Should().BeGreaterThan(diagnosticStart);
        var diagnosticBody = source.Substring(
            diagnosticStart,
            normalBootstrapStart - diagnosticStart);
        Regex.Matches(diagnosticBody, "AcquireDatabaseInitializationLockAsync", RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        Regex.Matches(diagnosticBody, "ReadAzureSqlPristinePlatformDiagnosticAsync", RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        Regex.Matches(diagnosticBody, "ReadSingleAuditSpecificationNameFingerprintAsync", RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        Regex.Matches(
                diagnosticBody,
                "ReadPristineDatabaseSurfaceAfterAuditConvergenceAsync",
                RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        Regex.Matches(diagnosticBody, "DatabaseBootstrapRecoveryContract.AssertPristine", RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        Regex.Matches(diagnosticBody, "ReleaseDatabaseInitializationLockAsync", RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        Regex.Matches(diagnosticBody, "return;", RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        diagnosticBody.Should().NotContain("EnsureEmptyDatabaseInitialized");
        diagnosticBody.Should().NotContain("BootstrapDatabaseAsync");
        diagnosticBody.Should().NotContain("EnsureRuntimePrincipalAsync");
        source.Should().Contain("OBJECT_ID(N'sys.database_firewall_rules')");
        source.Should().Contain("N'SqlDbAuditing_ServerAuditSpec'");
        source.Should().Contain("N'SqlDbAuditing_AuditSpec'");
        source.Should().Contain("AS dboConnectExact");
        source.Should().Contain("HASHBYTES(N'SHA2_256', CONVERT(varbinary(max), name))");
        source.Should().Contain("^sha256:[0-9a-f]{64}$");
    }

    [Fact]
    public void ExpectedSchemaContract_UsesDesignTimeModelForMigrationMetadata()
    {
        using var connection = new Microsoft.Data.SqlClient.SqlConnection(
            "Server=tcp:127.0.0.1,1;Database=GatewayDb;Integrated Security=True;" +
            "Encrypt=False;Connect Timeout=1");
        var options = new DbContextOptionsBuilder<GatewayDbContext>()
            .UseSqlServer(connection)
            .Options;
        using var context = new GatewayDbContext(options);

        connection.State.Should().Be(System.Data.ConnectionState.Closed);
        var tables = context
            .GetService<IDesignTimeModel>()
            .Model
            .GetRelationalModel()
            .Tables
            .ToArray();
        var excludedFromMigrations = () => tables
            .Select(table => table.IsExcludedFromMigrations)
            .ToArray();

        tables.Should().NotBeEmpty();
        excludedFromMigrations.Should().NotThrow();
        connection.State.Should().Be(System.Data.ConnectionState.Closed);

        var source = File.ReadAllText(Path.Combine(
            FindRepositoryRoot(),
            "tools",
            "Gateway.DatabaseMigrator",
            "Program.cs"));
        var methodBody = Regex.Match(
            source,
            @"static ExactDatabaseSchemaSnapshot GetExpectedSchemaContract\([\s\S]*?(?=\nstatic async Task<ExactDatabaseSchemaSnapshot> GetActualSchemaContractAsync)",
            RegexOptions.CultureInvariant).Value;

        methodBody.Should().NotBeEmpty();
        methodBody.Should().Contain("context.GetService<IDesignTimeModel>().Model");
        methodBody.Should().NotContain("context.Model");
    }

    [Fact]
    public void AuditSpecificationConvergence_IsBoundedAndRevalidatesTheFullSurfaceBeforeMutation()
    {
        var repositoryRoot = FindRepositoryRoot();
        var source = File.ReadAllText(Path.Combine(
            repositoryRoot,
            "tools",
            "Gateway.DatabaseMigrator",
            "Program.cs"));
        var contract = File.ReadAllText(Path.Combine(
            repositoryRoot,
            "tools",
            "Gateway.DatabaseMigrator",
            "DatabaseBootstrapRecoveryContract.cs"));
        var convergenceBody = Regex.Match(
            source,
            @"static async Task<PristineDatabaseSurfaceSnapshot>\s+ReadPristineDatabaseSurfaceAfterAuditConvergenceAsync\([\s\S]*?(?=\nstatic async Task<PristineDatabaseSurfaceSnapshot> ReadPristineDatabaseSurfaceAsync)",
            RegexOptions.CultureInvariant).Value;
        var waitBody = Regex.Match(
            source,
            @"static Task WaitForAzureSqlAuditSpecificationReadinessAsync\([\s\S]*?(?=\nstatic async Task<AzureSqlAuditSpecificationReadinessSnapshot>)",
            RegexOptions.CultureInvariant).Value;
        var readinessReadBody = Regex.Match(
            source,
            @"static async Task<AzureSqlAuditSpecificationReadinessSnapshot>\s+ReadAzureSqlAuditSpecificationReadinessAsync\([\s\S]*?(?=\nstatic async Task<AzureSqlPristinePlatformDiagnostic>)",
            RegexOptions.CultureInvariant).Value;
        var initializationBody = Regex.Match(
            source,
            @"static async Task<InitializationIntentEvidence> EnsureEmptyDatabaseInitializedUnderLockAsync\([\s\S]*?(?=\nstatic DatabaseInitializationIntent)",
            RegexOptions.CultureInvariant).Value;

        convergenceBody.Should().NotBeEmpty();
        waitBody.Should().NotBeEmpty();
        readinessReadBody.Should().NotBeEmpty();
        initializationBody.Should().NotBeEmpty();

        var fullSurfaceReads = Regex.Matches(
            convergenceBody,
            "ReadPristineDatabaseSurfaceAsync",
            RegexOptions.CultureInvariant);
        fullSurfaceReads.Count.Should().Be(2);
        var classifyPosition = convergenceBody.IndexOf(
            "DatabaseBootstrapRecoveryContract.ClassifyPristineReadiness(initialSurface)",
            StringComparison.Ordinal);
        var waitPosition = convergenceBody.IndexOf(
            "WaitForAzureSqlAuditSpecificationReadinessAsync(connection)",
            StringComparison.Ordinal);
        classifyPosition.Should().BeGreaterThan(fullSurfaceReads[0].Index);
        waitPosition.Should().BeGreaterThan(classifyPosition);
        fullSurfaceReads[1].Index.Should().BeGreaterThan(waitPosition);

        waitBody.Should().Contain("AzureSqlAuditSpecificationConvergence.WaitAsync");
        waitBody.Should().Contain("token => ReadAzureSqlAuditSpecificationReadinessAsync(connection, token)");
        waitBody.Should().Contain("TimeSpan.FromMinutes(10)");
        waitBody.Should().Contain("TimeSpan.FromSeconds(5)");
        waitBody.Should().Contain("cancellationToken");

        contract.Should().Contain("Stopwatch.GetTimestamp()");
        contract.Should().Contain("Stopwatch.GetElapsedTime(startedAt)");
        contract.Should().Contain("for (var attempt = 1; attempt <= maximumAttempts; attempt++)");
        contract.Should().Contain("CancellationTokenSource.CreateLinkedTokenSource(cancellationToken)");
        Regex.Matches(contract, "CancelAfter\\(remaining\\)", RegexOptions.CultureInvariant)
            .Count.Should().Be(2);
        contract.Should().Contain("Task.Delay(delay, token)");
        contract.Should().Contain("cancellationToken.ThrowIfCancellationRequested()");
        contract.Should().Contain("did not converge before the bounded monotonic deadline");

        readinessReadBody.Should().Contain("ExecuteReaderAsync(cancellationToken)");
        Regex.Matches(
                readinessReadBody,
                "ReadAsync\\(cancellationToken\\)",
                RegexOptions.CultureInvariant)
            .Count.Should().Be(2);

        var convergedReadPosition = initializationBody.IndexOf(
            "ReadPristineDatabaseSurfaceAfterAuditConvergenceAsync(connection)",
            StringComparison.Ordinal);
        var pristineAssertionPosition = initializationBody.IndexOf(
            "DatabaseBootstrapRecoveryContract.AssertPristine(pristineSurface)",
            StringComparison.Ordinal);
        var markerPosition = initializationBody.IndexOf(
            "WriteDatabaseInitializationMarkerAsync(connection, expectedMarker)",
            StringComparison.Ordinal);
        var schemaPosition = initializationBody.IndexOf(
            "context.Database.EnsureCreatedAsync()",
            StringComparison.Ordinal);
        convergedReadPosition.Should().BeGreaterThanOrEqualTo(0);
        pristineAssertionPosition.Should().BeGreaterThan(convergedReadPosition);
        markerPosition.Should().BeGreaterThan(pristineAssertionPosition);
        schemaPosition.Should().BeGreaterThan(markerPosition);
        Regex.Matches(
                source,
                "ReadPristineDatabaseSurfaceAfterAuditConvergenceAsync\\(connection\\)",
                RegexOptions.CultureInvariant)
            .Count.Should().Be(2);
    }

    [Fact]
    public void BootstrapEvidenceChunkProtocol_EmitsExactIndexedChecksummedChunks()
    {
        var executionIntentId = Guid.ParseExact(ExecutionIntentId, "D");
        var evidenceJson = JsonSerializer.Serialize(new
        {
            records = new[]
            {
                new { phase = "initialize", payload = new string('a', 9000) },
                new { phase = "principal", payload = "api" },
                new { phase = "principal", payload = "worker" }
            }
        });
        var rawBytes = Encoding.UTF8.GetBytes(evidenceJson);
        var expectedFingerprint =
            $"sha256:{Convert.ToHexString(SHA256.HashData(rawBytes)).ToLowerInvariant()}";

        var lines = DatabaseBootstrapEvidenceChunkProtocol.Encode(
            evidenceJson,
            executionIntentId);

        lines.Count.Should().BeGreaterThan(1);
        lines.Count.Should().BeLessThanOrEqualTo(
            DatabaseBootstrapEvidenceChunkProtocol.MaximumChunkCount);
        var chunks = new List<string>(lines.Count);
        var pattern = new Regex(
            @"^A365GW_DB_EVIDENCE\|(?<intent>[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})\|(?<index>[1-9][0-9]*)\|(?<total>[1-9][0-9]*)\|(?<fingerprint>sha256:[0-9a-f]{64})\|(?<chunk>[A-Za-z0-9+/]+={0,2})$",
            RegexOptions.CultureInvariant);

        for (var index = 0; index < lines.Count; index++)
        {
            var match = pattern.Match(lines[index]);
            match.Success.Should().BeTrue();
            match.Groups["intent"].Value.Should().Be(ExecutionIntentId);
            int.Parse(match.Groups["index"].Value).Should().Be(index + 1);
            int.Parse(match.Groups["total"].Value).Should().Be(lines.Count);
            match.Groups["fingerprint"].Value.Should().Be(expectedFingerprint);
            match.Groups["chunk"].Value.Length.Should().BeLessThanOrEqualTo(
                DatabaseBootstrapEvidenceChunkProtocol.MaximumChunkLength);
            chunks.Add(match.Groups["chunk"].Value);
        }

        var reconstructedJson = Encoding.UTF8.GetString(
            Convert.FromBase64String(string.Concat(chunks)));
        reconstructedJson.Should().Be(evidenceJson);
    }

    [Fact]
    public void BootstrapEvidenceChunkProtocol_RejectsMoreThan128Chunks()
    {
        var evidenceJson = JsonSerializer.Serialize(new
        {
            payload = new string('a', 600_000)
        });

        var action = () => DatabaseBootstrapEvidenceChunkProtocol.Encode(
            evidenceJson,
            Guid.ParseExact(ExecutionIntentId, "D"));

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("*128-chunk durable-log boundary*");
    }

    private static string[] CreateBoundBootstrapArguments(
        string executionIntentId = ExecutionIntentId) =>
    [
        "--server", "sql-test.database.windows.net",
        "--database", "GatewayDb",
        "--phase", "bootstrap",
        "--execution-intent-id", executionIntentId,
        "--deployment-ownership-id", OwnershipId,
        "--accepted-source-fingerprint", SourceFingerprint,
        "--expected-api-principal-name", "ca-gateway-api-dev",
        "--expected-api-principal-client-id", "22222222-2222-4222-8222-222222222222",
        "--expected-worker-principal-name", "ca-gateway-worker-dev-v3",
        "--expected-worker-principal-client-id", "33333333-3333-4333-8333-333333333333",
        "--expected-private-endpoint-ip", ExpectedPrivateEndpointIp
    ];

    private static async Task InvokeMigratorAsync(params string[] arguments)
    {
        var withRepositoryRoot = arguments
            .Concat(["--repository-root", FindRepositoryRoot()])
            .ToArray();
        var entryPoint = typeof(DatabaseBootstrapRecoveryContract).Assembly.EntryPoint
            ?? throw new InvalidOperationException("The database migrator entry point was not found.");
        object? invocation;
        try
        {
            invocation = entryPoint.Invoke(null, [withRepositoryRoot]);
        }
        catch (TargetInvocationException exception) when (exception.InnerException is not null)
        {
            ExceptionDispatchInfo.Capture(exception.InnerException).Throw();
            throw;
        }

        if (invocation is Task task)
            await task;
    }

    private static string FindRepositoryRoot()
    {
        foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
        {
            var current = new DirectoryInfo(start);
            while (current is not null)
            {
                if (File.Exists(Path.Combine(
                        current.FullName,
                        "tools",
                        "Gateway.DatabaseMigrator",
                        "Gateway.DatabaseMigrator.csproj")))
                {
                    return current.FullName;
                }
                current = current.Parent;
            }
        }

        throw new DirectoryNotFoundException("Could not locate the A365 Gateway repository root.");
    }
}
