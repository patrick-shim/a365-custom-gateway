using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace Gateway.AdminUi.BrowserHost;

internal sealed class FixtureTlsCertificate : IDisposable
{
    private readonly RSA key = RSA.Create(2048);
    public X509Certificate2 Certificate { get; }
    public string PublicCertificatePath { get; } =
        Path.Combine(AppContext.BaseDirectory, $"browser-fixture-{Guid.NewGuid():N}.pem");

    public FixtureTlsCertificate()
    {
        var request = new CertificateRequest("CN=127.0.0.1", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        var names = new SubjectAlternativeNameBuilder();
        names.AddIpAddress(IPAddress.Loopback);
        request.CertificateExtensions.Add(names.Build());
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(
            X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(
            new OidCollection { new("1.3.6.1.5.5.7.3.1") }, false));
        using var generated = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddHours(4));
        var encoded = generated.Export(X509ContentType.Pfx);
        try
        {
            // Schannel cannot use the ephemeral key handle returned by CreateSelfSigned.
            // Import through its key provider; no private-key file or trust entry is authored.
            Certificate = X509CertificateLoader.LoadPkcs12(encoded, null, X509KeyStorageFlags.DefaultKeySet);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(encoded);
        }
        File.WriteAllText(PublicCertificatePath, Certificate.ExportCertificatePem());
    }

    public void Dispose()
    {
        Certificate.Dispose();
        key.Dispose();
        File.Delete(PublicCertificatePath);
    }
}
