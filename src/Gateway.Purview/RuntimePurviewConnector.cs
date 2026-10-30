using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Gateway.Purview;

public sealed class PurviewConnectorOptions
{
    public const string SectionName = "PurviewConnector";
    public string QueueDirectory { get; set; } = string.Empty;
    public string AuthenticationKey { get; set; } = string.Empty;
    public Guid TenantId { get; set; }
    public Guid ConnectorInstanceId { get; set; }
}

public enum PurviewConnectorAction
{
    VerifyConnection,
    RefreshCatalog
}

public sealed record PurviewConnectorCommand(
    Guid OperationId,
    Guid TenantId,
    Guid ConnectorInstanceId,
    PurviewConnectorAction Action,
    long Generation,
    string RequestHash,
    DateTime IssuedAtUtc,
    DateTime ExpiresAtUtc);

public sealed record PurviewConnectorResult(
    Guid OperationId,
    Guid TenantId,
    Guid ConnectorInstanceId,
    PurviewConnectorAction Action,
    long Generation,
    string RequestHash,
    string Status,
    DateTime CompletedAtUtc,
    PurviewPolicyCatalog? Catalog,
    string? CatalogHash,
    string? FailureCode);

public sealed record PurviewConnectorHeartbeat(
    Guid TenantId,
    Guid ConnectorInstanceId,
    Guid ProcessInstanceId,
    DateTime ObservedAtUtc,
    Guid? LastCommandId,
    DateTime? LastCompletedAtUtc);

public sealed record PurviewConnectorCheckpoint(
    Guid TenantId,
    Guid ConnectorInstanceId,
    long HighestCompletedGeneration,
    DateTime UpdatedAtUtc);

public sealed record AuthenticatedConnectorMessage(string Payload, string Mac);

public static class PurviewConnectorProtocol
{
    public const int MaximumCommandEnvelopeBytes = 32_768;
    public const int MaximumResultEnvelopeBytes = 2_100_000;
    public const int MaximumHeartbeatEnvelopeBytes = 32_768;
    public const int MaximumCheckpointEnvelopeBytes = 32_768;
    public const string CommandDomain = "command";
    public const string ResultDomain = "result";
    public const string HeartbeatDomain = "heartbeat";
    public const string CheckpointDomain = "checkpoint";

    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        Converters = { new JsonStringEnumConverter(allowIntegerValues: false) }
    };

    public static string Digest<T>(T value) =>
        Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(value, Json)));

    public static string Sign<T>(T value, string key, string domain)
    {
        ValidateDomain(domain);
        var payload = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(value, Json));
        return JsonSerializer.Serialize(
            new AuthenticatedConnectorMessage(payload, Convert.ToBase64String(Mac(payload, key, domain))),
            Json);
    }

    public static T Verify<T>(string envelope, string key, string domain)
    {
        ValidateDomain(domain);
        ArgumentNullException.ThrowIfNull(envelope);
        var maximum = domain == ResultDomain ? MaximumResultEnvelopeBytes :
            domain == HeartbeatDomain ? MaximumHeartbeatEnvelopeBytes :
            domain == CheckpointDomain ? MaximumCheckpointEnvelopeBytes : MaximumCommandEnvelopeBytes;
        var envelopeBytes = Encoding.UTF8.GetByteCount(envelope);
        if (envelopeBytes <= 0 || envelopeBytes > maximum)
            throw new CryptographicException("Connector envelope exceeds its size bound.");
        var value = JsonSerializer.Deserialize<AuthenticatedConnectorMessage>(envelope, Json)
            ?? throw new JsonException("Missing connector envelope.");
        if (string.IsNullOrWhiteSpace(value.Payload) || string.IsNullOrWhiteSpace(value.Mac))
            throw new CryptographicException("Connector envelope authentication evidence is missing.");
        byte[] suppliedMac;
        byte[] payload;
        try
        {
            suppliedMac = Convert.FromBase64String(value.Mac);
            payload = Convert.FromBase64String(value.Payload);
        }
        catch (FormatException failure)
        {
            throw new CryptographicException("Connector envelope encoding is invalid.", failure);
        }
        if (!CryptographicOperations.FixedTimeEquals(suppliedMac, Mac(value.Payload, key, domain)))
            throw new CryptographicException("Connector message authentication failed.");
        if (payload.Length > maximum)
            throw new CryptographicException("Connector payload exceeds its size bound.");
        return JsonSerializer.Deserialize<T>(payload, Json)
            ?? throw new JsonException("Missing connector payload.");
    }

    public static void ValidateCommand(
        PurviewConnectorCommand command,
        Guid tenantId,
        Guid connectorInstanceId,
        DateTime utcNow)
    {
        utcNow = RequireUtc(utcNow, nameof(utcNow));
        var issued = RequireUtc(command.IssuedAtUtc, nameof(command.IssuedAtUtc));
        var expires = RequireUtc(command.ExpiresAtUtc, nameof(command.ExpiresAtUtc));
        if (tenantId == Guid.Empty || connectorInstanceId == Guid.Empty || command.OperationId == Guid.Empty ||
            command.TenantId != tenantId || command.ConnectorInstanceId != connectorInstanceId ||
            !Enum.IsDefined(command.Action) || command.Generation <= 0 || !IsDigest(command.RequestHash) ||
            issued > utcNow.AddMinutes(1) ||
            expires <= utcNow || expires <= issued || expires > issued.AddMinutes(10))
            throw new InvalidOperationException("Invalid or expired Purview connector command.");
    }

    public static void ValidateResult(
        PurviewConnectorResult result,
        PurviewConnectorCommand command,
        Guid tenantId,
        Guid connectorInstanceId,
        DateTime utcNow)
    {
        utcNow = RequireUtc(utcNow, nameof(utcNow));
        var completed = RequireUtc(result.CompletedAtUtc, nameof(result.CompletedAtUtc));
        if (result.OperationId != command.OperationId || result.TenantId != tenantId ||
            result.TenantId != command.TenantId || result.ConnectorInstanceId != connectorInstanceId ||
            result.ConnectorInstanceId != command.ConnectorInstanceId || result.Action != command.Action ||
            result.Generation != command.Generation || result.RequestHash != command.RequestHash ||
            result.Status is not ("Succeeded" or "Failed" or "NeedsAttention" or "TimedOut") ||
            completed < command.IssuedAtUtc || completed > utcNow.AddMinutes(1))
            throw new InvalidOperationException("Purview connector result binding is invalid.");

        if (result.Status == "Succeeded")
        {
            if (result.Catalog is null || !IsDigest(result.CatalogHash) ||
                result.CatalogHash != Digest(result.Catalog) || result.FailureCode is not null)
                throw new InvalidOperationException("Successful Purview connector result is incomplete.");
            PurviewPolicyCatalogValidation.Validate(result.Catalog, tenantId);
            var completedOffset = new DateTimeOffset(completed);
            if (result.Catalog.RetrievedAtUtc < completedOffset.Subtract(PurviewPolicyCatalogValidation.MaximumConnectorResultAge) ||
                result.Catalog.RetrievedAtUtc > completedOffset.AddMinutes(1))
                throw new InvalidOperationException("Purview connector catalog freshness is invalid for this result.");
        }
        else if (result.Catalog is not null || result.CatalogHash is not null || !IsFailureCode(result.FailureCode))
        {
            throw new InvalidOperationException("Failed Purview connector result contains invalid evidence.");
        }
    }

    public static void ValidateHeartbeat(
        PurviewConnectorHeartbeat heartbeat,
        Guid tenantId,
        Guid connectorInstanceId,
        DateTime utcNow)
    {
        utcNow = RequireUtc(utcNow, nameof(utcNow));
        var observed = RequireUtc(heartbeat.ObservedAtUtc, nameof(heartbeat.ObservedAtUtc));
        if (tenantId == Guid.Empty || connectorInstanceId == Guid.Empty ||
            heartbeat.TenantId != tenantId || heartbeat.ConnectorInstanceId != connectorInstanceId ||
            heartbeat.ProcessInstanceId == Guid.Empty || observed < utcNow.AddMinutes(-2) || observed > utcNow.AddMinutes(1) ||
            (heartbeat.LastCompletedAtUtc is { } completed &&
             (RequireUtc(completed, nameof(heartbeat.LastCompletedAtUtc)) > observed || heartbeat.LastCommandId is null)))
            throw new InvalidOperationException("Purview connector heartbeat is invalid or stale.");
    }

    public static void ValidateCheckpoint(
        PurviewConnectorCheckpoint checkpoint,
        Guid tenantId,
        Guid connectorInstanceId,
        DateTime utcNow)
    {
        utcNow = RequireUtc(utcNow, nameof(utcNow));
        var updated = RequireUtc(checkpoint.UpdatedAtUtc, nameof(checkpoint.UpdatedAtUtc));
        if (tenantId == Guid.Empty || connectorInstanceId == Guid.Empty ||
            checkpoint.TenantId != tenantId || checkpoint.ConnectorInstanceId != connectorInstanceId ||
            checkpoint.HighestCompletedGeneration <= 0 || updated > utcNow.AddMinutes(1))
            throw new InvalidOperationException("Purview connector checkpoint is invalid.");
    }

    public static async Task WriteAtomicAsync(string path, string content, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentNullException.ThrowIfNull(content);
        var directory = Path.GetDirectoryName(Path.GetFullPath(path))
            ?? throw new InvalidOperationException("Connector transport directory is unavailable.");
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await File.WriteAllTextAsync(temporary, content, new UTF8Encoding(false), cancellationToken);
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private static byte[] Mac(string payload, string key, string domain)
    {
        byte[] keyBytes;
        try { keyBytes = Convert.FromBase64String(key); }
        catch (FormatException failure) { throw new CryptographicException("Connector authentication key is invalid.", failure); }
        if (keyBytes.Length != 32) throw new CryptographicException("Connector authentication key is invalid.");
        return HMACSHA256.HashData(
            keyBytes,
            Encoding.UTF8.GetBytes($"A365Gateway.PurviewConnector.v1.{domain}\n{payload}"));
    }

    private static void ValidateDomain(string domain)
    {
        if (domain is not (CommandDomain or ResultDomain or HeartbeatDomain or CheckpointDomain))
            throw new CryptographicException("Connector authentication domain is invalid.");
    }

    private static DateTime RequireUtc(DateTime value, string field)
    {
        if (value.Kind != DateTimeKind.Utc) throw new InvalidOperationException($"{field} must be UTC.");
        return value;
    }

    private static bool IsDigest(string? value) =>
        value is { Length: 64 } && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static bool IsFailureCode(string? value) =>
        value is { Length: >= 3 and <= 128 } && value[0] is >= 'A' and <= 'Z' &&
        value.All(character => character is >= 'A' and <= 'Z' or >= '0' and <= '9' or '_');
}
