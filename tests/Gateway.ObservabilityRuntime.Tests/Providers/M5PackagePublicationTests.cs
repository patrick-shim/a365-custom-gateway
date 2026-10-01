using System.Net;
using System.Security.Cryptography;
using System.Text;
using Azure.Core.Pipeline;
using Azure.Storage.Blobs;
using Gateway.ObservabilityRuntime.Tests.Fixtures;
using Gateway.Purview.PackagePublisher;
using Publisher = Gateway.Purview.PackagePublisher.PackagePublisher;

namespace Gateway.ObservabilityRuntime.Tests.Providers;

public sealed class M5PackagePublicationTests
{
    private static readonly byte[] Payload = "synthetic package payload"u8.ToArray();
    private static string Digest => "sha256:" + Convert.ToHexStringLower(SHA256.HashData(Payload));
    private const string Container = "https://fixturestorage.blob.core.windows.net/purview-executor-packages";
    private static string BlobUri => Container + "/" + Digest[7..] + ".zip";

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CreateOrLostResponseRequiresExactReadbackWithoutAnotherWrite(bool lostResponse)
    {
        var store = new FinitePackageStore();
        store.Exists.Expect(_ => false);
        store.Create.Expect(stream =>
        {
            Assert.Equal(0, stream.Position);
            using var copied = new MemoryStream();
            stream.CopyTo(copied);
            Assert.Equal(Payload, copied.ToArray());
            if (lostResponse) throw new IOException("Synthetic response loss after accepted creation.");
            return true;
        });
        ExpectReadback(store, Payload);
        using var package = new MemoryStream(Payload);

        await Publisher.PublishAsync(package, Digest, Payload.Length, store, default);

        Assert.Single(store.Create.Requests);
        Assert.Single(store.Read.Requests);
        store.AssertComplete();
    }

    [Fact]
    public async Task ExistingMatchingContentIsReadBackWithoutCreatingOrOverwriting()
    {
        var store = new FinitePackageStore();
        store.Exists.Expect(_ => true);
        ExpectReadback(store, Payload);
        using var package = new MemoryStream(Payload);

        await Publisher.PublishAsync(package, Digest, Payload.Length, store, default);

        Assert.Empty(store.Create.Requests);
        store.AssertComplete();
    }

    [Theory]
    [InlineData("short")]
    [InlineData("long")]
    [InlineData("different")]
    public async Task LostUploadResponseCannotSucceedWithConflictingReadback(string fault)
    {
        var store = new FinitePackageStore();
        store.Exists.Expect(_ => false);
        store.Create.Expect(_ => throw new IOException("Synthetic unknown upload outcome."));
        var observed = fault switch
        {
            "short" => Payload[..^1],
            "long" => Payload.Concat(new byte[] { 1 }).ToArray(),
            "different" => Enumerable.Repeat((byte)'x', Payload.Length).ToArray(),
            _ => throw new InvalidOperationException()
        };
        ExpectReadback(store, observed);
        using var package = new MemoryStream(Payload);

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            Publisher.PublishAsync(package, Digest, Payload.Length, store, default));

        Assert.Single(store.Create.Requests);
        Assert.Single(store.Read.Requests);
        store.AssertComplete();
    }

    [Fact]
    public async Task UnavailableReadbackPreservesFailureWithoutRetryingUpload()
    {
        var store = new FinitePackageStore();
        store.Exists.Expect(_ => false);
        store.Create.Expect(_ => throw new IOException("Synthetic response loss."));
        store.Read.Expect(_ => throw new IOException("Synthetic readback outage."));
        using var package = new MemoryStream(Payload);

        await Assert.ThrowsAsync<IOException>(() =>
            Publisher.PublishAsync(package, Digest, Payload.Length, store, default));

        Assert.Single(store.Create.Requests);
        store.AssertComplete();
    }

    [Theory]
    [InlineData("digest")]
    [InlineData("length")]
    [InlineData("position")]
    [InlineData("content")]
    public async Task InvalidLocalPayloadNeverAccessesTheStore(string fault)
    {
        var store = new FinitePackageStore();
        using var package = new MemoryStream(fault == "content" ? new byte[Payload.Length] : Payload);
        if (fault == "position") package.Position = 1;

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            Publisher.PublishAsync(package, fault == "digest" ? "unbound" : Digest,
                fault == "length" ? Payload.Length + 1 : Payload.Length, store, default));

        Assert.Empty(store.Exists.Requests);
        Assert.Empty(store.Create.Requests);
        Assert.Empty(store.Read.Requests);
    }

    [Fact]
    public async Task CancelledPublicationDoesNotEnterTheStore()
    {
        var store = new FinitePackageStore();
        using var package = new MemoryStream(Payload);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            Publisher.PublishAsync(package, Digest, Payload.Length, store, cancellation.Token));

        Assert.Empty(store.Exists.Requests);
    }

    [Fact]
    public async Task BlobAdapterUsesCreateOnlyAndTheObservedEtagForIndependentReadback()
    {
        using var transport = new ScriptedTransport();
        using var client = transport.CreateClient();
        var credential = Credential();
        var options = PublisherConfiguration.CreateClientOptions();
        options.Transport = new HttpClientTransport(client);
        var store = new BlobPackageStore(new BlobClient(new Uri(BlobUri), credential, options));
        transport.Expect(HttpMethod.Head, BlobUri, _ =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.NotFound) { Content = new ByteArrayContent([]) };
            response.Headers.TryAddWithoutValidation("x-ms-error-code", "BlobNotFound");
            return response;
        });
        transport.Expect(HttpMethod.Put, BlobUri, request =>
        {
            Assert.Equal("*", request.IfNoneMatch);
            Assert.Equal(Encoding.UTF8.GetString(Payload), request.Body);
            return BlobResponse(HttpStatusCode.Created, []);
        });
        transport.Expect(HttpMethod.Head, BlobUri, _ => BlobResponse(HttpStatusCode.OK, Payload));
        transport.Expect(HttpMethod.Get, BlobUri, request =>
        {
            Assert.Equal("\"observed-fixture-etag\"", request.IfMatch);
            return BlobResponse(HttpStatusCode.OK, Payload);
        });
        using var package = new MemoryStream(Payload);

        await Publisher.PublishAsync(package, Digest, Payload.Length, store, default);

        Assert.Equal(4, transport.Requests.Count);
        transport.AssertComplete();
        credential.Calls.AssertComplete();
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task BlobAdapterRejectsWrongRemoteLengthOrTypeBeforeDownloading(bool wrongLength)
    {
        using var transport = new ScriptedTransport();
        using var client = transport.CreateClient();
        var credential = Credential();
        var options = PublisherConfiguration.CreateClientOptions();
        options.Transport = new HttpClientTransport(client);
        var store = new BlobPackageStore(new BlobClient(new Uri(BlobUri), credential, options));
        transport.Expect(HttpMethod.Head, BlobUri, _ =>
            BlobResponse(HttpStatusCode.OK, wrongLength ? [] : Payload, wrongLength ? "BlockBlob" : "PageBlob"));

        await Assert.ThrowsAsync<InvalidOperationException>(() => store.OpenExactReadAsync(Payload.Length, default));

        Assert.Single(transport.Requests);
        transport.AssertComplete();
        credential.Calls.AssertComplete();
    }

    [Fact]
    public void PublicationDisablesTransportRetriesAndProviderLogging()
    {
        var options = PublisherConfiguration.CreateClientOptions();
        Assert.Equal(0, options.Retry.MaxRetries);
        Assert.Equal(TimeSpan.FromSeconds(60), options.Retry.NetworkTimeout);
        Assert.False(options.Diagnostics.IsLoggingEnabled);
        Assert.False(options.Diagnostics.IsLoggingContentEnabled);
        Assert.False(options.Diagnostics.IsDistributedTracingEnabled);
    }

    [Theory]
    [InlineData("http://fixturestorage.blob.core.windows.net/purview-executor-packages")]
    [InlineData("https://fixturestorage.blob.core.windows.net/another-container")]
    [InlineData("https://fixturestorage.blob.core.windows.net/purview-executor-packages?sig=synthetic")]
    [InlineData("https://fixturestorage.blob.core.windows.net/purview-executor-packages#fragment")]
    [InlineData("https://fixturestorage.blob.core.windows.net.attacker.invalid/purview-executor-packages")]
    [InlineData("https://fixturestorage.blob.core.windows.net/purview-executor-packages/")]
    public void DestinationCannotAddCredentialsOrChangeTheFixedStorageScope(string destination) =>
        Assert.Throws<InvalidOperationException>(() => Publisher.ValidateDestination(destination, Digest));

    private static FixtureCredential Credential()
    {
        var credential = new FixtureCredential();
        credential.Calls.Expect(context =>
        {
            Assert.Equal(["https://storage.azure.com//.default"], context.Scopes);
            return FixtureIds.Token;
        });
        return credential;
    }

    private static HttpResponseMessage BlobResponse(HttpStatusCode status, byte[] content, string type = "BlockBlob")
    {
        var response = new HttpResponseMessage(status) { Content = new ByteArrayContent(content) };
        response.Headers.TryAddWithoutValidation("ETag", "\"observed-fixture-etag\"");
        response.Headers.TryAddWithoutValidation("x-ms-blob-type", type);
        response.Headers.TryAddWithoutValidation("x-ms-request-id", FixtureIds.Agent.ToString("D"));
        response.Content.Headers.ContentLength = content.Length;
        response.Content.Headers.LastModified = new DateTimeOffset(FixtureIds.Timestamp);
        return response;
    }

    private static void ExpectReadback(FinitePackageStore store, byte[] content) =>
        store.Read.Expect(length =>
        {
            Assert.Equal(Payload.Length, length);
            return new MemoryStream(content);
        });

    private sealed class FinitePackageStore : IPackageStore
    {
        internal FiniteCalls<bool, bool> Exists { get; } = new();
        internal FiniteCalls<Stream, bool> Create { get; } = new();
        internal FiniteCalls<long, Stream> Read { get; } = new();

        public Task<bool> ExistsAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(Exists.Invoke(true));
        }

        public Task CreateOnlyAsync(Stream content, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            _ = Create.Invoke(content);
            return Task.CompletedTask;
        }

        public Task<Stream> OpenExactReadAsync(long expectedLength, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(Read.Invoke(expectedLength));
        }

        internal void AssertComplete()
        {
            Exists.AssertComplete();
            Create.AssertComplete();
            Read.AssertComplete();
        }
    }
}
