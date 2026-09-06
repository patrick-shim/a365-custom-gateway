using System.Net;
using System.Text.Json;
using Azure.Storage.Blobs;
using Gateway.Purview.PackagePublisher;

try
{
    var configuration = PublisherConfiguration.Load(Environment.GetEnvironmentVariable);
    using var deadline = new CancellationTokenSource(PublisherConfiguration.OperationTimeout);
    var addresses = await Dns.GetHostAddressesAsync(configuration.Destination.Host, deadline.Token);
    configuration.ValidateResolution(addresses);
    var store = new BlobPackageStore(new BlobClient(configuration.Destination,
        PublisherConfiguration.CreateCredential(), PublisherConfiguration.CreateClientOptions()));
    await using var payload = new FileStream(Path.Combine(AppContext.BaseDirectory, "payload", "executor.zip"),
        FileMode.Open, FileAccess.Read, FileShare.Read);
    await PackagePublisher.PublishAsync(payload, configuration.PackageDigest, configuration.PackageBytes, store, deadline.Token);
    Console.WriteLine(JsonSerializer.Serialize(new
    {
        schemaVersion = 1,
        status = "Verified",
        deploymentOwnershipId = configuration.OwnershipId,
        executionIntentId = configuration.IntentId,
        executionSourceFingerprint = configuration.SourceFingerprint,
        packageDigest = configuration.PackageDigest,
        packageBytes = configuration.PackageBytes
    }));
    return 0;
}
catch
{
    // No provider body, token, credential or exception details reach job logs.
    Console.Error.WriteLine("PACKAGE_PUBLICATION_UNVERIFIED");
    return 1;
}
