using Gateway.Purview;
using System.Security.Cryptography;
using System.Text;

namespace Gateway.Purview.Executor;

internal enum ExecutorClaimState
{
    Started,
    Completed
}

internal sealed record ExecutorClaim(
    string InputHash,
    ExecutorClaimState State,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset? CompletedAtUtc = null);

internal interface IExecutorClaimStore
{
    // Must atomically create-if-absent. A transport failure is never a claim.
    Task<bool> TryCreateAsync(
        string key,
        ExecutorClaim value,
        CancellationToken cancellationToken);

    Task<ExecutorClaim?> ReadAsync(string key, CancellationToken cancellationToken);

    // Only the request that successfully created the claim may complete it.
    Task CompleteAsync(
        string key,
        ExecutorClaim started,
        CancellationToken cancellationToken);
}

internal enum ExecutorMutationDisposition
{
    Completed,
    Replayed,
    Conflict,
    OutcomeUnknown,
    HostUnavailable
}

internal sealed class ExecutorOperationJournal(
    IExecutorClaimStore store,
    TimeProvider timeProvider,
    PurviewProcessSafety safety)
{
    public async Task<ExecutorMutationDisposition> ExecuteAsync(
        Guid deploymentOwnershipId,
        Guid tenantId,
        Guid operationId,
        string step,
        string canonicalInput,
        Func<CancellationToken, Task> mutation,
        CancellationToken cancellationToken)
    {
        if (deploymentOwnershipId == Guid.Empty || tenantId == Guid.Empty ||
            operationId == Guid.Empty ||
            step is not ("CreateKnowYourData" or "CreateDlpPolicy" or "CreateDlpRule"))
        {
            throw new ArgumentException("Invalid executor mutation identity.");
        }

        if (!safety.CanMutate)
            return ExecutorMutationDisposition.HostUnavailable;

        var key = $"v1/{deploymentOwnershipId:D}/{tenantId:D}/{operationId:D}/{step}.json";
        var hash = Convert.ToHexStringLower(
            SHA256.HashData(Encoding.UTF8.GetBytes(canonicalInput)));
        var claim = new ExecutorClaim(hash, ExecutorClaimState.Started,
            timeProvider.GetUtcNow());

        // If create throws, no provider is invoked. The durable outcome can be
        // reconciled on the next call without taking ownership of an old claim.
        if (!await store.TryCreateAsync(key, claim, cancellationToken))
        {
            var existing = await store.ReadAsync(key, cancellationToken);
            if (existing is null)
                return ExecutorMutationDisposition.OutcomeUnknown;
            if (!string.Equals(existing.InputHash, hash, StringComparison.Ordinal))
                return ExecutorMutationDisposition.Conflict;
            return existing.State == ExecutorClaimState.Completed
                ? ExecutorMutationDisposition.Replayed
                : ExecutorMutationDisposition.OutcomeUnknown;
        }

        // Never delete or reset a Started claim, even when the callback failed
        // before returning. The caller must use its exact provider readback path.
        try
        {
            if (!safety.CanMutate)
                return ExecutorMutationDisposition.OutcomeUnknown;
            await mutation(cancellationToken);
            await store.CompleteAsync(key, claim, cancellationToken);
            return ExecutorMutationDisposition.Completed;
        }
        catch (OperationCanceledException)
        {
            // The owned provider implementation kills and awaits its child.
            // Cancellation still cannot prove that no external change occurred.
            return ExecutorMutationDisposition.OutcomeUnknown;
        }
        catch (ExecutorProviderException)
        {
            return ExecutorMutationDisposition.OutcomeUnknown;
        }
    }
}

internal sealed class ExecutorProviderException : Exception
{
    public ExecutorProviderException()
        : base("Purview executor provider outcome requires exact readback.")
    {
    }
}
