using System.Collections.Concurrent;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;

namespace Gateway.TestSupport;

public sealed class OfflineProviderException() : InvalidOperationException(
    "No explicitly scripted provider response remains. Network and ambient authentication are forbidden in this suite.");

public sealed class OfflineBlueprintCatalog : IAgentIdentityBlueprintCatalog
{
    private int _calls;
    public IReadOnlyList<AgentIdentityBlueprintCatalogItem>? Items { get; set; }
    public int MaximumCalls { get; init; } = 1;
    public int Calls => Volatile.Read(ref _calls);

    public Task<IReadOnlyList<AgentIdentityBlueprintCatalogItem>> ListAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (Interlocked.Increment(ref _calls) > MaximumCalls)
            throw new OfflineProviderException();
        return Task.FromResult(Items ?? throw new OfflineProviderException());
    }
}

public sealed class OfflinePromptShield : IPromptShieldClient
{
    private int _calls;
    public bool IsEnabled { get; set; }
    public int MaximumCalls { get; init; } = 1;
    public TimeSpan ReceiptLifetime { get; set; } = TimeSpan.FromMinutes(5);
    public Func<string, PromptShieldSubject, CancellationToken, Task<PromptShieldEvaluationResult>>? Evaluate { get; set; }
    public int Calls => Volatile.Read(ref _calls);
    public ConcurrentQueue<PromptShieldSubject> Subjects { get; } = new();

    public Task<PromptShieldEvaluationResult> EvaluateAsync(
        string prompt, PromptShieldSubject subject, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (Interlocked.Increment(ref _calls) > MaximumCalls)
            throw new OfflineProviderException();
        Subjects.Enqueue(subject);
        return Evaluate?.Invoke(prompt, subject, cancellationToken) ?? throw new OfflineProviderException();
    }
}

public sealed class OfflinePurview : IPurviewPolicyClient
{
    public bool IsEnabled { get; set; }
    public PurviewMode DefaultMode => PurviewMode.Enforce;
    public Task<PurviewEvaluationResult> EvaluatePromptAsync(PurviewInteraction interaction, CancellationToken ct) =>
        throw new OfflineProviderException();
    public Task<PurviewEvaluationResult> EvaluateInteractionAsync(PurviewInteraction interaction, CancellationToken ct) =>
        throw new OfflineProviderException();
}

public sealed class OfflineContentStore : IInteractionContentStore
{
    private int _stores;
    private int _discards;
    public bool AllowStaging { get; set; }
    public int MaximumStores { get; init; } = 1;
    public Func<CancellationToken, Task>? BeforeReturn { get; set; }
    public int Stores => Volatile.Read(ref _stores);
    public int Discards => Volatile.Read(ref _discards);
    public ConcurrentDictionary<Guid, string> Staged { get; } = new();

    public async Task<string> StoreAsync(Guid agentRegistrationId, Guid interactionRecordId,
        string promptContent, string promptContentType, string responseContent,
        string responseContentType, CancellationToken ct)
    {
        if (!AllowStaging)
            throw new OfflineProviderException();
        ct.ThrowIfCancellationRequested();
        if (Interlocked.Increment(ref _stores) > MaximumStores)
            throw new OfflineProviderException();
        var reference = $"offline://content/{agentRegistrationId:D}/{interactionRecordId:D}";
        if (!Staged.TryAdd(interactionRecordId, reference))
            throw new InvalidOperationException("A content record was staged twice.");
        if (BeforeReturn is not null)
            await BeforeReturn(ct);
        return reference;
    }

    public Task DiscardStagedAsync(Guid agentRegistrationId, Guid interactionRecordId, string contentReference, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!Staged.TryRemove(new KeyValuePair<Guid, string>(interactionRecordId, contentReference)))
            throw new InvalidOperationException("Only the exact staged content can be discarded.");
        Interlocked.Increment(ref _discards);
        return Task.CompletedTask;
    }
}

public sealed class OfflineHttpHandler : HttpMessageHandler
{
    private int _calls;
    public Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>>? Respond { get; set; }
    public int MaximumCalls { get; init; } = 1;
    public int Calls => Volatile.Read(ref _calls);

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (Interlocked.Increment(ref _calls) > MaximumCalls)
            throw new OfflineProviderException();
        return Respond?.Invoke(request, cancellationToken) ?? throw new OfflineProviderException();
    }
}
