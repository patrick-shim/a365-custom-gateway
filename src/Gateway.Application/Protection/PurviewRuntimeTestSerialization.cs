using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;

namespace Gateway.Application.Protection;

internal sealed record PurviewRuntimeContextEnvelope(
    PurviewRuntimeTestIdentityBinding Identity,
    PurviewRuntimeTestVersionBinding Versions,
    PurviewPolicyMode PolicyMode,
    string ProfileDisplayName,
    string PolicyProviderId,
    string RuleProviderId,
    ImmutableArray<PurviewSelectedSensitiveInformationType> SelectedTypes,
    ImmutableArray<PurviewPolicyActivity> Activities,
    ImmutableArray<PurviewDlpRuleAction> Actions)
{
    public PurviewRuntimeTestContext ToContext() => new(Identity, Versions, PolicyMode, ProfileDisplayName,
        PolicyProviderId, RuleProviderId, SelectedTypes, Activities, Actions);
    public static PurviewRuntimeContextEnvelope From(PurviewRuntimeTestContext context) => new(
        context.Identity, context.Versions, context.PolicyMode, context.ProfileDisplayName, context.PolicyProviderId,
        context.RuleProviderId, context.SelectedTypes, context.Activities, context.Actions);
}

internal sealed record PurviewRuntimeTestConsent(
    ReviewPurviewDlpRuntimeTestRequest Request, PurviewRuntimeContextEnvelope Context);
internal sealed record PurviewRuntimeConsentReference(string ConsentHash);
internal sealed record PurviewRuntimeStoredResult(
    PurviewRuntimeTestResultResponse Report,
    ImmutableArray<PurviewRuntimeTestCaseEvidence> Evidence,
    DateTimeOffset? TokenRolesVerifiedAtUtc,
    DateTimeOffset? CredentialExpiresAtUtc,
    DateTimeOffset? CertifiedUntilUtc = null);

internal static class PurviewRuntimeTestSerialization
{
    internal const int MaximumConsentCharacters = 262_144;
    internal const int MaximumResultCharacters = 65_536;
    internal static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        MaxDepth = 12,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        Converters = { new JsonStringEnumConverter() }
    };

    public static string WriteConsent(PurviewRuntimeTestConsent consent) => Bounded(consent, MaximumConsentCharacters);
    public static string WriteResult(PurviewRuntimeStoredResult result) => Bounded(result, MaximumResultCharacters);
    public static PurviewRuntimeConsentReference Reference(string json) =>
        new($"sha256:{Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(json))).ToLowerInvariant()}");

    public static PurviewRuntimeTestConsent ReadConsent(ProtectionAdminOperation operation)
    {
        var consent = Read<PurviewRuntimeTestConsent>(operation.RuntimeTestConsentJson, MaximumConsentCharacters);
        var reference = Reference(operation.RuntimeTestConsentJson!);
        var referenceElement = JsonSerializer.SerializeToElement(reference, Options);
        if (operation.Type != ProtectionAdminOperationType.TestDlpRuntime ||
            !string.Equals(operation.ReviewedPayloadHash,
                ProtectionOperationTokenService.ComputePayloadHash(referenceElement), StringComparison.Ordinal))
            throw Invalid();
        return consent;
    }

    public static PurviewRuntimeStoredResult ReadResult(ProtectionAdminOperation operation) =>
        Read<PurviewRuntimeStoredResult>(operation.RuntimeTestResultJson, MaximumResultCharacters);

    public static PurviewRuntimeTestPlan Plan(PurviewRuntimeTestConsent consent) =>
        PurviewRuntimeTestValidation.CreatePlan(consent.Context.ToContext(), consent.Request,
            consent.Context.Versions.InventoryExpiresAtUtc.AddTicks(-1));

    private static T Read<T>(string? json, int maximum)
    {
        try
        {
            if (string.IsNullOrEmpty(json) || json.Length > maximum)
                throw Invalid();
            return JsonSerializer.Deserialize<T>(json, Options) ?? throw Invalid();
        }
        catch (JsonException) { throw Invalid(); }
        catch (NotSupportedException) { throw Invalid(); }
    }

    private static string Bounded<T>(T value, int maximum)
    {
        var json = JsonSerializer.Serialize(value, Options);
        if (json.Length > maximum)
            throw new ValidationException(new Dictionary<string, string[]>
                { ["RuntimeTest"] = ["The bounded runtime-test metadata limit was exceeded."] });
        return json;
    }

    private static DomainException Invalid() => new(
        "The runtime-test consent or result is invalid.", ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
}
