using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Setup.Models;

namespace Gateway.Setup.Services;

internal interface IBootstrapConfigWriter
{
    Task<ConfigurationWriteResult> WriteAsync(
        SetupConfigurationForm form,
        CancellationToken cancellationToken = default);
}

internal sealed class BootstrapConfigWriter(
    RepositoryLayout repository,
    IAtomicFileWriter atomicFileWriter) : IBootstrapConfigWriter
{
    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public async Task<ConfigurationWriteResult> WriteAsync(
        SetupConfigurationForm form,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(form);
        var validationResults = new List<ValidationResult>();
        if (!Validator.TryValidateObject(
                form,
                new ValidationContext(form),
                validationResults,
                validateAllProperties: true))
        {
            var message = string.Join(" ", validationResults.Select(result => result.ErrorMessage));
            throw new ValidationException(message);
        }

        var configuration = BootstrapConfiguration.From(form);
        var json = JsonSerializer.Serialize(configuration, SerializerOptions) + Environment.NewLine;
        var targetPath = Path.GetFullPath(repository.BootstrapConfigPath);
        var expectedPath = Path.GetFullPath(Path.Combine(repository.RootPath, "bootstrap", "config.json"));
        if (!string.Equals(targetPath, expectedPath, PathComparison))
        {
            throw new InvalidOperationException("Setup may write only bootstrap/config.json.");
        }

        await EnsureExistingConfigurationMatchesAsync(
            targetPath,
            configuration,
            cancellationToken);
        await atomicFileWriter.WriteUtf8Async(targetPath, json, cancellationToken);
        return new ConfigurationWriteResult(targetPath, configuration);
    }

    internal static string SerializeForTest(BootstrapConfiguration configuration) =>
        JsonSerializer.Serialize(configuration, SerializerOptions);

    private static async Task EnsureExistingConfigurationMatchesAsync(
        string targetPath,
        BootstrapConfiguration proposed,
        CancellationToken cancellationToken)
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
            await using var stream = new FileStream(
                targetPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                16 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            var existing = await JsonSerializer.DeserializeAsync<BootstrapConfiguration>(
                stream,
                SerializerOptions,
                cancellationToken);
            var existingCanonical = JsonSerializer.Serialize(existing, SerializerOptions);
            var proposedCanonical = JsonSerializer.Serialize(proposed, SerializerOptions);
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
    BootstrapConfiguration Configuration);

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
