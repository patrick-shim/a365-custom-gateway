using System.Collections.Concurrent;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Purview;

public sealed class PurviewPolicyClient : IPurviewPolicyClient
{
    private const string UploadText = "uploadText";
    private const string DownloadText = "downloadText";
    private const string EvaluateInline = "evaluateInline";
    private const string EvaluateOffline = "evaluateOffline";

    private readonly ILogger<PurviewPolicyClient> _logger;
    private readonly PurviewOptions _options;
    private readonly IMemoryCache _cache;
    private readonly IPurviewGraphClient _graph;
    private readonly ConcurrentDictionary<ScopeCacheKey, SemaphoreSlim> _scopeLocks = new();

    internal PurviewPolicyClient(
        ILogger<PurviewPolicyClient> logger,
        IOptions<PurviewOptions> options,
        IMemoryCache cache,
        IPurviewGraphClient graph)
    {
        _logger = logger;
        _options = options.Value;
        _cache = cache;
        _graph = graph;
    }

    public bool IsEnabled => _options.Enabled;
    public PurviewMode DefaultMode => Enum.Parse<PurviewMode>(_options.DefaultMode);

    public async Task<PurviewEvaluationResult> EvaluatePromptAsync(
        PurviewInteraction interaction,
        CancellationToken cancellationToken)
    {
        Validate(interaction);
        if (!IsEnabled)
        {
            throw new PurviewPolicyException(
                "PURVIEW_NOT_CONFIGURED",
                "Purview evaluation is not enabled for this Gateway deployment.");
        }

        _logger.LogInformation(
            "Evaluating Purview prompt policy for agent registration {AgentRegistrationId}, correlation {CorrelationId}",
            interaction.AgentRegistrationId,
            interaction.CorrelationId);

        if (interaction.ExecutionMode == PurviewExecutionMode.EvaluateOffline)
        {
            await SubmitContentActivityAsync(interaction, UploadText, sequenceNumber: 0, cancellationToken);
            return new PurviewEvaluationResult(true, PurviewDecisionType.AuditLogged, "Audit", null);
        }

        var scopes = await GetProtectionScopesAsync(interaction, forceRefresh: false, cancellationToken);
        return await EvaluateContentAsync(
            interaction,
            UploadText,
            interaction.PromptContent,
            sequenceNumber: 0,
            scopes,
            cancellationToken);
    }

    public async Task<PurviewEvaluationResult> EvaluateInteractionAsync(
        PurviewInteraction interaction,
        CancellationToken cancellationToken)
    {
        Validate(interaction);
        if (!IsEnabled)
        {
            throw new PurviewPolicyException(
                "PURVIEW_NOT_CONFIGURED",
                "Purview evaluation is not enabled for this Gateway deployment.");
        }

        _logger.LogInformation(
            "Evaluating Purview policy for agent registration {AgentRegistrationId}, correlation {CorrelationId}",
            interaction.AgentRegistrationId,
            interaction.CorrelationId);

        if (interaction.ExecutionMode == PurviewExecutionMode.EvaluateOffline)
        {
            await SubmitContentActivityAsync(interaction, UploadText, sequenceNumber: 0, cancellationToken);
            await SubmitContentActivityAsync(interaction, DownloadText, sequenceNumber: 1, cancellationToken);
            return new PurviewEvaluationResult(true, PurviewDecisionType.AuditLogged, "Audit", null);
        }

        var scopes = await GetProtectionScopesAsync(interaction, forceRefresh: false, cancellationToken);
        var prompt = await EvaluateContentAsync(
            interaction,
            UploadText,
            interaction.PromptContent,
            sequenceNumber: 0,
            scopes,
            cancellationToken);
        if (!prompt.IsAllowed)
            return prompt;

        var response = await EvaluateContentAsync(
            interaction,
            DownloadText,
            interaction.ResponseContent,
            sequenceNumber: 1,
            scopes,
            cancellationToken);
        if (!response.IsAllowed)
            return response;

        var state = response.ProtectionScopeState ?? prompt.ProtectionScopeState;
        var action = response.PolicyAction ?? prompt.PolicyAction;
        var decision = prompt.Decision == PurviewDecisionType.AuditLogged
            || response.Decision == PurviewDecisionType.AuditLogged
                ? PurviewDecisionType.AuditLogged
                : PurviewDecisionType.Allowed;
        return new PurviewEvaluationResult(true, decision, action, state);
    }

    private async Task<PurviewEvaluationResult> EvaluateContentAsync(
        PurviewInteraction interaction,
        string activity,
        string content,
        long sequenceNumber,
        ProtectionScopes scopes,
        CancellationToken cancellationToken)
    {
        var actions = scopes.PolicyActions.TryGetValue(activity, out var scopedActions)
            ? scopedActions
            : [];
        if (ContainsBlockAction(actions))
            return Blocked(actions, protectionScopeState: null);

        if (!scopes.ExecutionModes.TryGetValue(activity, out var executionMode))
        {
            throw new PurviewPolicyException(
                "PURVIEW_SCOPE_MISSING",
                "No applicable Purview protection scope was returned for inline enforcement.");
        }

        var requireInlineDecision = string.Equals(
            executionMode,
            EvaluateInline,
            StringComparison.OrdinalIgnoreCase);
        if (!requireInlineDecision
            && !string.Equals(executionMode, EvaluateOffline, StringComparison.OrdinalIgnoreCase))
        {
            throw new PurviewPolicyException(
                "PURVIEW_SCOPE_INVALID_EXECUTION_MODE",
                "Purview returned an unsupported protection-scope execution mode.");
        }

        var decision = await ProcessContentAsync(
            interaction,
            activity,
            content,
            sequenceNumber,
            scopes,
            requireInlineDecision,
            cancellationToken);
        if (!string.Equals(
                decision.ProtectionScopeState,
                "modified",
                StringComparison.OrdinalIgnoreCase))
        {
            return decision;
        }

        var refreshed = await GetProtectionScopesAsync(interaction, forceRefresh: true, cancellationToken);
        var refreshedDecision = await ProcessContentAsync(
            interaction,
            activity,
            content,
            sequenceNumber,
            refreshed,
            requireInlineDecision,
            cancellationToken);
        if (string.Equals(
                refreshedDecision.ProtectionScopeState,
                "modified",
                StringComparison.OrdinalIgnoreCase))
        {
            throw new PurviewPolicyException(
                "PURVIEW_SCOPE_UNSTABLE",
                "The Purview protection scope changed repeatedly during evaluation.",
                isTransient: true);
        }

        return refreshedDecision;
    }

    private async Task<ProtectionScopes> GetProtectionScopesAsync(
        PurviewInteraction interaction,
        bool forceRefresh,
        CancellationToken cancellationToken)
    {
        var key = new ScopeCacheKey(interaction.TenantUserObjectId, interaction.BlueprintClientId);
        if (!forceRefresh && _cache.TryGetValue(key, out ProtectionScopes? cached) && cached is not null)
            return cached;

        var gate = _scopeLocks.GetOrAdd(key, static _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (!forceRefresh && _cache.TryGetValue(key, out cached) && cached is not null)
                return cached;

            var computed = await ComputeProtectionScopesAsync(interaction, cancellationToken);
            // Do not pin an offline-only or empty scope in memory. Purview policy
            // distribution is asynchronous, so an Enforce registration must be
            // able to observe the first inline scope as soon as it becomes active.
            if (computed.ExecutionModes.Values.Any(mode =>
                    string.Equals(mode, EvaluateInline, StringComparison.OrdinalIgnoreCase)))
            {
                _cache.Set(
                    key,
                    computed,
                    TimeSpan.FromMinutes(_options.ProtectionScopeCacheMinutes));
            }
            return computed;
        }
        finally
        {
            gate.Release();
        }
    }

    private async Task<ProtectionScopes> ComputeProtectionScopesAsync(
        PurviewInteraction interaction,
        CancellationToken cancellationToken)
    {
        var response = await _graph.PostAsync(
            "computeProtectionScopes",
            UserPath(interaction.TenantUserObjectId, "protectionScopes/compute"),
            new JsonObject
            {
                ["activities"] = $"{UploadText},{DownloadText}",
                ["locations"] = new JsonArray(ApplicationLocation(interaction)),
                ["integratedAppMetadata"] = IntegratedAppMetadata()
            },
            ifNoneMatch: null,
            cancellationToken);

        if (response.StatusCode != System.Net.HttpStatusCode.OK)
        {
            throw new PurviewPolicyException(
                "PURVIEW_SCOPE_INVALID_STATUS",
                "Microsoft Graph did not return a Purview protection scope.");
        }

        var executionModes = new Dictionary<string, string>(StringComparer.Ordinal);
        var policyActions = new Dictionary<string, List<JsonObject>>(StringComparer.Ordinal);
        if (response.Body["value"] is JsonArray values)
        {
            foreach (var scope in values.OfType<JsonObject>())
            {
                var mode = StringValue(scope["executionMode"]);
                var actions = scope["policyActions"] is JsonArray actionArray
                    ? actionArray.OfType<JsonObject>().Select(Clone).ToArray()
                    : [];
                foreach (var activity in (StringValue(scope["activities"]) ?? string.Empty)
                             .Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
                {
                    if (activity is not UploadText and not DownloadText)
                        continue;

                    if (mode is not null
                        && (string.Equals(mode, EvaluateInline, StringComparison.OrdinalIgnoreCase)
                            || !executionModes.ContainsKey(activity)))
                    {
                        executionModes[activity] = mode;
                    }

                    if (!policyActions.TryGetValue(activity, out var collected))
                    {
                        collected = [];
                        policyActions[activity] = collected;
                    }

                    collected.AddRange(actions.Select(Clone));
                }
            }
        }

        return new ProtectionScopes(
            response.ETag,
            executionModes,
            policyActions.ToDictionary(
                pair => pair.Key,
                pair => (IReadOnlyList<JsonObject>)pair.Value,
                StringComparer.Ordinal));
    }

    private async Task<PurviewEvaluationResult> ProcessContentAsync(
        PurviewInteraction interaction,
        string activity,
        string content,
        long sequenceNumber,
        ProtectionScopes scopes,
        bool requireInlineDecision,
        CancellationToken cancellationToken)
    {
        var response = await _graph.PostAsync(
            "processContent",
            UserPath(interaction.TenantUserObjectId, "processContent"),
            new JsonObject
            {
                ["contentToProcess"] = ContentMetadata(
                    interaction,
                    activity,
                    sequenceNumber,
                    content)
            },
            scopes.ETag,
            cancellationToken);

        if (response.StatusCode is System.Net.HttpStatusCode.Accepted
            or System.Net.HttpStatusCode.NoContent)
        {
            if (requireInlineDecision)
            {
                throw new PurviewPolicyException(
                    "PURVIEW_INLINE_DECISION_MISSING",
                    "Purview did not return the required inline policy decision.",
                    isTransient: true);
            }

            return new PurviewEvaluationResult(
                true,
                PurviewDecisionType.AuditLogged,
                "Audit",
                null);
        }

        if (response.StatusCode != System.Net.HttpStatusCode.OK)
        {
            throw new PurviewPolicyException(
                "PURVIEW_PROCESS_INVALID_STATUS",
                "Microsoft Graph did not return a valid Purview policy decision.");
        }

        if (response.Body["processingErrors"] is JsonArray errors && errors.Count > 0)
        {
            throw new PurviewPolicyException(
                "PURVIEW_PROCESSING_ERROR",
                "Purview reported an error while evaluating the content.");
        }

        var actions = response.Body["policyActions"] is JsonArray actionArray
            ? actionArray.OfType<JsonObject>().ToArray()
            : [];
        var state = StringValue(response.Body["protectionScopeState"]);
        if (ContainsBlockAction(actions))
            return Blocked(actions, state);

        return requireInlineDecision
            ? new PurviewEvaluationResult(
                true,
                PurviewDecisionType.Allowed,
                SummarizeAction(actions),
                state)
            : new PurviewEvaluationResult(
                true,
                PurviewDecisionType.AuditLogged,
                SummarizeAction(actions) ?? "Audit",
                state);
    }

    private async Task SubmitContentActivityAsync(
        PurviewInteraction interaction,
        string activity,
        long sequenceNumber,
        CancellationToken cancellationToken)
    {
        var response = await _graph.PostAsync(
            "createContentActivity",
            UserPath(interaction.TenantUserObjectId, "activities/contentActivities"),
            new JsonObject
            {
                // Microsoft Graph calls this property contentToProcess even for
                // contentActivity. Content itself is intentionally omitted.
                ["contentToProcess"] = ContentMetadata(
                    interaction,
                    activity,
                    sequenceNumber,
                    content: null,
                    includeAgentInfo: false)
            },
            ifNoneMatch: null,
            cancellationToken);

        if (response.StatusCode != System.Net.HttpStatusCode.Created)
        {
            throw new PurviewPolicyException(
                "PURVIEW_AUDIT_INVALID_STATUS",
                "Microsoft Graph did not accept the Purview content activity.");
        }
    }

    private JsonObject ContentMetadata(
        PurviewInteraction interaction,
        string activity,
        long sequenceNumber,
        string? content,
        bool includeAgentInfo = true)
    {
        var timestamp = interaction.OccurredAtUtc
            .ToUniversalTime()
            .ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
        var entry = new JsonObject
        {
            ["@odata.type"] = "microsoft.graph.processConversationMetadata",
            ["identifier"] = ContentEntryIdentifier(interaction, activity),
            ["name"] = $"{interaction.AgentName} {activity}",
            ["correlationId"] = interaction.CorrelationId,
            ["sequenceNumber"] = sequenceNumber,
            ["isTruncated"] = false,
            ["createdDateTime"] = timestamp,
            ["modifiedDateTime"] = timestamp
        };
        if (includeAgentInfo)
        {
            entry["agents"] = new JsonArray(new JsonObject
            {
                ["@odata.type"] = "microsoft.graph.aiAgentInfo",
                ["blueprintId"] = interaction.BlueprintClientId,
                ["identifier"] = interaction.AgentIdentityClientId,
                ["name"] = interaction.AgentName,
                ["version"] = "1.0"
            });
        }

        if (content is not null)
        {
            entry["content"] = new JsonObject
            {
                ["@odata.type"] = "microsoft.graph.textContent",
                ["data"] = content
            };
        }

        return new JsonObject
        {
            ["contentEntries"] = new JsonArray(entry),
            ["activityMetadata"] = new JsonObject { ["activity"] = activity },
            ["protectedAppMetadata"] = new JsonObject
            {
                ["name"] = interaction.AgentName,
                ["version"] = "1.0",
                ["applicationLocation"] = ApplicationLocation(interaction)
            },
            ["integratedAppMetadata"] = IntegratedAppMetadata()
        };
    }

    private JsonObject IntegratedAppMetadata() => new()
    {
        ["name"] = _options.AppName,
        ["version"] = _options.AppVersion
    };

    private static JsonObject ApplicationLocation(PurviewInteraction interaction) => new()
    {
        ["@odata.type"] = "microsoft.graph.policyLocationApplication",
        ["value"] = interaction.BlueprintClientId
    };

    private static string UserPath(string userObjectId, string suffix) =>
        $"users/{Uri.EscapeDataString(userObjectId)}/dataSecurityAndGovernance/{suffix}";

    private static string ContentEntryIdentifier(
        PurviewInteraction interaction,
        string activity)
    {
        var source = $"{interaction.AgentRegistrationId:D}\n{interaction.ExternalInteractionId}\n{activity}";
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(source));
        return new Guid(hash.AsSpan(0, 16)).ToString("D");
    }

    private static PurviewEvaluationResult Blocked(
        IReadOnlyCollection<JsonObject> actions,
        string? protectionScopeState) =>
        new(
            false,
            PurviewDecisionType.Blocked,
            SummarizeAction(actions) ?? "RestrictAccess:Block",
            protectionScopeState);

    private static bool ContainsBlockAction(IEnumerable<JsonObject> actions) =>
        actions.Any(action =>
            string.Equals(StringValue(action["action"]), "restrictAccess", StringComparison.OrdinalIgnoreCase)
            && string.Equals(
                StringValue(action["restrictionAction"]),
                "block",
                StringComparison.OrdinalIgnoreCase));

    private static string? SummarizeAction(IEnumerable<JsonObject> actions)
    {
        foreach (var action in actions)
        {
            var name = StringValue(action["action"]);
            var restriction = StringValue(action["restrictionAction"]);
            if (string.Equals(name, "restrictAccess", StringComparison.OrdinalIgnoreCase)
                && restriction is not null)
            {
                var summary = $"RestrictAccess:{restriction}";
                return summary[..Math.Min(30, summary.Length)];
            }

            if (!string.IsNullOrWhiteSpace(name))
                return name[..Math.Min(30, name.Length)];
        }

        return null;
    }

    private static string? StringValue(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static JsonObject Clone(JsonObject value) =>
        JsonNode.Parse(value.ToJsonString())!.AsObject();

    private static void Validate(PurviewInteraction interaction)
    {
        if (interaction.AgentRegistrationId == Guid.Empty
            || !Guid.TryParse(interaction.TenantUserObjectId, out var userId)
            || userId == Guid.Empty
            || !Guid.TryParse(interaction.AgentIdentityClientId, out var agentId)
            || agentId == Guid.Empty
            || !Guid.TryParse(interaction.BlueprintClientId, out var blueprintId)
            || blueprintId == Guid.Empty
            || string.IsNullOrWhiteSpace(interaction.ExternalInteractionId)
            || string.IsNullOrWhiteSpace(interaction.AgentName))
        {
            throw new PurviewPolicyException(
                "PURVIEW_INTERACTION_INVALID",
                "The interaction does not contain valid Purview identity metadata.");
        }
    }

    private readonly record struct ScopeCacheKey(string UserObjectId, string BlueprintClientId);

    private sealed record ProtectionScopes(
        string? ETag,
        IReadOnlyDictionary<string, string> ExecutionModes,
        IReadOnlyDictionary<string, IReadOnlyList<JsonObject>> PolicyActions);
}
