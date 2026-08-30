using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Gateway.Setup.Models;

namespace Gateway.Setup.Services;

internal sealed record AzureAccountDiscoveryResult(
    IReadOnlyList<AzureSubscription> Subscriptions,
    string? Guidance)
{
    public bool Succeeded => Guidance is null;
}

internal sealed record ManagerApplicationCandidate(
    Guid ApplicationId,
    Guid ServicePrincipalObjectId,
    string DisplayName,
    string PublisherName,
    string VerifiedPublisherName,
    string ServicePrincipalType,
    int BlueprintReferenceCount,
    IReadOnlyList<string> ReferencingBlueprintNames);

internal sealed record ManagerApplicationDiscoveryResult(
    Guid SubscriptionId,
    Guid TenantId,
    IReadOnlyList<ManagerApplicationCandidate> Candidates,
    string Provenance,
    string? Guidance)
{
    public bool Succeeded => Guidance is null && Candidates.Count is > 0 and <= 10;
}

internal interface IAzureAccountDiscovery
{
    Task<AzureAccountDiscoveryResult> DiscoverAsync(CancellationToken cancellationToken = default);

    Task<ManagerApplicationDiscoveryResult> DiscoverManagerApplicationsAsync(
        Guid subscriptionId,
        Guid tenantId,
        CancellationToken cancellationToken = default);
}

internal enum AzureCliInvocationStatus
{
    Completed,
    Missing,
    TimedOut,
    OutputRejected
}

internal sealed record AzureCliInvocationResult(
    AzureCliInvocationStatus Status,
    int ExitCode,
    string StandardOutput);

internal interface IAzureCliRunner
{
    Task<AzureCliInvocationResult> RunAsync(
        IReadOnlyList<string> arguments,
        TimeSpan timeout,
        CancellationToken cancellationToken);
}

internal sealed class AzureCliRunner : IAzureCliRunner
{
    private const int MaximumOutputCharacters = 256 * 1024;

    public async Task<AzureCliInvocationResult> RunAsync(
        IReadOnlyList<string> arguments,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "az",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        startInfo.Environment["AZURE_CORE_NO_COLOR"] = "1";
        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start())
            {
                return new AzureCliInvocationResult(AzureCliInvocationStatus.Missing, -1, string.Empty);
            }
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return new AzureCliInvocationResult(AzureCliInvocationStatus.Missing, -1, string.Empty);
        }

        using var boundedCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        boundedCancellation.CancelAfter(timeout);
        var outputTask = ReadBoundedAsync(process.StandardOutput, boundedCancellation.Token);
        var errorTask = ReadBoundedAsync(process.StandardError, boundedCancellation.Token);

        try
        {
            await process.WaitForExitAsync(boundedCancellation.Token);
            var output = await outputTask;
            _ = await errorTask;
            return new AzureCliInvocationResult(
                AzureCliInvocationStatus.Completed,
                process.ExitCode,
                output);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            TryKill(process);
            return new AzureCliInvocationResult(AzureCliInvocationStatus.TimedOut, -1, string.Empty);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            throw;
        }
        catch (JsonException)
        {
            TryKill(process);
            return new AzureCliInvocationResult(AzureCliInvocationStatus.OutputRejected, -1, string.Empty);
        }
    }

    private static async Task<string> ReadBoundedAsync(
        StreamReader reader,
        CancellationToken cancellationToken)
    {
        var buffer = new char[4 * 1024];
        var builder = new StringBuilder();
        while (true)
        {
            var count = await reader.ReadAsync(buffer.AsMemory(), cancellationToken);
            if (count == 0)
            {
                return builder.ToString();
            }

            if (builder.Length + count > MaximumOutputCharacters)
            {
                throw new JsonException("Azure CLI output exceeded the safe bound.");
            }

            builder.Append(buffer, 0, count);
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
            // Process already exited.
        }
    }
}

internal sealed class AzureAccountDiscovery : IAzureAccountDiscovery
{
    internal const string ManagerApplicationProvenance =
        "Microsoft Graph v1.0 typed agentIdentityBlueprint managerApplications inventory plus exact tenant service-principal appId readback";
    private const int MaximumBlueprintPages = 20;
    private static readonly TimeSpan AccountDiscoveryTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan GraphDiscoveryTimeout = TimeSpan.FromSeconds(30);
    private readonly IAzureCliRunner runner;

    public AzureAccountDiscovery()
        : this(new AzureCliRunner())
    {
    }

    internal AzureAccountDiscovery(IAzureCliRunner runner)
    {
        this.runner = runner;
    }

    public async Task<AzureAccountDiscoveryResult> DiscoverAsync(
        CancellationToken cancellationToken = default)
    {
        var invocation = await runner.RunAsync(
            [
                "account",
                "list",
                "--all",
                "--query",
                "[].{name:name,id:id,tenantId:tenantId,isDefault:isDefault,state:state}",
                "--output",
                "json",
                "--only-show-errors"
            ],
            AccountDiscoveryTimeout,
            cancellationToken);

        if (invocation.Status == AzureCliInvocationStatus.Missing)
        {
            return MissingCli();
        }

        if (invocation.Status == AzureCliInvocationStatus.TimedOut)
        {
            return new AzureAccountDiscoveryResult(
                [],
                "Azure account discovery timed out. Run `az account list` in the terminal, then try again.");
        }

        if (invocation.Status == AzureCliInvocationStatus.OutputRejected)
        {
            return UnexpectedAccountInventory();
        }

        if (invocation.ExitCode != 0)
        {
            return LoginGuidance();
        }

        try
        {
            var subscriptions = ParseSubscriptions(invocation.StandardOutput);
            return subscriptions.Count == 0
                ? LoginGuidance()
                : new AzureAccountDiscoveryResult(subscriptions, null);
        }
        catch (JsonException)
        {
            return UnexpectedAccountInventory();
        }
    }

    public async Task<ManagerApplicationDiscoveryResult> DiscoverManagerApplicationsAsync(
        Guid subscriptionId,
        Guid tenantId,
        CancellationToken cancellationToken = default)
    {
        if (subscriptionId == Guid.Empty || tenantId == Guid.Empty)
        {
            return ManagerFailure(
                subscriptionId,
                tenantId,
                "Select an enabled Azure subscription before discovering Agent 365 manager applications.");
        }

        try
        {
            var accountInvocation = await runner.RunAsync(
                [
                    "account",
                    "show",
                    "--subscription",
                    subscriptionId.ToString("D"),
                    "--query",
                    "{id:id,tenantId:tenantId,state:state}",
                    "--output",
                    "json",
                    "--only-show-errors"
                ],
                AccountDiscoveryTimeout,
                cancellationToken);
            var accountIssue = GetInvocationIssue(accountInvocation, "selected Azure account");
            if (accountIssue is not null)
            {
                return ManagerFailure(subscriptionId, tenantId, accountIssue);
            }

            var selectedAccount = ParseSelectedAccount(accountInvocation.StandardOutput);
            if (selectedAccount.SubscriptionId != subscriptionId || selectedAccount.TenantId != tenantId)
            {
                return ManagerFailure(
                    subscriptionId,
                    tenantId,
                    "Azure CLI did not return the exact selected subscription and tenant. Setup did not inspect or accept any manager application.");
            }

            if (!IsEnabled(selectedAccount.State))
            {
                return ManagerFailure(
                    subscriptionId,
                    tenantId,
                    "The selected Azure subscription is not Enabled. Choose an enabled subscription before tenant discovery.");
            }

            var observations = new Dictionary<Guid, ManagerApplicationObservation>();
            var visited = new HashSet<string>(StringComparer.Ordinal);
            var nextUrl =
                "https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint?$select=id,displayName,managerApplications&$top=100";
            for (var pageNumber = 1; pageNumber <= MaximumBlueprintPages; pageNumber++)
            {
                if (!visited.Add(nextUrl))
                {
                    throw new DiscoveryContractException("Repeated Microsoft Graph continuation.");
                }

                var pageInvocation = await InvokeGraphGetAsync(
                    nextUrl,
                    subscriptionId,
                    cancellationToken);
                var graphIssue = GetInvocationIssue(pageInvocation, "typed Agent ID blueprint inventory");
                if (graphIssue is not null)
                {
                    return ManagerFailure(
                        subscriptionId,
                        tenantId,
                        "Setup could not read typed Agent ID blueprints through Microsoft Graph for the exact selected tenant. " +
                        "Use an authorized work account with AgentIdentityBlueprint.Read.All and the required Agent ID administrator role, then retry. No candidate was accepted.");
                }

                var page = ParseBlueprintPage(pageInvocation.StandardOutput);
                foreach (var blueprint in page.Blueprints)
                {
                    foreach (var managerId in blueprint.ManagerApplicationIds)
                    {
                        if (!observations.TryGetValue(managerId, out var observation))
                        {
                            observation = new ManagerApplicationObservation();
                            observations.Add(managerId, observation);
                        }

                        observation.BlueprintObjectIds.Add(blueprint.BlueprintObjectId);
                        observation.BlueprintNames.Add(blueprint.DisplayName);
                    }
                }

                if (observations.Count > 10)
                {
                    return ManagerFailure(
                        subscriptionId,
                        tenantId,
                        "The tenant inventory exposed more than ten distinct manager applications. Setup will not choose a subset; review the provider configuration independently.");
                }

                if (page.NextLink is null)
                {
                    break;
                }

                if (pageNumber == MaximumBlueprintPages)
                {
                    return ManagerFailure(
                        subscriptionId,
                        tenantId,
                        "Typed blueprint discovery exceeded the bounded 2,000-item inventory. Setup did not accept a partial result.");
                }

                nextUrl = ValidateBlueprintNextLink(page.NextLink);
            }

            if (observations.Count == 0)
            {
                return ManagerFailure(
                    subscriptionId,
                    tenantId,
                    "No existing typed Agent ID blueprint exposed a managerApplications value in this tenant. Setup will not guess a first-party application ID. " +
                    "Use an official Agent 365 provider/bootstrap result or have an Agent ID administrator establish and review the prerequisite, then retry discovery.");
            }

            var candidates = new List<ManagerApplicationCandidate>(observations.Count);
            foreach (var pair in observations.OrderBy(item => item.Key.ToString("D"), StringComparer.Ordinal))
            {
                var servicePrincipalUrl =
                    $"https://graph.microsoft.com/v1.0/servicePrincipals?$filter=appId%20eq%20'{pair.Key:D}'&" +
                    "$select=id,appId,displayName,publisherName,verifiedPublisher,servicePrincipalType&$top=2";
                var servicePrincipalInvocation = await InvokeGraphGetAsync(
                    servicePrincipalUrl,
                    subscriptionId,
                    cancellationToken);
                var servicePrincipalIssue = GetInvocationIssue(
                    servicePrincipalInvocation,
                    "manager application service-principal inventory");
                if (servicePrincipalIssue is not null)
                {
                    return ManagerFailure(
                        subscriptionId,
                        tenantId,
                        "Setup observed managerApplications on typed blueprints but could not complete exact tenant service-principal readback. " +
                        "Grant the signed-in administrator the required read access and retry; no candidate was accepted.");
                }

                var principal = ParseServicePrincipal(servicePrincipalInvocation.StandardOutput, pair.Key);
                candidates.Add(new ManagerApplicationCandidate(
                    pair.Key,
                    principal.ObjectId,
                    principal.DisplayName,
                    principal.PublisherName,
                    principal.VerifiedPublisherName,
                    principal.ServicePrincipalType,
                    pair.Value.BlueprintObjectIds.Count,
                    pair.Value.BlueprintNames
                        .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
                        .Take(3)
                        .ToArray()));
            }

            return new ManagerApplicationDiscoveryResult(
                subscriptionId,
                tenantId,
                candidates,
                ManagerApplicationProvenance,
                null);
        }
        catch (JsonException)
        {
            return ManagerFailure(
                subscriptionId,
                tenantId,
                "Microsoft Graph returned an unexpected tenant inventory. Setup did not accept any manager application.");
        }
        catch (DiscoveryContractException)
        {
            return ManagerFailure(
                subscriptionId,
                tenantId,
                "Microsoft Graph tenant discovery crossed a bounded response contract. Setup did not accept any partial or ambiguous result.");
        }
    }

    internal static List<AzureSubscription> ParseSubscriptions(string json)
    {
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 6 });
        if (document.RootElement.ValueKind != JsonValueKind.Array)
        {
            throw new JsonException("Expected an array.");
        }

        var subscriptions = new List<AzureSubscription>();
        foreach (var item in document.RootElement.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object ||
                !Guid.TryParse(ReadString(item, "id"), out var subscriptionId) ||
                subscriptionId == Guid.Empty ||
                !Guid.TryParse(ReadString(item, "tenantId"), out var tenantId) ||
                tenantId == Guid.Empty)
            {
                continue;
            }

            var name = ReadSafeString(item, "name", "Azure subscription", 100);
            var state = ReadSafeString(item, "state", "Unknown", 40);
            var isDefault = item.TryGetProperty("isDefault", out var defaultElement) &&
                defaultElement.ValueKind is JsonValueKind.True;
            subscriptions.Add(new AzureSubscription(subscriptionId, tenantId, name, isDefault, state));
        }

        return subscriptions
            .OrderByDescending(subscription => IsEnabled(subscription.State))
            .ThenByDescending(subscription => subscription.IsDefault)
            .ThenBy(subscription => subscription.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    internal static bool IsEnabled(string? state) =>
        string.Equals(state, "Enabled", StringComparison.OrdinalIgnoreCase);

    private async Task<AzureCliInvocationResult> InvokeGraphGetAsync(
        string url,
        Guid subscriptionId,
        CancellationToken cancellationToken) =>
        await runner.RunAsync(
            [
                "rest",
                "--method",
                "get",
                "--url",
                url,
                "--resource",
                "https://graph.microsoft.com/",
                "--subscription",
                subscriptionId.ToString("D"),
                "--output",
                "json",
                "--only-show-errors"
            ],
            GraphDiscoveryTimeout,
            cancellationToken);

    private static SelectedAccount ParseSelectedAccount(string json)
    {
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 4 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            !Guid.TryParse(ReadString(root, "id"), out var subscriptionId) ||
            subscriptionId == Guid.Empty ||
            !Guid.TryParse(ReadString(root, "tenantId"), out var tenantId) ||
            tenantId == Guid.Empty)
        {
            throw new JsonException("Selected account shape was invalid.");
        }

        return new SelectedAccount(
            subscriptionId,
            tenantId,
            ReadSafeString(root, "state", "Unknown", 40));
    }

    private static BlueprintPage ParseBlueprintPage(string json)
    {
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            !root.TryGetProperty("value", out var value) ||
            value.ValueKind != JsonValueKind.Array ||
            value.GetArrayLength() > 100)
        {
            throw new DiscoveryContractException("Blueprint collection shape was invalid.");
        }

        var blueprints = new List<BlueprintObservation>(value.GetArrayLength());
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object ||
                !Guid.TryParse(ReadString(item, "id"), out var blueprintObjectId) ||
                blueprintObjectId == Guid.Empty ||
                !item.TryGetProperty("managerApplications", out var managers) ||
                managers.ValueKind != JsonValueKind.Array ||
                managers.GetArrayLength() > 10)
            {
                throw new DiscoveryContractException("Blueprint item shape was invalid.");
            }

            var managerIds = new HashSet<Guid>();
            foreach (var manager in managers.EnumerateArray())
            {
                if (manager.ValueKind != JsonValueKind.String ||
                    !Guid.TryParse(manager.GetString(), out var managerId) ||
                    managerId == Guid.Empty ||
                    !managerIds.Add(managerId))
                {
                    throw new DiscoveryContractException("Blueprint manager application shape was invalid.");
                }
            }

            blueprints.Add(new BlueprintObservation(
                blueprintObjectId,
                ReadSafeString(item, "displayName", "Agent identity blueprint", 100),
                managerIds.OrderBy(id => id.ToString("D"), StringComparer.Ordinal).ToArray()));
        }

        string? nextLink = null;
        if (root.TryGetProperty("@odata.nextLink", out var continuation))
        {
            if (continuation.ValueKind != JsonValueKind.String ||
                string.IsNullOrWhiteSpace(continuation.GetString()))
            {
                throw new DiscoveryContractException("Blueprint continuation shape was invalid.");
            }

            nextLink = continuation.GetString();
        }

        return new BlueprintPage(blueprints, nextLink);
    }

    private static ServicePrincipalObservation ParseServicePrincipal(string json, Guid expectedAppId)
    {
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            !root.TryGetProperty("value", out var value) ||
            value.ValueKind != JsonValueKind.Array ||
            value.GetArrayLength() != 1)
        {
            throw new DiscoveryContractException("Manager service-principal lookup was not exact.");
        }

        var item = value[0];
        if (item.ValueKind != JsonValueKind.Object ||
            !Guid.TryParse(ReadString(item, "id"), out var objectId) ||
            objectId == Guid.Empty ||
            !Guid.TryParse(ReadString(item, "appId"), out var appId) ||
            appId != expectedAppId)
        {
            throw new DiscoveryContractException("Manager service-principal identity did not match.");
        }

        var verifiedPublisherName = "Not reported";
        if (item.TryGetProperty("verifiedPublisher", out var verifiedPublisher) &&
            verifiedPublisher.ValueKind == JsonValueKind.Object)
        {
            verifiedPublisherName = ReadSafeString(
                verifiedPublisher,
                "displayName",
                "Not reported",
                256);
        }
        else if (item.TryGetProperty("verifiedPublisher", out verifiedPublisher) &&
            verifiedPublisher.ValueKind is not JsonValueKind.Null)
        {
            throw new DiscoveryContractException("Verified publisher shape was invalid.");
        }

        return new ServicePrincipalObservation(
            objectId,
            ReadSafeString(item, "displayName", "Microsoft first-party manager application", 256),
            ReadSafeString(item, "publisherName", "Not reported", 256),
            verifiedPublisherName,
            ReadSafeString(item, "servicePrincipalType", "Not reported", 64));
    }

    private static string ValidateBlueprintNextLink(string value)
    {
        if (value.Length > 16 * 1024 ||
            !Uri.TryCreate(value, UriKind.Absolute, out var uri) ||
            !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.Ordinal) ||
            !string.Equals(uri.DnsSafeHost, "graph.microsoft.com", StringComparison.OrdinalIgnoreCase) ||
            (!uri.IsDefaultPort && uri.Port != 443) ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Fragment) ||
            !string.Equals(
                uri.AbsolutePath,
                "/v1.0/applications/microsoft.graph.agentIdentityBlueprint",
                StringComparison.OrdinalIgnoreCase))
        {
            throw new DiscoveryContractException("Blueprint continuation left the reviewed Graph boundary.");
        }

        return uri.AbsoluteUri;
    }

    private static string? GetInvocationIssue(
        AzureCliInvocationResult invocation,
        string operation) => invocation.Status switch
        {
            AzureCliInvocationStatus.Missing =>
                "Azure CLI is not installed or not on PATH. Run `gateway doctor`, then retry.",
            AzureCliInvocationStatus.TimedOut =>
                $"Azure CLI timed out while reading the {operation}. Retry after confirming the signed-in session.",
            AzureCliInvocationStatus.OutputRejected =>
                $"Azure CLI returned an oversized or malformed {operation} response. Update Azure CLI and retry.",
            _ when invocation.ExitCode != 0 =>
                $"Azure CLI could not read the {operation}. Reauthenticate the exact tenant and retry.",
            _ => null
        };

    private static string? ReadString(JsonElement item, string name) =>
        item.TryGetProperty(name, out var element) && element.ValueKind == JsonValueKind.String
            ? element.GetString()
            : null;

    private static string ReadSafeString(
        JsonElement item,
        string propertyName,
        string fallback,
        int maximumLength)
    {
        var value = ReadString(item, propertyName)?.Trim();
        return string.IsNullOrWhiteSpace(value) ||
            value.Length > maximumLength ||
            !SafePublicValuePolicy.IsAllowed(value)
                ? fallback
                : value;
    }

    private static AzureAccountDiscoveryResult MissingCli() => new(
        [],
        "Azure CLI is not installed or not on PATH. Run `gateway doctor` or install Azure CLI, then try again.");

    private static AzureAccountDiscoveryResult LoginGuidance() => new(
        [],
        "No usable Azure subscriptions were found. Run `az login` in the terminal; Setup never asks for or stores your password or token.");

    private static AzureAccountDiscoveryResult UnexpectedAccountInventory() => new(
        [],
        "Azure CLI returned an unexpected account inventory. Update Azure CLI and try again.");

    private static ManagerApplicationDiscoveryResult ManagerFailure(
        Guid subscriptionId,
        Guid tenantId,
        string guidance) => new(
            subscriptionId,
            tenantId,
            [],
            ManagerApplicationProvenance,
            guidance);

    private sealed record SelectedAccount(Guid SubscriptionId, Guid TenantId, string State);

    private sealed record BlueprintObservation(
        Guid BlueprintObjectId,
        string DisplayName,
        IReadOnlyList<Guid> ManagerApplicationIds);

    private sealed record BlueprintPage(
        IReadOnlyList<BlueprintObservation> Blueprints,
        string? NextLink);

    private sealed record ServicePrincipalObservation(
        Guid ObjectId,
        string DisplayName,
        string PublisherName,
        string VerifiedPublisherName,
        string ServicePrincipalType);

    private sealed class ManagerApplicationObservation
    {
        public HashSet<Guid> BlueprintObjectIds { get; } = [];

        public HashSet<string> BlueprintNames { get; } = new(StringComparer.OrdinalIgnoreCase);
    }

    private sealed class DiscoveryContractException(string message) : Exception(message);
}
