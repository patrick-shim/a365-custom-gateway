using System.Text.Json;

namespace Gateway.Agent365;

// The worker owns writes. The API receives a read-only bind mount. No credential
// value enters workflow state, logs, API responses or the PostgreSQL database.
internal static class RuntimeBlueprintCredentialStore
{
    private const string CredentialName = "a365gw-runtime-runtime";
    internal sealed record Credential(Guid TenantId, Guid BlueprintId, Guid KeyId, DateTimeOffset ExpiresAtUtc, string Secret)
    {
        public DateTimeOffset CreatedAtUtc { get; init; }
    }

    internal static Credential? Read(string? directory, Guid tenantId, Guid blueprintId)
    {
        if (string.IsNullOrWhiteSpace(directory)) return null;
        var path = Path.Combine(directory, $"{tenantId:D}-{blueprintId:D}.json");
        if (!File.Exists(path)) return null;
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new Agent365ObservabilityConfigurationException("RuntimeBlueprintCredentialLinkRejected");
        var value = JsonSerializer.Deserialize<Credential>(File.ReadAllText(path));
        if (value is null || value.TenantId != tenantId || value.BlueprintId != blueprintId ||
            value.KeyId == Guid.Empty || string.IsNullOrWhiteSpace(value.Secret) || value.ExpiresAtUtc <= DateTimeOffset.UtcNow)
            throw new Agent365ObservabilityConfigurationException("RuntimeBlueprintCredentialInvalid");
        return value;
    }

    internal static async Task EnsureAsync(string directory, Guid tenantId, Guid blueprintObjectId,
        Guid blueprintId, bool mayCreate, MicrosoftGraphProvisioningClient graph, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(directory);
        if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
            throw new Agent365ObservabilityConfigurationException("RuntimeBlueprintCredentialDirectoryRejected");
        var path = Path.Combine(directory, $"{tenantId:D}-{blueprintId:D}.json");
        // Shared filesystem lock also protects sibling agents using this blueprint.
        using var lease = new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        var existing = Read(directory, tenantId, blueprintId);
        var application = await graph.GetBlueprintCredentialsAsync(blueprintObjectId, cancellationToken);
        if (application.Id != blueprintObjectId.ToString("D") || application.AppId != blueprintId.ToString("D"))
            throw new Agent365ObservabilityConfigurationException("RuntimeBlueprintIdentityMismatch");
        var owned = (application.PasswordCredentials ?? []).Where(x => x.DisplayName == CredentialName).ToArray();
        if (existing is not null)
        {
            if (owned.Length != 1 || owned[0].KeyId != existing.KeyId || owned[0].EndDateTime <= DateTimeOffset.UtcNow)
                throw new Agent365ObservabilityConfigurationException("RuntimeBlueprintCredentialReadbackMismatch");
            return;
        }
        // Never rotate/recreate a one-time secret after an ambiguous prior write.
        if (!mayCreate || owned.Length != 0)
            throw new Agent365ObservabilityConfigurationException("RuntimeBlueprintCredentialRepairRequired");
        var created = await graph.AddBlueprintPasswordAsync(blueprintObjectId, CredentialName, cancellationToken);
        if (created.KeyId == Guid.Empty || string.IsNullOrWhiteSpace(created.SecretText) || created.EndDateTime <= DateTimeOffset.UtcNow)
            throw new Agent365ObservabilityConfigurationException("RuntimeBlueprintCredentialCreateUnconfirmed");
        var value = new Credential(tenantId, blueprintId, created.KeyId, created.EndDateTime, created.SecretText)
            { CreatedAtUtc = DateTimeOffset.UtcNow };
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        var fileOptions = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None };
        if (!OperatingSystem.IsWindows()) fileOptions.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        await using (var stream = new FileStream(temporary, fileOptions))
        {
            await JsonSerializer.SerializeAsync(stream, value, cancellationToken: cancellationToken);
            await stream.FlushAsync(cancellationToken);
            stream.Flush(flushToDisk: true);
        }
        File.Move(temporary, path, overwrite: false);
        var verified = await graph.GetBlueprintCredentialsAsync(blueprintObjectId, cancellationToken);
        if (verified.Id != application.Id || verified.AppId != application.AppId ||
            (verified.PasswordCredentials ?? []).Count(x => x.KeyId == value.KeyId && x.DisplayName == CredentialName) != 1)
            throw new Agent365ObservabilityConfigurationException("RuntimeBlueprintCredentialReadbackMismatch");
    }
}
