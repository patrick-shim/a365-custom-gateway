namespace Gateway.Purview;

internal interface IPurviewSettingsFailureObserver
{
    void Record(Guid operationId, string operation, string stage, Exception exception,
        int? childExitCode = null, string standardError = "");
}
