using Azure;
using Azure.Core;
using Azure.Identity;
using Gateway.Domain.Models;
using Microsoft.Extensions.Options;

namespace Gateway.Purview;

internal sealed class DefaultAzurePurviewTokenProvider : IPurviewTokenProvider
{
    private static readonly TokenRequestContext GraphTokenRequest =
        new(["https://graph.microsoft.com/.default"]);

    private readonly TokenCredential _credential;

    public DefaultAzurePurviewTokenProvider(IOptions<PurviewOptions> options)
        : this(CreateCredential(options.Value))
    {
    }

    internal DefaultAzurePurviewTokenProvider(TokenCredential credential)
    {
        _credential = credential;
    }

    public async ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken)
    {
        try
        {
            var token = await _credential.GetTokenAsync(GraphTokenRequest, cancellationToken);
            if (string.IsNullOrWhiteSpace(token.Token))
                throw Failure("PURVIEW_TOKEN_EMPTY", "The Purview identity returned an empty Microsoft Graph token.");

            if (token.ExpiresOn <= DateTimeOffset.UtcNow.AddMinutes(1))
            {
                throw Failure(
                    "PURVIEW_TOKEN_EXPIRED",
                    "The Purview identity returned an expired Microsoft Graph token.",
                    isTransient: true);
            }

            return token;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (PurviewPolicyException)
        {
            throw;
        }
        catch (CredentialUnavailableException exception)
        {
            throw Failure(
                "PURVIEW_CREDENTIAL_UNAVAILABLE",
                "The managed identity credential for Purview is unavailable.",
                innerException: exception);
        }
        catch (AuthenticationFailedException exception) when (IsTransient(exception))
        {
            throw Failure(
                "PURVIEW_TOKEN_TRANSIENT",
                "Microsoft Graph token acquisition for Purview is temporarily unavailable.",
                isTransient: true,
                innerException: exception);
        }
        catch (AuthenticationFailedException exception)
        {
            throw Failure(
                "PURVIEW_TOKEN_ACQUISITION_FAILED",
                "Microsoft Graph token acquisition for Purview failed.",
                innerException: exception);
        }
    }

    private static TokenCredential CreateCredential(PurviewOptions options) =>
        string.IsNullOrWhiteSpace(options.ManagedIdentityClientId)
            ? new ManagedIdentityCredential()
            : new ManagedIdentityCredential(options.ManagedIdentityClientId);

    private static bool IsTransient(Exception exception)
    {
        if (exception is RequestFailedException requestFailed
            && (requestFailed.Status is 408 or 429 || requestFailed.Status >= 500))
        {
            return true;
        }

        return exception.InnerException is not null && IsTransient(exception.InnerException);
    }

    private static PurviewPolicyException Failure(
        string code,
        string message,
        bool isTransient = false,
        Exception? innerException = null) =>
        new(code, message, isTransient, innerException);
}
