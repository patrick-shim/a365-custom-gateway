namespace Gateway.Infrastructure.Services;

internal sealed class IngressRateLimitProcessStore
{
    internal SemaphoreSlim Gate { get; } = new(1, 1);

    internal Dictionary<(byte ScopeType, Guid ScopeId), ProcessBucket> Buckets { get; } = [];

    internal sealed class ProcessBucket
    {
        public DateTime WindowStartUtc { get; set; }
        public int RequestCount { get; set; }
    }
}
