using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace Gateway.Purview.PackagePublisher;

internal interface IPackageStore
{
    Task<bool> ExistsAsync(CancellationToken cancellationToken);
    Task CreateOnlyAsync(Stream content, CancellationToken cancellationToken);
    Task<Stream> OpenExactReadAsync(long expectedLength, CancellationToken cancellationToken);
}

internal static partial class PackagePublisher
{
    internal const long MaximumPackageBytes = 1024L * 1024 * 1024;

    [GeneratedRegex("\\Asha256:[0-9a-f]{64}\\z", RegexOptions.CultureInvariant)]
    private static partial Regex DigestPattern();

    internal static bool IsDigest(string value) => DigestPattern().IsMatch(value);

    internal static Uri ValidateDestination(string containerUri, string digest)
    {
        if (!IsDigest(digest) || !Uri.TryCreate(containerUri, UriKind.Absolute, out var uri) ||
            uri.Scheme != Uri.UriSchemeHttps || !uri.IsDefaultPort || uri.UserInfo.Length != 0 ||
            uri.Query.Length != 0 || uri.Fragment.Length != 0 ||
            uri.AbsolutePath != "/purview-executor-packages" ||
            !Regex.IsMatch(uri.Host, "^[a-z0-9]{3,24}\\.blob\\.core\\.windows\\.net$", RegexOptions.CultureInvariant) ||
            uri.AbsoluteUri != containerUri)
        {
            throw new InvalidOperationException("Package destination is invalid.");
        }

        return new Uri(containerUri + "/" + digest[7..] + ".zip");
    }

    internal static async Task PublishAsync(Stream package, string expectedDigest, long expectedLength,
        IPackageStore store, CancellationToken cancellationToken)
    {
        if (!IsDigest(expectedDigest) || expectedLength is <= 0 or > MaximumPackageBytes ||
            !package.CanSeek || package.Position != 0 || package.Length != expectedLength)
        {
            throw new InvalidOperationException("Package input is invalid.");
        }

        // Verify the fixed image payload before any provider access. Keep this handle
        // open without sharing writes until the conditional upload finishes.
        await VerifyAsync(package, expectedDigest, expectedLength, cancellationToken);
        package.Position = 0;
        if (!await store.ExistsAsync(cancellationToken))
        {
            try
            {
                await store.CreateOnlyAsync(package, cancellationToken);
            }
            catch (Exception) when (!cancellationToken.IsCancellationRequested)
            {
                // A race or lost response permits readback only. Never retry upload,
                // overwrite, delete, or regard a provider success response as proof.
            }
        }

        await using var readback = await store.OpenExactReadAsync(expectedLength, cancellationToken);
        await VerifyAsync(readback, expectedDigest, expectedLength, cancellationToken);
    }

    private static async Task VerifyAsync(Stream stream, string expectedDigest, long expectedLength,
        CancellationToken cancellationToken)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[81920];
        long total = 0;
        while (true)
        {
            var count = await stream.ReadAsync(buffer.AsMemory(), cancellationToken);
            if (count == 0) { break; }
            total += count;
            if (total > expectedLength) { throw new InvalidOperationException("Package length differs."); }
            hash.AppendData(buffer, 0, count);
        }

        var actual = "sha256:" + Convert.ToHexStringLower(hash.GetHashAndReset());
        if (total != expectedLength || actual != expectedDigest)
        {
            throw new InvalidOperationException("Package readback differs.");
        }
    }
}
