using System.Text.Json;
using System.Text.Json.Serialization;
using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;

namespace Gateway.Purview.Executor;

internal sealed class BlobExecutorClaimStore(BlobContainerClient container) : IExecutorClaimStore
{
    private const int MaximumClaimBytes = 4096;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public async Task<bool> TryCreateAsync(string key, ExecutorClaim value,
        CancellationToken cancellationToken)
    {
        try
        {
            await container.GetBlobClient(key).UploadAsync(
                BinaryData.FromObjectAsJson(value, JsonOptions),
                new BlobUploadOptions
                {
                    Conditions = new BlobRequestConditions { IfNoneMatch = ETag.All },
                    HttpHeaders = new BlobHttpHeaders { ContentType = "application/json" }
                }, cancellationToken);
            return true;
        }
        catch (RequestFailedException exception) when (
            exception.ErrorCode is "BlobAlreadyExists" or "ConditionNotMet")
        {
            return false;
        }
    }

    public async Task<ExecutorClaim?> ReadAsync(string key, CancellationToken cancellationToken)
    {
        var current = await ReadWithETagAsync(key, cancellationToken);
        return current?.Claim;
    }

    public async Task CompleteAsync(string key, ExecutorClaim started, CancellationToken cancellationToken)
    {
        var current = await ReadWithETagAsync(key, cancellationToken);
        if (current is null || current.Value.Claim != started ||
            current.Value.Claim.State != ExecutorClaimState.Started)
        {
            throw new InvalidOperationException("Executor claim ownership could not be verified.");
        }

        var completed = started with
        {
            State = ExecutorClaimState.Completed,
            CompletedAtUtc = DateTimeOffset.UtcNow
        };
        await container.GetBlobClient(key).UploadAsync(
            BinaryData.FromObjectAsJson(completed, JsonOptions),
            new BlobUploadOptions
            {
                Conditions = new BlobRequestConditions { IfMatch = current.Value.ETag },
                HttpHeaders = new BlobHttpHeaders { ContentType = "application/json" }
            }, cancellationToken);
    }

    private async Task<(ExecutorClaim Claim, ETag ETag)?> ReadWithETagAsync(
        string key, CancellationToken cancellationToken)
    {
        try
        {
            var download = await container.GetBlobClient(key).DownloadStreamingAsync(
                cancellationToken: cancellationToken);
            await using var content = download.Value.Content;
            if (download.Value.Details.ContentLength > MaximumClaimBytes)
                throw new InvalidOperationException("Executor claim exceeds its bounded schema.");

            var bytes = new byte[MaximumClaimBytes + 1];
            var length = 0;
            while (length < bytes.Length)
            {
                var read = await content.ReadAsync(bytes.AsMemory(length), cancellationToken);
                if (read == 0) break;
                length += read;
            }
            if (length > MaximumClaimBytes)
                throw new InvalidOperationException("Executor claim exceeds its bounded schema.");

            var claim = JsonSerializer.Deserialize<ExecutorClaim>(bytes.AsSpan(0, length), JsonOptions);
            if (claim is null || claim.InputHash is null || claim.InputHash.Length != 64 ||
                claim.InputHash.Any(character => !char.IsAsciiHexDigitLower(character)) ||
                !Enum.IsDefined(claim.State) ||
                claim.StartedAtUtc == default || claim.StartedAtUtc.Offset != TimeSpan.Zero ||
                (claim.State == ExecutorClaimState.Started && claim.CompletedAtUtc is not null) ||
                (claim.State == ExecutorClaimState.Completed &&
                 (claim.CompletedAtUtc is null || claim.CompletedAtUtc.Value.Offset != TimeSpan.Zero ||
                  claim.CompletedAtUtc < claim.StartedAtUtc)))
            {
                throw new InvalidOperationException("Executor claim is invalid.");
            }
            return (claim, download.Value.Details.ETag);
        }
        catch (RequestFailedException exception) when (exception.ErrorCode == "BlobNotFound")
        {
            return null;
        }
        catch (JsonException)
        {
            throw new InvalidOperationException("Executor claim has an invalid schema.");
        }
    }
}
