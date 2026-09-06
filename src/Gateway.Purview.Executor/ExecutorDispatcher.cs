using System.Text.Json;
using Azure;
using Gateway.Domain.Models;
using Gateway.Provisioning.Worker;
using Microsoft.Extensions.Options;

namespace Gateway.Purview.Executor;

internal sealed class ExecutorDispatcher(
    IOptions<ExecutorHostOptions> options,
    IPurviewConnectionVerificationProvider connection,
    IPurviewSettingsAutomation settings,
    ExecutorOperationJournal journal,
    TimeProvider timeProvider)
{
    public async Task<PurviewExecutorReply> ExecuteAsync(
        PurviewExecutorRequest request, CancellationToken cancellationToken)
    {
        var expected = options.Value.Binding;
        if (expected is null || request.Binding != expected || request.OperationId == Guid.Empty ||
            !Enum.IsDefined(request.Command) || request.ExpiresAtUtc.Offset != TimeSpan.Zero ||
            request.ExpiresAtUtc <= timeProvider.GetUtcNow() ||
            request.ExpiresAtUtc > timeProvider.GetUtcNow().AddMinutes(5) ||
            request.Input.ValueKind != JsonValueKind.Object)
            return Reply(request, "Rejected", failureCode: "PURVIEW_EXECUTOR_REQUEST_BINDING_MISMATCH");

        try
        {
            switch (request.Command)
            {
                case PurviewExecutorCommand.VerifyConnection:
                    {
                        var input = Parse<PurviewConnectionVerificationRequest>(request);
                        var certificateUri = new Uri(expected.CertificateSecretUri);
                        if (input.OperationId != request.OperationId || input.TenantId != expected.TenantId ||
                            input.AdministratorObjectId == Guid.Empty ||
                            input.ExpectedAuthorityApplicationId != expected.AutomationApplicationId ||
                            input.ExpectedAuthorityServicePrincipalObjectId != expected.AutomationServicePrincipalObjectId ||
                            input.ExpectedKeyVaultResourceId != expected.KeyVaultResourceId ||
                            input.ExpectedKeyVaultHost != certificateUri.Host ||
                            input.ExpectedCertificateName != expected.CertificateName ||
                            input.ExpectedCertificateSecretUri != certificateUri)
                            return Reply(request, "Rejected", failureCode: "PURVIEW_EXECUTOR_CAPABILITY_MISMATCH");
                        var evidence = await connection.VerifyAsync(input, cancellationToken);
                        return Reply(request, "Completed", evidence);
                    }
                case PurviewExecutorCommand.ReadKnowYourData:
                case PurviewExecutorCommand.CreateKnowYourData:
                    {
                        var input = Parse<PurviewKnowYourDataIntent>(request);
                        if (input.OperationId != request.OperationId || input.TenantId != expected.TenantId)
                            return Reply(request, "Rejected", failureCode: "PURVIEW_EXECUTOR_INTENT_MISMATCH");
                        if (request.Command == PurviewExecutorCommand.ReadKnowYourData)
                            return Reply(request, "Completed", await settings.ReadKnowYourDataAsync(input, cancellationToken));
                        return await MutateAsync(request, input,
                            ct => settings.CreateKnowYourDataAsync(input, ct), cancellationToken);
                    }
                case PurviewExecutorCommand.ReadDlpProfile:
                case PurviewExecutorCommand.CreateDlpPolicy:
                case PurviewExecutorCommand.CreateDlpRule:
                    {
                        var input = Parse<PurviewDlpProfileIntent>(request);
                        if (input.OperationId != request.OperationId || input.TenantId != expected.TenantId ||
                            input.BlueprintApplicationId == Guid.Empty)
                            return Reply(request, "Rejected", failureCode: "PURVIEW_EXECUTOR_INTENT_MISMATCH");
                        if (request.Command == PurviewExecutorCommand.ReadDlpProfile)
                            return Reply(request, "Completed", await settings.ReadDlpProfileAsync(input, cancellationToken));
                        return await MutateAsync(request, input, ct =>
                            request.Command == PurviewExecutorCommand.CreateDlpPolicy
                                ? settings.CreateDlpPolicyAsync(input, ct)
                                : settings.CreateDlpRuleAsync(input, ct), cancellationToken);
                    }
                default:
                    return Reply(request, "Rejected", failureCode: "PURVIEW_EXECUTOR_COMMAND_INVALID");
            }
        }
        catch (JsonException)
        {
            return Reply(request, "Rejected", failureCode: "PURVIEW_EXECUTOR_INPUT_INVALID");
        }
        catch (PurviewPolicyException)
        {
            return Reply(request, "Unavailable", failureCode: "PURVIEW_EXECUTOR_PROVIDER_UNAVAILABLE");
        }
        catch (PurviewConnectionVerificationException exception)
        {
            if (exception.IsTransient && exception.FailureCode == "PURVIEW_CONNECTION_READ_TIMEOUT")
                return Reply(request, "RetryableRead", failureCode: "PURVIEW_EXECUTOR_CONNECTION_READ_TIMEOUT");
            return Reply(request, "Unavailable", failureCode: "PURVIEW_EXECUTOR_CONNECTION_UNVERIFIED");
        }
        catch (PurviewMutationOutcomeUnknownException)
        {
            return Reply(request, "OutcomeUnknown", failureCode: "PURVIEW_EXECUTOR_MUTATION_UNKNOWN");
        }
        catch (RequestFailedException)
        {
            return Reply(request, "OutcomeUnknown", failureCode: "PURVIEW_EXECUTOR_STORAGE_UNAVAILABLE");
        }
        catch (OperationCanceledException)
        {
            if (request.Command == PurviewExecutorCommand.VerifyConnection)
                return Reply(request, "RetryableRead", failureCode: "PURVIEW_EXECUTOR_CONNECTION_READ_TIMEOUT");
            return Reply(request, "OutcomeUnknown", failureCode: "PURVIEW_EXECUTOR_DEADLINE_EXCEEDED");
        }
        catch (IOException)
        {
            return Reply(request, "OutcomeUnknown", failureCode: "PURVIEW_EXECUTOR_STORAGE_UNAVAILABLE");
        }
        catch (InvalidOperationException)
        {
            return Reply(request, "OutcomeUnknown", failureCode: "PURVIEW_EXECUTOR_OPERATION_UNVERIFIED");
        }
    }

    private async Task<PurviewExecutorReply> MutateAsync<T>(PurviewExecutorRequest request,
        T input, Func<CancellationToken, Task> mutation, CancellationToken cancellationToken)
    {
        var expected = options.Value.Binding!;
        var semanticInput = JsonSerializer.Serialize(new
        {
            binding = expected,
            command = request.Command,
            input
        }, PurviewExecutorJson.Options);
        var disposition = await journal.ExecuteAsync(expected.DeploymentOwnershipId,
            expected.TenantId, request.OperationId, request.Command.ToString(), semanticInput,
            async ct =>
            {
                try { await mutation(ct); }
                catch (PurviewPolicyException) { throw new ExecutorProviderException(); }
                catch (PurviewMutationOutcomeUnknownException) { throw new ExecutorProviderException(); }
            }, cancellationToken);
        return disposition switch
        {
            ExecutorMutationDisposition.Completed => Reply(request, "Completed"),
            ExecutorMutationDisposition.Replayed => Reply(request, "Replayed"),
            ExecutorMutationDisposition.Conflict => Reply(request, "Conflict", failureCode: "PURVIEW_EXECUTOR_INPUT_CONFLICT"),
            ExecutorMutationDisposition.HostUnavailable => Reply(request, "Unavailable", failureCode: "PURVIEW_EXECUTOR_HOST_UNAVAILABLE"),
            _ => Reply(request, "OutcomeUnknown", failureCode: "PURVIEW_EXECUTOR_MUTATION_UNKNOWN")
        };
    }

    private static T Parse<T>(PurviewExecutorRequest request) =>
        request.Input.Deserialize<T>(PurviewExecutorJson.Options)
        ?? throw new JsonException("Executor input is missing.");

    private PurviewExecutorReply Reply(PurviewExecutorRequest request, string status,
        object? value = null, string? failureCode = null) =>
        new(options.Value.Binding!, request.OperationId, request.Command, status,
            value is null ? null : JsonSerializer.SerializeToElement(value, PurviewExecutorJson.Options), failureCode);
}
