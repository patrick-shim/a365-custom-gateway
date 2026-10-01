using Microsoft.JSInterop;

namespace Gateway.AdminUi.Services;

public static class ProtectionRecovery
{
    public const string FailureMessage =
        "The browser could not confirm that it saved this operation's recovery link. " +
        "No confirmation or protection change was sent for this action. " +
        "Reload this page, check its current status, and review the action again.";

    public static async ValueTask<bool> TryRetainAsync(
        IJSRuntime js,
        ILogger logger,
        string uri,
        Guid operationId,
        CancellationToken cancellationToken)
    {
        try
        {
            var retained = await js.InvokeAsync<bool>("A365Gateway.retainProtectionRecovery",
                cancellationToken, uri, operationId.ToString("D"));
            if (!retained)
                logger.LogWarning("The browser did not acknowledge recovery for protection operation {OperationId}.", operationId);
            return retained;
        }
        catch (Exception exception) when (exception is JSException or JSDisconnectedException ||
            exception is OperationCanceledException && !cancellationToken.IsCancellationRequested)
        {
            logger.LogWarning(
                "Browser recovery failed for protection operation {OperationId}. ErrorType: {ErrorType}",
                operationId, exception.GetType().Name);
            return false;
        }
    }
}
