using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Setup.Models;

namespace Gateway.Setup.Services;

internal interface IBootstrapConfigWriter
{
    Task<StagedBootstrapConfiguration> StageAsync(
        PlanReadyConfiguration planReady,
        CancellationToken cancellationToken = default);
}

internal sealed class BootstrapConfigWriter(
    RepositoryLayout repository,
    IAtomicFileWriter atomicFileWriter) : IBootstrapConfigWriter
{
    private const int MaximumConfigurationBytes = 64 * 1024;

    public async Task<StagedBootstrapConfiguration> StageAsync(
        PlanReadyConfiguration planReady,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(planReady);
        var configuration = planReady.Configuration;
        var json = BootstrapConfigurationDocument.Serialize(configuration);
        if (!string.Equals(json, planReady.SerializedJson, StringComparison.Ordinal) ||
            !BootstrapConfigurationDocument.HasFingerprint(
                planReady.SerializedJson,
                planReady.Readiness.ConfigurationFingerprint))
        {
            throw new InvalidOperationException(
                "The reviewed bootstrap configuration snapshot is not internally consistent.");
        }

        var targetPath = Path.GetFullPath(repository.BootstrapConfigPath);
        var expectedPath = Path.GetFullPath(Path.Combine(repository.RootPath, "bootstrap", "config.json"));
        if (!string.Equals(targetPath, expectedPath, PathComparison))
        {
            throw new InvalidOperationException("Setup may write only bootstrap/config.json.");
        }

        EnsureExistingConfigurationMatches(targetPath, configuration);
        var directory = Path.GetDirectoryName(targetPath)
            ?? throw new InvalidOperationException("Bootstrap configuration has no parent directory.");
        var stagePath = Path.Combine(
            directory,
            $".{Path.GetFileName(targetPath)}.{Guid.NewGuid():N}.stage");
        try
        {
            await atomicFileWriter.WriteUtf8Async(stagePath, json, cancellationToken);
            return new StagedBootstrapConfiguration(
                this,
                stagePath,
                targetPath,
                configuration,
                planReady.Readiness,
                Encoding.UTF8.GetByteCount(json));
        }
        catch
        {
            Discard(stagePath);
            throw;
        }
    }

    internal static string SerializeForTest(BootstrapConfiguration configuration) =>
        BootstrapConfigurationDocument.Serialize(configuration).TrimEnd('\r', '\n');

    internal ConfigurationWriteResult? TryPublish(StagedBootstrapConfiguration staged)
    {
        ArgumentNullException.ThrowIfNull(staged);
        var targetPath = Path.GetFullPath(repository.BootstrapConfigPath);
        var expectedPath = Path.GetFullPath(Path.Combine(repository.RootPath, "bootstrap", "config.json"));
        if (!string.Equals(targetPath, expectedPath, PathComparison) ||
            !string.Equals(Path.GetFullPath(staged.CanonicalPath), targetPath, PathComparison) ||
            !IsOwnedStagePath(staged.StagePath, targetPath))
        {
            throw new InvalidOperationException(
                "Setup may publish only its exact provisional bootstrap configuration.");
        }

        if (!IsExactFile(
                staged.StagePath,
                staged.ContentLength,
                staged.ConfigurationFileFingerprint))
        {
            return null;
        }

        EnsureExistingConfigurationMatches(targetPath, staged.Configuration);
        File.Move(staged.StagePath, targetPath, overwrite: true);
        return new ConfigurationWriteResult(
            targetPath,
            staged.Configuration,
            staged.Readiness,
            staged.ContentLength,
            staged.ConfigurationFileFingerprint);
    }

    internal void Discard(string stagePath)
    {
        if (File.Exists(stagePath))
        {
            File.Delete(stagePath);
        }
    }

    private static void EnsureExistingConfigurationMatches(
        string targetPath,
        BootstrapConfiguration proposed)
    {
        var file = new FileInfo(targetPath);
        if (!file.Exists)
        {
            return;
        }

        if (file.LinkTarget is not null || file.Length is <= 0 or > 64 * 1024)
        {
            throw new ExistingConfigurationChangedException();
        }

        try
        {
            using var stream = new FileStream(
                targetPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                16 * 1024,
                FileOptions.SequentialScan);
            var existing = JsonSerializer.Deserialize<BootstrapConfiguration>(
                stream,
                BootstrapConfigurationDocument.SerializerOptions);
            var existingCanonical = JsonSerializer.Serialize(
                existing,
                BootstrapConfigurationDocument.SerializerOptions);
            var proposedCanonical = JsonSerializer.Serialize(
                proposed,
                BootstrapConfigurationDocument.SerializerOptions);
            if (!string.Equals(existingCanonical, proposedCanonical, StringComparison.Ordinal))
            {
                throw new ExistingConfigurationChangedException();
            }
        }
        catch (Exception exception) when (
            exception is JsonException or UnauthorizedAccessException)
        {
            throw new ExistingConfigurationChangedException(exception);
        }
    }

    private static bool IsExactFile(
        string path,
        int expectedLength,
        string expectedFingerprint)
    {
        try
        {
            var file = new FileInfo(path);
            if (!file.Exists ||
                file.LinkTarget is not null ||
                file.Length != expectedLength ||
                file.Length is <= 0 or > MaximumConfigurationBytes)
            {
                return false;
            }

            using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                16 * 1024,
                FileOptions.SequentialScan);
            return string.Equals(
                BootstrapConfigurationDocument.FormatFingerprint(SHA256.HashData(stream)),
                expectedFingerprint,
                StringComparison.Ordinal);
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static bool IsOwnedStagePath(string stagePath, string targetPath)
    {
        var fullStagePath = Path.GetFullPath(stagePath);
        var expectedDirectory = Path.GetDirectoryName(targetPath);
        return expectedDirectory is not null &&
            string.Equals(
                Path.GetDirectoryName(fullStagePath),
                expectedDirectory,
                PathComparison) &&
            Path.GetFileName(fullStagePath).StartsWith(
                $".{Path.GetFileName(targetPath)}.",
                StringComparison.Ordinal) &&
            Path.GetFileName(fullStagePath).EndsWith(".stage", StringComparison.Ordinal);
    }

    private static StringComparison PathComparison =>
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
}

internal sealed class ExistingConfigurationChangedException : IOException
{
    public ExistingConfigurationChangedException()
        : base("bootstrap/config.json exists with different or unsupported content.")
    {
    }

    public ExistingConfigurationChangedException(Exception innerException)
        : base("bootstrap/config.json exists with different or unsupported content.", innerException)
    {
    }
}

internal sealed record ConfigurationWriteResult(
    string Path,
    BootstrapConfiguration Configuration,
    PlanReadinessToken Readiness,
    int ContentLength,
    string ConfigurationFileFingerprint);

internal sealed class StagedBootstrapConfiguration : IDisposable
{
    private readonly object sync = new();
    private BootstrapConfigWriter? owner;

    internal StagedBootstrapConfiguration(
        BootstrapConfigWriter owner,
        string stagePath,
        string canonicalPath,
        BootstrapConfiguration configuration,
        PlanReadinessToken readiness,
        int contentLength)
    {
        this.owner = owner;
        StagePath = stagePath;
        CanonicalPath = canonicalPath;
        Configuration = configuration;
        Readiness = readiness;
        ContentLength = contentLength;
    }

    public string StagePath { get; }

    public string CanonicalPath { get; }

    public BootstrapConfiguration Configuration { get; }

    public PlanReadinessToken Readiness { get; }

    public int ContentLength { get; }

    public string ConfigurationFileFingerprint => Readiness.ConfigurationFingerprint;

    public ConfigurationWriteResult? TryPublish()
    {
        lock (sync)
        {
            if (owner is null)
            {
                return null;
            }

            var result = owner.TryPublish(this);
            if (result is not null)
            {
                owner = null;
            }

            return result;
        }
    }

    public void Dispose()
    {
        lock (sync)
        {
            owner?.Discard(StagePath);
            owner = null;
        }
    }
}

internal static class BootstrapConfigurationDocument
{
    internal static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public static string Serialize(BootstrapConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        return JsonSerializer.Serialize(configuration, SerializerOptions) + Environment.NewLine;
    }

    public static string Fingerprint(string serializedJson)
    {
        ArgumentNullException.ThrowIfNull(serializedJson);
        return FormatFingerprint(SHA256.HashData(Encoding.UTF8.GetBytes(serializedJson)));
    }

    public static bool HasFingerprint(string serializedJson, string expectedFingerprint) =>
        string.Equals(
            Fingerprint(serializedJson),
            expectedFingerprint,
            StringComparison.Ordinal);

    public static string FormatFingerprint(ReadOnlySpan<byte> digest) =>
        $"sha256:{Convert.ToHexStringLower(digest)}";
}

internal interface IAtomicFileWriter
{
    Task WriteUtf8Async(string targetPath, string content, CancellationToken cancellationToken);
}

internal sealed class AtomicFileWriter : IAtomicFileWriter
{
    public async Task WriteUtf8Async(
        string targetPath,
        string content,
        CancellationToken cancellationToken)
    {
        var directory = Path.GetDirectoryName(targetPath)
            ?? throw new InvalidOperationException("Bootstrap configuration has no parent directory.");
        Directory.CreateDirectory(directory);

        var temporaryPath = Path.Combine(
            directory,
            $".{Path.GetFileName(targetPath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                16 * 1024,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            await using (var writer = new StreamWriter(
                stream,
                new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
                16 * 1024,
                leaveOpen: true))
            {
                await writer.WriteAsync(content.AsMemory(), cancellationToken);
                await writer.FlushAsync(cancellationToken);
                stream.Flush(flushToDisk: true);
            }

            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(
                    temporaryPath,
                    UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }

            File.Move(temporaryPath, targetPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}
