using System.Globalization;
using System.Text.Json;
using Gateway.Setup.Models;

namespace Gateway.Setup.Services;

internal sealed record PurviewSensitiveInformationTypeDiscoveryResult(
    Guid SubscriptionId,
    Guid TenantId,
    IReadOnlyList<PurviewSensitiveInformationType> Types,
    string Provenance,
    string? Guidance)
{
    public bool Succeeded => Guidance is null && Types.Count is > 0 and <= 2048;
}

internal interface IPurviewSensitiveInformationTypeDiscovery
{
    bool IsSupported { get; }

    string? UnsupportedGuidance { get; }

    Task<PurviewSensitiveInformationTypeDiscoveryResult> DiscoverAsync(
        Guid subscriptionId,
        Guid tenantId,
        CancellationToken cancellationToken = default);
}

internal sealed class PurviewSensitiveInformationTypeDiscovery(
    IAzureCliRunner azureCliRunner,
    IPurviewSensitiveInformationTypeRunner purviewRunner)
    : IPurviewSensitiveInformationTypeDiscovery
{
    internal const string Provenance =
        "Tenant Security & Compliance PowerShell Get-DlpSensitiveInformationType inventory after exact Azure account and Microsoft Graph /me verification";
    internal const string UnsupportedPlatformGuidance =
        "Microsoft does not support Security & Compliance PowerShell in PowerShell 7 on macOS or Linux. Use Gateway Setup on Windows for Purview; core Gateway setup remains available on this platform with Purview off.";
    private const int MaximumTypes = 2048;
    private const int MaximumNameLength = 255;
    private const int MaximumPublisherLength = 200;
    private static readonly TimeSpan AzureDiscoveryTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan PurviewDiscoveryTimeout = TimeSpan.FromMinutes(5);

    public bool IsSupported => purviewRunner.IsSupported;

    public string? UnsupportedGuidance => IsSupported ? null : UnsupportedPlatformGuidance;

    public async Task<PurviewSensitiveInformationTypeDiscoveryResult> DiscoverAsync(
        Guid subscriptionId,
        Guid tenantId,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!IsSupported)
        {
            return Failure(
                subscriptionId,
                tenantId,
                UnsupportedPlatformGuidance);
        }

        if (subscriptionId == Guid.Empty || tenantId == Guid.Empty)
        {
            return Failure(
                subscriptionId,
                tenantId,
                "Select an enabled Azure subscription before loading tenant Purview sensitive information types.");
        }

        var accountInvocation = await azureCliRunner.RunAsync(
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
            AzureDiscoveryTimeout,
            cancellationToken);
        var accountIssue = GetAzureInvocationIssue(
            accountInvocation,
            "selected Azure account");
        if (accountIssue is not null)
        {
            return Failure(subscriptionId, tenantId, accountIssue);
        }

        try
        {
            var account = ParseSelectedAccount(accountInvocation.StandardOutput);
            if (account.SubscriptionId != subscriptionId || account.TenantId != tenantId)
            {
                return Failure(
                    subscriptionId,
                    tenantId,
                    "Azure CLI did not return the exact selected subscription and tenant. Setup did not open a Purview session.");
            }

            if (!AzureAccountDiscovery.IsEnabled(account.State))
            {
                return Failure(
                    subscriptionId,
                    tenantId,
                    "The selected Azure subscription is not Enabled. Choose an enabled subscription before Purview discovery.");
            }
        }
        catch (Exception exception) when (
            exception is JsonException or DiscoveryContractException)
        {
            return Failure(
                subscriptionId,
                tenantId,
                "Azure CLI returned an unexpected selected-account response. Setup did not open a Purview session.");
        }

        var graphInvocation = await azureCliRunner.RunAsync(
            [
                "rest",
                "--method",
                "GET",
                "--url",
                "https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName,userType",
                "--resource",
                "https://graph.microsoft.com/",
                "--subscription",
                subscriptionId.ToString("D"),
                "--query",
                "{id:id,userPrincipalName:userPrincipalName,userType:userType}",
                "--output",
                "json",
                "--only-show-errors"
            ],
            AzureDiscoveryTimeout,
            cancellationToken);
        var graphIssue = GetAzureInvocationIssue(
            graphInvocation,
            "signed-in Microsoft Graph user");
        if (graphIssue is not null)
        {
            return Failure(
                subscriptionId,
                tenantId,
                "Setup could not verify the signed-in Microsoft Graph user for the exact selected subscription. Reauthenticate that tenant and retry.");
        }

        GraphUser graphUser;
        try
        {
            graphUser = ParseGraphUser(graphInvocation.StandardOutput);
        }
        catch (Exception exception) when (
            exception is JsonException or DiscoveryContractException)
        {
            return Failure(
                subscriptionId,
                tenantId,
                "Microsoft Graph returned an unexpected signed-in Microsoft Graph user response. Setup did not open a Purview session.");
        }

        if (!string.Equals(graphUser.UserType, "Member", StringComparison.Ordinal))
        {
            return Failure(
                subscriptionId,
                tenantId,
                "Microsoft Graph did not report the signed-in user as userType Member in the selected tenant. Sign in with an authorized Member account and retry; Setup did not open a Purview session.");
        }

        var purviewInvocation = await purviewRunner.RunAsync(
            tenantId,
            graphUser.UserPrincipalName,
            PurviewDiscoveryTimeout,
            cancellationToken);
        if (purviewInvocation.Status == PurviewSensitiveInformationTypeInvocationStatus.Unavailable)
        {
            return Failure(
                subscriptionId,
                tenantId,
                "Setup could not safely start the repository Purview inventory helper through PowerShell. Run the root launcher doctor command and retry.");
        }

        if (purviewInvocation.Status == PurviewSensitiveInformationTypeInvocationStatus.TimedOut)
        {
            return Failure(
                subscriptionId,
                tenantId,
                "Purview sign-in or tenant inventory discovery timed out. Complete the official sign-in promptly and retry.");
        }

        if (purviewInvocation.Status == PurviewSensitiveInformationTypeInvocationStatus.OutputRejected)
        {
            return Failure(
                subscriptionId,
                tenantId,
                "The Purview inventory helper crossed its bounded output contract. No partial tenant inventory was accepted.");
        }

        if (purviewInvocation.ExitCode != 0)
        {
            return Failure(
                subscriptionId,
                tenantId,
                "Security & Compliance PowerShell could not return the tenant sensitive information type inventory. Confirm the required Purview role and retry; dependency details were withheld.");
        }

        try
        {
            var types = ParseInventory(purviewInvocation.StandardOutput, tenantId);
            return new PurviewSensitiveInformationTypeDiscoveryResult(
                subscriptionId,
                tenantId,
                types,
                Provenance,
                null);
        }
        catch (Exception exception) when (
            exception is JsonException or DiscoveryContractException)
        {
            return Failure(
                subscriptionId,
                tenantId,
                "Security & Compliance PowerShell returned an unexpected tenant inventory. Setup accepted no classifier; update the supported module and retry.");
        }
    }

    internal static IReadOnlyList<PurviewSensitiveInformationType> ParseInventory(
        string json,
        Guid expectedTenantId)
    {
        using var document = JsonDocument.Parse(
            json,
            new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 6
            });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            root.EnumerateObject().Count() != 3 ||
            !root.TryGetProperty("schemaVersion", out var schemaVersion) ||
            schemaVersion.ValueKind != JsonValueKind.Number ||
            !schemaVersion.TryGetInt32(out var version) ||
            version != 1 ||
            !Guid.TryParse(ReadRequiredString(root, "tenantId"), out var tenantId) ||
            tenantId == Guid.Empty ||
            tenantId != expectedTenantId ||
            !root.TryGetProperty("types", out var inventory) ||
            inventory.ValueKind != JsonValueKind.Array ||
            inventory.GetArrayLength() is < 1 or > MaximumTypes)
        {
            throw new DiscoveryContractException("Purview inventory envelope was invalid.");
        }

        var types = new List<PurviewSensitiveInformationType>(inventory.GetArrayLength());
        var ids = new HashSet<Guid>();
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in inventory.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object ||
                item.EnumerateObject().Count() != 3 ||
                !Guid.TryParse(ReadRequiredString(item, "id"), out var id) ||
                id == Guid.Empty ||
                !ids.Add(id))
            {
                throw new DiscoveryContractException("Purview inventory item identity was invalid.");
            }

            var name = ReadRequiredString(item, "name");
            var publisher = ReadRequiredString(item, "publisher");
            if (!IsExactProviderString(name, MaximumNameLength, allowEmpty: false) ||
                !IsExactProviderString(publisher, MaximumPublisherLength, allowEmpty: true) ||
                !names.Add(name))
            {
                throw new DiscoveryContractException("Purview inventory item text was invalid.");
            }

            types.Add(new PurviewSensitiveInformationType(id, name, publisher));
        }

        return types
            .OrderBy(type => type.Name, StringComparer.Ordinal)
            .ThenBy(type => type.Id.ToString("D"), StringComparer.Ordinal)
            .ToArray();
    }

    private static SelectedAccount ParseSelectedAccount(string json)
    {
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 4 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            root.EnumerateObject().Count() != 3 ||
            !Guid.TryParse(ReadRequiredString(root, "id"), out var subscriptionId) ||
            subscriptionId == Guid.Empty ||
            !Guid.TryParse(ReadRequiredString(root, "tenantId"), out var tenantId) ||
            tenantId == Guid.Empty)
        {
            throw new DiscoveryContractException("Selected Azure account response was invalid.");
        }

        var state = ReadRequiredString(root, "state");
        if (!IsExactProviderString(state, 40, allowEmpty: false))
        {
            throw new DiscoveryContractException("Selected Azure account state was invalid.");
        }

        return new SelectedAccount(subscriptionId, tenantId, state);
    }

    private static GraphUser ParseGraphUser(string json)
    {
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 4 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            root.EnumerateObject().Count() != 3)
        {
            throw new DiscoveryContractException("Microsoft Graph user response was invalid.");
        }

        var objectIdText = ReadRequiredString(root, "id");
        if (
            !Guid.TryParseExact(objectIdText, "D", out var objectId) ||
            objectId == Guid.Empty ||
            !string.Equals(objectIdText, objectId.ToString("D"), StringComparison.Ordinal))
        {
            throw new DiscoveryContractException("Microsoft Graph user response was invalid.");
        }

        var userPrincipalName = ReadRequiredString(root, "userPrincipalName");
        if (!IsExactUserPrincipalName(userPrincipalName))
        {
            throw new DiscoveryContractException("Microsoft Graph user principal name was invalid.");
        }

        var userType = ReadRequiredString(root, "userType");
        if (!IsExactProviderString(userType, 16, allowEmpty: false))
        {
            throw new DiscoveryContractException("Microsoft Graph user type was invalid.");
        }

        return new GraphUser(objectId, userPrincipalName, userType);
    }

    private static bool IsExactUserPrincipalName(string value)
    {
        if (value.Length is < 1 or > 254 ||
            !string.Equals(value, value.Trim(), StringComparison.Ordinal))
        {
            return false;
        }

        foreach (var character in value)
        {
            if (char.IsWhiteSpace(character) ||
                char.GetUnicodeCategory(character) is
                    UnicodeCategory.Control or UnicodeCategory.Format)
            {
                return false;
            }
        }

        var separator = value.IndexOf('@');
        if (separator <= 0 || separator != value.LastIndexOf('@'))
        {
            return false;
        }

        var domain = value.AsSpan(separator + 1);
        var dot = domain.IndexOf('.');
        return dot > 0 && dot < domain.Length - 1;
    }

    private static string? GetAzureInvocationIssue(
        AzureCliInvocationResult invocation,
        string operation) => invocation.Status switch
        {
            AzureCliInvocationStatus.Unavailable =>
                "Setup could not safely start Azure CLI from its current process environment. Close Setup, run the root launcher doctor command, then restart Setup.",
            AzureCliInvocationStatus.TimedOut =>
                $"Azure CLI timed out while reading the {operation}. Reauthenticate the exact tenant and retry.",
            AzureCliInvocationStatus.OutputRejected =>
                $"Azure CLI returned an oversized or malformed {operation} response. Update Azure CLI and retry.",
            _ when invocation.ExitCode != 0 =>
                $"Azure CLI could not read the {operation}. Reauthenticate the exact tenant and retry.",
            _ => null
        };

    private static string ReadRequiredString(JsonElement item, string propertyName)
    {
        if (!item.TryGetProperty(propertyName, out var value) ||
            value.ValueKind != JsonValueKind.String ||
            value.GetString() is not { } text)
        {
            throw new DiscoveryContractException($"Required property '{propertyName}' was missing.");
        }

        return text;
    }

    private static bool IsExactProviderString(
        string value,
        int maximumLength,
        bool allowEmpty) =>
        (allowEmpty || value.Length > 0) &&
        value.Length <= maximumLength &&
        string.Equals(value, value.Trim(), StringComparison.Ordinal) &&
        !value.Any(char.IsControl);

    private static PurviewSensitiveInformationTypeDiscoveryResult Failure(
        Guid subscriptionId,
        Guid tenantId,
        string guidance) => new(
            subscriptionId,
            tenantId,
            [],
            Provenance,
            guidance);

    private sealed record SelectedAccount(Guid SubscriptionId, Guid TenantId, string State);

    private sealed record GraphUser(Guid ObjectId, string UserPrincipalName, string UserType);

    private sealed class DiscoveryContractException(string message) : Exception(message);
}
