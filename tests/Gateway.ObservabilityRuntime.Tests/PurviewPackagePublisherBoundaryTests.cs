using System.Net;
using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using FluentAssertions;
using Gateway.Purview.PackagePublisher;
using NSubstitute;

namespace Gateway.ObservabilityRuntime.Tests;

public sealed class PurviewPackagePublisherBoundaryTests
{
    [Fact]
    public async Task Actual_sdk_upload_is_create_only_and_forwards_deadline()
    {
        var client = Substitute.For<BlobClient>();
        using var deadline = new CancellationTokenSource();
        using var content = new MemoryStream([1]);
        await new BlobPackageStore(client).CreateOnlyAsync(content, deadline.Token);
        await client.Received(1).UploadAsync(content,
            Arg.Is<BlobUploadOptions>(o => o.Conditions.IfNoneMatch == ETag.All &&
                o.TransferOptions.MaximumConcurrency == 1), deadline.Token);
    }

    [Fact]
    public async Task Actual_sdk_download_is_pinned_to_independent_metadata_etag()
    {
        var client = ClientWithProperties(BlobType.Block, 5);
        using var deadline = new CancellationTokenSource();
        var content = new MemoryStream([1, 2, 3, 4, 5]);
        client.DownloadStreamingAsync(Arg.Any<BlobDownloadOptions>(), Arg.Any<CancellationToken>())
            .Returns(Response.FromValue(BlobsModelFactory.BlobDownloadStreamingResult(content, null), Substitute.For<Response>()));

        await using var result = await new BlobPackageStore(client).OpenExactReadAsync(5, deadline.Token);
        result.Should().BeSameAs(content);
        await client.Received(1).DownloadStreamingAsync(
            Arg.Is<BlobDownloadOptions>(o => o.Conditions.IfMatch == new ETag("observed-version")), deadline.Token);
    }

    [Theory]
    [InlineData(BlobType.Append, 5)]
    [InlineData(BlobType.Page, 5)]
    [InlineData(BlobType.Block, 4)]
    [InlineData(BlobType.Block, 6)]
    public async Task Wrong_blob_shape_never_downloads(BlobType type, long length)
    {
        var client = ClientWithProperties(type, length);
        var action = () => new BlobPackageStore(client).OpenExactReadAsync(5, default);
        await action.Should().ThrowAsync<InvalidOperationException>();
        await client.DidNotReceive().DownloadStreamingAsync(Arg.Any<BlobDownloadOptions>(), Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Changed_blob_etag_failure_is_not_retried_or_replaced()
    {
        var client = ClientWithProperties(BlobType.Block, 5);
        client.DownloadStreamingAsync(Arg.Any<BlobDownloadOptions>(), Arg.Any<CancellationToken>())
            .Returns<Task<Response<BlobDownloadStreamingResult>>>(_ => throw new RequestFailedException(412, "synthetic"));
        var action = () => new BlobPackageStore(client).OpenExactReadAsync(5, default);
        await action.Should().ThrowAsync<RequestFailedException>().Where(e => e.Status == 412);
        await client.Received(1).DownloadStreamingAsync(Arg.Any<BlobDownloadOptions>(), Arg.Any<CancellationToken>());
        await client.DidNotReceive().UploadAsync(Arg.Any<Stream>(), Arg.Any<BlobUploadOptions>(), Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData("PUBLISHER_EXECUTION_SOURCE_FINGERPRINT", "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n")]
    [InlineData("PUBLISHER_EXECUTION_SOURCE_FINGERPRINT", "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n")]
    [InlineData("PUBLISHER_PACKAGE_DIGEST", "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n")]
    [InlineData("PUBLISHER_PACKAGE_BYTES", "0")]
    [InlineData("PUBLISHER_PACKAGE_BYTES", "1073741825")]
    [InlineData("PUBLISHER_PACKAGE_BYTES", "+5")]
    [InlineData("PUBLISHER_PACKAGE_BYTES", "05")]
    [InlineData("PUBLISHER_PACKAGE_BYTES", "5\n")]
    [InlineData("PUBLISHER_PRIVATE_ENDPOINT_IP", "8.8.8.8")]
    [InlineData("PUBLISHER_PRIVATE_ENDPOINT_IP", "127.0.0.1")]
    [InlineData("PUBLISHER_PRIVATE_ENDPOINT_IP", "::ffff:10.42.2.4")]
    [InlineData("PUBLISHER_PRIVATE_ENDPOINT_IP", "10.42.2.004")]
    [InlineData("PUBLISHER_DEPLOYMENT_OWNERSHIP_ID", "00000000-0000-0000-0000-000000000000")]
    public void Invalid_host_binding_is_rejected_before_dns_or_credentials(string name, string value)
    {
        var values = ValidConfiguration();
        values[name] = value;
        var action = () => PublisherConfiguration.Load(key => values.GetValueOrDefault(key));
        action.Should().Throw<InvalidOperationException>();
    }

    [Theory]
    [InlineData("")]
    [InlineData("10.42.2.5")]
    [InlineData("10.42.2.4,10.42.2.5")]
    [InlineData("10.42.2.4,8.8.8.8")]
    [InlineData("::ffff:10.42.2.4")]
    public void Dns_must_return_only_the_exact_reviewed_private_ipv4(string addresses)
    {
        var values = ValidConfiguration();
        var configuration = PublisherConfiguration.Load(key => values.GetValueOrDefault(key));
        var answer = addresses.Length == 0 ? [] : addresses.Split(',').Select(IPAddress.Parse).ToArray();
        var action = () => configuration.ValidateResolution(answer);
        action.Should().Throw<InvalidOperationException>();
        configuration.ValidateResolution([IPAddress.Parse("10.42.2.4")]);
    }

    [Fact]
    public void Host_uses_bounded_no_retry_client_without_provider_diagnostics()
    {
        var options = PublisherConfiguration.CreateClientOptions();
        options.Retry.MaxRetries.Should().Be(0);
        options.Retry.NetworkTimeout.Should().Be(TimeSpan.FromSeconds(60));
        options.Diagnostics.IsLoggingEnabled.Should().BeFalse();
        options.Diagnostics.IsLoggingContentEnabled.Should().BeFalse();
        options.Diagnostics.IsDistributedTracingEnabled.Should().BeFalse();
        PublisherConfiguration.OperationTimeout.Should().Be(TimeSpan.FromMinutes(10));
        PublisherConfiguration.CreateCredential().GetType().FullName.Should().Be("Azure.Identity.ManagedIdentityCredential");
    }

    private static BlobClient ClientWithProperties(BlobType type, long length)
    {
        var client = Substitute.For<BlobClient>();
        client.GetPropertiesAsync(Arg.Any<BlobRequestConditions>(), Arg.Any<CancellationToken>())
            .Returns(Response.FromValue(BlobsModelFactory.BlobProperties(
                blobType: type, contentLength: length, eTag: new ETag("observed-version")), Substitute.For<Response>()));
        return client;
    }

    private static Dictionary<string, string> ValidConfiguration() => new()
    {
        ["PUBLISHER_DEPLOYMENT_OWNERSHIP_ID"] = "11111111-1111-4111-8111-111111111111",
        ["PUBLISHER_EXECUTION_INTENT_ID"] = "22222222-2222-4222-8222-222222222222",
        ["PUBLISHER_EXECUTION_SOURCE_FINGERPRINT"] = "sha256:" + new string('a', 64),
        ["PUBLISHER_PACKAGE_DIGEST"] = "sha256:" + new string('b', 64),
        ["PUBLISHER_PACKAGE_BYTES"] = "5",
        ["PUBLISHER_CONTAINER_URI"] = "https://abcdef.blob.core.windows.net/purview-executor-packages",
        ["PUBLISHER_PRIVATE_ENDPOINT_IP"] = "10.42.2.4"
    };
}
