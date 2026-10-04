using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.ValueObjects;
using Gateway.Contracts.Messages;
using System.Text.Json;
using Gateway.Infrastructure;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.Infrastructure.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Metadata;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

static void Check(bool ok, string message) { if (!ok) throw new Exception(message); }
Check(InfrastructureProvider.Resolve(new ConfigurationBuilder().Build()) == InfrastructureProvider.Runtime,
    "An unconfigured host must select the runtime infrastructure.");
foreach (var retiredOrInvalid in new[] { "Azure", "Portabel" })
{
    var invalidProvider = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        { ["Infrastructure:Provider"] = retiredOrInvalid }).Build();
    try { InfrastructureProvider.Resolve(invalidProvider); throw new Exception("Retired or unknown provider accepted."); }
    catch (InvalidOperationException) { }
}
await RabbitMqRegression.RunAsync();

// Requires explicit opt-in. All writes go to a fresh database generated here;
// the supplied database is used only to create/drop that disposable database.
var adminString = Environment.GetEnvironmentVariable("GATEWAY_TEST_DB");
if (string.IsNullOrWhiteSpace(adminString))
{
    Console.WriteLine("Provider checks passed; PostgreSQL checks skipped (set GATEWAY_TEST_DB).");
    return;
}
var name = "gateway_audit_" + Guid.NewGuid().ToString("N");
await using var admin = new NpgsqlConnection(adminString);
await admin.OpenAsync();
await using (var create = new NpgsqlCommand($"CREATE DATABASE \"{name}\"", admin)) await create.ExecuteNonQueryAsync();
var connectionString = new NpgsqlConnectionStringBuilder(adminString) { Database = name, Pooling = false }.ConnectionString;
GatewayDbContext Context() => new(new DbContextOptionsBuilder<GatewayDbContext>()
    .UseNpgsql(connectionString).AddInterceptors(new PostgresRowVersionInterceptor()).Options);
try
{
    var services = new ServiceCollection();
    services.AddDbContext<GatewayDbContext>(o => o.UseNpgsql(connectionString).AddInterceptors(new PostgresRowVersionInterceptor()));
    await using var provider = services.BuildServiceProvider();
    var initializer = new RuntimeSchemaInitializer(provider.GetRequiredService<IServiceScopeFactory>(), NullLogger<RuntimeSchemaInitializer>.Instance);
    await Task.WhenAll(initializer.StartAsync(default), initializer.StartAsync(default));
    await initializer.StartAsync(default);
    await using var db = Context();
    // Joining a feature-update transaction must serialize the same key without
    // committing or disposing the caller's transaction.
    var scopeAgent = Guid.NewGuid();
    await using (var transaction = await db.Database.BeginTransactionAsync())
    {
        await using var lease = await new IdempotencyService(db)
            .AcquireScopeInExistingTransactionAsync(scopeAgent, "features", "joined", default);
        await lease.CompleteAsync(default);
        Check(db.Database.CurrentTransaction == transaction, "Joined lease committed the caller's transaction.");
        await using var contender = Context();
        using var deadline = new CancellationTokenSource(TimeSpan.FromMilliseconds(300));
        try
        {
            await using var competingLease = await new IdempotencyService(contender)
                .AcquireScopeAsync(scopeAgent, "features", "joined", deadline.Token);
            throw new Exception("A second context bypassed the transaction-scoped idempotency lock.");
        }
        catch (OperationCanceledException) when (deadline.IsCancellationRequested) { }
        await transaction.RollbackAsync();
    }
    await using (var released = await new IdempotencyService(db).AcquireScopeAsync(scopeAgent, "features", "joined", default))
        await released.CompleteAsync(default);
    await CheckSchemaAsync(db);
    db.AgentPolicyAssignments.Add(new() { Id = Guid.NewGuid(), AgentRegistrationId = Guid.NewGuid(), CreatedAtUtc = DateTime.UtcNow, ExpiresAtUtc = DateTime.UtcNow.AddMinutes(10) });
    try { await db.SaveChangesAsync(); throw new Exception("Orphan assignment accepted."); }
    catch (DbUpdateException e) when (e.InnerException is PostgresException { SqlState: "23503" }) { db.ChangeTracker.Clear(); }

    // Distinct contexts and process stores deliberately share no in-memory gate.
    await db.SystemConfigurations.ExecuteUpdateAsync(s => s.SetProperty(x => x.RateLimitPerClient, 7));
    var registration = Guid.NewGuid(); var credential = Guid.NewGuid();
    var decisions = await Task.WhenAll(Enumerable.Range(0, 24).Select(async _ => {
        await using var context = Context();
        return await new SqlIngressRateLimiter(context, new IngressRateLimitProcessStore()).TryAcquireAsync(registration, credential, default);
    }));
    Check(decisions.Count(x => x.Allowed) == 7, "Replica-shared credential limit exceeded.");
    Check(decisions.Where(x => !x.Allowed).All(x => x.Scope == "credential" && x.Remaining == 0), "Wrong denial scope.");
    await db.SystemConfigurations.ExecuteUpdateAsync(s => s.SetProperty(x => x.RateLimitPerClient, 100).SetProperty(x => x.RateLimitPerAgent, 5));
    var secondRegistration = Guid.NewGuid();
    var agentDecisions = await Task.WhenAll(Enumerable.Range(0, 12).Select(async _ => {
        await using var context = Context();
        return await new SqlIngressRateLimiter(context, new IngressRateLimitProcessStore()).TryAcquireAsync(secondRegistration, Guid.NewGuid(), default);
    }));
    Check(agentDecisions.Count(x => x.Allowed) == 5, "Registration limit did not span credentials.");
    await db.SystemConfigurations.ExecuteUpdateAsync(s => s.SetProperty(x => x.RateLimitGlobal, 12));
    await using (var globalContext = Context())
        Check(!(await new SqlIngressRateLimiter(globalContext, new()).TryAcquireAsync(Guid.NewGuid(), Guid.NewGuid(), default)).Allowed, "Global count lost denied-request accounting.");

    var now = DateTime.UtcNow;
    var leaseTime = now.AddMinutes(2);
    for (var i = 0; i < 40; i++) db.OutboxMessages.Add(new() { Id = Guid.NewGuid(), MessageType = "ProcessActivity", Payload = "{}", Status = OutboxMessageStatus.Pending, CreatedAtUtc = now });
    await db.SaveChangesAsync();
    var batches = await Task.WhenAll(Enumerable.Range(0, 8).Select(async _ => {
        await using var context = Context();
        return await new OutboxRepository(context).ClaimPendingAsync(5, now, leaseTime, default);
    }));
    var claimed = batches.SelectMany(x => x).ToArray();
    Check(claimed.Length == 40 && claimed.Select(x => x.Id).Distinct().Count() == 40, "Outbox replicas claimed duplicate or missing messages.");
    leaseTime = claimed[0].NextRetryAtUtc!.Value; // Use the persisted PostgreSQL microsecond precision, as the relay does.
    await using (var context = Context())
    {
        var repository = new OutboxRepository(context);
        Check(!await repository.MarkPublishedAsync(claimed[0].Id, leaseTime.AddSeconds(1), now, default), "Stale publisher lease accepted.");
        Check(await repository.MarkPublishedAsync(claimed[0].Id, leaseTime, now, default), "Claim owner could not publish.");
        Check(await repository.MarkFailedAsync(claimed[1].Id, leaseTime, null, true, default), "Terminal failure not persisted.");
        Check((await repository.ClaimPendingAsync(50, now, leaseTime, default)).Count == 0, "Unexpired leases reclaimed.");
        Check((await repository.ClaimPendingAsync(50, leaseTime.AddSeconds(1), leaseTime.AddMinutes(2), default)).Count == 38, "Expired leases not recovered.");
    }
    var receiptAgent = new AgentRegistration {
        Id = Guid.NewGuid(), ExternalAgentId = new ExternalAgentId("receipt-audit"), Name = "Receipt audit",
        OwnerObjectId = Guid.NewGuid().ToString(), Status = AgentStatus.Active,
        Agent365AgentId = Guid.NewGuid().ToString(), BlueprintId = Guid.NewGuid().ToString(),
        CreatedAtUtc = DateTime.UtcNow, UpdatedAtUtc = DateTime.UtcNow,
        FeatureConfiguration = new AgentFeatureConfiguration { PromptShieldEnabled = false, PurviewEnabled = false }
    };
    receiptAgent.FeatureConfiguration.AgentRegistrationId = receiptAgent.Id;
    db.AgentRegistrations.Add(receiptAgent);
    await db.SaveChangesAsync();
    await using (var receiptTx = await db.Database.BeginTransactionAsync(System.Data.IsolationLevel.Serializable))
    {
        var receipts = new PromptEvaluationRepository(db);
        var protection = await receipts.GetProtectionContextAsync(receiptAgent.Id, default)
            ?? throw new Exception("Fresh receipt context unavailable.");
        Check(await receipts.IsProtectionContextCurrentAsync(protection, default), "Current receipt context rejected.");
        Check(!await receipts.IsProtectionContextCurrentAsync(protection with { Hash = new string('0', 64) }, default), "Stale receipt context accepted.");
        var receipt = new PromptEvaluationRecord {
            Id = Guid.NewGuid(), AgentRegistrationId = receiptAgent.Id,
            Agent365AgentId = Guid.Parse(receiptAgent.Agent365AgentId), BlueprintId = Guid.Parse(receiptAgent.BlueprintId),
            ExternalInteractionId = Guid.NewGuid().ToString(), TenantUserObjectId = Guid.NewGuid().ToString(),
            PromptHashSalt = new byte[32], PromptHash = new byte[32], Outcome = PromptEvaluationOutcome.Allowed,
            PromptShieldDecision = PromptShieldDecisionType.Allowed, PurviewDecision = PurviewDecisionType.PurviewDisabled,
            ProtectionRevision = protection.ProtectionRevision, ProtectionContextHash = protection.Hash,
            PromptShieldRequired = protection.PromptShieldRequired, EvaluatedPurviewPolicyMode = protection.PurviewMode,
            CorrelationId = Guid.NewGuid().ToString(), CreatedAtUtc = DateTime.UtcNow, ExpiresAtUtc = DateTime.UtcNow.AddMinutes(2)
        };
        await receipts.AddAsync(receipt, default); await db.SaveChangesAsync();
        Check(await receipts.TryConsumeAsync(receipt, protection, default), "First receipt consumption failed.");
        Check(!await receipts.TryConsumeAsync(receipt, protection, default), "Receipt consumed twice.");
        await receiptTx.RollbackAsync();
    }
    Console.WriteLine("PostgreSQL schema/model parity, concurrent initialization, orphan rejection, replica-shared rate limits, atomic outbox claims, stale leases, recovery, idempotency and receipt transactions passed.");

    if (Environment.GetEnvironmentVariable("GATEWAY_SCHEMA_AUDIT_DB") is { Length: > 0 } auditConnection)
    {
        await using var live = new GatewayDbContext(new DbContextOptionsBuilder<GatewayDbContext>().UseNpgsql(auditConnection).Options);
        await CheckSchemaAsync(live);
        Console.WriteLine("Existing PostgreSQL database: read-only schema/model parity and registration-reference orphan checks passed.");
    }
}
finally
{
    // name is generated locally above, never taken from configuration or arguments.
    await using var drop = new NpgsqlCommand($"DROP DATABASE \"{name}\" WITH (FORCE)", admin);
    await drop.ExecuteNonQueryAsync();
}

static async Task CheckSchemaAsync(GatewayDbContext db)
{
    var model = db.GetService<IDesignTimeModel>().Model.GetRelationalModel();
    await db.Database.OpenConnectionAsync();
    try
    {
        await using var command = db.Database.GetDbConnection().CreateCommand();
        command.CommandText = "SELECT table_name, column_name, is_nullable FROM information_schema.columns WHERE table_schema='public'";
        var actual = new Dictionary<(string, string), bool>();
        await using (var reader = await command.ExecuteReaderAsync())
            while (await reader.ReadAsync()) actual.Add((reader.GetString(0), reader.GetString(1)), reader.GetString(2) == "YES");
        var expected = model.Tables.SelectMany(t => t.Columns.Select(c => ((t.Name, c.Name), c.IsNullable))).ToDictionary(x => x.Item1, x => x.IsNullable);
        Check(expected.Count == actual.Count && expected.All(x => actual.TryGetValue(x.Key, out var nullable) && nullable == x.Value), "Database columns/nullability differ from the EF model.");
        command.CommandText = "SELECT c.relname, a.attname, format_type(a.atttypid,a.atttypmod) FROM pg_attribute a JOIN pg_class c ON a.attrelid=c.oid JOIN pg_namespace n ON c.relnamespace=n.oid WHERE n.nspname='public' AND c.relkind='r' AND a.attnum>0 AND NOT a.attisdropped";
        var actualTypes = new Dictionary<(string, string), string>();
        await using (var reader = await command.ExecuteReaderAsync())
            while (await reader.ReadAsync()) actualTypes[(reader.GetString(0), reader.GetString(1))] = reader.GetString(2);
        foreach (var table in model.Tables)
            foreach (var column in table.Columns)
                Check(NormalizeType(column.StoreType) == NormalizeType(actualTypes[(table.Name, column.Name)]), $"Column type differs: {table.Name}.{column.Name}");
        command.CommandText = "SELECT tablename,indexname FROM pg_indexes WHERE schemaname='public'";
        var indexes = new HashSet<(string, string)>();
        await using (var reader = await command.ExecuteReaderAsync())
            while (await reader.ReadAsync()) indexes.Add((reader.GetString(0), reader.GetString(1)));
        foreach (var table in model.Tables)
            foreach (var index in table.Indexes) Check(indexes.Contains((table.Name, index.Name)), $"Missing index {index.Name}");
        command.CommandText = "SELECT conname FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname='public'";
        var constraints = new HashSet<string>();
        await using (var reader = await command.ExecuteReaderAsync()) while (await reader.ReadAsync()) constraints.Add(reader.GetString(0));
        foreach (var table in model.Tables)
        {
            foreach (var constraint in table.ForeignKeyConstraints)
                Check(constraints.Contains(constraint.Name), $"Missing FK {constraint.Name}");
            foreach (var constraint in table.CheckConstraints) Check(constraints.Contains(constraint.Name!), $"Missing check {constraint.Name}");
            if (table.Columns.Any(c => c.Name == "AgentRegistrationId"))
            {
                command.CommandText = $"SELECT count(*) FROM \"{table.Name}\" child LEFT JOIN \"AgentRegistrations\" parent ON parent.\"Id\"=child.\"AgentRegistrationId\" WHERE child.\"AgentRegistrationId\" IS NOT NULL AND parent.\"Id\" IS NULL";
                Check(Convert.ToInt64(await command.ExecuteScalarAsync()) == 0, $"Orphan registration references in {table.Name}.");
            }
        }
        Console.WriteLine($"Schema checked: {model.Tables.Count()} tables, {expected.Count} columns, {constraints.Count} constraints.");
    }
    finally { await db.Database.CloseConnectionAsync(); }
}

static string NormalizeType(string type) => type.ToLowerInvariant()
    .Replace("character varying", "varchar").Replace("timestamp(7)", "timestamp")
    .Replace("timestamp(6)", "timestamp");
