using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;

namespace Gateway.Purview;

public sealed partial class PurviewPolicyClient : IPurviewRuntimeProbeClient
{
    private static readonly UTF8Encoding ProbeUtf8 = new(false, true);
    private readonly Guid? _runtimeProbePrincipalId;
    private readonly TimeProvider _runtimeProbeClock;

    public async Task<PurviewRuntimeProbeResult> ProbeAsync(
        Guid operationId,
        PurviewRuntimeTestContext context,
        PurviewRuntimeEphemeralSample sample,
        DateTimeOffset deadlineUtc,
        CancellationToken cancellationToken)
    {
        if (context?.PolicyMode == PurviewPolicyMode.Disabled)
            return ProbeFailure(PurviewRuntimeTestFailureCodes.Disabled, contentSubmissionStarted: false);
        if (!IsEnabled)
            return ProbeFailure(PurviewRuntimeTestFailureCodes.ProviderUnavailable, contentSubmissionStarted: false);

        var now = _runtimeProbeClock.GetUtcNow();
        if (context is null || !ValidProbeContext(operationId, context, sample) ||
            _runtimeProbePrincipalId is null ||
            _runtimeProbePrincipalId != context.Identity.RuntimePrincipalObjectId ||
            deadlineUtc.Offset != TimeSpan.Zero ||
            deadlineUtc > now.Add(PurviewRuntimeTestLimits.ExecutionDeadline))
            return ProbeFailure(PurviewRuntimeTestFailureCodes.ContextInvalid, contentSubmissionStarted: false);
        if (deadlineUtc <= now)
            return ProbeFailure(PurviewRuntimeTestFailureCodes.DeadlineExceeded, contentSubmissionStarted: false);
        if (context.Versions.InventoryExpiresAtUtc <= now)
            return ProbeFailure(PurviewRuntimeTestFailureCodes.InventoryExpired, contentSubmissionStarted: false);

        using var timeout = new CancellationTokenSource(deadlineUtc - now, _runtimeProbeClock);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeout.Token);
        var contentSubmissionStarted = false;
        JsonObject? contentRequest = null;
        try
        {
            deadline.Token.ThrowIfCancellationRequested();
            var content = sample.ReadContent();
            if (content.Length is < 1 or > PurviewRuntimeTestLimits.MaximumUtf8BytesPerSample ||
                ProbeUtf8.GetByteCount(content) > PurviewRuntimeTestLimits.MaximumUtf8BytesPerSample)
                return ProbeFailure(PurviewRuntimeTestFailureCodes.SampleBoundsExceeded, contentSubmissionStarted: false);

            // Identity is server-resolved, version-bound consent. No credential/endpoint is taken
            // from it; the existing Graph transport supplies the configured managed identity.
            var identity = context.Identity;
            var interaction = new PurviewInteraction(
                identity.AgentRegistrationId,
                identity.ActorObjectId.ToString("D"),
                $"{operationId:D}:runtime-test:{sample.CaseId:D}",
                string.Empty,
                "text/plain",
                string.Empty,
                "text/plain",
                null,
                null,
                identity.ChildApplicationId.ToString("D"),
                identity.BlueprintApplicationId.ToString("D"),
                "A365 Gateway approved runtime test",
                now.UtcDateTime,
                context.PolicyMode.ToExecutionMode(),
                operationId.ToString("D"));

            // Bypass (and do not populate) the normal evaluation cache.
            var scopes = await ComputeProtectionScopesAsync(interaction, deadline.Token);
            deadline.Token.ThrowIfCancellationRequested();
            if (context.Versions.InventoryExpiresAtUtc <= _runtimeProbeClock.GetUtcNow())
                return ProbeFailure(PurviewRuntimeTestFailureCodes.InventoryExpired, contentSubmissionStarted: false);
            if (!scopes.ExecutionModes.TryGetValue(UploadText, out var executionMode) ||
                (!string.Equals(executionMode, EvaluateInline, StringComparison.OrdinalIgnoreCase) &&
                 !string.Equals(executionMode, EvaluateOffline, StringComparison.OrdinalIgnoreCase)) ||
                string.IsNullOrWhiteSpace(scopes.ETag) || scopes.ETag.Length > 512 ||
                scopes.ETag.Any(char.IsControl))
                return ProbeFailure(PurviewRuntimeTestFailureCodes.NoInlineDecision, contentSubmissionStarted: false);

            if (scopes.PolicyActions.TryGetValue(UploadText, out var scopeActions) && ContainsBlockAction(scopeActions))
                return BindProbeScope(new(PurviewRuntimeProbeDecision.Blocked, PurviewRuntimeContentProcessing.NotSubmitted,
                    PurviewRuntimeActionSource.ProtectionScope, _runtimeProbeClock.GetUtcNow()), scopes.ETag);

            contentRequest = new JsonObject
            {
                ["contentToProcess"] = ContentMetadata(interaction, UploadText, sequenceNumber: 0, content)
            };
            deadline.Token.ThrowIfCancellationRequested();
            contentSubmissionStarted = true;
            var response = await _graph.PostAsync(
                "processContent",
                UserPath(identity.ActorObjectId.ToString("D"), "processContent"),
                contentRequest,
                scopes.ETag,
                deadline.Token);
            deadline.Token.ThrowIfCancellationRequested();
            if (context.Versions.InventoryExpiresAtUtc <= _runtimeProbeClock.GetUtcNow() ||
                (response.ETag is not null && !string.Equals(response.ETag, scopes.ETag, StringComparison.Ordinal)))
                return ProbeFailure(PurviewRuntimeTestFailureCodes.ContextChanged, contentSubmissionStarted: true);
            return BindProbeScope(InterpretProbeResponse(response, executionMode, context.PolicyMode), scopes.ETag);
        }
        catch (EncoderFallbackException)
        {
            return ProbeFailure(PurviewRuntimeTestFailureCodes.SampleUtf8Invalid, contentSubmissionStarted);
        }
        catch (ObjectDisposedException)
        {
            return ProbeFailure(PurviewRuntimeTestFailureCodes.ContextInvalid, contentSubmissionStarted);
        }
        catch (OperationCanceledException)
        {
            return ProbeFailure(
                !cancellationToken.IsCancellationRequested && deadline.IsCancellationRequested
                    ? PurviewRuntimeTestFailureCodes.DeadlineExceeded
                    : PurviewRuntimeTestFailureCodes.OutcomeUnknown,
                contentSubmissionStarted);
        }
        catch (PurviewPolicyException)
        {
            return ProbeFailure(
                contentSubmissionStarted
                    ? PurviewRuntimeTestFailureCodes.OutcomeUnknown
                    : PurviewRuntimeTestFailureCodes.ProviderUnavailable,
                contentSubmissionStarted);
        }
        catch (Exception)
        {
            return ProbeFailure(PurviewRuntimeTestFailureCodes.OutcomeUnknown, contentSubmissionStarted);
        }
        finally
        {
            contentRequest?.Clear();
        }
    }

    private PurviewRuntimeProbeResult InterpretProbeResponse(
        PurviewGraphResponse response,
        string executionMode,
        PurviewPolicyMode mode)
    {
        var now = _runtimeProbeClock.GetUtcNow();
        if (response.StatusCode is HttpStatusCode.Accepted or HttpStatusCode.NoContent)
            return new(PurviewRuntimeProbeDecision.NoInlineDecision,
                PurviewRuntimeContentProcessing.SubmittedWithoutDecision, PurviewRuntimeActionSource.None, now,
                mode == PurviewPolicyMode.Enforce ? PurviewRuntimeTestFailureCodes.NoInlineDecision : null);

        if (response.StatusCode != HttpStatusCode.OK ||
            response.Body["policyActions"] is not JsonArray actions ||
            response.Body["processingErrors"] is not JsonArray errors || errors.Count != 0)
            return ProbeFailure(PurviewRuntimeTestFailureCodes.OutcomeUnknown, contentSubmissionStarted: true);

        var state = StringValue(response.Body["protectionScopeState"]);
        if (string.Equals(state, "modified", StringComparison.OrdinalIgnoreCase))
        {
            // No automatic replay of user-approved raw content, even for scope refresh.
            return ProbeFailure(PurviewRuntimeTestFailureCodes.ContextChanged, contentSubmissionStarted: true);
        }
        if (!string.Equals(state, "notModified", StringComparison.OrdinalIgnoreCase))
            return ProbeFailure(PurviewRuntimeTestFailureCodes.OutcomeUnknown, contentSubmissionStarted: true);

        var restrictions = new List<string>(actions.Count);
        foreach (var node in actions)
        {
            if (node is not JsonObject action ||
                !string.Equals(StringValue(action["action"]), "restrictAccess", StringComparison.OrdinalIgnoreCase))
                return ProbeFailure(PurviewRuntimeTestFailureCodes.OutcomeUnknown, contentSubmissionStarted: true);
            var restriction = StringValue(action["restrictionAction"]);
            if (!string.Equals(restriction, "block", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(restriction, "warn", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(restriction, "audit", StringComparison.OrdinalIgnoreCase))
                return ProbeFailure(PurviewRuntimeTestFailureCodes.OutcomeUnknown, contentSubmissionStarted: true);
            restrictions.Add(restriction!);
        }

        if (restrictions.Contains("block", StringComparer.OrdinalIgnoreCase))
            return new(PurviewRuntimeProbeDecision.Blocked, PurviewRuntimeContentProcessing.Processed,
                PurviewRuntimeActionSource.Content, now);
        if (restrictions.Contains("warn", StringComparer.OrdinalIgnoreCase))
            return new(PurviewRuntimeProbeDecision.Warned, PurviewRuntimeContentProcessing.Processed,
                PurviewRuntimeActionSource.Content, now);
        if (restrictions.Count > 0)
            return new(PurviewRuntimeProbeDecision.AuditAccepted, PurviewRuntimeContentProcessing.Processed,
                PurviewRuntimeActionSource.Content, now);
        if (string.Equals(executionMode, EvaluateInline, StringComparison.OrdinalIgnoreCase))
            return new(PurviewRuntimeProbeDecision.Allowed, PurviewRuntimeContentProcessing.Processed,
                PurviewRuntimeActionSource.None, now);

        return new(PurviewRuntimeProbeDecision.NoInlineDecision,
            PurviewRuntimeContentProcessing.SubmittedWithoutDecision, PurviewRuntimeActionSource.None, now,
            mode == PurviewPolicyMode.Enforce ? PurviewRuntimeTestFailureCodes.NoInlineDecision : null);
    }

    private static bool ValidProbeContext(
        Guid operationId,
        PurviewRuntimeTestContext? context,
        PurviewRuntimeEphemeralSample? sample)
    {
        if (context?.Identity is not { } identity || context.Versions is null || sample is null ||
            !Enum.IsDefined(context.PolicyMode) || context.Versions.InventoryExpiresAtUtc.Offset != TimeSpan.Zero ||
            !context.Activities.Contains(PurviewPolicyActivity.UploadText) ||
            context.Actions is not [{ Activity: PurviewPolicyActivity.UploadText, Action: PurviewDlpAction.Block }])
            return false;
        return !new[] { operationId, sample.CaseId, identity.TenantId, identity.ActorObjectId, identity.ProfileId,
            identity.TenantConnectionId, identity.AgentRegistrationId, identity.ChildApplicationId,
            identity.BlueprintApplicationId, identity.RuntimePrincipalObjectId, context.Versions.InventoryGenerationId }
            .Contains(Guid.Empty);
    }

    private PurviewRuntimeProbeResult ProbeFailure(string code, bool contentSubmissionStarted) =>
        new(PurviewRuntimeProbeDecision.Unknown,
            contentSubmissionStarted
                ? PurviewRuntimeContentProcessing.SubmittedWithoutDecision
                : PurviewRuntimeContentProcessing.NotSubmitted,
            PurviewRuntimeActionSource.None, _runtimeProbeClock.GetUtcNow(), code);

    private static PurviewRuntimeProbeResult BindProbeScope(PurviewRuntimeProbeResult result, string etag) =>
        new(result.Decision, result.ContentProcessing, result.ActionSource, result.ObservedAtUtc, result.FailureCode,
            $"sha256:{Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
                $"A365Gateway.PurviewRuntime.Scope.v1\0{etag}"))).ToLowerInvariant()}");
}
