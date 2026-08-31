using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Domain.Models;

namespace Gateway.Agent365;

internal sealed class MicrosoftGraphProvisioningClient
{
    internal static readonly Uri OfficialBaseAddress = new("https://graph.microsoft.com/");
    private const int MaximumCatalogPageCount = 1000;
    private const string BlueprintCatalogAbsolutePath =
        "/v1.0/applications/microsoft.graph.agentIdentityBlueprint";
    private const string BlueprintCatalogPath =
        "v1.0/applications/microsoft.graph.agentIdentityBlueprint?$select=id,appId,displayName,managerApplications&$top=100";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly HttpClient _httpClient;
    private readonly IAgent365ProvisioningTokenProvider _tokenProvider;

    public MicrosoftGraphProvisioningClient(
        HttpClient httpClient,
        IAgent365ProvisioningTokenProvider tokenProvider)
    {
        _httpClient = httpClient;
        _tokenProvider = tokenProvider;
    }

    public async Task<Guid> GetCallerPrincipalObjectIdAsync(CancellationToken cancellationToken)
    {
        var token = await _tokenProvider.GetTokenAsync(cancellationToken);
        var segments = token.Token.Split('.');
        if (segments.Length < 2)
            throw Failure("PROVISIONING_TOKEN_INVALID", "The provisioning identity token is invalid.");

        try
        {
            var payload = segments[1].Replace('-', '+').Replace('_', '/');
            payload = payload.PadRight(payload.Length + ((4 - payload.Length % 4) % 4), '=');
            using var document = JsonDocument.Parse(Convert.FromBase64String(payload));
            if (!document.RootElement.TryGetProperty("oid", out var oidElement) ||
                !Guid.TryParse(oidElement.GetString(), out var objectId) ||
                objectId == Guid.Empty)
            {
                throw Failure(
                    "PROVISIONING_TOKEN_IDENTITY_MISSING",
                    "The provisioning identity token doesn't contain a valid object ID.");
            }

            return objectId;
        }
        catch (Agent365ProvisioningException)
        {
            throw;
        }
        catch (Exception exception) when (exception is FormatException or JsonException)
        {
            throw Failure("PROVISIONING_TOKEN_INVALID", "The provisioning identity token is invalid.");
        }
    }

    public Task<GraphApplication?> FindBlueprintAsync(
        string displayName,
        CancellationToken cancellationToken)
    {
        var filter = Uri.EscapeDataString($"displayName eq '{EscapeODataString(displayName)}'");
        var path = "v1.0/applications/microsoft.graph.agentIdentityBlueprint"
            + $"?$filter={filter}&$select=id,appId,displayName,tags&$top=2";
        return FindSingleAsync<GraphApplication>(
            path,
            "GRAPH_APPLICATION_LOOKUP_AMBIGUOUS",
            cancellationToken);
    }

    public async Task<IReadOnlyList<AgentIdentityBlueprintCatalogItem>> ListAgentIdentityBlueprintsAsync(
        IReadOnlyCollection<Guid> requiredManagerApplicationIds,
        CancellationToken cancellationToken)
    {
        var results = new List<AgentIdentityBlueprintCatalogItem>();
        var objectIds = new HashSet<Guid>();
        var clientIds = new HashSet<Guid>();
        var visitedPages = new HashSet<string>(StringComparer.Ordinal);
        string? nextPage = BlueprintCatalogPath;
        var pageCount = 0;

        while (nextPage is not null)
        {
            if (pageCount == MaximumCatalogPageCount)
            {
                throw Failure(
                    "MICROSOFT_GRAPH_NEXT_LINK_INVALID",
                    "Microsoft Graph returned more Agent Identity blueprint pages than the safety limit allows.");
            }

            var pageUri = ResolveGraphV1Uri(nextPage);
            if (!visitedPages.Add(pageUri.AbsoluteUri))
            {
                throw Failure(
                    "MICROSOFT_GRAPH_NEXT_LINK_INVALID",
                    "Microsoft Graph returned a repeated Agent Identity blueprint paging link.");
            }

            pageCount++;
            var page = await SendRequiredJsonAsync<GraphCollection<GraphApplication>>(
                HttpMethod.Get,
                pageUri.AbsoluteUri,
                body: null,
                mutation: false,
                cancellationToken);

            if (page.Value is null)
            {
                throw Failure(
                    "MICROSOFT_GRAPH_RESPONSE_INVALID",
                    "Microsoft Graph returned an invalid Agent Identity blueprint catalog response.");
            }

            foreach (var blueprint in page.Value)
            {
                var item = ValidateCatalogBlueprint(
                    blueprint,
                    requiredManagerApplicationIds);
                if (!objectIds.Add(item.BlueprintObjectId) ||
                    !clientIds.Add(item.BlueprintClientId))
                {
                    throw Failure(
                        "MICROSOFT_GRAPH_RESPONSE_INVALID",
                        "Microsoft Graph returned duplicate Agent Identity blueprint identifiers.");
                }

                results.Add(item);
            }

            nextPage = string.IsNullOrWhiteSpace(page.NextLink)
                ? null
                : page.NextLink;
        }

        return results
            .OrderBy(item => item.DisplayName, StringComparer.OrdinalIgnoreCase)
            .ThenBy(item => item.BlueprintClientId)
            .ToArray();
    }

    public Task<GraphApplication?> GetBlueprintAsync(
        string applicationObjectId,
        CancellationToken cancellationToken)
    {
        var objectId = RequiredGuid(applicationObjectId, "APPLICATION_OBJECT_ID_INVALID");
        return SendJsonAsync<GraphApplication>(
            HttpMethod.Get,
            $"v1.0/applications/{objectId:D}/microsoft.graph.agentIdentityBlueprint"
                + "?$select=id,appId,displayName,tags,managerApplications",
            body: null,
            allowNotFound: true,
            mutation: false,
            cancellationToken);
    }

    public Task<GraphApplication> CreateBlueprintAsync(
        string displayName,
        string? description,
        Guid ownerObjectId,
        IReadOnlyList<Guid> managerApplicationIds,
        string gatewayBlueprintKey,
        CancellationToken cancellationToken)
    {
        var ownerReference = $"https://graph.microsoft.com/v1.0/users/{ownerObjectId:D}";
        var body = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["displayName"] = displayName,
            ["description"] = description,
            ["signInAudience"] = "AzureADMyOrg",
            ["sponsors@odata.bind"] = new[] { ownerReference },
            ["owners@odata.bind"] = new[] { ownerReference },
            ["managerApplications"] = managerApplicationIds.Select(id => id.ToString("D")).ToArray(),
            ["tags"] = new[]
            {
                "A365CustomGateway",
                $"GatewayBlueprint:{gatewayBlueprintKey}"
            }
        };

        return SendRequiredJsonAsync<GraphApplication>(
            HttpMethod.Post,
            "v1.0/applications/microsoft.graph.agentIdentityBlueprint",
            body,
            mutation: true,
            cancellationToken);
    }

    public Task<GraphServicePrincipal?> GetServicePrincipalByAppIdAsync(
        string applicationClientId,
        CancellationToken cancellationToken)
    {
        var appId = RequiredGuid(applicationClientId, "APPLICATION_CLIENT_ID_INVALID");
        return SendJsonAsync<GraphServicePrincipal>(
            HttpMethod.Get,
            $"v1.0/servicePrincipals(appId='{appId:D}')?$select=id,appId,displayName,appRoles",
            body: null,
            allowNotFound: true,
            mutation: false,
            cancellationToken);
    }

    public Task<GraphServicePrincipal?> GetBlueprintPrincipalByAppIdAsync(
        string applicationClientId,
        CancellationToken cancellationToken)
    {
        var appId = RequiredGuid(applicationClientId, "APPLICATION_CLIENT_ID_INVALID");
        return SendJsonAsync<GraphServicePrincipal>(
            HttpMethod.Get,
            $"v1.0/servicePrincipals(appId='{appId:D}')/microsoft.graph.agentIdentityBlueprintPrincipal?$select=id,appId,displayName,appRoles",
            body: null,
            allowNotFound: true,
            mutation: false,
            cancellationToken);
    }

    public Task<GraphServicePrincipal?> GetBlueprintPrincipalAsync(
        string servicePrincipalObjectId,
        CancellationToken cancellationToken)
    {
        var objectId = RequiredGuid(
            servicePrincipalObjectId,
            "SERVICE_PRINCIPAL_OBJECT_ID_INVALID");
        return SendJsonAsync<GraphServicePrincipal>(
            HttpMethod.Get,
            $"v1.0/servicePrincipals/{objectId:D}/microsoft.graph.agentIdentityBlueprintPrincipal?$select=id,appId,displayName,appRoles",
            body: null,
            allowNotFound: true,
            mutation: false,
            cancellationToken);
    }

    public Task<GraphServicePrincipal?> GetAgentIdentityAsync(
        string servicePrincipalObjectId,
        CancellationToken cancellationToken)
    {
        var objectId = RequiredGuid(servicePrincipalObjectId, "SERVICE_PRINCIPAL_OBJECT_ID_INVALID");
        return SendJsonAsync<GraphServicePrincipal>(
            HttpMethod.Get,
            $"v1.0/servicePrincipals/{objectId:D}/microsoft.graph.agentIdentity"
                + "?$select=id,appId,displayName,appRoles,agentIdentityBlueprintId"
                + "&$expand=sponsors($select=id)",
            body: null,
            allowNotFound: true,
            mutation: false,
            cancellationToken);
    }

    public Task<GraphServicePrincipal> CreateBlueprintPrincipalAsync(
        string applicationClientId,
        CancellationToken cancellationToken)
    {
        var appId = RequiredGuid(applicationClientId, "APPLICATION_CLIENT_ID_INVALID");
        return SendRequiredJsonAsync<GraphServicePrincipal>(
            HttpMethod.Post,
            "v1.0/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal",
            new { appId = appId.ToString("D") },
            mutation: true,
            cancellationToken);
    }

    public async Task<IReadOnlyList<GraphAppRoleAssignment>> ListAppRoleAssignmentsAsync(
        string servicePrincipalObjectId,
        CancellationToken cancellationToken)
    {
        var objectId = RequiredGuid(
            servicePrincipalObjectId,
            "SERVICE_PRINCIPAL_OBJECT_ID_INVALID");
        var result = await SendRequiredJsonAsync<GraphCollection<GraphAppRoleAssignment>>(
            HttpMethod.Get,
            $"v1.0/servicePrincipals/{objectId:D}/appRoleAssignments?$select=id,principalId,resourceId,appRoleId&$top=999",
            body: null,
            mutation: false,
            cancellationToken);

        return result.Value ?? [];
    }

    public Task<GraphAppRoleAssignment> CreateAppRoleAssignmentAsync(
        Guid principalId,
        Guid resourceId,
        Guid appRoleId,
        CancellationToken cancellationToken)
    {
        return SendRequiredJsonAsync<GraphAppRoleAssignment>(
            HttpMethod.Post,
            $"v1.0/servicePrincipals/{principalId:D}/appRoleAssignments",
            new
            {
                principalId,
                resourceId,
                appRoleId
            },
            mutation: true,
            cancellationToken);
    }

    public Task<GraphServicePrincipal?> FindAgentIdentityAsync(
        string displayName,
        string blueprintClientId,
        CancellationToken cancellationToken)
    {
        var blueprintAppId = RequiredGuid(blueprintClientId, "BLUEPRINT_CLIENT_ID_INVALID");
        var filter = Uri.EscapeDataString(
            $"displayName eq '{EscapeODataString(displayName)}' and agentIdentityBlueprintId eq '{blueprintAppId:D}'");
        var path = "v1.0/servicePrincipals/microsoft.graph.agentIdentity"
            + $"?$filter={filter}&$select=id,appId,displayName,agentIdentityBlueprintId&$top=2";

        return FindSingleAsync<GraphServicePrincipal>(
            path,
            "AGENT_IDENTITY_LOOKUP_AMBIGUOUS",
            cancellationToken);
    }

    public Task<GraphServicePrincipal> CreateAgentIdentityAsync(
        string displayName,
        string blueprintClientId,
        Guid ownerObjectId,
        CancellationToken cancellationToken)
    {
        var blueprintAppId = RequiredGuid(blueprintClientId, "BLUEPRINT_CLIENT_ID_INVALID");
        var ownerReference = $"https://graph.microsoft.com/v1.0/users/{ownerObjectId:D}";
        var body = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["displayName"] = displayName,
            ["agentIdentityBlueprintId"] = blueprintAppId.ToString("D"),
            ["sponsors@odata.bind"] = new[] { ownerReference }
        };

        return SendRequiredJsonAsync<GraphServicePrincipal>(
            HttpMethod.Post,
            "v1.0/servicePrincipals/microsoft.graph.agentIdentity",
            body,
            mutation: true,
            cancellationToken);
    }

    public async Task<IReadOnlyList<GraphFederatedIdentityCredential>>
        ListFederatedIdentityCredentialsAsync(
            string applicationObjectId,
            CancellationToken cancellationToken)
    {
        var objectId = RequiredGuid(applicationObjectId, "APPLICATION_OBJECT_ID_INVALID");
        var result = await SendRequiredJsonAsync<GraphCollection<GraphFederatedIdentityCredential>>(
            HttpMethod.Get,
            $"v1.0/applications/{objectId:D}/federatedIdentityCredentials"
                + "?$select=id,name,issuer,subject,audiences&$top=100",
            body: null,
            mutation: false,
            cancellationToken);

        return result.Value
            ?? throw Failure(
                "MICROSOFT_GRAPH_RESPONSE_INVALID",
                "Microsoft Graph returned an invalid federated identity credential collection.",
                requiresManualIntervention: true);
    }

    public Task<GraphFederatedIdentityCredential> CreateFederatedIdentityCredentialAsync(
        string applicationObjectId,
        string name,
        string issuer,
        string subject,
        CancellationToken cancellationToken)
    {
        var objectId = RequiredGuid(applicationObjectId, "APPLICATION_OBJECT_ID_INVALID");
        return SendRequiredJsonAsync<GraphFederatedIdentityCredential>(
            HttpMethod.Post,
            $"v1.0/applications/{objectId:D}/federatedIdentityCredentials",
            new
            {
                name,
                issuer,
                subject,
                audiences = new[] { "api://AzureADTokenExchange" }
            },
            mutation: true,
            cancellationToken);
    }

    public async Task<IReadOnlyList<Guid>> ListBlueprintOwnerIdsAsync(
        string applicationObjectId,
        CancellationToken cancellationToken)
    {
        var objectId = RequiredGuid(applicationObjectId, "APPLICATION_OBJECT_ID_INVALID");
        return await ListRelationshipIdsAsync(
            $"v1.0/applications/{objectId:D}/microsoft.graph.agentIdentityBlueprint/owners?$select=id&$top=999",
            cancellationToken);
    }

    public async Task<IReadOnlyList<Guid>> ListBlueprintSponsorIdsAsync(
        string applicationObjectId,
        CancellationToken cancellationToken)
    {
        var objectId = RequiredGuid(applicationObjectId, "APPLICATION_OBJECT_ID_INVALID");
        return await ListRelationshipIdsAsync(
            $"v1.0/applications/{objectId:D}/microsoft.graph.agentIdentityBlueprint/sponsors?$select=id&$top=999",
            cancellationToken);
    }

    private async Task<T?> FindSingleAsync<T>(
        string path,
        string ambiguousCode,
        CancellationToken cancellationToken)
    {
        var result = await SendRequiredJsonAsync<GraphCollection<T>>(
            HttpMethod.Get,
            path,
            body: null,
            mutation: false,
            cancellationToken);
        var values = result.Value ?? [];

        return values.Count switch
        {
            0 => default,
            1 => values[0],
            _ => throw Failure(
                ambiguousCode,
                "More than one Microsoft resource matched the deterministic provisioning key.",
                requiresManualIntervention: true)
        };
    }

    private async Task<IReadOnlyList<Guid>> ListRelationshipIdsAsync(
        string path,
        CancellationToken cancellationToken)
    {
        var result = await SendRequiredJsonAsync<GraphCollection<GraphDirectoryObject>>(
            HttpMethod.Get,
            path,
            body: null,
            mutation: false,
            cancellationToken);
        var ids = new List<Guid>();

        foreach (var item in result.Value ?? [])
        {
            ids.Add(RequiredGuid(item.Id, "MICROSOFT_RELATIONSHIP_ID_INVALID"));
        }

        return ids;
    }

    private async Task<T> SendRequiredJsonAsync<T>(
        HttpMethod method,
        string path,
        object? body,
        bool mutation,
        CancellationToken cancellationToken)
    {
        return await SendJsonAsync<T>(
                method,
                path,
                body,
                allowNotFound: false,
                mutation,
                cancellationToken)
            ?? throw Failure(
                "MICROSOFT_GRAPH_RESPONSE_INVALID",
                "Microsoft Graph returned an empty success response.",
                requiresManualIntervention: mutation);
    }

    private async Task<T?> SendJsonAsync<T>(
        HttpMethod method,
        string path,
        object? body,
        bool allowNotFound,
        bool mutation,
        CancellationToken cancellationToken)
    {
        using var request = await CreateRequestAsync(method, path, body, cancellationToken);
        using var response = await SendAsync(request, mutation, cancellationToken);

        if (allowNotFound && response.StatusCode == HttpStatusCode.NotFound)
            return default;

        EnsureSuccess(response.StatusCode, mutation);

        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            return await JsonSerializer.DeserializeAsync<T>(stream, JsonOptions, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (JsonException)
        {
            throw Failure(
                "MICROSOFT_GRAPH_RESPONSE_INVALID",
                "Microsoft Graph returned an invalid success response.",
                requiresManualIntervention: mutation);
        }
    }

    private async Task<HttpRequestMessage> CreateRequestAsync(
        HttpMethod method,
        string path,
        object? body,
        CancellationToken cancellationToken)
    {
        var accessToken = await _tokenProvider.GetTokenAsync(cancellationToken);
        var request = new HttpRequestMessage(method, path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken.Token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.TryAddWithoutValidation("OData-Version", "4.0");

        if (body is not null)
            request.Content = JsonContent.Create(body, options: JsonOptions);

        return request;
    }

    private async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        bool mutation,
        CancellationToken cancellationToken)
    {
        try
        {
            return await _httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (TaskCanceledException)
        {
            throw Failure(
                mutation
                    ? "MICROSOFT_GRAPH_OUTCOME_UNKNOWN"
                    : "MICROSOFT_GRAPH_TIMEOUT",
                mutation
                    ? "The Microsoft Graph operation outcome is unknown and requires reconciliation."
                    : "Microsoft Graph didn't respond before the request timeout.",
                isTransient: !mutation,
                requiresManualIntervention: mutation);
        }
        catch (HttpRequestException)
        {
            throw Failure(
                mutation
                    ? "MICROSOFT_GRAPH_OUTCOME_UNKNOWN"
                    : "MICROSOFT_GRAPH_NETWORK_FAILURE",
                mutation
                    ? "The Microsoft Graph operation outcome is unknown and requires reconciliation."
                    : "Microsoft Graph is temporarily unreachable.",
                isTransient: !mutation,
                requiresManualIntervention: mutation);
        }
    }

    private static void EnsureSuccess(HttpStatusCode statusCode, bool mutation)
    {
        var status = (int)statusCode;
        if (status is >= 200 and <= 299)
            return;

        if (statusCode == HttpStatusCode.Unauthorized)
        {
            throw Failure(
                "MICROSOFT_GRAPH_UNAUTHORIZED",
                "Microsoft Graph rejected the provisioning identity.");
        }

        if (statusCode == HttpStatusCode.Forbidden)
        {
            throw Failure(
                "MICROSOFT_GRAPH_FORBIDDEN",
                "The provisioning identity lacks a required Microsoft Graph permission.");
        }

        if (statusCode == HttpStatusCode.Conflict)
        {
            throw Failure(
                "MICROSOFT_GRAPH_CONFLICT",
                "Microsoft Graph reported a conflicting resource state.",
                isTransient: true);
        }

        if (statusCode == HttpStatusCode.TooManyRequests)
        {
            throw Failure(
                mutation
                    ? "MICROSOFT_GRAPH_OUTCOME_UNKNOWN"
                    : "MICROSOFT_GRAPH_THROTTLED",
                mutation
                    ? "The Microsoft Graph operation outcome is unknown and requires reconciliation."
                    : "Microsoft Graph throttled the provisioning request.",
                isTransient: !mutation,
                requiresManualIntervention: mutation);
        }

        if (status == 408 || status >= 500)
        {
            throw Failure(
                mutation
                    ? "MICROSOFT_GRAPH_OUTCOME_UNKNOWN"
                    : "MICROSOFT_GRAPH_TRANSIENT",
                mutation
                    ? "The Microsoft Graph operation outcome is unknown and requires reconciliation."
                    : "Microsoft Graph is temporarily unavailable.",
                isTransient: !mutation,
                requiresManualIntervention: mutation);
        }

        if (statusCode == HttpStatusCode.NotFound)
        {
            throw Failure(
                "MICROSOFT_GRAPH_RESOURCE_NOT_FOUND",
                "A required Microsoft resource wasn't found.");
        }

        throw Failure(
            "MICROSOFT_GRAPH_REQUEST_REJECTED",
            "Microsoft Graph rejected the provisioning request.");
    }

    private static string EscapeODataString(string value)
    {
        return value.Replace("'", "''", StringComparison.Ordinal);
    }

    private AgentIdentityBlueprintCatalogItem ValidateCatalogBlueprint(
        GraphApplication? blueprint,
        IReadOnlyCollection<Guid> requiredManagerApplicationIds)
    {
        if (blueprint is null ||
            !Guid.TryParse(blueprint.Id, out var objectId) || objectId == Guid.Empty ||
            !Guid.TryParse(blueprint.AppId, out var clientId) || clientId == Guid.Empty)
        {
            throw Failure(
                "MICROSOFT_GRAPH_RESPONSE_INVALID",
                "Microsoft Graph returned invalid Agent Identity blueprint identifiers.");
        }

        var displayName = blueprint.DisplayName?.Trim();
        if (string.IsNullOrEmpty(displayName) ||
            displayName.Length > 256 ||
            displayName.Any(char.IsControl))
        {
            throw Failure(
                "MICROSOFT_GRAPH_RESPONSE_INVALID",
                "Microsoft Graph returned an invalid Agent Identity blueprint display name.");
        }

        var expectedManagers = requiredManagerApplicationIds.ToHashSet();
        var actualManagers = (blueprint.ManagerApplications ?? []).ToHashSet();
        var managerApplicationsConfigured = expectedManagers.Count > 0;
        var compatible = managerApplicationsConfigured && expectedManagers.IsSubsetOf(actualManagers);
        var compatibilityIssue = compatible
            ? null
            : managerApplicationsConfigured
                ? AgentIdentityBlueprintCompatibilityIssues.MissingRequiredManagerApplications
                : AgentIdentityBlueprintCompatibilityIssues.ManagerApplicationsNotConfigured;

        return new AgentIdentityBlueprintCatalogItem(
            objectId,
            clientId,
            displayName,
            compatible,
            compatibilityIssue);
    }

    private Uri ResolveGraphV1Uri(string url)
    {
        if (_httpClient.BaseAddress is null ||
            !Uri.TryCreate(_httpClient.BaseAddress, url, out var resolved) ||
            !IsGlobalGraphV1Uri(resolved) ||
            !string.Equals(
                resolved.AbsolutePath,
                BlueprintCatalogAbsolutePath,
                StringComparison.Ordinal))
        {
            throw Failure(
                "MICROSOFT_GRAPH_NEXT_LINK_INVALID",
                "Microsoft Graph returned an invalid Agent Identity blueprint paging link.");
        }

        return resolved;
    }

    private static bool IsGlobalGraphV1Uri(Uri uri)
    {
        if (!uri.IsAbsoluteUri ||
            !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(uri.Host, "graph.microsoft.com", StringComparison.OrdinalIgnoreCase) ||
            !uri.IsDefaultPort ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Fragment))
        {
            return false;
        }

        var escapedPath = uri.AbsolutePath;
        if (escapedPath.Contains("%2f", StringComparison.OrdinalIgnoreCase) ||
            escapedPath.Contains("%5c", StringComparison.OrdinalIgnoreCase) ||
            escapedPath.Contains("%2e", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        string path;
        try
        {
            path = Uri.UnescapeDataString(escapedPath);
        }
        catch (UriFormatException)
        {
            return false;
        }

        return path.StartsWith("/v1.0/", StringComparison.Ordinal) &&
               path.Split('/', StringSplitOptions.RemoveEmptyEntries)
                   .All(segment => segment is not "." and not "..");
    }

    internal static Guid RequiredGuid(string? value, string errorCode)
    {
        if (!Guid.TryParse(value, out var parsed) || parsed == Guid.Empty)
        {
            throw Failure(
                errorCode,
                "A required provisioning identifier is missing or invalid.",
                requiresManualIntervention: true);
        }

        return parsed;
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

internal sealed record GraphCollection<T>
{
    [JsonPropertyName("value")]
    public List<T>? Value { get; init; }

    [JsonPropertyName("@odata.nextLink")]
    public string? NextLink { get; init; }
}

internal sealed record GraphApplication
{
    public string? Id { get; init; }
    public string? AppId { get; init; }
    public string? DisplayName { get; init; }
    public List<string>? Tags { get; init; }
    public List<Guid>? ManagerApplications { get; init; }
}

internal sealed record GraphServicePrincipal
{
    public string? Id { get; init; }
    public string? AppId { get; init; }
    public string? DisplayName { get; init; }
    public string? AgentIdentityBlueprintId { get; init; }
    public List<GraphAppRole>? AppRoles { get; init; }
    public List<GraphDirectoryObject>? Sponsors { get; init; }
}

internal sealed record GraphAppRole
{
    public Guid? Id { get; init; }
    public string? Value { get; init; }
    public bool? IsEnabled { get; init; }
    public List<string>? AllowedMemberTypes { get; init; }
}

internal sealed record GraphAppRoleAssignment
{
    public string? Id { get; init; }
    public Guid? PrincipalId { get; init; }
    public Guid? ResourceId { get; init; }
    public Guid? AppRoleId { get; init; }
}

internal sealed record GraphFederatedIdentityCredential
{
    public string? Id { get; init; }
    public string? Name { get; init; }
    public string? Issuer { get; init; }
    public string? Subject { get; init; }
    public List<string>? Audiences { get; init; }
}

internal sealed record GraphDirectoryObject
{
    public string? Id { get; init; }
}
