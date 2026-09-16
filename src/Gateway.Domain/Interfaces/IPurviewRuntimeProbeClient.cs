using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

public interface IPurviewRuntimeProbeClient
{
    // The caller must commit authorization/acceptance before invoking this side-effecting method.
    // Implementations use fresh scopes, never infer sample processing from cached scope actions,
    // and must honor the deadline and cancellation without retaining or queueing the sample.
    Task<PurviewRuntimeProbeResult> ProbeAsync(
        Guid operationId,
        PurviewRuntimeTestContext context,
        PurviewRuntimeEphemeralSample sample,
        DateTimeOffset deadlineUtc,
        CancellationToken cancellationToken);
}
