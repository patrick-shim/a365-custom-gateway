using System.Security.Cryptography;
using System.Text.Json;
using Gateway.Domain.Models;
using Gateway.Provisioning.Worker;
using Gateway.Purview;

namespace Gateway.Purview.Executor;

internal sealed record PurviewSettingsFailure(
    Guid OperationId, DateTimeOffset ObservedAtUtc, string Operation, string Stage,
    string FailureKind, int? ChildExitCode, int? ProviderStage,
    IReadOnlyList<PurviewProviderError> ProviderErrors);

internal sealed class PurviewSettingsFailureDiagnostics(TimeProvider timeProvider)
    : IPurviewSettingsFailureObserver
{
    private PurviewSettingsFailure? lastFailure;

    public void Record(Guid operationId, string operation, string stage, Exception exception,
        int? childExitCode = null, string standardError = "")
    {
        if (operationId == Guid.Empty ||
            operation is not ("ReadKnowYourData" or "CreateKnowYourData" or
                "ReadDlpProfile" or "CreateDlpPolicy" or "CreateDlpRule") ||
            stage is not ("HostPreparation" or "ChildInput" or "ChildCompletion" or
                "ResultParsing" or "OutputBound" or "ChildTimeout"))
            return;
        var kind = exception switch
        {
            JsonException => "Json",
            CryptographicException => "Cryptography",
            UnauthorizedAccessException => "AccessDenied",
            OperationCanceledException => "Cancelled",
            PurviewPolicyException => "PurviewPolicy",
            InvalidOperationException => "InvalidOperation",
            IOException => "FileOrPipe",
            _ => "Other"
        };
        var provider = PurviewConnectionVerificationDiagnostics.ParseProviderFailure(standardError);
        Interlocked.Exchange(ref lastFailure, new(operationId, timeProvider.GetUtcNow(),
            operation, stage, kind, childExitCode, provider?.Stage, provider?.Errors ?? []));
    }

    internal PurviewSettingsFailure? Read()
    {
        var value = Volatile.Read(ref lastFailure);
        return value is not null &&
            timeProvider.GetUtcNow() - value.ObservedAtUtc is var age &&
            age >= TimeSpan.Zero && age <= TimeSpan.FromMinutes(5) ? value : null;
    }
}
