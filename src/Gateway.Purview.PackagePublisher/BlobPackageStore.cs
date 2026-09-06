using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;

namespace Gateway.Purview.PackagePublisher;

internal sealed class BlobPackageStore(BlobClient client) : IPackageStore
{
    public async Task<bool> ExistsAsync(CancellationToken cancellationToken) =>
        (await client.ExistsAsync(cancellationToken)).Value;

    public async Task CreateOnlyAsync(Stream content, CancellationToken cancellationToken) =>
        await client.UploadAsync(content, new BlobUploadOptions
        {
            Conditions = new BlobRequestConditions { IfNoneMatch = ETag.All },
            HttpHeaders = new BlobHttpHeaders { ContentType = "application/zip" },
            TransferOptions = new Azure.Storage.StorageTransferOptions
            {
                InitialTransferSize = 4 * 1024 * 1024,
                MaximumTransferSize = 4 * 1024 * 1024,
                MaximumConcurrency = 1
            }
        }, cancellationToken);

    public async Task<Stream> OpenExactReadAsync(long expectedLength, CancellationToken cancellationToken)
    {
        var properties = (await client.GetPropertiesAsync(cancellationToken: cancellationToken)).Value;
        if (properties.ContentLength != expectedLength || properties.BlobType != BlobType.Block)
        {
            throw new InvalidOperationException("Package blob shape differs.");
        }

        return (await client.DownloadStreamingAsync(new BlobDownloadOptions
        {
            Conditions = new BlobRequestConditions { IfMatch = properties.ETag }
        }, cancellationToken)).Value.Content;
    }
}
