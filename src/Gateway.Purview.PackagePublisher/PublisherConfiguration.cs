using System.Globalization;
using System.Net;
using System.Net.Sockets;
using Azure.Identity;
using Azure.Storage.Blobs;

namespace Gateway.Purview.PackagePublisher;

internal sealed record PublisherConfiguration(string OwnershipId, string IntentId,
    string SourceFingerprint, string PackageDigest, long PackageBytes, Uri Destination, IPAddress PrivateEndpoint)
{
    internal static readonly TimeSpan OperationTimeout = TimeSpan.FromMinutes(10);

    internal static PublisherConfiguration Load(Func<string, string?> read)
    {
        string Required(string key) => read(key) ?? throw new InvalidOperationException();
        string CanonicalGuid(string key)
        {
            var text = Required(key);
            return Guid.TryParseExact(text, "D", out var id) && id != Guid.Empty && id.ToString("D") == text
                ? text : throw new InvalidOperationException();
        }

        var ownershipId = CanonicalGuid("PUBLISHER_DEPLOYMENT_OWNERSHIP_ID");
        var intentId = CanonicalGuid("PUBLISHER_EXECUTION_INTENT_ID");
        var source = Required("PUBLISHER_EXECUTION_SOURCE_FINGERPRINT");
        var digest = Required("PUBLISHER_PACKAGE_DIGEST");
        var destination = PackagePublisher.ValidateDestination(Required("PUBLISHER_CONTAINER_URI"), digest);
        var lengthText = Required("PUBLISHER_PACKAGE_BYTES");
        if (!long.TryParse(lengthText, NumberStyles.None, CultureInfo.InvariantCulture, out var length) ||
            length is <= 0 or > PackagePublisher.MaximumPackageBytes ||
            length.ToString(CultureInfo.InvariantCulture) != lengthText || !PackagePublisher.IsDigest(source) ||
            !IPAddress.TryParse(Required("PUBLISHER_PRIVATE_ENDPOINT_IP"), out var expectedAddress) ||
            expectedAddress.AddressFamily != AddressFamily.InterNetwork ||
            expectedAddress.ToString() != Required("PUBLISHER_PRIVATE_ENDPOINT_IP"))
        {
            throw new InvalidOperationException();
        }

        var octets = expectedAddress.GetAddressBytes();
        if (!(octets[0] == 10 || octets[0] == 172 && octets[1] is >= 16 and <= 31 ||
            octets[0] == 192 && octets[1] == 168)) { throw new InvalidOperationException(); }

        return new(ownershipId, intentId, source, digest, length, destination, expectedAddress);
    }

    internal void ValidateResolution(IPAddress[] addresses)
    {
        if (addresses.Length != 1 || !addresses[0].Equals(PrivateEndpoint))
        {
            throw new InvalidOperationException();
        }
    }

    internal static ManagedIdentityCredential CreateCredential() =>
        new(ManagedIdentityId.SystemAssigned);

    internal static BlobClientOptions CreateClientOptions()
    {
        var options = new BlobClientOptions();
        options.Retry.MaxRetries = 0;
        options.Retry.NetworkTimeout = TimeSpan.FromSeconds(60);
        options.Diagnostics.IsLoggingEnabled = false;
        options.Diagnostics.IsLoggingContentEnabled = false;
        options.Diagnostics.IsDistributedTracingEnabled = false;
        return options;
    }
}
