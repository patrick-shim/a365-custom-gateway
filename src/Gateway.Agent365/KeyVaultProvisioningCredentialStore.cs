using Azure;
using Azure.Core;
using Azure.Security.KeyVault.Secrets;
using Gateway.Domain.Models;
using Microsoft.Extensions.Options;

namespace Gateway.Agent365;

internal interface IProvisioningCredentialStore
{
    Task<StoredPasswordCredential?> FindAsync(
        Guid agentRegistrationId,
        string applicationObjectId,
        CancellationToken cancellationToken);

    Task<StoredPasswordCredential> StoreAsync(
        Guid agentRegistrationId,
        string applicationObjectId,
        string passwordCredentialKeyId,
        string secretText,
        DateTimeOffset expiresAtUtc,
        CancellationToken cancellationToken);
}

internal sealed record StoredPasswordCredential(
    string PasswordCredentialKeyId,
    string KeyVaultSecretUri,
    DateTimeOffset ExpiresAtUtc);

internal sealed class KeyVaultProvisioningCredentialStore : IProvisioningCredentialStore
{
    private const string ApplicationObjectIdTag = "ApplicationObjectId";
    private const string PasswordCredentialKeyIdTag = "PasswordCredentialKeyId";

    private readonly Lazy<SecretClient> _secretClient;

    public KeyVaultProvisioningCredentialStore(IOptions<Agent365Options> options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _secretClient = new Lazy<SecretClient>(
            () => CreateClient(options.Value),
            LazyThreadSafetyMode.ExecutionAndPublication);
    }

    internal KeyVaultProvisioningCredentialStore(SecretClient secretClient)
    {
        ArgumentNullException.ThrowIfNull(secretClient);
        _secretClient = new Lazy<SecretClient>(() => secretClient);
    }

    public async Task<StoredPasswordCredential?> FindAsync(
        Guid agentRegistrationId,
        string applicationObjectId,
        CancellationToken cancellationToken)
    {
        var secretName = GetSecretName(agentRegistrationId);

        try
        {
            SecretProperties? latest = null;
            await foreach (var properties in _secretClient.Value
                .GetPropertiesOfSecretVersionsAsync(secretName, cancellationToken))
            {
                if (properties.Enabled == false)
                    continue;

                if (latest is null || properties.CreatedOn > latest.CreatedOn)
                    latest = properties;
            }

            if (latest is null)
                return null;

            if (!latest.Tags.TryGetValue(ApplicationObjectIdTag, out var storedApplicationObjectId)
                || !string.Equals(
                    storedApplicationObjectId,
                    applicationObjectId,
                    StringComparison.OrdinalIgnoreCase)
                || !latest.Tags.TryGetValue(
                    PasswordCredentialKeyIdTag,
                    out var passwordCredentialKeyId)
                || !Guid.TryParse(passwordCredentialKeyId, out var parsedCredentialKeyId)
                || parsedCredentialKeyId == Guid.Empty
                || latest.ExpiresOn is null)
            {
                throw Failure(
                    "KEY_VAULT_CREDENTIAL_METADATA_INVALID",
                    "The existing credential reference requires manual verification.",
                    requiresManualIntervention: true);
            }

            return new StoredPasswordCredential(
                parsedCredentialKeyId.ToString("D"),
                latest.Id.AbsoluteUri,
                latest.ExpiresOn.Value);
        }
        catch (RequestFailedException exception) when (exception.Status == 404)
        {
            return null;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Agent365ProvisioningException)
        {
            throw;
        }
        catch (RequestFailedException exception) when (IsTransient(exception.Status))
        {
            throw Failure(
                "KEY_VAULT_READ_TRANSIENT",
                "The credential vault is temporarily unavailable.",
                isTransient: true);
        }
        catch (RequestFailedException exception) when (exception.Status is 401 or 403)
        {
            throw Failure(
                "KEY_VAULT_ACCESS_DENIED",
                "The provisioning identity cannot access the credential vault.");
        }
        catch (RequestFailedException)
        {
            throw Failure(
                "KEY_VAULT_READ_FAILED",
                "The existing credential reference couldn't be verified.");
        }
    }

    public async Task<StoredPasswordCredential> StoreAsync(
        Guid agentRegistrationId,
        string applicationObjectId,
        string passwordCredentialKeyId,
        string secretText,
        DateTimeOffset expiresAtUtc,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrEmpty(secretText))
            throw Failure("GRAPH_PASSWORD_SECRET_EMPTY", "Microsoft Graph returned an empty credential.");

        var secret = new KeyVaultSecret(GetSecretName(agentRegistrationId), secretText);
        secret.Properties.ExpiresOn = expiresAtUtc;
        secret.Properties.Tags[ApplicationObjectIdTag] = applicationObjectId;
        secret.Properties.Tags[PasswordCredentialKeyIdTag] = passwordCredentialKeyId;

        try
        {
            var response = await _secretClient.Value.SetSecretAsync(secret, cancellationToken);
            var properties = response.Value.Properties;
            if (properties.Id is null || properties.ExpiresOn is null)
            {
                throw Failure(
                    "KEY_VAULT_WRITE_RESPONSE_INVALID",
                    "The credential vault didn't return a verifiable secret reference.",
                    requiresManualIntervention: true);
            }

            return new StoredPasswordCredential(
                passwordCredentialKeyId,
                properties.Id.AbsoluteUri,
                properties.ExpiresOn.Value);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Agent365ProvisioningException)
        {
            throw;
        }
        catch (RequestFailedException exception) when (IsTransient(exception.Status))
        {
            throw Failure(
                "KEY_VAULT_WRITE_TRANSIENT",
                "The credential vault is temporarily unavailable.",
                isTransient: true);
        }
        catch (RequestFailedException exception) when (exception.Status is 401 or 403)
        {
            throw Failure(
                "KEY_VAULT_ACCESS_DENIED",
                "The provisioning identity cannot write to the credential vault.");
        }
        catch (RequestFailedException)
        {
            throw Failure(
                "KEY_VAULT_WRITE_FAILED",
                "The generated credential couldn't be stored in the credential vault.");
        }
    }

    internal static string GetSecretName(Guid agentRegistrationId)
    {
        return $"a365-{agentRegistrationId:N}-client-secret";
    }

    private static SecretClient CreateClient(Agent365Options options)
    {
        if (!Uri.TryCreate(options.CredentialKeyVaultUri, UriKind.Absolute, out var vaultUri)
            || !string.Equals(vaultUri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            || !vaultUri.Host.EndsWith(".vault.azure.net", StringComparison.OrdinalIgnoreCase))
        {
            throw Failure(
                "KEY_VAULT_URI_INVALID",
                "The provisioning credential vault URI isn't configured correctly.");
        }

        TokenCredential credential = ProvisioningManagedIdentityCredentialFactory.Create(options);
        return new SecretClient(vaultUri, credential);
    }

    private static bool IsTransient(int status)
    {
        return status is 408 or 429 || status >= 500;
    }

    private static Agent365ProvisioningException Failure(
        string code,
        string summary,
        bool isTransient = false,
        bool requiresManualIntervention = false)
    {
        return new Agent365ProvisioningException(
            code,
            summary,
            isTransient,
            requiresManualIntervention);
    }
}
