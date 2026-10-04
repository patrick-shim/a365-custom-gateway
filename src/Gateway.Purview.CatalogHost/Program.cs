using System.Diagnostics;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Gateway.Purview;

if (!OperatingSystem.IsWindows()) throw new InvalidOperationException("Run the catalog host under the Windows catalog-host certificate account.");
if (args.Length is < 2 or > 4 || args.Length == 3 && args[2] != "--once")
    throw new ArgumentException("Usage: CatalogHost <bootstrap-identity.json> <snapshot-directory> [--once]");
var queueDirectory = args.Length == 4 ? Path.GetFullPath(args[2]) : null;
var assignmentKey = args.Length == 4 ? (await File.ReadAllTextAsync(args[3])).Trim() : null;
var jsonOptions = new JsonSerializerOptions(JsonSerializerDefaults.Web);
var identity = JsonSerializer.Deserialize<Identity>(await File.ReadAllTextAsync(args[0]), jsonOptions)
    ?? throw new InvalidOperationException("Missing identity.");
if (!identity.AccessVerified || identity.TenantId == Guid.Empty || identity.ApplicationId == Guid.Empty ||
    string.IsNullOrWhiteSpace(identity.Organization) || identity.CertificateThumbprint.Length != 40)
    throw new InvalidOperationException("Bootstrap must verify the dedicated identity first.");
var destination = Path.GetFullPath(args[1]);
Directory.CreateDirectory(destination);
using var ownershipLock = new FileStream(Path.Combine(destination, "publisher.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
using var store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
store.Open(OpenFlags.ReadOnly);
var matches = store.Certificates.Find(X509FindType.FindByThumbprint, identity.CertificateThumbprint, false);
if (matches.Count != 1 || !matches[0].HasPrivateKey) throw new InvalidOperationException("Exact bootstrap certificate unavailable.");
using var certificate = matches[0];
// This is public trust material. Bootstrap pins it in API configuration separately;
// the API must never accept a public key supplied alongside an untrusted snapshot.
await File.WriteAllTextAsync(Path.Combine(destination, "publisher-public-certificate.txt"), Convert.ToBase64String(certificate.RawData));
using var shutdown = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; shutdown.Cancel(); };
do
{
    try
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
        deadline.CancelAfter(TimeSpan.FromMinutes(6));
        PolicyAssignmentRequest? assignmentRequest = null;
        string? jobPrefix = null;
        if (queueDirectory is not null && Directory.Exists(queueDirectory))
        {
            foreach (var path in Directory.EnumerateFiles(queueDirectory, "*.request.json").Order())
            {
                if (File.Exists(path.Replace(".request.json", ".result.json"))) continue;
                try
                {
                    if (new FileInfo(path).Length > 32768) continue;
                    var candidate = PolicyAssignmentProtocol.Verify<PolicyAssignmentRequest>(await File.ReadAllTextAsync(path), assignmentKey!, "request");
                    PolicyAssignmentProtocol.Validate(candidate, identity.TenantId);
                    if (Path.GetFileName(path) != candidate.OperationId.ToString("D") + ".request.json") continue;
                    assignmentRequest = candidate; jobPrefix = Path.Combine(queueDirectory, candidate.OperationId.ToString("D")); break;
                }
                catch (Exception) { Console.Error.WriteLine("Invalid or expired assignment request ignored."); }
            }
        }
        var requestPath = Path.Combine(destination, "active-assignment.json");
        if (assignmentRequest is not null) await File.WriteAllTextAsync(requestPath, JsonSerializer.Serialize(assignmentRequest, jsonOptions));
        var start = new ProcessStartInfo("pwsh.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-File", Path.Combine(AppContext.BaseDirectory, "Read-Catalog.ps1"),
            "-TenantId", identity.TenantId.ToString(), "-ApplicationId", identity.ApplicationId.ToString(), "-Organization", identity.Organization,
            "-CertificateThumbprint", identity.CertificateThumbprint }) start.ArgumentList.Add(argument);
        if (assignmentRequest is not null) { start.ArgumentList.Add("-AssignmentRequestPath"); start.ArgumentList.Add(requestPath); }
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Catalog reader could not start.");
        string output;
        try
        {
            var stdout = ReadBoundedAsync(process.StandardOutput, 1_500_000, deadline.Token);
            var stderr = ReadBoundedAsync(process.StandardError, 16_384, deadline.Token);
            await Task.WhenAll(stdout, stderr, process.WaitForExitAsync(deadline.Token));
            if (process.ExitCode != 0) throw new InvalidOperationException("Catalog read failed.");
            output = await stdout;
        }
        finally { if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); } }
        var read = JsonSerializer.Deserialize<HostRead>(output, jsonOptions) ?? throw new JsonException("Missing readback.");
        var catalog = read.Catalog;
        PurviewPolicyCatalogValidation.Validate(catalog, identity.TenantId);
        var envelope = PurviewCatalogSignature.Sign(catalog, certificate);
        var staging = Path.Combine(destination, "catalog.json.tmp");
        await File.WriteAllTextAsync(staging, JsonSerializer.Serialize(envelope, jsonOptions), shutdown.Token);
        File.Move(staging, Path.Combine(destination, "catalog.json"), overwrite: true);
        if (assignmentRequest is not null && read.Assignment is { } result)
        {
            var response = new PolicyAssignmentResult(assignmentRequest.OperationId, identity.TenantId, assignmentRequest.AgentIdentityId,
                assignmentRequest.PolicyId, PolicyAssignmentProtocol.Digest(assignmentRequest), result.Assigned,
                result.Revision, result.FailureCode, DateTime.UtcNow);
            await PolicyAssignmentProtocol.WriteAtomicAsync(jobPrefix + ".result.json", PolicyAssignmentProtocol.Sign(response, assignmentKey!, "result"), shutdown.Token);
        }
        Console.WriteLine($"{DateTimeOffset.UtcNow:O} Catalog refreshed: {catalog.Items.Count} policies.");
    }
    catch (OperationCanceledException) when (shutdown.IsCancellationRequested) { break; }
    catch (Exception)
    {
        Console.Error.WriteLine($"{DateTimeOffset.UtcNow:O} Catalog refresh failed. Previous data will expire; no success published.");
        if (args.Length == 3) { Environment.ExitCode = 1; break; }
    }
    if (args.Length == 3) break;
    try { await Task.Delay(TimeSpan.FromMinutes(1), shutdown.Token); } catch (OperationCanceledException) { break; }
} while (!shutdown.IsCancellationRequested);

static async Task<string> ReadBoundedAsync(StreamReader reader, int maximum, CancellationToken ct)
{
    var text = new StringBuilder();
    var buffer = new char[4096];
    int count;
    while ((count = await reader.ReadAsync(buffer, ct)) != 0)
    {
        if (text.Length + count > maximum) throw new InvalidOperationException("Reader output exceeded bound.");
        text.Append(buffer, 0, count);
    }
    return text.ToString();
}
sealed record HostRead(PurviewPolicyCatalog Catalog, AssignmentRead? Assignment);
sealed record AssignmentRead(bool Assigned, string? Revision, string? FailureCode);
sealed record Identity(Guid TenantId, Guid ApplicationId, string Organization, string CertificateThumbprint, bool AccessVerified);
