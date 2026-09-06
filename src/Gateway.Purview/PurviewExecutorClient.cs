using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Azure.Core;
using Azure.Identity;
using Gateway.Domain.Models;
using Microsoft.Extensions.Options;

namespace Gateway.Purview;

internal sealed class PurviewExecutorClient(
    IHttpClientFactory clients,
    IOptions<PurviewExecutorOptions> executorOptions,
    IOptions<PurviewOptions> purviewOptions,
    TokenCredential credential) : IPurviewExecutorClient
{
    internal const string HttpClientName = "PurviewExecutor";
    private const int MaximumResponseBytes = 512 * 1024;

    public async Task<TResponse> ReadAsync<TRequest, TResponse>(
        PurviewExecutorCommand command, Guid operationId, Guid tenantId,
        TRequest input, CancellationToken cancellationToken)
    {
        if (command is not (PurviewExecutorCommand.VerifyConnection or
            PurviewExecutorCommand.ReadKnowYourData or PurviewExecutorCommand.ReadDlpProfile))
            throw new ArgumentException("Unsupported executor read operation.");

        PurviewExecutorReply reply;
        try
        {
            reply = await SendAsync(command, operationId, tenantId, input, cancellationToken);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested &&
            command == PurviewExecutorCommand.VerifyConnection)
        {
            throw Failure("PURVIEW_EXECUTOR_CONNECTION_READ_TIMEOUT", isTransient: true);
        }
        if (command == PurviewExecutorCommand.VerifyConnection && reply.Status == "RetryableRead" &&
            reply.FailureCode == "PURVIEW_EXECUTOR_CONNECTION_READ_TIMEOUT" && reply.Value is null)
            throw Failure("PURVIEW_EXECUTOR_CONNECTION_READ_TIMEOUT", isTransient: true);
        if (reply.Status != "Completed" || reply.Value is not { } value ||
            reply.FailureCode is not null)
            throw Failure("PURVIEW_EXECUTOR_READ_UNAVAILABLE");
        try
        {
            return value.Deserialize<TResponse>(PurviewExecutorJson.Options)
                ?? throw Failure("PURVIEW_EXECUTOR_RESPONSE_INVALID");
        }
        catch (JsonException)
        {
            throw Failure("PURVIEW_EXECUTOR_RESPONSE_INVALID");
        }
    }

    public async Task MutateAsync<TRequest>(
        PurviewExecutorCommand command, Guid operationId, Guid tenantId,
        TRequest input, CancellationToken cancellationToken)
    {
        if (command is not (PurviewExecutorCommand.CreateKnowYourData or
            PurviewExecutorCommand.CreateDlpPolicy or PurviewExecutorCommand.CreateDlpRule))
            throw new ArgumentException("Unsupported executor mutation.");

        // Configuration errors are known before dispatch; transport outcomes
        // after this point always require the existing exact-readback recovery.
        _ = RequireConfiguration(operationId, tenantId);
        try
        {
            var reply = await SendAsync(command, operationId, tenantId, input, cancellationToken);
            if (reply.Status is not ("Completed" or "Replayed") ||
                reply.FailureCode is not null || reply.Value is not null)
                throw new PurviewMutationOutcomeUnknownException("PURVIEW_EXECUTOR_MUTATION_UNKNOWN");
        }
        catch (PurviewPolicyException)
        {
            throw new PurviewMutationOutcomeUnknownException("PURVIEW_EXECUTOR_MUTATION_UNKNOWN");
        }
        catch (OperationCanceledException)
        {
            throw new PurviewMutationOutcomeUnknownException("PURVIEW_EXECUTOR_MUTATION_UNKNOWN");
        }
    }

    private async Task<PurviewExecutorReply> SendAsync<TRequest>(
        PurviewExecutorCommand command, Guid operationId, Guid tenantId,
        TRequest input, CancellationToken cancellationToken)
    {
        var (endpoint, binding, timeout) = RequireConfiguration(operationId, tenantId);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        var ct = deadline.Token;
        try
        {
            var token = await credential.GetTokenAsync(new TokenRequestContext(
                [$"api://{binding.ExecutorApplicationId:D}/.default"]), ct);
            var envelope = new PurviewExecutorRequest(binding, operationId, command,
                DateTimeOffset.UtcNow.AddMinutes(4),
                JsonSerializer.SerializeToElement(input, PurviewExecutorJson.Options));
            using var request = new HttpRequestMessage(HttpMethod.Post,
                new Uri(endpoint, "executor/v1/execute"));
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
            request.Content = JsonContent.Create(envelope, options: PurviewExecutorJson.Options);
            using var response = await clients.CreateClient(HttpClientName).SendAsync(
                request, HttpCompletionOption.ResponseHeadersRead, ct);
            if (response.StatusCode != System.Net.HttpStatusCode.OK ||
                response.Content.Headers.ContentLength > MaximumResponseBytes)
                throw Failure("PURVIEW_EXECUTOR_UNAVAILABLE");

            await using var stream = await response.Content.ReadAsStreamAsync(ct);
            var bytes = new byte[MaximumResponseBytes + 1];
            var length = 0;
            while (length < bytes.Length)
            {
                var count = await stream.ReadAsync(bytes.AsMemory(length), ct);
                if (count == 0) break;
                length += count;
            }
            if (length > MaximumResponseBytes)
                throw Failure("PURVIEW_EXECUTOR_RESPONSE_INVALID");
            var reply = JsonSerializer.Deserialize<PurviewExecutorReply>(
                bytes.AsSpan(0, length), PurviewExecutorJson.Options);
            if (reply is null || reply.Binding != binding ||
                reply.OperationId != operationId || reply.Command != command)
                throw Failure("PURVIEW_EXECUTOR_RESPONSE_BINDING_MISMATCH");
            return reply;
        }
        catch (HttpRequestException)
        {
            throw Failure("PURVIEW_EXECUTOR_UNAVAILABLE");
        }
        catch (IOException)
        {
            throw Failure("PURVIEW_EXECUTOR_UNAVAILABLE");
        }
        catch (AuthenticationFailedException)
        {
            throw Failure("PURVIEW_EXECUTOR_AUTHENTICATION_UNAVAILABLE");
        }
        catch (JsonException)
        {
            throw Failure("PURVIEW_EXECUTOR_RESPONSE_INVALID");
        }
    }

    private (Uri Endpoint, PurviewExecutorBinding Binding, TimeSpan Timeout)
        RequireConfiguration(Guid operationId, Guid tenantId)
    {
        var options = executorOptions.Value;
        if (!options.Enabled || options.Binding is not { } binding ||
            operationId == Guid.Empty || tenantId != binding.TenantId ||
            options.TimeoutSeconds is < 205 or > 220 ||
            !Uri.TryCreate(options.Endpoint, UriKind.Absolute, out var endpoint) ||
            endpoint.Scheme != Uri.UriSchemeHttps || !endpoint.IsDefaultPort ||
            !endpoint.Host.EndsWith(".azurewebsites.net", StringComparison.Ordinal) ||
            endpoint.Host.Contains(".scm.", StringComparison.Ordinal) ||
            endpoint.AbsolutePath != "/" || endpoint.Query.Length != 0 ||
            endpoint.Fragment.Length != 0 || endpoint.UserInfo.Length != 0)
            throw Failure("PURVIEW_EXECUTOR_NOT_CONFIGURED");
        _ = binding.Validate(purviewOptions.Value);
        return (endpoint, binding, TimeSpan.FromSeconds(options.TimeoutSeconds));
    }

    private static PurviewPolicyException Failure(string code, bool isTransient = false) =>
        new(code, "Purview Windows execution is unavailable or could not be independently verified.", isTransient);
}
