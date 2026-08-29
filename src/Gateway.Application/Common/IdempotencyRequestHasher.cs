using System.Security.Cryptography;
using System.Text.Json;
using Gateway.Application.Activities.Commands;
using Gateway.Application.Interactions.Commands;
using Gateway.Application.Prompts.Commands;

namespace Gateway.Application.Common;

internal static class IdempotencyRequestHasher
{
    internal const string ActivityEndpoint = "/api/v1/agent-activities";
    internal const string BatchActivityEndpoint = "/api/v1/agent-activities:batch";
    internal const string InteractionEndpoint = "/api/v1/ai-interactions";
    internal const string PromptEvaluationEndpoint = "/api/v1/prompts:evaluate";

    public static string Compute(EvaluatePromptCommand request)
    {
        var canonicalPayload = new
        {
            request.ExternalAgentId,
            request.InteractionId,
            OccurredAtUtc = AsUtc(request.OccurredAtUtc),
            UserContext = request.UserContext is null
                ? null
                : new { request.UserContext.TenantUserObjectId },
            Prompt = new
            {
                request.Prompt.ContentType,
                request.Prompt.Content
            }
        };
        return Compute(canonicalPayload);
    }

    public static string Compute(SubmitActivityCommand request)
    {
        var canonicalPayload = new
        {
            request.ExternalAgentId,
            request.ActivityId,
            request.SessionId,
            request.ActivityType,
            OccurredAtUtc = AsUtc(request.OccurredAtUtc),
            Actor = new
            {
                request.Actor.Type,
                request.Actor.TenantUserObjectId
            },
            Tool = request.Tool is null
                ? null
                : new
                {
                    request.Tool.Name,
                    request.Tool.Operation,
                    request.Tool.Outcome,
                    request.Tool.DurationMs
                },
            Attributes = Sort(request.Attributes)
        };

        return Compute(canonicalPayload);
    }

    public static string Compute(SubmitInteractionCommand request)
    {
        var canonicalPayload = new
        {
            request.ExternalAgentId,
            request.InteractionId,
            request.SessionId,
            OccurredAtUtc = AsUtc(request.OccurredAtUtc),
            UserContext = request.UserContext is null
                ? null
                : new
                {
                    request.UserContext.TenantUserObjectId
                },
            Prompt = new
            {
                request.Prompt.ContentType,
                request.Prompt.Content
            },
            Response = new
            {
                request.Response.ContentType,
                request.Response.Content
            },
            Model = request.Model is null
                ? null
                : new
                {
                    request.Model.Provider,
                    request.Model.Name
                },
            Metadata = Sort(request.Metadata),
            request.PromptEvaluationReceiptId
        };

        return Compute(canonicalPayload);
    }

    public static string Compute(SubmitBatchActivityCommand request)
    {
        var canonicalPayload = new
        {
            request.ExternalAgentId,
            Activities = request.Activities.Select(item => new
            {
                item.ActivityId,
                item.SessionId,
                item.ActivityType,
                OccurredAtUtc = AsUtc(item.OccurredAtUtc),
                Actor = item.Actor is null
                    ? null
                    : new
                    {
                        item.Actor.Type,
                        item.Actor.TenantUserObjectId
                    },
                Tool = item.Tool is null
                    ? null
                    : new
                    {
                        item.Tool.Name,
                        item.Tool.Operation,
                        item.Tool.Outcome,
                        item.Tool.DurationMs
                    },
                Attributes = Sort(item.Attributes)
            })
        };

        return Compute(canonicalPayload);
    }

    private static string Compute<T>(T canonicalPayload)
    {
        var payloadBytes = JsonSerializer.SerializeToUtf8Bytes(canonicalPayload);
        try
        {
            return Convert.ToHexString(SHA256.HashData(payloadBytes));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(payloadBytes);
        }
    }

    private static SortedDictionary<string, string>? Sort(
        IReadOnlyDictionary<string, string>? values)
    {
        if (values is null)
            return null;

        var sorted = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in values)
            sorted.Add(pair.Key, pair.Value);

        return sorted;
    }

    private static DateTime AsUtc(DateTime value) => value.Kind switch
    {
        DateTimeKind.Utc => value,
        DateTimeKind.Local => value.ToUniversalTime(),
        _ => DateTime.SpecifyKind(value, DateTimeKind.Utc)
    };
}
