using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Gateway.Purview;

public sealed record PolicyAssignmentRequest(Guid OperationId, Guid TenantId, Guid AgentRegistrationId,
    Guid AgentIdentityId, Guid BlueprintId, Guid PolicyId, string ReviewedRevision, DateTime ExpiresAtUtc);
public sealed record PolicyAssignmentResult(Guid OperationId, Guid TenantId, Guid AgentIdentityId,
    Guid PolicyId, string RequestDigest, bool Assigned, string? Revision, string? DefinitionRevision,
    string? FailureCode, DateTime ReadAtUtc);
public sealed record AuthenticatedAssignment(string Payload, string Mac);
public sealed class RuntimePolicyAssignmentOptions
{
    public string QueueDirectory { get; set; } = "";
    public string AuthenticationKey { get; set; } = "";
}

// Separate request/result domains prevent reflecting an authenticated request as a result.
// The key is installed by bootstrap outside the writable queue, never accepted from a message.
public static class PolicyAssignmentProtocol
{
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    public static string Digest<T>(T value) => Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(value, Json)));
    public static string Sign<T>(T value, string key, string domain)
    {
        var payload = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(value, Json));
        return JsonSerializer.Serialize(new AuthenticatedAssignment(payload, Convert.ToBase64String(Mac(payload, key, domain))), Json);
    }
    public static T Verify<T>(string envelope, string key, string domain)
    {
        if (string.IsNullOrWhiteSpace(envelope) || envelope.Length > 32_768)
            throw new CryptographicException("Assignment envelope is invalid.");
        var value = JsonSerializer.Deserialize<AuthenticatedAssignment>(envelope, Json) ?? throw new JsonException();
        if (string.IsNullOrWhiteSpace(value.Payload) || string.IsNullOrWhiteSpace(value.Mac))
            throw new CryptographicException("Assignment authentication failed.");
        if (!CryptographicOperations.FixedTimeEquals(Convert.FromBase64String(value.Mac), Mac(value.Payload, key, domain)))
            throw new CryptographicException("Assignment authentication failed.");
        return JsonSerializer.Deserialize<T>(Convert.FromBase64String(value.Payload), Json) ?? throw new JsonException();
    }
    private static byte[] Mac(string payload, string key, string domain)
    {
        var bytes = Convert.FromBase64String(key);
        if (bytes.Length != 32 || domain is not ("request" or "result")) throw new CryptographicException("Assignment key or domain invalid.");
        return HMACSHA256.HashData(bytes, Encoding.UTF8.GetBytes($"A365Gateway.Assignment.v1.{domain}\n{payload}"));
    }
    public static void Validate(PolicyAssignmentRequest request, Guid tenant)
    {
        if (tenant == Guid.Empty || request.TenantId != tenant || request.OperationId == Guid.Empty ||
            request.AgentRegistrationId == Guid.Empty || request.PolicyId == Guid.Empty || request.AgentIdentityId == Guid.Empty ||
            request.BlueprintId == Guid.Empty || request.AgentIdentityId == request.BlueprintId ||
            request.ExpiresAtUtc <= DateTime.UtcNow || request.ExpiresAtUtc > DateTime.UtcNow.AddMinutes(20) ||
            request.ReviewedRevision is not { Length: 64 } || !request.ReviewedRevision.All(char.IsAsciiHexDigitLower))
            throw new InvalidOperationException("Invalid or expired individual assignment request.");
    }
    public static void Validate(
        PolicyAssignmentResult result,
        PolicyAssignmentRequest request,
        DateTime utcNow)
    {
        if (utcNow.Kind != DateTimeKind.Utc || result.ReadAtUtc.Kind != DateTimeKind.Utc ||
            result.OperationId != request.OperationId || result.TenantId != request.TenantId ||
            result.AgentIdentityId != request.AgentIdentityId || result.PolicyId != request.PolicyId ||
            result.RequestDigest != Digest(request) || result.ReadAtUtc > utcNow.AddMinutes(1) ||
            result.ReadAtUtc > request.ExpiresAtUtc)
            throw new InvalidOperationException("Assignment response binding mismatch.");

        if (result.Assigned)
        {
            if (!IsDigest(result.Revision) || !IsDigest(result.DefinitionRevision) || result.FailureCode is not null)
                throw new InvalidOperationException("Successful assignment response is incomplete.");
        }
        else if (result.Revision is not null || result.DefinitionRevision is not null ||
                 !IsFailureCode(result.FailureCode))
        {
            throw new InvalidOperationException("Failed assignment response contains invalid evidence.");
        }
    }
    private static bool IsDigest(string? value) =>
        value is { Length: 64 } && value.All(char.IsAsciiHexDigitLower);
    private static bool IsFailureCode(string? value) =>
        value is { Length: >= 3 and <= 128 } && value[0] is >= 'A' and <= 'Z' &&
        value.All(character => character is >= 'A' and <= 'Z' or >= '0' and <= '9' or '_');
    public static async Task WriteAtomicAsync(string path, string content, CancellationToken ct)
    {
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { await File.WriteAllTextAsync(temp, content, ct); File.Move(temp, path, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}
