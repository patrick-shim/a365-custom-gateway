using System.Data;
using System.Security.Cryptography;
using System.Text.Json;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence;
using Gateway.Purview;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Infrastructure;

/// <summary>
/// Dispatches durable connector operations over the authenticated filesystem
/// transport and accepts provider evidence into PostgreSQL. The provider is
/// never called by an HTTP request or by this process.
/// </summary>
internal sealed class PurviewConnectorDispatcher(
    IServiceScopeFactory scopes,
    IOptions<PurviewConnectorOptions> connectorOptions,
    TimeProvider timeProvider,
    ILogger<PurviewConnectorDispatcher> logger) : BackgroundService
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);
    internal static readonly TimeSpan HeartbeatStaleAfter = TimeSpan.FromSeconds(30);
    // The Windows listener bounds a provider child to six minutes. Keep a
    // longer terminal grace window so a child that was already running when
    // the API recorded a timeout can still publish authenticated evidence for
    // cleanup, without reopening the terminal operation or accepting a catalog.
    private static readonly TimeSpan TerminalTransportGracePeriod = TimeSpan.FromMinutes(10);
    private readonly PurviewConnectorOptions _options = connectorOptions.Value;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!IsConfigured(_options))
        {
            logger.LogInformation("Purview connector dispatcher is inactive because bootstrap-owned connector settings are unavailable.");
            return;
        }

        try
        {
            _ = Convert.FromBase64String(_options.AuthenticationKey) is { Length: 32 } key
                ? key
                : throw new CryptographicException();
            Directory.CreateDirectory(Path.GetFullPath(_options.QueueDirectory));
        }
        catch (Exception failure) when (failure is FormatException or CryptographicException or IOException or UnauthorizedAccessException)
        {
            logger.LogError("Purview connector dispatcher configuration is invalid ({FailureType}).", failure.GetType().Name);
            return;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await ProcessHeartbeatAsync(stoppingToken);
                var commands = await ProcessDurableStateAsync(stoppingToken);
                foreach (var operation in commands)
                    await EnsureCommandPublishedAsync(operation, stoppingToken);
                await CleanupAcceptedTransportAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception failure)
            {
                logger.LogWarning(
                    "Purview connector reconciliation is temporarily unavailable ({FailureType}); no success was inferred.",
                    failure.GetType().Name);
            }

            try { await Task.Delay(PollInterval, stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
        }
    }

    private async Task ProcessHeartbeatAsync(CancellationToken cancellationToken)
    {
        var path = Path.Combine(
            Path.GetFullPath(_options.QueueDirectory),
            $"{_options.ConnectorInstanceId:D}.heartbeat.json");
        if (!File.Exists(path))
            return;

        try
        {
            var info = new FileInfo(path);
            if (info.Length is <= 0 or > PurviewConnectorProtocol.MaximumHeartbeatEnvelopeBytes)
                throw new InvalidDataException();
            var heartbeat = PurviewConnectorProtocol.Verify<PurviewConnectorHeartbeat>(
                await File.ReadAllTextAsync(path, cancellationToken),
                _options.AuthenticationKey,
                PurviewConnectorProtocol.HeartbeatDomain);
            var now = UtcNow();
            PurviewConnectorProtocol.ValidateHeartbeat(
                heartbeat,
                _options.TenantId,
                _options.ConnectorInstanceId,
                now);

            await using var scope = scopes.CreateAsyncScope();
            var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
            // A heartbeat is liveness evidence, not a management mutation. Keep it
            // outside the connector row-version token so an administrator can act
            // on a freshly reviewed connection while heartbeats continue.
            await db.PurviewConnectorStates
                .Where(state => state.TenantId == _options.TenantId &&
                    state.ConnectorInstanceId == _options.ConnectorInstanceId &&
                    (state.LastHeartbeatAtUtc == null || state.LastHeartbeatAtUtc < heartbeat.ObservedAtUtc))
                .ExecuteUpdateAsync(setters => setters
                    .SetProperty(state => state.LastHeartbeatAtUtc, heartbeat.ObservedAtUtc), cancellationToken);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or
            CryptographicException or JsonException or InvalidDataException or InvalidOperationException or
            FormatException or PurviewPolicyException)
        {
            logger.LogWarning(
                "Invalid, stale, or unauthenticated Purview connector heartbeat ignored ({FailureType}).",
                failure.GetType().Name);
        }
    }

    private async Task<List<PurviewConnectorOperation>> ProcessDurableStateAsync(
        CancellationToken cancellationToken)
    {
        await using var scope = scopes.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        await using var transaction = await db.Database.BeginTransactionAsync(IsolationLevel.Serializable, cancellationToken);
        if (PostgresAdvisoryLock.IsNpgsql(db))
        {
            var (key1, key2) = PostgresAdvisoryLock.ToKeyPair(
                $"a365gw:purview-connector:{_options.TenantId:D}");
            await db.Database.ExecuteSqlInterpolatedAsync(
                $"SELECT pg_advisory_xact_lock({key1}, {key2})", cancellationToken);
        }

        var now = UtcNow();
        var state = await db.PurviewConnectorStates
            .SingleOrDefaultAsync(item => item.TenantId == _options.TenantId, cancellationToken);
        if (state is null)
            state = await TryImportBootstrapCatalogAsync(scope.ServiceProvider, db, now, cancellationToken);

        var commands = new List<PurviewConnectorOperation>();
        var running = await db.PurviewConnectorOperations
            .Where(operation => operation.TenantId == _options.TenantId &&
                operation.Status == PurviewConnectorOperationStatus.Running)
            .OrderBy(operation => operation.CreatedAtUtc)
            .Take(20)
            .ToListAsync(cancellationToken);
        foreach (var operation in running)
        {
            state ??= await db.PurviewConnectorStates
                .SingleAsync(item => item.TenantId == _options.TenantId, cancellationToken);
            var resultPath = ResultPath(operation.Id);
            if (File.Exists(resultPath))
                await AcceptResultAsync(db, state, operation, resultPath, now, cancellationToken);
            else if (operation.ExpiresAtUtc <= now)
                await CompleteFailureAsync(
                    db, state, operation, PurviewConnectorOperationStatus.TimedOut,
                    ErrorCodes.PURVIEW_CONNECTOR_TIMED_OUT, now, cancellationToken);
            else if (RequiresCommandPublication(operation, resultExists: false, now))
                // Covers the crash window after Running was committed but before
                // the command file was atomically published. Publication is
                // idempotent and verifies an existing file before accepting it.
                commands.Add(operation);
        }

        if (state is not null)
            await ReconcileHeartbeatAvailabilityAsync(db, state, now, cancellationToken);

        await ReconcileTerminalTransportAsync(db, now, cancellationToken);
        await SweepTransportArrivingAfterCleanupAsync(db, now, cancellationToken);

        var hasRunning = await db.PurviewConnectorOperations.AnyAsync(operation =>
            operation.TenantId == _options.TenantId &&
            operation.Status == PurviewConnectorOperationStatus.Running, cancellationToken);
        if (!hasRunning)
        {
            var pending = await db.PurviewConnectorOperations
                .Where(operation => operation.TenantId == _options.TenantId &&
                    operation.Status == PurviewConnectorOperationStatus.Pending)
                .OrderBy(operation => operation.CreatedAtUtc)
                .FirstOrDefaultAsync(cancellationToken);
            if (pending is not null)
            {
                state ??= await db.PurviewConnectorStates
                    .SingleAsync(item => item.TenantId == _options.TenantId, cancellationToken);
                if (pending.ExpiresAtUtc <= now)
                {
                    await CompleteFailureAsync(
                        db, state, pending, PurviewConnectorOperationStatus.TimedOut,
                        ErrorCodes.PURVIEW_CONNECTOR_TIMED_OUT, now, cancellationToken);
                }
                else
                {
                    pending.Status = PurviewConnectorOperationStatus.Running;
                    pending.CurrentStep = pending.Type == PurviewConnectorOperationType.Connect
                        ? "VerifyingConnection"
                        : "RefreshingCatalog";
                    pending.PercentComplete = 20;
                    pending.IssuedAtUtc = CanonicalizeTransportTimestamp(now);
                    pending.StartedAtUtc ??= now;
                    pending.LeaseExpiresAtUtc = now.AddSeconds(30);
                    pending.AttemptCount++;
                    pending.RowVersion = NewRowVersion();
                    state.UpdatedAtUtc = now;
                    state.RowVersion = NewRowVersion();
                    if (commands.All(existing => existing.Id != pending.Id))
                        commands.Add(pending);
                }
            }
        }

        await db.SaveChangesAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        return commands;
    }

    private static async Task ReconcileHeartbeatAvailabilityAsync(
        GatewayDbContext db,
        PurviewConnectorStateRecord state,
        DateTime now,
        CancellationToken cancellationToken)
    {
        if (state.State is PurviewConnectorState.Connecting or PurviewConnectorState.Refreshing)
            return;

        var hasAcceptedCatalog = await db.PurviewCatalogSnapshots.AnyAsync(snapshot =>
            snapshot.TenantId == state.TenantId &&
            snapshot.ConnectorInstanceId == state.ConnectorInstanceId,
            cancellationToken);
        var transition = ReconcileHeartbeatAvailability(state, hasAcceptedCatalog, now);
        if (transition is null)
            return;

        state.UpdatedAtUtc = now;
        state.RowVersion = NewRowVersion();
        db.AuditEvents.Add(new AuditEvent
        {
            Id = Guid.NewGuid(),
            EventType = transition,
            PerformedByObjectId = "system",
            PerformedByRole = "System",
            Details = $"ConnectorInstanceId={state.ConnectorInstanceId:D}; State={state.State}; LastHeartbeatAtUtc={state.LastHeartbeatAtUtc:O}",
            CorrelationId = state.LastCorrelationId,
            OccurredAtUtc = now
        });
    }

    internal static string? ReconcileHeartbeatAvailability(
        PurviewConnectorStateRecord state,
        bool hasAcceptedCatalog,
        DateTime utcNow)
    {
        // Bootstrap may import its verified catalog before the listener writes
        // the first heartbeat. Give that fresh record one normal heartbeat
        // window; once a heartbeat exists it is the only liveness timestamp and
        // a later state update cannot hide a stale listener.
        var livenessObservedAt = state.LastHeartbeatAtUtc ??
            (state.UpdatedAtUtc >= state.CreatedAtUtc ? state.UpdatedAtUtc : state.CreatedAtUtc);
        var heartbeatCurrent =
            livenessObservedAt >= utcNow.Subtract(HeartbeatStaleAfter) &&
            livenessObservedAt <= utcNow.AddMinutes(1);

        if (!heartbeatCurrent && state.State is PurviewConnectorState.Connected or PurviewConnectorState.NotConfigured)
        {
            state.State = hasAcceptedCatalog
                ? PurviewConnectorState.Degraded
                : PurviewConnectorState.Disconnected;
            state.LastFailureCode = ErrorCodes.PURVIEW_CONNECTOR_UNAVAILABLE;
            return "PurviewConnectorLivenessLost";
        }

        if (heartbeatCurrent &&
            string.Equals(state.LastFailureCode, ErrorCodes.PURVIEW_CONNECTOR_UNAVAILABLE, StringComparison.Ordinal) &&
            state.State is PurviewConnectorState.Degraded or PurviewConnectorState.Disconnected)
        {
            state.State = hasAcceptedCatalog
                ? PurviewConnectorState.Connected
                : PurviewConnectorState.NotConfigured;
            state.LastFailureCode = null;
            return "PurviewConnectorLivenessRestored";
        }

        return null;
    }

    private async Task ReconcileTerminalTransportAsync(
        GatewayDbContext db,
        DateTime now,
        CancellationToken cancellationToken)
    {
        var terminal = await db.PurviewConnectorOperations
            .Where(operation => operation.TenantId == _options.TenantId &&
                operation.ConnectorInstanceId == _options.ConnectorInstanceId &&
                operation.TransportCleanedAtUtc == null &&
                operation.ResultHash == null &&
                operation.ExpiresAtUtc <= now &&
                (operation.Status == PurviewConnectorOperationStatus.Succeeded ||
                 operation.Status == PurviewConnectorOperationStatus.Failed ||
                 operation.Status == PurviewConnectorOperationStatus.NeedsAttention ||
                 operation.Status == PurviewConnectorOperationStatus.TimedOut ||
                 operation.Status == PurviewConnectorOperationStatus.Cancelled))
            .OrderBy(operation => operation.ExpiresAtUtc)
            .Take(100)
            .ToListAsync(cancellationToken);

        foreach (var operation in terminal)
        {
            var commandPath = CommandPath(operation.Id);
            var resultPath = ResultPath(operation.Id);
            var graceElapsed = TerminalTransportGraceElapsed(operation, now);

            if (File.Exists(resultPath))
            {
                try
                {
                    if (new FileInfo(resultPath).Length is <= 0 or > PurviewConnectorProtocol.MaximumResultEnvelopeBytes)
                        throw new InvalidDataException("Late connector result exceeds its size bound.");
                    var result = PurviewConnectorProtocol.Verify<PurviewConnectorResult>(
                        await File.ReadAllTextAsync(resultPath, cancellationToken),
                        _options.AuthenticationKey,
                        PurviewConnectorProtocol.ResultDomain);
                    var command = CreateCommand(operation);
                    PurviewConnectorProtocol.ValidateResult(
                        result, command, _options.TenantId, _options.ConnectorInstanceId, now);

                    // The durable operation is already terminal. Retain only a
                    // digest proving which authenticated late result was seen;
                    // never accept its catalog or change the terminal outcome.
                    operation.ResultHash = PurviewConnectorProtocol.Digest(result);
                    operation.RowVersion = NewRowVersion();
                    db.AuditEvents.Add(new AuditEvent
                    {
                        Id = Guid.NewGuid(),
                        EventType = "PurviewConnectorLateResultObserved",
                        PerformedByObjectId = "system",
                        PerformedByRole = "System",
                        Details = $"OperationId={operation.Id:D}; ConnectorInstanceId={operation.ConnectorInstanceId:D}; Generation={operation.Generation}; TerminalStatus={operation.Status}",
                        CorrelationId = operation.CorrelationId,
                        OccurredAtUtc = now
                    });
                    continue;
                }
                catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or
                    CryptographicException or JsonException or InvalidDataException or InvalidOperationException or
                    FormatException or PurviewPolicyException)
                {
                    logger.LogWarning(
                        "Late Purview connector result for terminal operation {OperationId} was rejected ({FailureType}).",
                        operation.Id,
                        failure.GetType().Name);
                    if (graceElapsed)
                        TryDeleteOwnedTransportFile(resultPath, operation.Id, "result");
                }
            }

            if (File.Exists(commandPath))
            {
                try
                {
                    if (new FileInfo(commandPath).Length is <= 0 or > PurviewConnectorProtocol.MaximumCommandEnvelopeBytes)
                        throw new InvalidDataException("Expired connector command exceeds its size bound.");
                    var storedCommand = PurviewConnectorProtocol.Verify<PurviewConnectorCommand>(
                        await File.ReadAllTextAsync(commandPath, cancellationToken),
                        _options.AuthenticationKey,
                        PurviewConnectorProtocol.CommandDomain);
                    if (!CommandMatchesOperation(storedCommand, operation))
                        throw new InvalidDataException("Expired connector command binding mismatch.");
                    // Preserve the authenticated command through the same grace
                    // period as a possible in-flight host child. An expired
                    // command cannot be newly accepted by the listener, and this
                    // avoids racing a command it already opened before expiry.
                    if (graceElapsed)
                        File.Delete(commandPath);
                }
                catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or
                    CryptographicException or JsonException or InvalidDataException or InvalidOperationException or FormatException)
                {
                    logger.LogWarning(
                        "Expired Purview connector command for terminal operation {OperationId} was retained ({FailureType}).",
                        operation.Id,
                        failure.GetType().Name);
                    if (graceElapsed)
                        TryDeleteOwnedTransportFile(commandPath, operation.Id, "command");
                }
            }

            if (operation.ResultHash is null && graceElapsed &&
                !File.Exists(commandPath) && !File.Exists(resultPath))
            {
                operation.TransportCleanedAtUtc = now;
                operation.RowVersion = NewRowVersion();
            }
        }
    }

    private async Task SweepTransportArrivingAfterCleanupAsync(
        GatewayDbContext db,
        DateTime now,
        CancellationToken cancellationToken)
    {
        var candidates = EnumerateTransportCandidates("*.result.json", ".result.json", 100)
            .Concat(EnumerateTransportCandidates("*.command.json", ".command.json", 100))
            .ToArray();
        if (candidates.Length == 0)
            return;

        var operationIds = candidates.Select(candidate => candidate.OperationId).Distinct().ToArray();
        var cleaned = await db.PurviewConnectorOperations
            .Where(operation => operation.TenantId == _options.TenantId &&
                operation.ConnectorInstanceId == _options.ConnectorInstanceId &&
                operation.TransportCleanedAtUtc != null &&
                operationIds.Contains(operation.Id) &&
                (operation.Status == PurviewConnectorOperationStatus.Succeeded ||
                 operation.Status == PurviewConnectorOperationStatus.Failed ||
                 operation.Status == PurviewConnectorOperationStatus.NeedsAttention ||
                 operation.Status == PurviewConnectorOperationStatus.TimedOut ||
                 operation.Status == PurviewConnectorOperationStatus.Cancelled))
            .ToDictionaryAsync(operation => operation.Id, cancellationToken);

        foreach (var candidate in candidates)
        {
            if (!cleaned.TryGetValue(candidate.OperationId, out var operation))
                continue;
            try
            {
                var command = CreateCommand(operation);
                if (candidate.Kind == "result")
                {
                    if (new FileInfo(candidate.Path).Length is <= 0 or > PurviewConnectorProtocol.MaximumResultEnvelopeBytes)
                        throw new InvalidDataException("Late connector result exceeds its size bound.");
                    var result = PurviewConnectorProtocol.Verify<PurviewConnectorResult>(
                        await File.ReadAllTextAsync(candidate.Path, cancellationToken),
                        _options.AuthenticationKey,
                        PurviewConnectorProtocol.ResultDomain);
                    PurviewConnectorProtocol.ValidateResult(
                        result, command, _options.TenantId, _options.ConnectorInstanceId, now);
                    if (operation.ResultHash is null)
                    {
                        operation.ResultHash = PurviewConnectorProtocol.Digest(result);
                        operation.RowVersion = NewRowVersion();
                        db.AuditEvents.Add(new AuditEvent
                        {
                            Id = Guid.NewGuid(),
                            EventType = "PurviewConnectorLateResultObserved",
                            PerformedByObjectId = "system",
                            PerformedByRole = "System",
                            Details = $"OperationId={operation.Id:D}; ConnectorInstanceId={operation.ConnectorInstanceId:D}; Generation={operation.Generation}; TerminalStatus={operation.Status}",
                            CorrelationId = operation.CorrelationId,
                            OccurredAtUtc = now
                        });
                    }
                }
                else
                {
                    if (new FileInfo(candidate.Path).Length is <= 0 or > PurviewConnectorProtocol.MaximumCommandEnvelopeBytes)
                        throw new InvalidDataException("Late connector command exceeds its size bound.");
                    var storedCommand = PurviewConnectorProtocol.Verify<PurviewConnectorCommand>(
                        await File.ReadAllTextAsync(candidate.Path, cancellationToken),
                        _options.AuthenticationKey,
                        PurviewConnectorProtocol.CommandDomain);
                    if (!CommandMatchesOperation(storedCommand, operation))
                        throw new InvalidDataException("Late connector command binding mismatch.");
                }
                File.Delete(candidate.Path);
            }
            catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or
                CryptographicException or JsonException or InvalidDataException or InvalidOperationException or
                FormatException or PurviewPolicyException)
            {
                logger.LogWarning(
                    "Purview connector {Kind} arriving after terminal cleanup for operation {OperationId} was rejected ({FailureType}).",
                    candidate.Kind,
                    operation.Id,
                    failure.GetType().Name);
                // The exact path belongs to an already terminal, already-cleaned
                // durable operation. An invalid file cannot be provider evidence
                // and must not pin local transport retention indefinitely.
                TryDeleteOwnedTransportFile(candidate.Path, operation.Id, candidate.Kind);
            }
        }
    }

    private IEnumerable<(Guid OperationId, string Path, string Kind)> EnumerateTransportCandidates(
        string searchPattern,
        string suffix,
        int maximum)
    {
        foreach (var path in Directory.EnumerateFiles(
                     Path.GetFullPath(_options.QueueDirectory), searchPattern)
                 .Order(StringComparer.Ordinal)
                 .Take(maximum))
        {
            var fileName = Path.GetFileName(path);
            var idText = fileName[..^suffix.Length];
            if (Guid.TryParseExact(idText, "D", out var operationId) &&
                string.Equals(fileName, $"{operationId:D}{suffix}", StringComparison.Ordinal))
                yield return (operationId, path, suffix == ".result.json" ? "result" : "command");
        }
    }

    private void TryDeleteOwnedTransportFile(string path, Guid operationId, string kind)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException)
        {
            logger.LogWarning(
                "Invalid Purview connector {Kind} for terminal operation {OperationId} could not be removed ({FailureType}).",
                kind,
                operationId,
                failure.GetType().Name);
        }
    }

    internal static bool TerminalTransportGraceElapsed(
        PurviewConnectorOperation operation,
        DateTime utcNow) =>
        (operation.Status is PurviewConnectorOperationStatus.Succeeded or
            PurviewConnectorOperationStatus.Failed or
            PurviewConnectorOperationStatus.NeedsAttention or
            PurviewConnectorOperationStatus.TimedOut or
            PurviewConnectorOperationStatus.Cancelled) &&
        operation.ResultHash is null &&
        operation.TransportCleanedAtUtc is null &&
        operation.ExpiresAtUtc.Add(TerminalTransportGracePeriod) <= utcNow;

    private async Task<PurviewConnectorStateRecord?> TryImportBootstrapCatalogAsync(
        IServiceProvider services,
        GatewayDbContext db,
        DateTime now,
        CancellationToken cancellationToken)
    {
        PurviewPolicyCatalog catalog;
        try
        {
            // RuntimePurviewCatalogClient verifies the bootstrap X509 signature,
            // tenant binding, schema, uniqueness, and canonical revisions. It only
            // reads the already-published file and never invokes the provider.
            catalog = await services.GetRequiredService<IPurviewPolicyCatalogClient>()
                .ReadAsync(_options.TenantId, cancellationToken);
        }
        catch (PurviewPolicyException)
        {
            return null;
        }

        PurviewPolicyCatalogValidation.Validate(catalog, _options.TenantId);
        PurviewPolicyCatalogValidation.EnsureFreshForManagement(catalog);
        var catalogHash = PurviewConnectorProtocol.Digest(catalog);
        var operationId = Guid.NewGuid();
        var counts = CountPolicies(catalog);
        var generation = 1L;
        var operation = new PurviewConnectorOperation
        {
            Id = operationId,
            TenantId = _options.TenantId,
            ConnectorInstanceId = _options.ConnectorInstanceId,
            Type = PurviewConnectorOperationType.Connect,
            Status = PurviewConnectorOperationStatus.Succeeded,
            CurrentStep = "BootstrapCatalogAccepted",
            PercentComplete = 100,
            Generation = generation,
            IdempotencyKey = operationId.ToString("D"),
            RequestHash = catalogHash,
            RequestedByObjectId = "bootstrap",
            CorrelationId = "bootstrap-catalog-import",
            IssuedAtUtc = now,
            ExpiresAtUtc = now,
            AttemptCount = 1,
            StartedAtUtc = now,
            CompletedAtUtc = now,
            ResultHash = catalogHash,
            CatalogHash = catalogHash,
            CreatedAtUtc = now,
            RowVersion = NewRowVersion()
        };
        var state = new PurviewConnectorStateRecord
        {
            Id = Guid.NewGuid(),
            TenantId = _options.TenantId,
            ConnectorInstanceId = _options.ConnectorInstanceId,
            ConnectorProfile = "LocalWindows",
            State = PurviewConnectorState.Connected,
            RefreshMode = "Manual",
            NextGeneration = generation + 1,
            LastSuccessfulRefreshAtUtc = catalog.RetrievedAtUtc.UtcDateTime,
            CatalogRetrievedAtUtc = catalog.RetrievedAtUtc.UtcDateTime,
            PolicyCount = counts.PolicyCount,
            CompatiblePolicyCount = counts.CompatibleCount,
            IncompatiblePolicyCount = counts.IncompatibleCount,
            CatalogVerificationStatus = "Verified",
            LastCorrelationId = operation.CorrelationId,
            CreatedAtUtc = now,
            UpdatedAtUtc = now,
            RowVersion = NewRowVersion()
        };
        db.PurviewConnectorOperations.Add(operation);
        db.PurviewConnectorStates.Add(state);
        db.PurviewCatalogSnapshots.Add(CreateSnapshot(catalog, catalogHash, operation, counts, now));
        db.AuditEvents.Add(new AuditEvent
        {
            Id = Guid.NewGuid(),
            EventType = "PurviewBootstrapCatalogAccepted",
            PerformedByObjectId = "bootstrap",
            PerformedByRole = "System",
            Details = $"OperationId={operationId:D}; ConnectorInstanceId={_options.ConnectorInstanceId:D}; Generation={generation}; CatalogHash={catalogHash}",
            CorrelationId = operation.CorrelationId,
            OccurredAtUtc = now
        });
        return state;
    }

    private async Task AcceptResultAsync(
        GatewayDbContext db,
        PurviewConnectorStateRecord state,
        PurviewConnectorOperation operation,
        string resultPath,
        DateTime now,
        CancellationToken cancellationToken)
    {
        try
        {
            var info = new FileInfo(resultPath);
            if (info.Length is <= 0 or > PurviewConnectorProtocol.MaximumResultEnvelopeBytes)
                throw new InvalidDataException();
            var result = PurviewConnectorProtocol.Verify<PurviewConnectorResult>(
                await File.ReadAllTextAsync(resultPath, cancellationToken),
                _options.AuthenticationKey,
                PurviewConnectorProtocol.ResultDomain);
            var command = CreateCommand(operation);
            // Validate the immutable command at its issue time; result acceptance
            // separately enforces the operation deadline below.
            PurviewConnectorProtocol.ValidateCommand(
                command, _options.TenantId, _options.ConnectorInstanceId, command.IssuedAtUtc);
            PurviewConnectorProtocol.ValidateResult(
                result, command, _options.TenantId, _options.ConnectorInstanceId, now);
            if (result.CompletedAtUtc > operation.ExpiresAtUtc)
                throw new InvalidOperationException("Connector result completed after the operation deadline.");

            operation.ResultHash = PurviewConnectorProtocol.Digest(result);
            if (result.Status == "Succeeded")
            {
                await AcceptCatalogAsync(db, state, operation, result.Catalog!, result.CatalogHash!, now, cancellationToken);
                return;
            }

            var status = result.Status switch
            {
                "NeedsAttention" => PurviewConnectorOperationStatus.NeedsAttention,
                "TimedOut" => PurviewConnectorOperationStatus.TimedOut,
                _ => PurviewConnectorOperationStatus.Failed
            };
            var failureCode = status == PurviewConnectorOperationStatus.TimedOut
                ? ErrorCodes.PURVIEW_CONNECTOR_TIMED_OUT
                : result.FailureCode!;
            await CompleteFailureAsync(db, state, operation, status, failureCode, now, cancellationToken);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or
            CryptographicException or JsonException or InvalidDataException or InvalidOperationException or
            FormatException or PurviewPolicyException)
        {
            logger.LogWarning(
                "Purview connector result was rejected ({FailureType}); no catalog was accepted.",
                failure.GetType().Name);
            await CompleteFailureAsync(
                db, state, operation, PurviewConnectorOperationStatus.NeedsAttention,
                ErrorCodes.PURVIEW_CONNECTOR_RESULT_INVALID, now, cancellationToken);
        }
    }

    private async Task AcceptCatalogAsync(
        GatewayDbContext db,
        PurviewConnectorStateRecord state,
        PurviewConnectorOperation operation,
        PurviewPolicyCatalog catalog,
        string catalogHash,
        DateTime now,
        CancellationToken cancellationToken)
    {
        if (state.CurrentOperationId != operation.Id || state.ConnectorInstanceId != operation.ConnectorInstanceId)
            throw new InvalidOperationException("Connector state no longer matches the operation.");
        var latestGeneration = await db.PurviewCatalogSnapshots
            .Where(snapshot => snapshot.TenantId == operation.TenantId)
            .Select(snapshot => (long?)snapshot.Generation)
            .MaxAsync(cancellationToken);
        if (latestGeneration is not null && latestGeneration >= operation.Generation)
            throw new InvalidOperationException("Catalog generation is not monotonic.");

        PurviewPolicyCatalogValidation.Validate(catalog, operation.TenantId);
        var counts = CountPolicies(catalog);
        db.PurviewCatalogSnapshots.Add(CreateSnapshot(catalog, catalogHash, operation, counts, now));
        await ReconcileAssignmentsAsync(db, operation, catalog, now, cancellationToken);

        operation.Status = PurviewConnectorOperationStatus.Succeeded;
        operation.CurrentStep = "Completed";
        operation.PercentComplete = 100;
        operation.CompletedAtUtc = now;
        operation.LeaseExpiresAtUtc = null;
        operation.CatalogHash = catalogHash;
        operation.FailureCode = null;
        operation.FailureSummary = null;
        operation.RowVersion = NewRowVersion();

        state.State = PurviewConnectorState.Connected;
        state.CurrentOperationId = null;
        state.LastSuccessfulRefreshAtUtc = now;
        state.CatalogRetrievedAtUtc = catalog.RetrievedAtUtc.UtcDateTime;
        state.PolicyCount = counts.PolicyCount;
        state.CompatiblePolicyCount = counts.CompatibleCount;
        state.IncompatiblePolicyCount = counts.IncompatibleCount;
        state.CatalogVerificationStatus = "Verified";
        state.LastFailureCode = null;
        state.LastCorrelationId = operation.CorrelationId;
        state.UpdatedAtUtc = now;
        state.RowVersion = NewRowVersion();
        db.AuditEvents.Add(new AuditEvent
        {
            Id = Guid.NewGuid(),
            EventType = operation.Type == PurviewConnectorOperationType.Connect
                ? "PurviewConnectionVerified"
                : "PurviewCatalogRefreshSucceeded",
            PerformedByObjectId = operation.RequestedByObjectId,
            PerformedByRole = "GatewayAdministrator",
            Details = $"OperationId={operation.Id:D}; ConnectorInstanceId={operation.ConnectorInstanceId:D}; Generation={operation.Generation}; CatalogHash={catalogHash}; PolicyCount={counts.PolicyCount}",
            CorrelationId = operation.CorrelationId,
            OccurredAtUtc = now
        });
    }

    private static async Task ReconcileAssignmentsAsync(
        GatewayDbContext db,
        PurviewConnectorOperation operation,
        PurviewPolicyCatalog catalog,
        DateTime now,
        CancellationToken cancellationToken)
    {
        var assigned = await db.AgentPolicyAssignments
            .Where(row => row.TenantId == operation.TenantId &&
                row.ConfirmedAtUtc != null && row.Status == "Assigned")
            .OrderBy(row => row.AgentRegistrationId)
            .ThenBy(row => row.PolicyId)
            .ThenByDescending(row => row.ConfirmedAtUtc)
            .ToListAsync(cancellationToken);
        var current = assigned
            .GroupBy(row => new { row.AgentRegistrationId, row.PolicyId })
            .Select(group => group.First())
            .ToArray();
        if (current.Length == 0)
            return;

        var policies = catalog.Items.ToDictionary(policy => policy.Id);
        var affectedAgents = new Dictionary<Guid, string>();
        foreach (var row in current)
        {
            var failureCode = AssignmentFailure(row, policies);
            if (failureCode is null)
                continue;
            row.Status = "NeedsAttention";
            row.FailureCode = failureCode;
            affectedAgents[row.AgentRegistrationId] = failureCode;
        }

        if (affectedAgents.Count == 0)
            return;
        var agentIds = affectedAgents.Keys.Order().ToArray();
        var agents = await db.AgentRegistrations
            .Where(agent => agentIds.Contains(agent.Id))
            .OrderBy(agent => agent.Id)
            .ToListAsync(cancellationToken);
        foreach (var agent in agents)
        {
            agent.ProtectionRevision = Guid.NewGuid();
            agent.UpdatedAtUtc = now;
            agent.UpdatedByObjectId = operation.RequestedByObjectId;
            db.AuditEvents.Add(new AuditEvent
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agent.Id,
                EventType = "PurviewAssignmentNeedsAttention",
                PerformedByObjectId = operation.RequestedByObjectId,
                PerformedByRole = "GatewayAdministrator",
                Details = $"OperationId={operation.Id:D}; FailureCode={affectedAgents[agent.Id]}",
                CorrelationId = operation.CorrelationId,
                OccurredAtUtc = now
            });
        }
    }

    internal static string? AssignmentFailure(
        AgentPolicyAssignment assignment,
        IReadOnlyDictionary<Guid, PurviewExistingPolicy> policies)
    {
        if (!policies.TryGetValue(assignment.PolicyId, out var policy))
            return "ASSIGNMENT_POLICY_REMOVED";
        if (!string.Equals(assignment.AssignedRevision, policy.Revision, StringComparison.Ordinal))
            return "ASSIGNMENT_POLICY_REVISION_CHANGED";
        if (policy.AllAccountsApplicationIds is null ||
            !policy.AllAccountsApplicationIds.Contains(assignment.AgentIdentityId))
            return "ASSIGNMENT_POLICY_SCOPE_CHANGED";
        return PurviewPolicyCatalogValidation.Incompatibility(policy) is null
            ? null
            : "ASSIGNMENT_POLICY_INCOMPATIBLE";
    }

    internal static bool RequiresCommandPublication(
        PurviewConnectorOperation operation,
        bool resultExists,
        DateTime utcNow) =>
        operation.Status == PurviewConnectorOperationStatus.Running &&
        !resultExists &&
        operation.ExpiresAtUtc > utcNow;

    private async Task CompleteFailureAsync(
        GatewayDbContext db,
        PurviewConnectorStateRecord state,
        PurviewConnectorOperation operation,
        PurviewConnectorOperationStatus status,
        string failureCode,
        DateTime now,
        CancellationToken cancellationToken)
    {
        var hasAcceptedCatalog = await db.PurviewCatalogSnapshots
            .AnyAsync(snapshot => snapshot.TenantId == operation.TenantId, cancellationToken);
        operation.Status = status;
        operation.CurrentStep = status == PurviewConnectorOperationStatus.TimedOut
            ? "TimedOut"
            : status == PurviewConnectorOperationStatus.NeedsAttention
                ? "NeedsAttention"
                : "Failed";
        operation.PercentComplete = 100;
        operation.CompletedAtUtc = now;
        operation.LeaseExpiresAtUtc = null;
        operation.FailureCode = failureCode;
        operation.FailureSummary = FailureSummary(failureCode);
        operation.RowVersion = NewRowVersion();
        if (state.CurrentOperationId == operation.Id)
            state.CurrentOperationId = null;
        state.State = hasAcceptedCatalog ? PurviewConnectorState.Degraded : PurviewConnectorState.Disconnected;
        state.LastFailureCode = failureCode;
        state.LastCorrelationId = operation.CorrelationId;
        state.UpdatedAtUtc = now;
        state.RowVersion = NewRowVersion();
        db.AuditEvents.Add(new AuditEvent
        {
            Id = Guid.NewGuid(),
            EventType = "PurviewConnectorOperationFailed",
            PerformedByObjectId = operation.RequestedByObjectId,
            PerformedByRole = "GatewayAdministrator",
            Details = $"OperationId={operation.Id:D}; ConnectorInstanceId={operation.ConnectorInstanceId:D}; FailureCode={failureCode}",
            CorrelationId = operation.CorrelationId,
            OccurredAtUtc = now
        });
    }

    private async Task EnsureCommandPublishedAsync(
        PurviewConnectorOperation operation,
        CancellationToken cancellationToken)
    {
        var command = CreateCommand(operation);
        var path = CommandPath(operation.Id);
        if (File.Exists(path))
        {
            var info = new FileInfo(path);
            if (info.Length is <= 0 or > PurviewConnectorProtocol.MaximumCommandEnvelopeBytes)
                throw new InvalidDataException("Existing connector command exceeds its size bound.");
            var existing = PurviewConnectorProtocol.Verify<PurviewConnectorCommand>(
                await File.ReadAllTextAsync(path, cancellationToken),
                _options.AuthenticationKey,
                PurviewConnectorProtocol.CommandDomain);
            if (!CommandMatchesOperation(existing, operation))
                throw new InvalidDataException("Existing connector command does not match durable operation state.");
            return;
        }

        PurviewConnectorProtocol.ValidateCommand(
            command, _options.TenantId, _options.ConnectorInstanceId, UtcNow());
        await PurviewConnectorProtocol.WriteAtomicAsync(
            path,
            PurviewConnectorProtocol.Sign(command, _options.AuthenticationKey, PurviewConnectorProtocol.CommandDomain),
            cancellationToken);
    }

    private async Task CleanupAcceptedTransportAsync(CancellationToken cancellationToken)
    {
        var checkpointPath = Path.Combine(
            Path.GetFullPath(_options.QueueDirectory),
            $"{_options.ConnectorInstanceId:D}.checkpoint.json");
        if (!File.Exists(checkpointPath))
            return;

        PurviewConnectorCheckpoint checkpoint;
        try
        {
            var info = new FileInfo(checkpointPath);
            if (info.Length is <= 0 or > PurviewConnectorProtocol.MaximumCheckpointEnvelopeBytes)
                throw new InvalidDataException();
            checkpoint = PurviewConnectorProtocol.Verify<PurviewConnectorCheckpoint>(
                await File.ReadAllTextAsync(checkpointPath, cancellationToken),
                _options.AuthenticationKey,
                PurviewConnectorProtocol.CheckpointDomain);
            PurviewConnectorProtocol.ValidateCheckpoint(
                checkpoint, _options.TenantId, _options.ConnectorInstanceId, UtcNow());
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or
            CryptographicException or JsonException or InvalidDataException or InvalidOperationException or FormatException)
        {
            logger.LogWarning(
                "Purview connector transport retention was deferred ({FailureType}); operation evidence was preserved.",
                failure.GetType().Name);
            return;
        }

        await using var scope = scopes.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        var accepted = await db.PurviewConnectorOperations
            .Where(operation => operation.TenantId == _options.TenantId &&
                operation.ConnectorInstanceId == _options.ConnectorInstanceId &&
                operation.ResultHash != null && operation.TransportCleanedAtUtc == null &&
                operation.Generation <= checkpoint.HighestCompletedGeneration &&
                (operation.Status == PurviewConnectorOperationStatus.Succeeded ||
                 operation.Status == PurviewConnectorOperationStatus.Failed ||
                 operation.Status == PurviewConnectorOperationStatus.NeedsAttention ||
                 operation.Status == PurviewConnectorOperationStatus.TimedOut ||
                 operation.Status == PurviewConnectorOperationStatus.Cancelled))
            .OrderBy(operation => operation.Generation)
            .Take(100)
            .ToListAsync(cancellationToken);
        foreach (var operation in accepted)
        {
            try
            {
                if (!CheckpointCovers(checkpoint, operation))
                    continue;
                var commandPath = CommandPath(operation.Id);
                var resultPath = ResultPath(operation.Id);
                var command = CreateCommand(operation);
                if (File.Exists(commandPath))
                {
                    if (new FileInfo(commandPath).Length is <= 0 or > PurviewConnectorProtocol.MaximumCommandEnvelopeBytes)
                        throw new InvalidDataException("Connector command cleanup size mismatch.");
                    var storedCommand = PurviewConnectorProtocol.Verify<PurviewConnectorCommand>(
                        await File.ReadAllTextAsync(commandPath, cancellationToken),
                        _options.AuthenticationKey,
                        PurviewConnectorProtocol.CommandDomain);
                    if (!CommandMatchesOperation(storedCommand, operation))
                        throw new InvalidDataException("Connector command cleanup binding mismatch.");
                }
                if (File.Exists(resultPath))
                {
                    if (new FileInfo(resultPath).Length is <= 0 or > PurviewConnectorProtocol.MaximumResultEnvelopeBytes)
                        throw new InvalidDataException("Connector result cleanup size mismatch.");
                    var storedResult = PurviewConnectorProtocol.Verify<PurviewConnectorResult>(
                        await File.ReadAllTextAsync(resultPath, cancellationToken),
                        _options.AuthenticationKey,
                        PurviewConnectorProtocol.ResultDomain);
                    PurviewConnectorProtocol.ValidateResult(
                        storedResult, command, _options.TenantId, _options.ConnectorInstanceId, UtcNow());
                    if (!CryptographicOperations.FixedTimeEquals(
                            Convert.FromHexString(operation.ResultHash!),
                            Convert.FromHexString(PurviewConnectorProtocol.Digest(storedResult))))
                        throw new InvalidDataException("Connector result cleanup binding mismatch.");
                }

                // Delete the command first. If the process stops between deletes,
                // the remaining authenticated result is inert and can be removed
                // on the next pass without causing the host to replay the command.
                File.Delete(commandPath);
                File.Delete(resultPath);
                operation.TransportCleanedAtUtc = UtcNow();
                operation.RowVersion = NewRowVersion();
            }
            catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or
                CryptographicException or JsonException or InvalidDataException or InvalidOperationException or FormatException)
            {
                logger.LogWarning(
                    "Purview connector evidence for operation {OperationId} was retained ({FailureType}).",
                    operation.Id,
                    failure.GetType().Name);
            }
        }
        await db.SaveChangesAsync(cancellationToken);
    }

    internal static bool CheckpointCovers(
        PurviewConnectorCheckpoint checkpoint,
        PurviewConnectorOperation operation) =>
        checkpoint.TenantId == operation.TenantId &&
        checkpoint.ConnectorInstanceId == operation.ConnectorInstanceId &&
        checkpoint.HighestCompletedGeneration >= operation.Generation &&
        operation.ResultHash is not null &&
        operation.Status is PurviewConnectorOperationStatus.Succeeded or
            PurviewConnectorOperationStatus.Failed or
            PurviewConnectorOperationStatus.NeedsAttention or
            PurviewConnectorOperationStatus.TimedOut or
            PurviewConnectorOperationStatus.Cancelled;

    internal static PurviewConnectorCommand CreateCommand(PurviewConnectorOperation operation) => new(
        operation.Id,
        operation.TenantId,
        operation.ConnectorInstanceId,
        operation.Type == PurviewConnectorOperationType.Connect
            ? PurviewConnectorAction.VerifyConnection
            : PurviewConnectorAction.RefreshCatalog,
        operation.Generation,
        operation.RequestHash,
        CanonicalizeTransportTimestamp(operation.IssuedAtUtc),
        CanonicalizeTransportTimestamp(operation.ExpiresAtUtc));

    internal static bool CommandMatchesOperation(
        PurviewConnectorCommand command,
        PurviewConnectorOperation operation) =>
        command with
        {
            IssuedAtUtc = CanonicalizeTransportTimestamp(command.IssuedAtUtc),
            ExpiresAtUtc = CanonicalizeTransportTimestamp(command.ExpiresAtUtc)
        } == CreateCommand(operation);

    internal static DateTime CanonicalizeTransportTimestamp(DateTime value)
    {
        // PostgreSQL persists timestamp-with-time-zone values at microsecond
        // precision, while a command can be published from the pre-save entity.
        // Use the durable precision for command identity across a process restart.
        var utc = DateTime.SpecifyKind(value, DateTimeKind.Utc);
        return utc.AddTicks(-(utc.Ticks % TimeSpan.TicksPerMicrosecond));
    }

    private string CommandPath(Guid operationId) => Path.Combine(
        Path.GetFullPath(_options.QueueDirectory), $"{operationId:D}.command.json");

    private string ResultPath(Guid operationId) => Path.Combine(
        Path.GetFullPath(_options.QueueDirectory), $"{operationId:D}.result.json");

    private static PurviewCatalogSnapshot CreateSnapshot(
        PurviewPolicyCatalog catalog,
        string catalogHash,
        PurviewConnectorOperation operation,
        (int PolicyCount, int CompatibleCount, int IncompatibleCount) counts,
        DateTime now) => new()
    {
        Id = Guid.NewGuid(),
        TenantId = operation.TenantId,
        ConnectorInstanceId = operation.ConnectorInstanceId,
        OperationId = operation.Id,
        Generation = operation.Generation,
        CatalogHash = catalogHash,
        CatalogJson = JsonSerializer.Serialize(catalog, PurviewConnectorProtocol.Json),
        RetrievedAtUtc = catalog.RetrievedAtUtc.UtcDateTime,
        AcceptedAtUtc = now,
        PolicyCount = counts.PolicyCount,
        CompatiblePolicyCount = counts.CompatibleCount,
        IncompatiblePolicyCount = counts.IncompatibleCount
    };

    private static (int PolicyCount, int CompatibleCount, int IncompatibleCount) CountPolicies(
        PurviewPolicyCatalog catalog)
    {
        var compatible = catalog.Items.Count(policy =>
            PurviewPolicyCatalogValidation.Incompatibility(policy) is null);
        return (catalog.Items.Count, compatible, catalog.Items.Count - compatible);
    }

    private static string FailureSummary(string failureCode) => failureCode switch
    {
        ErrorCodes.PURVIEW_CONNECTOR_TIMED_OUT =>
            "The Purview connector did not return a verified result before the operation deadline.",
        ErrorCodes.PURVIEW_CONNECTOR_RESULT_INVALID =>
            "The Gateway rejected connector evidence because its authentication or operation binding was invalid.",
        "PURVIEW_CONNECTOR_GENERATION_REPLAY" =>
            "The connector rejected a generation that had already completed. Refresh the connection state before retrying.",
        "PURVIEW_CATALOG_READ_FAILED" =>
            "The connector could not read a current Purview policy catalog.",
        _ => "The Purview connector could not complete the operation."
    };

    private DateTime UtcNow() => timeProvider.GetUtcNow().UtcDateTime;

    private static byte[] NewRowVersion() => Guid.NewGuid().ToByteArray();

    private static bool IsConfigured(PurviewConnectorOptions options)
    {
        if (options.TenantId == Guid.Empty || options.ConnectorInstanceId == Guid.Empty ||
            string.IsNullOrWhiteSpace(options.QueueDirectory) ||
            string.IsNullOrWhiteSpace(options.AuthenticationKey))
            return false;
        try { return Path.IsPathFullyQualified(options.QueueDirectory); }
        catch (Exception) { return false; }
    }
}
