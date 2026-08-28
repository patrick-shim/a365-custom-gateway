using Azure;
using Azure.Core;
using Azure.Identity;
using Gateway.Domain.Models;
using Microsoft.Extensions.Options;

namespace Gateway.Agent365;

internal sealed class DefaultAzureProvisioningTokenProvider : IAgent365ProvisioningTokenProvider
{
    private static readonly TokenRequestContext GraphTokenRequest =
        new(["https://graph.microsoft.com/.default"]);

    private readonly TokenCredential _credential;

    public DefaultAzureProvisioningTokenProvider(IOptions<Agent365Options> options)
        : this(ProvisioningManagedIdentityCredentialFactory.Create(options.Value))
    {
    }

    internal DefaultAzureProvisioningTokenProvider(TokenCredential credential)
    {
        _credential = credential;
    }

    public async ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken)
    {
        try
        {
            var token = await _credential.GetTokenAsync(GraphTokenRequest, cancellationToken);
            if (string.IsNullOrWhiteSpace(token.Token))
                throw Failure(
                    "PROVISIONING_TOKEN_EMPTY",
                    "The provisioning identity returned an empty Microsoft Graph token.");

            if (token.ExpiresOn <= DateTimeOffset.UtcNow.AddMinutes(1))
            {
                throw Failure(
                    "PROVISIONING_TOKEN_EXPIRED",
                    "The provisioning identity returned an expired Microsoft Graph token.",
                    isTransient: true);
            }

            return token;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Agent365ProvisioningException)
        {
            throw;
        }
        catch (CredentialUnavailableException)
        {
            throw Failure(
                "PROVISIONING_CREDENTIAL_UNAVAILABLE",
                "The managed identity credential is unavailable.");
        }
        catch (AuthenticationFailedException exception) when (IsTransient(exception))
        {
            throw Failure(
                "PROVISIONING_TOKEN_TRANSIENT",
                "Microsoft Graph token acquisition is temporarily unavailable.",
                isTransient: true);
        }
        catch (AuthenticationFailedException)
        {
            throw Failure(
                "PROVISIONING_TOKEN_ACQUISITION_FAILED",
                "Microsoft Graph token acquisition failed.");
        }
    }

    private static bool IsTransient(Exception exception)
    {
        if (exception is RequestFailedException requestFailed
            && (requestFailed.Status is 408 or 429 || requestFailed.Status >= 500))
        {
            return true;
        }

        return exception.InnerException is not null && IsTransient(exception.InnerException);
    }

    private static Agent365ProvisioningException Failure(
        string code,
        string summary,
        bool isTransient = false)
    {
        return new Agent365ProvisioningException(code, summary, isTransient);
    }
}

internal static class ProvisioningManagedIdentityCredentialFactory
{
    public static TokenCredential Create(Agent365Options options)
    {
        return string.IsNullOrWhiteSpace(options.ProvisioningManagedIdentityClientId)
            ? new ManagedIdentityCredential()
            : new ManagedIdentityCredential(options.ProvisioningManagedIdentityClientId);
    }
}
