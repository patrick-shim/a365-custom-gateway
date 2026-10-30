using System.Diagnostics;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Gateway.Purview;

namespace Gateway.Purview.CatalogHost;

public sealed record CatalogHostIdentity(
    Guid TenantId,
    Guid ApplicationId,
    Guid ConnectorInstanceId,
    string Organization,
    string CertificateThumbprint,
    bool AccessVerified);

public sealed record CatalogHostAssignmentRead(
    bool Assigned,
    string? Revision,
    string? DefinitionRevision,
    string? FailureCode);

public interface IPurviewCatalogHostExecutor
{
    Task<PurviewPolicyCatalog> ReadCatalogAsync(PurviewConnectorAction action, CancellationToken cancellationToken);
    Task<CatalogHostAssignmentRead> ApplyAssignmentAsync(PolicyAssignmentRequest request, CancellationToken cancellationToken);
}

public sealed class PowerShellPurviewCatalogHostExecutor(
    CatalogHostIdentity identity,
    string scriptPath) : IPurviewCatalogHostExecutor
{
    public async Task<PurviewPolicyCatalog> ReadCatalogAsync(
        PurviewConnectorAction action,
        CancellationToken cancellationToken)
    {
        var read = await ExecuteAsync(action.ToString(), null, cancellationToken);
        return read.Catalog ?? throw new InvalidOperationException("Purview catalog readback was missing.");
    }

    public async Task<CatalogHostAssignmentRead> ApplyAssignmentAsync(
        PolicyAssignmentRequest request,
        CancellationToken cancellationToken)
    {
        var requestPath = Path.Combine(Path.GetTempPath(), $"a365gw-assignment-{request.OperationId:D}-{Guid.NewGuid():N}.json");
        try
        {
            await File.WriteAllTextAsync(
                requestPath,
                JsonSerializer.Serialize(request, PurviewConnectorProtocol.Json),
                new UTF8Encoding(false),
                cancellationToken);
            var read = await ExecuteAsync("ApplyAssignment", requestPath, cancellationToken);
            return read.Assignment ?? throw new InvalidOperationException("Purview assignment readback was missing.");
        }
        finally
        {
            if (File.Exists(requestPath)) File.Delete(requestPath);
        }
    }

    private async Task<CatalogHostProcessRead> ExecuteAsync(
        string operation,
        string? assignmentRequestPath,
        CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo("pwsh.exe")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in new[]
        {
            "-NoLogo", "-NoProfile", "-NonInteractive", "-File", scriptPath,
            "-TenantId", identity.TenantId.ToString("D"),
            "-ApplicationId", identity.ApplicationId.ToString("D"),
            "-Organization", identity.Organization,
            "-CertificateThumbprint", identity.CertificateThumbprint,
            "-Operation", operation
        }) start.ArgumentList.Add(argument);
        if (assignmentRequestPath is not null)
        {
            start.ArgumentList.Add("-AssignmentRequestPath");
            start.ArgumentList.Add(assignmentRequestPath);
        }

        using var process = Process.Start(start)
            ?? throw new InvalidOperationException("Purview catalog reader could not start.");
        try
        {
            var stdout = ReadBoundedAsync(process.StandardOutput, 1_500_000, cancellationToken);
            var stderr = ReadBoundedAsync(process.StandardError, 16_384, cancellationToken);
            await Task.WhenAll(stdout, stderr, process.WaitForExitAsync(cancellationToken));
            if (process.ExitCode != 0) throw new InvalidOperationException("Purview catalog reader failed.");
            return JsonSerializer.Deserialize<CatalogHostProcessRead>(await stdout, PurviewConnectorProtocol.Json)
                ?? throw new JsonException("Purview catalog reader returned no result.");
        }
        finally
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync(CancellationToken.None);
            }
        }
    }

    private static async Task<string> ReadBoundedAsync(
        StreamReader reader,
        int maximumCharacters,
        CancellationToken cancellationToken)
    {
        var text = new StringBuilder();
        var buffer = new char[4096];
        int count;
        while ((count = await reader.ReadAsync(buffer, cancellationToken)) != 0)
        {
            if (text.Length + count > maximumCharacters)
                throw new InvalidOperationException("Purview catalog reader output exceeded its bound.");
            text.Append(buffer, 0, count);
        }
        return text.ToString();
    }

    private sealed record CatalogHostProcessRead(
        PurviewPolicyCatalog? Catalog,
        CatalogHostAssignmentRead? Assignment);
}

public sealed class PurviewCatalogHostListener
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan MaximumProviderDuration = TimeSpan.FromMinutes(6);

    private readonly CatalogHostIdentity _identity;
    private readonly string _connectorDirectory;
    private readonly string _assignmentDirectory;
    private readonly string _authenticationKey;
    private readonly IPurviewCatalogHostExecutor _executor;
    private readonly Func<PurviewPolicyCatalog, CancellationToken, Task> _publishCompatibilityCatalog;
    private readonly Func<DateTime> _utcNow;
    private readonly Action<string> _writeInformation;
    private readonly Action<string> _writeWarning;
    private readonly Guid _processInstanceId = Guid.NewGuid();
    private DateTime _lastHeartbeatAtUtc = DateTime.MinValue;
    private Guid? _lastCommandId;
    private DateTime? _lastCompletedAtUtc;
    private long? _highestCompletedGeneration;

    public PurviewCatalogHostListener(
        CatalogHostIdentity identity,
        string connectorDirectory,
        string assignmentDirectory,
        string authenticationKey,
        IPurviewCatalogHostExecutor executor,
        Func<PurviewPolicyCatalog, CancellationToken, Task> publishCompatibilityCatalog,
        Func<DateTime>? utcNow = null,
        Action<string>? writeInformation = null,
        Action<string>? writeWarning = null)
    {
        _identity = identity;
        _connectorDirectory = Path.GetFullPath(connectorDirectory);
        _assignmentDirectory = Path.GetFullPath(assignmentDirectory);
        _authenticationKey = authenticationKey;
        _executor = executor;
        _publishCompatibilityCatalog = publishCompatibilityCatalog;
        _utcNow = utcNow ?? (() => DateTime.UtcNow);
        _writeInformation = writeInformation ?? Console.WriteLine;
        _writeWarning = writeWarning ?? Console.Error.WriteLine;
        Directory.CreateDirectory(_connectorDirectory);
        Directory.CreateDirectory(_assignmentDirectory);

        // Fail startup before publishing health if the configured key is malformed.
        _ = PurviewConnectorProtocol.Sign(
            new PurviewConnectorHeartbeat(
                identity.TenantId,
                identity.ConnectorInstanceId,
                _processInstanceId,
                RequireUtc(_utcNow()),
                null,
                null),
            _authenticationKey,
            PurviewConnectorProtocol.HeartbeatDomain);
    }

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        await PublishHeartbeatAsync(force: true, cancellationToken);
        while (!cancellationToken.IsCancellationRequested)
        {
            var processed = false;
            try
            {
                processed = await PollOnceAsync(cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception failure)
            {
                _writeWarning($"{RequireUtc(_utcNow()):O} Purview connector listener error ({failure.GetType().Name}); no success inferred.");
            }

            if (!processed)
            {
                try { await Task.Delay(PollInterval, cancellationToken); }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            }
        }
    }

    public async Task<bool> PollOnceAsync(CancellationToken cancellationToken)
    {
        await PublishHeartbeatAsync(force: false, cancellationToken);
        if (await ProcessConnectorCommandAsync(cancellationToken)) return true;
        return await ProcessAssignmentAsync(cancellationToken);
    }

    private async Task<bool> ProcessConnectorCommandAsync(CancellationToken cancellationToken)
    {
        var candidates = new List<(string Path, PurviewConnectorCommand Command)>();
        foreach (var path in Directory.EnumerateFiles(_connectorDirectory, "*.command.json").Order(StringComparer.Ordinal))
        {
            var resultPath = ResultPath(path);
            if (File.Exists(resultPath)) continue;
            try
            {
                if (new FileInfo(path).Length is <= 0 or > PurviewConnectorProtocol.MaximumCommandEnvelopeBytes)
                    continue;
                var command = PurviewConnectorProtocol.Verify<PurviewConnectorCommand>(
                    await File.ReadAllTextAsync(path, cancellationToken),
                    _authenticationKey,
                    PurviewConnectorProtocol.CommandDomain);
                PurviewConnectorProtocol.ValidateCommand(
                    command,
                    _identity.TenantId,
                    _identity.ConnectorInstanceId,
                    RequireUtc(_utcNow()));
                if (Path.GetFileName(path) != $"{command.OperationId:D}.command.json") continue;
                candidates.Add((path, command));
            }
            catch (Exception failure) when (failure is not OperationCanceledException)
            {
                _writeWarning("Invalid, expired, or unauthenticated Purview connector command ignored.");
            }
        }

        var candidate = candidates.OrderBy(item => item.Command.Generation)
            .ThenBy(item => item.Command.OperationId)
            .FirstOrDefault();
        if (candidate.Command is null) return false;

        _highestCompletedGeneration ??= await ReadHighestCompletedGenerationAsync(cancellationToken);
        if (candidate.Command.Generation <= _highestCompletedGeneration)
        {
            await WriteConnectorResultAsync(
                candidate.Command,
                "NeedsAttention",
                null,
                "PURVIEW_CONNECTOR_GENERATION_REPLAY",
                cancellationToken);
            return true;
        }

        PurviewPolicyCatalog? catalog = null;
        string status;
        string? failureCode;
        using var providerDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var now = RequireUtc(_utcNow());
        var deadline = candidate.Command.ExpiresAtUtc < now.Add(MaximumProviderDuration)
            ? candidate.Command.ExpiresAtUtc
            : now.Add(MaximumProviderDuration);
        providerDeadline.CancelAfter(deadline - now);
        try
        {
            catalog = await _executor.ReadCatalogAsync(candidate.Command.Action, providerDeadline.Token);
            PurviewPolicyCatalogValidation.Validate(catalog, _identity.TenantId);
            if (RequireUtc(_utcNow()) >= candidate.Command.ExpiresAtUtc)
            {
                catalog = null;
                status = "TimedOut";
                failureCode = "PURVIEW_CONNECTOR_OPERATION_TIMED_OUT";
            }
            else
            {
                status = "Succeeded";
                failureCode = null;
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            status = "TimedOut";
            failureCode = "PURVIEW_CONNECTOR_OPERATION_TIMED_OUT";
        }
        catch (Exception failure) when (failure is not OperationCanceledException)
        {
            status = "Failed";
            failureCode = "PURVIEW_CATALOG_READ_FAILED";
        }

        await WriteConnectorResultAsync(candidate.Command, status, catalog, failureCode, cancellationToken);
        if (status == "Succeeded" && catalog is not null)
        {
            try
            {
                // The operation-bound result is authoritative. This second atomic
                // publication temporarily preserves legacy runtime readers during cutover.
                await _publishCompatibilityCatalog(catalog, cancellationToken);
            }
            catch (Exception failure) when (failure is not OperationCanceledException)
            {
                _writeWarning($"{RequireUtc(_utcNow()):O} Compatibility catalog publication failed ({failure.GetType().Name}); connector result remains authoritative.");
            }
        }
        return true;
    }

    private async Task WriteConnectorResultAsync(
        PurviewConnectorCommand command,
        string status,
        PurviewPolicyCatalog? catalog,
        string? failureCode,
        CancellationToken cancellationToken)
    {
        var completedAtUtc = RequireUtc(_utcNow());
        var result = new PurviewConnectorResult(
            command.OperationId,
            command.TenantId,
            command.ConnectorInstanceId,
            command.Action,
            command.Generation,
            command.RequestHash,
            status,
            completedAtUtc,
            status == "Succeeded" ? catalog : null,
            status == "Succeeded" && catalog is not null ? PurviewConnectorProtocol.Digest(catalog) : null,
            status == "Succeeded" ? null : failureCode);
        PurviewConnectorProtocol.ValidateResult(
            result,
            command,
            _identity.TenantId,
            _identity.ConnectorInstanceId,
            completedAtUtc);
        await PurviewConnectorProtocol.WriteAtomicAsync(
            Path.Combine(_connectorDirectory, $"{command.OperationId:D}.result.json"),
            PurviewConnectorProtocol.Sign(result, _authenticationKey, PurviewConnectorProtocol.ResultDomain),
            cancellationToken);
        _highestCompletedGeneration = Math.Max(_highestCompletedGeneration ?? 0, command.Generation);
        await WriteGenerationCheckpointAsync(_highestCompletedGeneration.Value, completedAtUtc, cancellationToken);
        _lastCommandId = command.OperationId;
        _lastCompletedAtUtc = completedAtUtc;
        await PublishHeartbeatAsync(force: true, cancellationToken);
        _writeInformation($"{completedAtUtc:O} Purview connector {command.Action} {status}.");
    }

    private async Task<long> ReadHighestCompletedGenerationAsync(CancellationToken cancellationToken)
    {
        long highest = 0;
        var checkpointPath = Path.Combine(
            _connectorDirectory,
            $"{_identity.ConnectorInstanceId:D}.checkpoint.json");
        if (File.Exists(checkpointPath))
        {
            try
            {
                if (new FileInfo(checkpointPath).Length is <= 0 or > PurviewConnectorProtocol.MaximumCheckpointEnvelopeBytes)
                    throw new InvalidOperationException("Purview connector checkpoint exceeds its size bound.");
                var checkpoint = PurviewConnectorProtocol.Verify<PurviewConnectorCheckpoint>(
                    await File.ReadAllTextAsync(checkpointPath, cancellationToken),
                    _authenticationKey,
                    PurviewConnectorProtocol.CheckpointDomain);
                PurviewConnectorProtocol.ValidateCheckpoint(
                    checkpoint,
                    _identity.TenantId,
                    _identity.ConnectorInstanceId,
                    RequireUtc(_utcNow()));
                highest = checkpoint.HighestCompletedGeneration;
            }
            catch (Exception failure) when (failure is not OperationCanceledException)
            {
                _writeWarning("Invalid Purview connector generation checkpoint ignored.");
            }
        }
        foreach (var path in Directory.EnumerateFiles(_connectorDirectory, "*.result.json"))
        {
            try
            {
                if (new FileInfo(path).Length is <= 0 or > PurviewConnectorProtocol.MaximumResultEnvelopeBytes)
                    continue;
                var result = PurviewConnectorProtocol.Verify<PurviewConnectorResult>(
                    await File.ReadAllTextAsync(path, cancellationToken),
                    _authenticationKey,
                    PurviewConnectorProtocol.ResultDomain);
                if (result.TenantId == _identity.TenantId &&
                    result.ConnectorInstanceId == _identity.ConnectorInstanceId &&
                    result.OperationId != Guid.Empty && result.Generation > highest &&
                    Path.GetFileName(path) == $"{result.OperationId:D}.result.json")
                    highest = result.Generation;
            }
            catch (Exception failure) when (failure is not OperationCanceledException)
            {
                _writeWarning("Invalid Purview connector result ignored while restoring generation state.");
            }
        }
        if (highest > 0)
            await WriteGenerationCheckpointAsync(highest, RequireUtc(_utcNow()), cancellationToken);
        return highest;
    }

    private Task WriteGenerationCheckpointAsync(
        long highestCompletedGeneration,
        DateTime updatedAtUtc,
        CancellationToken cancellationToken)
    {
        var checkpoint = new PurviewConnectorCheckpoint(
            _identity.TenantId,
            _identity.ConnectorInstanceId,
            highestCompletedGeneration,
            updatedAtUtc);
        PurviewConnectorProtocol.ValidateCheckpoint(
            checkpoint,
            _identity.TenantId,
            _identity.ConnectorInstanceId,
            updatedAtUtc);
        return PurviewConnectorProtocol.WriteAtomicAsync(
            Path.Combine(_connectorDirectory, $"{_identity.ConnectorInstanceId:D}.checkpoint.json"),
            PurviewConnectorProtocol.Sign(
                checkpoint,
                _authenticationKey,
                PurviewConnectorProtocol.CheckpointDomain),
            cancellationToken);
    }

    private async Task<bool> ProcessAssignmentAsync(CancellationToken cancellationToken)
    {
        foreach (var path in Directory.EnumerateFiles(_assignmentDirectory, "*.request.json").Order(StringComparer.Ordinal))
        {
            var resultPath = path.Replace(".request.json", ".result.json", StringComparison.Ordinal);
            if (File.Exists(resultPath)) continue;
            try
            {
                if (new FileInfo(path).Length is <= 0 or > 32_768) continue;
                var request = PolicyAssignmentProtocol.Verify<PolicyAssignmentRequest>(
                    await File.ReadAllTextAsync(path, cancellationToken),
                    _authenticationKey,
                    "request");
                PolicyAssignmentProtocol.Validate(request, _identity.TenantId);
                if (Path.GetFileName(path) != $"{request.OperationId:D}.request.json") continue;

                CatalogHostAssignmentRead read;
                using var providerDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                var remaining = request.ExpiresAtUtc - RequireUtc(_utcNow());
                if (remaining <= TimeSpan.Zero) continue;
                providerDeadline.CancelAfter(remaining < MaximumProviderDuration ? remaining : MaximumProviderDuration);
                try
                {
                    read = await _executor.ApplyAssignmentAsync(request, providerDeadline.Token);
                }
                catch (Exception failure) when (failure is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
                {
                    read = new(false, null, null, "ASSIGNMENT_OUTCOME_UNCONFIRMED");
                }

                var response = new PolicyAssignmentResult(
                    request.OperationId,
                    _identity.TenantId,
                    request.AgentIdentityId,
                    request.PolicyId,
                    PolicyAssignmentProtocol.Digest(request),
                    read.Assigned,
                    read.Revision,
                    read.DefinitionRevision,
                    read.FailureCode,
                    RequireUtc(_utcNow()));
                PolicyAssignmentProtocol.Validate(response, request, RequireUtc(_utcNow()));
                await PolicyAssignmentProtocol.WriteAtomicAsync(
                    resultPath,
                    PolicyAssignmentProtocol.Sign(response, _authenticationKey, "result"),
                    cancellationToken);
                _writeInformation($"{RequireUtc(_utcNow()):O} Purview assignment operation completed.");
                return true;
            }
            catch (Exception failure) when (failure is not OperationCanceledException)
            {
                _writeWarning("Invalid, expired, or unauthenticated Purview assignment request ignored.");
            }
        }
        return false;
    }

    private async Task PublishHeartbeatAsync(bool force, CancellationToken cancellationToken)
    {
        var observedAtUtc = RequireUtc(_utcNow());
        if (!force && observedAtUtc - _lastHeartbeatAtUtc < HeartbeatInterval) return;
        var heartbeat = new PurviewConnectorHeartbeat(
            _identity.TenantId,
            _identity.ConnectorInstanceId,
            _processInstanceId,
            observedAtUtc,
            _lastCommandId,
            _lastCompletedAtUtc);
        PurviewConnectorProtocol.ValidateHeartbeat(
            heartbeat,
            _identity.TenantId,
            _identity.ConnectorInstanceId,
            observedAtUtc);
        await PurviewConnectorProtocol.WriteAtomicAsync(
            Path.Combine(_connectorDirectory, $"{_identity.ConnectorInstanceId:D}.heartbeat.json"),
            PurviewConnectorProtocol.Sign(heartbeat, _authenticationKey, PurviewConnectorProtocol.HeartbeatDomain),
            cancellationToken);
        _lastHeartbeatAtUtc = observedAtUtc;
    }

    private static string ResultPath(string commandPath) =>
        commandPath.Replace(".command.json", ".result.json", StringComparison.Ordinal);

    private static DateTime RequireUtc(DateTime value) =>
        value.Kind == DateTimeKind.Utc ? value : value.ToUniversalTime();
}

public static class PurviewCompatibilityCatalogPublisher
{
    public static async Task PublishAsync(
        string destinationDirectory,
        PurviewPolicyCatalog catalog,
        X509Certificate2 certificate,
        CancellationToken cancellationToken)
    {
        PurviewPolicyCatalogValidation.Validate(catalog, catalog.TenantId);
        var envelope = PurviewCatalogSignature.Sign(catalog, certificate);
        await PurviewConnectorProtocol.WriteAtomicAsync(
            Path.Combine(Path.GetFullPath(destinationDirectory), "catalog.json"),
            JsonSerializer.Serialize(envelope, PurviewConnectorProtocol.Json),
            cancellationToken);
    }
}
