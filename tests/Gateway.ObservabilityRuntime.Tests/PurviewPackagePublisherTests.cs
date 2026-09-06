using System.Security.Cryptography;
using FluentAssertions;
using Gateway.Purview.PackagePublisher;
using Publisher = Gateway.Purview.PackagePublisher.PackagePublisher;

namespace Gateway.ObservabilityRuntime.Tests;

public sealed class PurviewPackagePublisherTests
{
    private static readonly byte[] Payload = [1, 2, 3, 4, 5];
    private static readonly string Digest = "sha256:" + Convert.ToHexStringLower(SHA256.HashData(Payload));

    [Theory]
    [InlineData("\n")]
    [InlineData("\r\n")]
    [InlineData(" ")]
    public void Trailing_text_is_not_a_canonical_digest(string suffix)
    {
        Publisher.IsDigest(Digest + suffix).Should().BeFalse();
    }

    [Fact]
    public void Embedded_newline_is_not_a_canonical_digest()
    {
        Publisher.IsDigest(Digest.Insert(20, "\n")).Should().BeFalse();
    }

    [Fact]
    public async Task Wrong_local_hash_never_touches_provider()
    {
        var store = new Store();
        var action = () => Publisher.PublishAsync(new MemoryStream([8, 8, 8, 8, 8]), Digest, 5, store, default);
        await action.Should().ThrowAsync<InvalidOperationException>();
        store.Calls.Should().BeEmpty();
    }

    [Fact]
    public async Task Fresh_upload_requires_independent_exact_content_readback()
    {
        var store = new Store();
        await Publisher.PublishAsync(new MemoryStream(Payload), Digest, 5, store, default);
        store.Calls.Should().Equal("exists", "create", "read");
    }

    [Fact]
    public async Task Existing_exact_blob_is_only_read()
    {
        var store = new Store { Remote = Payload };
        await Publisher.PublishAsync(new MemoryStream(Payload), Digest, 5, store, default);
        store.Calls.Should().Equal("exists", "read");
    }

    [Fact]
    public async Task Lost_success_response_is_reconciled_without_second_upload()
    {
        var store = new Store { LoseResponse = true };
        await Publisher.PublishAsync(new MemoryStream(Payload), Digest, 5, store, default);
        store.Calls.Should().Equal("exists", "create", "read");
    }

    [Fact]
    public async Task Absent_after_unknown_upload_does_not_retry()
    {
        var store = new Store { FailUpload = true };
        var action = () => Publisher.PublishAsync(new MemoryStream(Payload), Digest, 5, store, default);
        await action.Should().ThrowAsync<IOException>();
        store.Calls.Should().Equal("exists", "create", "read");
    }

    [Theory]
    [InlineData(4)]
    [InlineData(5)]
    [InlineData(6)]
    public async Task Corrupt_existing_blob_is_never_overwritten(int length)
    {
        var store = new Store { Remote = new byte[length] };
        var action = () => Publisher.PublishAsync(new MemoryStream(Payload), Digest, 5, store, default);
        await action.Should().ThrowAsync<InvalidOperationException>();
        store.Calls.Should().Equal("exists", "read");
    }

    [Fact]
    public async Task Failed_existence_read_prevents_upload()
    {
        var store = new Store { FailExists = true };
        var action = () => Publisher.PublishAsync(new MemoryStream(Payload), Digest, 5, store, default);
        await action.Should().ThrowAsync<IOException>();
        store.Calls.Should().Equal("exists");
    }

    [Theory]
    [InlineData("http://abcdef.blob.core.windows.net/purview-executor-packages")]
    [InlineData("https://abcdef.blob.core.windows.net:8443/purview-executor-packages")]
    [InlineData("https://abcdef.blob.core.windows.net/purview-executor-packages?sig=value")]
    [InlineData("https://abcdef.blob.core.windows.net/purview-executor-packages#value")]
    [InlineData("https://user@abcdef.blob.core.windows.net/purview-executor-packages")]
    [InlineData("https://abcdef.blob.core.windows.net/purview-executor-claims")]
    [InlineData("https://abcdef.blob.core.windows.net/purview-executor-packages/")]
    [InlineData("https://abcdef.blob.core.windows.net.evil.test/purview-executor-packages")]
    [InlineData("https://abcdef.blob.core.windows.net/a/../purview-executor-packages")]
    public void Unsupported_destination_is_rejected(string uri)
    {
        var action = () => Publisher.ValidateDestination(uri, Digest);
        action.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void Exact_container_derives_only_content_addressed_package_path()
    {
        Publisher.ValidateDestination("https://abcdef.blob.core.windows.net/purview-executor-packages", Digest)
            .AbsolutePath.Should().Be("/purview-executor-packages/" + Digest[7..] + ".zip");
    }

    private sealed class Store : IPackageStore
    {
        internal byte[]? Remote { get; set; }
        internal bool LoseResponse { get; init; }
        internal bool FailUpload { get; init; }
        internal bool FailExists { get; init; }
        internal List<string> Calls { get; } = [];

        public Task<bool> ExistsAsync(CancellationToken cancellationToken)
        {
            Calls.Add("exists");
            if (FailExists) { throw new IOException(); }
            return Task.FromResult(Remote is not null);
        }

        public async Task CreateOnlyAsync(Stream content, CancellationToken cancellationToken)
        {
            Calls.Add("create");
            if (FailUpload || Remote is not null) { throw new IOException(); }
            using var copy = new MemoryStream();
            await content.CopyToAsync(copy, cancellationToken);
            Remote = copy.ToArray();
            if (LoseResponse) { throw new IOException(); }
        }

        public Task<Stream> OpenExactReadAsync(long expectedLength, CancellationToken cancellationToken)
        {
            Calls.Add("read");
            return Task.FromResult<Stream>(new MemoryStream(Remote ?? throw new IOException()));
        }
    }
}
