using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;

namespace Gateway.Purview;

public sealed record PurviewExecutorBinding(
    Guid DeploymentOwnershipId,
    Guid TenantId,
    string BootstrapSourceFingerprint,
    string ExecutionSourceFingerprint,
    string PackageDigest,
    Guid AutomationApplicationId,
    Guid AutomationServicePrincipalObjectId,
    string KeyVaultResourceId,
    string CertificateName,
    string CertificateSecretUri,
    Guid GatewayApiPrincipalId,
    Guid GatewayWorkerPrincipalId,
    Guid RuntimeClientId,
    Guid RuntimePrincipalId,
    Guid ExecutorApplicationId,
    Guid ExecutorPrincipalId,
    Guid CallerApplicationId)
{
    public PurviewAutomationCapabilityBinding Validate(PurviewOptions options)
    {
        if (new[]
            {
                DeploymentOwnershipId, TenantId, AutomationApplicationId,
                AutomationServicePrincipalObjectId, GatewayApiPrincipalId,
                GatewayWorkerPrincipalId, RuntimeClientId, RuntimePrincipalId,
                ExecutorApplicationId, ExecutorPrincipalId, CallerApplicationId
            }.Any(value => value == Guid.Empty) ||
            !IsDigest(BootstrapSourceFingerprint) ||
            !IsDigest(ExecutionSourceFingerprint) || !IsDigest(PackageDigest) ||
            ExecutorPrincipalId == GatewayWorkerPrincipalId ||
            ExecutorPrincipalId == GatewayApiPrincipalId ||
            ExecutorPrincipalId == RuntimePrincipalId ||
            !string.Equals(CertificateSecretUri,
                options.PolicyProvisioningCertificateSecretUri, StringComparison.Ordinal))
        {
            throw new PurviewPolicyException("PURVIEW_EXECUTOR_BINDING_INVALID",
                "The independently configured Purview execution binding is invalid.");
        }

        return PurviewAutomationCapabilityBindingValidator.Bind(
            new ProtectionCapabilityResourceIdentifiers(
                PurviewAutomationApplicationId: new ApplicationClientId(AutomationApplicationId),
                PurviewAutomationServicePrincipalObjectId: new ServicePrincipalObjectId(AutomationServicePrincipalObjectId),
                KeyVaultResourceId: KeyVaultResourceId,
                CertificateName: CertificateName), options);
    }

    private static bool IsDigest(string? value) =>
        value is { Length: 71 } && value.StartsWith("sha256:", StringComparison.Ordinal) &&
        value.AsSpan(7).ToArray().All(char.IsAsciiHexDigitLower);
}

public enum PurviewExecutorCommand
{
    VerifyConnection,
    ReadKnowYourData,
    CreateKnowYourData,
    ReadDlpProfile,
    CreateDlpPolicy,
    CreateDlpRule
}

public sealed record PurviewExecutorRequest(
    PurviewExecutorBinding Binding,
    Guid OperationId,
    PurviewExecutorCommand Command,
    DateTimeOffset ExpiresAtUtc,
    JsonElement Input);

public sealed record PurviewExecutorReply(
    PurviewExecutorBinding Binding,
    Guid OperationId,
    PurviewExecutorCommand Command,
    string Status,
    JsonElement? Value = null,
    string? FailureCode = null);

public sealed class PurviewExecutorOptions
{
    public const string SectionName = "PurviewExecutor";
    public bool Enabled { get; set; }
    public string? Endpoint { get; set; }
    public PurviewExecutorBinding? Binding { get; set; }
    public int TimeoutSeconds { get; set; } = 215;
}

public interface IPurviewExecutorClient
{
    Task<TResponse> ReadAsync<TRequest, TResponse>(
        PurviewExecutorCommand command,
        Guid operationId,
        Guid tenantId,
        TRequest input,
        CancellationToken cancellationToken);

    Task MutateAsync<TRequest>(
        PurviewExecutorCommand command,
        Guid operationId,
        Guid tenantId,
        TRequest input,
        CancellationToken cancellationToken);
}

public static class PurviewExecutorJson
{
    public static JsonSerializerOptions Options { get; } = Create();

    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web)
        {
            PropertyNameCaseInsensitive = false,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
            MaxDepth = 32
        };
        options.Converters.Add(new JsonStringEnumConverter(allowIntegerValues: false));
        return options;
    }
}
