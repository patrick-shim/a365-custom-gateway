using System.Text.Json;
using Amazon.S3;
using Amazon.S3.Model;
using Gateway.Domain.Interfaces;
using Microsoft.Extensions.Options;

namespace Gateway.Infrastructure.Storage;

internal sealed class S3InteractionContentStore : IInteractionContentStore
{
    private readonly IAmazonS3 _client;
    private readonly ObjectStorageOptions _options;

    public S3InteractionContentStore(IAmazonS3 client, IOptions<ObjectStorageOptions> options)
    {
        _client = client;
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
        var key = $"{now:yyyy}/{now:MM}/{now:dd}/{agentRegistrationId}/{interactionRecordId}.json";
        var json = JsonSerializer.Serialize(new
        {
            prompt = new { content = promptContent, contentType = promptContentType },
            response = new { content = responseContent, contentType = responseContentType }
        });

        await EnsureBucketAsync(ct);
        await _client.PutObjectAsync(
            new PutObjectRequest
            {
                BucketName = _options.BucketName,
                Key = key,
                ContentBody = json,
                ContentType = "application/json"
            },
            ct);

        return $"{_options.ServiceUrl.TrimEnd('/')}/{_options.BucketName}/{key}";
    }

    private async Task EnsureBucketAsync(CancellationToken ct)
    {
        if (!_options.CreateBucketIfMissing)
            return;

        try
        {
            await _client.PutBucketAsync(_options.BucketName, ct);
        }
        catch (AmazonS3Exception ex) when (
            ex.StatusCode is System.Net.HttpStatusCode.Conflict or System.Net.HttpStatusCode.OK ||
            string.Equals(ex.ErrorCode, "BucketAlreadyOwnedByYou", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(ex.ErrorCode, "BucketAlreadyExists", StringComparison.OrdinalIgnoreCase))
        {
        }
    }

    public async Task DiscardStagedAsync(
        Guid agentRegistrationId,
        Guid interactionRecordId,
        string contentReference,
        CancellationToken ct)
    {
        if (!TryParseKey(contentReference, out var key) ||
            !key.EndsWith($"/{agentRegistrationId}/{interactionRecordId}.json", StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "The staged content reference does not belong to this content store.");
        }

        await _client.DeleteObjectAsync(_options.BucketName, key, ct);
    }

    private bool TryParseKey(string contentReference, out string key)
    {
        key = string.Empty;
        if (!Uri.TryCreate(contentReference, UriKind.Absolute, out var uri) ||
            uri.Query.Length != 0 ||
            uri.Fragment.Length != 0 ||
            uri.UserInfo.Length != 0)
        {
            return false;
        }

        var prefix = $"/{_options.BucketName}/";
        var path = uri.AbsolutePath;
        if (!path.StartsWith(prefix, StringComparison.Ordinal))
            return false;

        key = Uri.UnescapeDataString(path[prefix.Length..]);
        return key.Length > 0 && !key.Contains("..", StringComparison.Ordinal);
    }
}
