using System.Text.Json;
using Azure.Storage.Blobs;
using Gateway.Domain.Interfaces;
using Microsoft.Extensions.Options;

namespace Gateway.Infrastructure.Storage;

internal sealed class BlobInteractionContentStore : IInteractionContentStore
{
    private readonly BlobServiceClient _blobServiceClient;
    private readonly BlobStorageOptions _options;

    public BlobInteractionContentStore(
        IOptions<BlobStorageOptions> options,
        BlobServiceClient blobServiceClient)
    {
        _blobServiceClient = blobServiceClient;
        _options = options.Value;
    }

    public async Task<string> StoreAsync(
        Guid agentRegistrationId,
        Guid interactionRecordId,
        string promptContent,
        string promptContentType,
        string responseContent,
        string responseContentType,
        CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;
        var blobPath = $"{now:yyyy}/{now:MM}/{now:dd}/{agentRegistrationId}/{interactionRecordId}.json";

        var content = new
        {
            prompt = new { content = promptContent, contentType = promptContentType },
            response = new { content = responseContent, contentType = responseContentType }
        };

        var json = JsonSerializer.Serialize(content);

        var containerClient = _blobServiceClient.GetBlobContainerClient(_options.ContainerName);
        var blobClient = containerClient.GetBlobClient(blobPath);
        await blobClient.UploadAsync(BinaryData.FromString(json), overwrite: true, cancellationToken: ct);

        return blobClient.Uri.ToString();
    }
}
