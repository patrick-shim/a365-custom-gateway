using System.Buffers.Binary;
using System.Net;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;

namespace Gateway.AdminUi.BrowserHost;

internal sealed partial class FixtureState
{
    private readonly Dictionary<Guid, (PurviewRuntimeTestReviewDto Review, string Version, DateTime Expires)> runtimeReviews = [];
    private readonly Dictionary<Guid, PurviewRuntimeTestResultResponse> runtimeReports = [];
    private Guid? latestRuntimeOperation;

    internal PurviewRuntimeReviewTicket ReviewRuntime(ReviewPurviewDlpRuntimeTestRequest request)
    {
        RequireProtection(nameof(ReviewRuntime));
        if (fixtureProfile is null || request.ProfileId != fixtureProfile.Id || fixtureProfile.PolicyMode == "Disabled" ||
            request.ExpectedRowVersion != fixtureProfile.RowVersion || request.InventoryGenerationId != FixtureInventoryId ||
            !request.AcknowledgeSyntheticData ||
            !RuntimeTestUiProtocol.ValidManifest(request.Suite, SelectedTypes().Select(item => item.SensitiveInformationTypeId).ToArray()) ||
            !RuntimeTestUiProtocol.ValidBatch(request.Suite, request.PositiveCaseIds))
            throw Error(HttpStatusCode.BadRequest, "The synthetic runtime review is not bound to the saved profile and full sample suite.", "PURVIEW_RUNTIME_CONTEXT_INVALID");
        var id = Guid.NewGuid();
        latestRuntimeOperation = newestProtectionOperation = id;
        var hash = "sha256:" + Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(request.Suite))).ToLowerInvariant();
        var review = new PurviewRuntimeTestReviewDto(FixtureIdentity.TenantId, FixtureProfileId, agents.Keys.First(),
            Id(8, 1), BlueprintClientId, FixtureIdentity.ActorId, FixtureInventoryId, fixtureProfile.PolicyMode!,
            hash, FixtureHash('b'), FixtureHash('c'), SelectedTypes(), request.Suite, request.PositiveCaseIds,
            new(8, 8192, 65536, 60));
        var expires = DateTime.UtcNow.AddMinutes(5);
        runtimeReviews[id] = (review, request.ExpectedRowVersion, expires);
        protectionOperations[id] = ProtectionOperation(id, "TestDlpRuntime", "AwaitingConfirmation", "DlpProfile", FixtureProfileId.ToString("D"));
        return new(new(id, $"synthetic-runtime-review-{id:D}", FixtureHash('d'), expires, review), request);
    }

    internal PurviewRuntimeTestResultResponse GetRuntimeReport(Guid id)
    {
        RequireProtection(nameof(GetRuntimeReport));
        return runtimeReports.TryGetValue(id, out var report) ? report :
            throw Error(HttpStatusCode.NotFound, "No saved synthetic runtime result.", "NOT_FOUND");
    }

    internal Task<PurviewRuntimeTestResultResponse> ExecuteRuntimeAsync(ClaimsPrincipal user, Guid profileId,
        RuntimePortalExecutionRequest request, CancellationToken cancellationToken)
    {
        if (!user.IsInRole(GatewayRoles.Administrator) ||
            user.FindFirst("tid")?.Value != FixtureIdentity.TenantId.ToString("D") ||
            user.FindFirst("oid")?.Value != FixtureIdentity.ActorId.ToString("D"))
            throw Error(HttpStatusCode.Forbidden, "Synthetic runtime identity mismatch.", "FORBIDDEN");
        return ExecuteAsync(CaptureLease(), "ExecuteRuntimeSamples", FixtureAccess.Administrator, profileId,
            true, cancellationToken, () => ExecuteRuntime(profileId, request));
    }

    private PurviewRuntimeTestResultResponse ExecuteRuntime(Guid profileId, RuntimePortalExecutionRequest request)
    {
        RequireProtection(nameof(ExecuteRuntime));
        if (!runtimeReviews.TryGetValue(request.ReviewTokenId, out var stored) || stored.Expires <= DateTime.UtcNow ||
            runtimeReports.ContainsKey(request.ReviewTokenId) || fixtureProfile is null || profileId != fixtureProfile.Id ||
            request.ExpectedRowVersion != stored.Version || request.ExpectedRowVersion != fixtureProfile.RowVersion ||
            request.ReviewToken != $"synthetic-runtime-review-{request.ReviewTokenId:D}")
            throw Error(HttpStatusCode.Conflict, "Runtime authority is expired, consumed, or changed.", "PURVIEW_RUNTIME_CONTEXT_CHANGED");
        var selected = stored.Review.Suite.PositiveSamples
            .Where(item => stored.Review.PositiveCaseIds.Contains(item.CaseId)).Append(stored.Review.Suite.NegativeSample).ToArray();
        if (request.Samples.Count != selected.Length || selected.Any(expected =>
            request.Samples.Count(sample => sample.CaseId == expected.CaseId &&
                SampleHash(stored.Review.Suite.SuiteNonce, sample.Content) == expected.ContentHash &&
                Encoding.UTF8.GetByteCount(sample.Content) == expected.Utf8ByteCount) != 1))
            throw Error(HttpStatusCode.BadRequest, "The approved sample commitments changed.", "PURVIEW_RUNTIME_SAMPLE_MISMATCH");

        var unknown = scenario.Protection == "runtime-unknown";
        var enforce = stored.Review.PolicyMode == "Enforce";
        var cases = selected.Select(item => new PurviewRuntimeTestCaseResultDto(item.CaseId,
            item.IntendedSensitiveInformationTypeId, item.ContentHash,
            unknown ? "Unknown" : enforce && item.IntendedSensitiveInformationTypeId is not null ? "Blocked" : "Allowed",
            unknown ? "NotSubmitted" : "Processed",
            unknown || item.IntendedSensitiveInformationTypeId is null ? "None" : "Content", DateTimeOffset.UtcNow,
            unknown ? "PURVIEW_RUNTIME_OUTCOME_UNKNOWN" : null)).ToArray();
        var outstanding = stored.Review.Suite.PositiveSamples
            .Where(item => !stored.Review.PositiveCaseIds.Contains(item.CaseId))
            .Select(item => item.IntendedSensitiveInformationTypeId!.Value).ToArray();
        var verified = enforce && !unknown && outstanding.Length == 0;
        var result = new PurviewRuntimeTestResultResponse(request.ReviewTokenId,
            unknown ? "RequiresManualIntervention" : "Completed",
            unknown ? "OutcomeUnknown" : verified ? "EnforcementBehaviorVerified" : enforce ? "Partial" : "SimulationExercised",
            stored.Review.PolicyMode, stored.Review.SuiteHash, stored.Review.ConfigurationFingerprint, stored.Version,
            DateTimeOffset.UtcNow, cases, outstanding, verified, unknown ? "PURVIEW_RUNTIME_OUTCOME_UNKNOWN" : null);
        runtimeReports[request.ReviewTokenId] = result;
        protectionOperations[request.ReviewTokenId] = ProtectionOperation(request.ReviewTokenId,
            "TestDlpRuntime", result.Status, "DlpProfile", FixtureProfileId.ToString("D"));
        if (verified)
        {
            var expiry = scenario.Protection == "runtime-expiry"
                ? DateTime.UtcNow.AddSeconds(10) : DateTime.UtcNow.AddMinutes(10);
            fixtureProfile = fixtureProfile with { Readiness = Readiness(true, expiry), RuntimeBehaviorSuiteHash = result.SuiteHash,
                RuntimeBehaviorVerifiedUntilUtc = expiry, Status = "Ready" };
            ApplyProtectionToAgents();
        }
        if (scenario.Protection is "runtime-unknown" or "runtime-unknown-committed") throw Interrupted();
        return result;
    }

    private static string SampleHash(string nonceText, string content)
    {
        var domain = Encoding.UTF8.GetBytes("A365Gateway.PurviewRuntimeTest.Sample.v1\0");
        var nonce = Convert.FromHexString(nonceText);
        var contentBytes = new UTF8Encoding(false, true).GetBytes(content);
        var bytes = new byte[domain.Length + nonce.Length + 4 + contentBytes.Length];
        try
        {
            domain.CopyTo(bytes, 0);
            nonce.CopyTo(bytes, domain.Length);
            BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(domain.Length + nonce.Length), (uint)contentBytes.Length);
            contentBytes.CopyTo(bytes, domain.Length + nonce.Length + 4);
            return "sha256:" + Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        }
        finally
        {
            CryptographicOperations.ZeroMemory(nonce);
            CryptographicOperations.ZeroMemory(contentBytes);
            CryptographicOperations.ZeroMemory(bytes);
        }
    }
}

internal sealed class FixtureRuntimeExecution(FixtureState state, IsolationGuards guards) : IPurviewRuntimeExecutionClient
{
    public Task<PurviewRuntimeTestResultResponse> ExecuteAsync(ClaimsPrincipal user, Guid profileId,
        RuntimePortalExecutionRequest request, CancellationToken cancellationToken) =>
        state.Role == GatewayRoles.Administrator
            ? state.ExecuteRuntimeAsync(user, profileId, request, cancellationToken)
            : throw guards.RejectRuntime();
}
