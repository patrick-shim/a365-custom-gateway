using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

public interface IPurviewRuntimeTestRunner
{
    // Synchronous request lifetime only. No raw samples enter the worker/outbox or a retry queue.
    Task<PurviewRuntimeTestBatchEvidence> RunAsync(
        Guid operationId,
        PurviewRuntimeTestPlan plan,
        PurviewRuntimeEphemeralBatch samples,
        DateTimeOffset deadlineUtc,
        CancellationToken cancellationToken);
}
