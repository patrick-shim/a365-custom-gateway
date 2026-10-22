using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using Gateway.Purview;
using Gateway.Purview.CatalogHost;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            await RunAsync(args);
            return 0;
        }
        catch (Exception failure)
        {
            // This project publishes a Windows GUI-subsystem apphost so the
            // scheduled listener never opens a terminal. Keep every top-level
            // failure handled so Windows records the nonzero task result without
            // presenting an unhandled-exception or WER dialog. Bootstrap invokes
            // the managed DLL and can therefore capture this diagnostic.
            try
            {
                Console.Error.WriteLine(
                    $"Purview connector stopped ({failure.GetType().Name}): {failure.Message}");
            }
            catch
            {
                // Returning a failure code is still authoritative if stderr is
                // unavailable to the GUI-subsystem process.
            }

            return 1;
        }
    }

    private static async Task RunAsync(string[] args)
    {
        if (!OperatingSystem.IsWindows())
            throw new InvalidOperationException("Run the Purview connector under the Windows certificate-owning account.");
        var publishBootstrapCatalog = args.Length == 7 && args[0] == "--publish-bootstrap";
        var offset = publishBootstrapCatalog ? 1 : 0;
        if ((!publishBootstrapCatalog && args.Length != 5) || (publishBootstrapCatalog && args.Length != 7))
            throw new ArgumentException(
                "Usage: CatalogHost [--publish-bootstrap] <bootstrap-identity.json> <snapshot-directory> <connector-queue> <assignment-queue> <transport-key> [<verified-catalog.json>]");

        var identityPath = Path.GetFullPath(args[offset]);
        var destination = Path.GetFullPath(args[offset + 1]);
        var connectorDirectory = Path.GetFullPath(args[offset + 2]);
        var assignmentDirectory = Path.GetFullPath(args[offset + 3]);
        var authenticationKey = (await File.ReadAllTextAsync(Path.GetFullPath(args[offset + 4]))).Trim();
        // Bootstrap owns a richer identity document than this process needs. Keep the
        // connector wire protocol strict while accepting those explicitly managed
        // bootstrap fields here.
        var identityJson = new JsonSerializerOptions(JsonSerializerDefaults.Web)
        {
            PropertyNameCaseInsensitive = false
        };
        var identity = JsonSerializer.Deserialize<CatalogHostIdentity>(
            await File.ReadAllTextAsync(identityPath),
            identityJson) ?? throw new InvalidOperationException("Missing Purview connector identity.");
        if (!identity.AccessVerified || identity.TenantId == Guid.Empty || identity.ApplicationId == Guid.Empty ||
            identity.ConnectorInstanceId == Guid.Empty || string.IsNullOrWhiteSpace(identity.Organization) ||
            identity.CertificateThumbprint.Length != 40 || !identity.CertificateThumbprint.All(char.IsAsciiHexDigit))
            throw new InvalidOperationException("Bootstrap must verify the dedicated Purview connector identity first.");

        Directory.CreateDirectory(destination);
        Directory.CreateDirectory(connectorDirectory);
        Directory.CreateDirectory(assignmentDirectory);
        using var ownershipLock = new FileStream(
            Path.Combine(destination, "publisher.lock"),
            FileMode.OpenOrCreate,
            FileAccess.ReadWrite,
            FileShare.None);
        using var store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
        store.Open(OpenFlags.ReadOnly);
        var matches = store.Certificates.Find(
            X509FindType.FindByThumbprint,
            identity.CertificateThumbprint,
            validOnly: false);
        if (matches.Count != 1 || !matches[0].HasPrivateKey)
            throw new InvalidOperationException("Exact bootstrap certificate unavailable.");
        using var certificate = matches[0];

        // Public trust material is pinned independently by bootstrap. The private key
        // remains in this Windows user's certificate store.
        await PurviewConnectorProtocol.WriteAtomicAsync(
            Path.Combine(destination, "publisher-public-certificate.txt"),
            Convert.ToBase64String(certificate.RawData),
            CancellationToken.None);

        if (publishBootstrapCatalog)
        {
            var catalog = JsonSerializer.Deserialize<PurviewPolicyCatalog>(
                await File.ReadAllTextAsync(Path.GetFullPath(args[offset + 5])),
                PurviewConnectorProtocol.Json) ?? throw new InvalidOperationException("Missing verified bootstrap catalog.");
            PurviewPolicyCatalogValidation.Validate(catalog, identity.TenantId);
            await PurviewCompatibilityCatalogPublisher.PublishAsync(
                destination,
                catalog,
                certificate,
                CancellationToken.None);
            return;
        }

        using var shutdown = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            shutdown.Cancel();
        };

        var executor = new PowerShellPurviewCatalogHostExecutor(
            identity,
            Path.Combine(AppContext.BaseDirectory, "Read-Catalog.ps1"));
        var listener = new PurviewCatalogHostListener(
            identity,
            connectorDirectory,
            assignmentDirectory,
            authenticationKey,
            executor,
            (catalog, cancellationToken) => PurviewCompatibilityCatalogPublisher.PublishAsync(
                destination,
                catalog,
                certificate,
                cancellationToken));
        await listener.RunAsync(shutdown.Token);
    }
}
