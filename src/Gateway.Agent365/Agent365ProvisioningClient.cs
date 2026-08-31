using System.Security.Cryptography;
using System.Text;
using Gateway.Contracts;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Agent365;

public sealed class Agent365ProvisioningClient : IAgent365ProvisioningClient
{
    private static readonly TimeSpan[] RecoveryLookupDelays =
    [
        TimeSpan.Zero,
        TimeSpan.FromMilliseconds(250),
        TimeSpan.FromMilliseconds(750)
    ];
    private static readonly TimeSpan[] FederatedCredentialVerificationLookupDelays =
    [
        TimeSpan.Zero,
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
        TimeSpan.FromSeconds(8)
    ];
    private static readonly TimeSpan[] PostMutationVerificationLookupDelays =
    [
        TimeSpan.Zero,
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
        TimeSpan.FromSeconds(8),
        TimeSpan.FromSeconds(16),
        TimeSpan.FromSeconds(24)
    ];

    private readonly ILogger<Agent365ProvisioningClient> _logger;
    private readonly Agent365Options _options;
    private readonly MicrosoftGraphProvisioningClient _graph;
    private readonly IAgent365ObservabilityTokenProvider? _observabilityTokenProvider;
    private readonly IReadOnlyList<TimeSpan> _federatedCredentialVerificationLookupDelays;
    private readonly IReadOnlyList<TimeSpan> _postMutationVerificationLookupDelays;

    internal Agent365ProvisioningClient(
        ILogger<Agent365ProvisioningClient> logger,
        IOptions<Agent365Options> options,
        IHttpClientFactory httpClientFactory,
        IAgent365ProvisioningTokenProvider tokenProvider,
        IAgent365ObservabilityTokenProvider observabilityTokenProvider)
        : this(
            logger,
            options.Value,
            new MicrosoftGraphProvisioningClient(
                httpClientFactory.CreateClient(nameof(Agent365ProvisioningClient)),
                tokenProvider),
            observabilityTokenProvider)
    {
    }

    internal Agent365ProvisioningClient(
        ILogger<Agent365ProvisioningClient> logger,
        Agent365Options options,
        MicrosoftGraphProvisioningClient graph)
        : this(logger, options, graph, observabilityTokenProvider: null)
    {
    }

    internal Agent365ProvisioningClient(
        ILogger<Agent365ProvisioningClient> logger,
        Agent365Options options,
        MicrosoftGraphProvisioningClient graph,
        IAgent365ObservabilityTokenProvider? observabilityTokenProvider,
        IReadOnlyList<TimeSpan>? federatedCredentialVerificationLookupDelays = null,
        IReadOnlyList<TimeSpan>? postMutationVerificationLookupDelays = null)
    {
        _logger = logger;
        _options = options;
        _graph = graph;
        _observabilityTokenProvider = observabilityTokenProvider;
        _federatedCredentialVerificationLookupDelays =
            federatedCredentialVerificationLookupDelays?.ToArray()
            ?? FederatedCredentialVerificationLookupDelays;
        _postMutationVerificationLookupDelays =
            postMutationVerificationLookupDelays?.ToArray()
            ?? PostMutationVerificationLookupDelays;
    }

    public async Task<Agent365ProvisioningStepResult> ExecuteStepAsync(
        Agent365ProvisioningStepRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var context = ValidatePreflight(request);

        _logger.LogInformation(
            "Executing real provisioning step {StepType} for agent {AgentRegistrationId}",
            request.StepType,
            request.Agent.AgentRegistrationId);

        try
        {
            return request.StepType switch
            {
                ProvisioningStepType.ResolveBlueprint =>
                    await ResolveBlueprintAsync(request, context, cancellationToken),
                ProvisioningStepType.EnsureBlueprintPrincipal =>
                    await EnsureBlueprintPrincipalAsync(request, context, cancellationToken),
                ProvisioningStepType.ConfigureGatewayFederation =>
                    await ConfigureGatewayFederationAsync(request, context, cancellationToken),
                ProvisioningStepType.CreateAgentIdentity =>
                    await CreateAgentIdentityAsync(request, context, cancellationToken),
                ProvisioningStepType.AssignAgent365Access =>
                    await AssignAgent365AccessAsync(request, cancellationToken),
                ProvisioningStepType.RegisterAgent =>
                    throw Failure(
                        ErrorCodes.AGENT365_REGISTRY_ACTION_REQUIRED,
                        "Workflow v3 requires the signed-in administrator to complete Agent 365 Registry creation.",
                        requiresManualIntervention: true),
                ProvisioningStepType.VerifyAgent365Connection =>
                    await VerifyAgent365ConnectionAsync(request, context, cancellationToken),
                _ => throw Failure(
                    ErrorCodes.PROVISIONING_STEP_NOT_IMPLEMENTED,
                    "The selected provisioning step isn't supported.")
            };
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Agent365ProvisioningException exception)
        {
            throw NormalizeDependencyFailure(exception);
        }
    }

    private async Task<Agent365ProvisioningStepResult> AssignAgent365AccessAsync(
        Agent365ProvisioningStepRequest request,
        CancellationToken cancellationToken)
    {
        var state = request.State;
        var agentIdentityObjectId = RequiredStateGuid(
            state.AgentIdentityObjectId,
            "The Agent Identity ID is required before assigning Agent 365 access.");
        var observabilityApplicationClientId = RequiredOptionGuid(
            _options.ObservabilityApplicationClientId);
        var observabilityAssignmentId = await EnsureApplicationRoleAssignmentAsync(
            agentIdentityObjectId,
            observabilityApplicationClientId,
            _options.ObservabilityAppRoleValue,
            state.ObservabilityAppRoleAssignmentId,
            "Agent 365 observability",
            cancellationToken);

        return Complete(
            request,
            state with { ObservabilityAppRoleAssignmentId = observabilityAssignmentId },
            "AgentIdentityObservabilityAppRoleVerified");
    }

    private async Task<string> EnsureApplicationRoleAssignmentAsync(
        Guid principalId,
        Guid resourceApplicationClientId,
        string roleValue,
        string? persistedAssignmentId,
        string resourceName,
        CancellationToken cancellationToken)
    {
        var resourcePrincipal = await _graph.GetServicePrincipalByAppIdAsync(
            resourceApplicationClientId.ToString("D"),
            cancellationToken)
            ?? throw Failure(
                ErrorCodes.PROVISIONING_CONFIGURATION_INVALID,
                $"The configured {resourceName} service principal wasn't found.");
        var resourceId = RequiredDependencyGuid(
            resourcePrincipal.Id,
            $"The {resourceName} service principal returned an invalid object ID.");

        var matchingRoles = (resourcePrincipal.AppRoles ?? [])
            .Where(role =>
                role.Id is not null &&
                role.Id != Guid.Empty &&
                role.IsEnabled == true &&
                string.Equals(role.Value, roleValue, StringComparison.Ordinal) &&
                (role.AllowedMemberTypes ?? []).Contains("Application", StringComparer.Ordinal))
            .ToList();
        if (matchingRoles.Count != 1)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_CONFIGURATION_INVALID,
                $"The {resourceName} application role couldn't be resolved uniquely.");
        }

        var appRoleId = matchingRoles[0].Id!.Value;
        if (!string.IsNullOrWhiteSpace(persistedAssignmentId))
        {
            var persistedAssignment = await VerifyPersistedApplicationRoleAssignmentAfterPropagationAsync(
                principalId,
                resourceId,
                appRoleId,
                persistedAssignmentId,
                resourceName,
                cancellationToken);
            return persistedAssignment.Id!;
        }

        var assignments = await ListAppRoleAssignmentsAfterPrincipalPropagationAsync(
            principalId,
            cancellationToken);
        var matches = FindMatchingAssignments(assignments, principalId, resourceId, appRoleId);
        if (matches.Count == 0)
        {
            GraphAppRoleAssignment? assignment;
            try
            {
                assignment = await CreateAppRoleAssignmentAfterPrincipalPropagationAsync(
                    principalId,
                    resourceId,
                    appRoleId,
                    cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw PostMutationCancellation(resourceName);
            }
            catch (Agent365ProvisioningException exception)
            {
                if (!CanRecoverCreate(exception))
                    throw;

                assignment = null;
            }

            string? createdAssignmentId = null;
            if (assignment is not null)
            {
                ValidateAssignment(assignment, principalId, resourceId, appRoleId);
                createdAssignmentId = RequiredDependencyIdentifier(
                    assignment.Id,
                    $"The created {resourceName} app-role assignment returned an invalid ID.");
            }

            GraphAppRoleAssignment verifiedAssignment;
            try
            {
                verifiedAssignment = await VerifyApplicationRoleAssignmentAfterMutationAsync(
                    principalId,
                    resourceId,
                    appRoleId,
                    createdAssignmentId,
                    resourceName,
                    cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw PostMutationCancellation(resourceName);
            }

            matches = [verifiedAssignment];
        }

        if (matches.Count != 1 || string.IsNullOrWhiteSpace(matches[0].Id))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                $"The {resourceName} app-role assignment couldn't be verified uniquely.",
                requiresManualIntervention: true);
        }

        return matches[0].Id!;
    }

    private async Task<GraphAppRoleAssignment>
        VerifyPersistedApplicationRoleAssignmentAfterPropagationAsync(
            Guid principalId,
            Guid resourceId,
            Guid appRoleId,
            string persistedAssignmentId,
            string resourceName,
            CancellationToken cancellationToken)
    {
        foreach (var delay in _postMutationVerificationLookupDelays)
        {
            if (delay > TimeSpan.Zero)
                await Task.Delay(delay, cancellationToken);

            IReadOnlyList<GraphAppRoleAssignment> assignments;
            try
            {
                assignments = await _graph.ListAppRoleAssignmentsAsync(
                    principalId.ToString("D"),
                    cancellationToken);
            }
            catch (Agent365ProvisioningException exception)
                when (IsRetryableVerificationRead(exception))
            {
                continue;
            }

            var matches = FindMatchingAssignments(assignments, principalId, resourceId, appRoleId);
            if (matches.Count > 1)
            {
                throw Failure(
                    ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                    $"The persisted {resourceName} app-role assignment couldn't be verified uniquely.",
                    requiresManualIntervention: true);
            }

            var knownIdMatches = assignments
                .Where(assignment => string.Equals(
                    assignment.Id,
                    persistedAssignmentId,
                    StringComparison.Ordinal))
                .ToList();
            if (knownIdMatches.Count > 1)
            {
                throw Failure(
                    ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                    $"The persisted {resourceName} app-role assignment ID wasn't unique.",
                    requiresManualIntervention: true);
            }

            if (knownIdMatches.Count == 1)
            {
                ValidateAssignment(knownIdMatches[0], principalId, resourceId, appRoleId);
                if (matches.Count != 1)
                {
                    throw Failure(
                        ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                        $"The persisted {resourceName} app-role assignment couldn't be verified uniquely.",
                        requiresManualIntervention: true);
                }

                return knownIdMatches[0];
            }

            if (matches.Count == 1)
            {
                throw Failure(
                    ErrorCodes.PROVISIONING_STATE_INVALID,
                    $"The persisted {resourceName} app-role assignment ID doesn't match the verified assignment.",
                    requiresManualIntervention: true);
            }

            // Microsoft Graph can return a successful but stale relationship list
            // immediately after an app-role assignment is created. Retry only the
            // bounded exact read; never repeat the assignment POST.
        }

        throw Failure(
            ErrorCodes.PROVISIONING_STATE_INVALID,
            $"The persisted {resourceName} app-role assignment couldn't be verified after bounded read-only reconciliation.",
            requiresManualIntervention: true);
    }

    private async Task<GraphAppRoleAssignment> CreateAppRoleAssignmentAfterPrincipalPropagationAsync(
        Guid principalId,
        Guid resourceId,
        Guid appRoleId,
        CancellationToken cancellationToken)
    {
        Agent365ProvisioningException? lastNotFound = null;

        foreach (var delay in _postMutationVerificationLookupDelays)
        {
            if (delay > TimeSpan.Zero)
                await Task.Delay(delay, cancellationToken);

            try
            {
                return await _graph.CreateAppRoleAssignmentAsync(
                    principalId,
                    resourceId,
                    appRoleId,
                    cancellationToken);
            }
            catch (Agent365ProvisioningException exception)
                when (string.Equals(
                    exception.ErrorCode,
                    "MICROSOFT_GRAPH_RESOURCE_NOT_FOUND",
                    StringComparison.Ordinal))
            {
                // Graph can expose a newly created Agent Identity through GET
                // before the relationship-write replica accepts it. An explicit
                // HTTP 404 proves that this POST did not create an assignment, so
                // retrying the same exact relationship is safe. Any ambiguous
                // mutation outcome is still handled by the caller without reposting.
                lastNotFound = exception;
            }
        }

        throw lastNotFound ?? Failure(
            ErrorCodes.PROVISIONING_CONFIGURATION_INVALID,
            "The Agent Identity wasn't available for app-role assignment.");
    }

    private async Task<Agent365ProvisioningStepResult> ResolveBlueprintAsync(
        Agent365ProvisioningStepRequest request,
        ProvisioningContext context,
        CancellationToken cancellationToken)
    {
        var state = request.State;
        GraphApplication? blueprint;
        var useExisting = string.Equals(
            request.Agent.BlueprintSelectionMode,
            "UseExisting",
            StringComparison.Ordinal);

        if (HasEither(state.BlueprintObjectId, state.BlueprintClientId))
        {
            RequirePair(
                state.BlueprintObjectId,
                state.BlueprintClientId,
                "The blueprint identifiers are incomplete.");
            blueprint = await _graph.GetBlueprintAsync(
                state.BlueprintObjectId!,
                cancellationToken);
        }
        else if (useExisting)
        {
            var requestedObjectId = RequiredStateGuid(
                request.Agent.RequestedBlueprintObjectId,
                "An existing Agent Identity blueprint object ID is required.");
            blueprint = await _graph.GetBlueprintAsync(
                requestedObjectId.ToString("D"),
                cancellationToken);
        }
        else
        {
            blueprint = await _graph.FindBlueprintAsync(
                context.BlueprintDisplayName,
                cancellationToken);

            if (blueprint is null)
            {
                try
                {
                    blueprint = await _graph.CreateBlueprintAsync(
                        context.BlueprintDisplayName,
                        $"Reusable Agent Identity blueprint for {request.Agent.Environment} agents registered through A365 Gateway.",
                        context.OwnerObjectId,
                        context.ManagerApplicationIds,
                        context.BlueprintKey,
                        cancellationToken);
                }
                catch (Agent365ProvisioningException exception)
                {
                    blueprint = await RecoverLookupAsync(
                        () => _graph.FindBlueprintAsync(
                            context.BlueprintDisplayName,
                            cancellationToken),
                        cancellationToken);

                    if (blueprint is null)
                    {
                        if (CanRecoverCreate(exception))
                            throw AmbiguousCreate();

                        throw;
                    }
                }
            }
        }

        var (objectId, clientId) = useExisting
            ? ValidateSelectedBlueprint(
                blueprint,
                request.Agent.RequestedBlueprintObjectId,
                state.BlueprintObjectId,
                state.BlueprintClientId)
            : ValidateGatewayBlueprint(
                blueprint,
                context.BlueprintDisplayName,
                context.BlueprintKey,
                state.BlueprintObjectId,
                state.BlueprintClientId);
        var verified = await VerifyBlueprintAfterMutationAsync(
            objectId,
            cancellationToken)
            ?? throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The agent identity blueprint couldn't be verified.",
                requiresManualIntervention: true);
        if (useExisting)
        {
            ValidateSelectedBlueprint(
                verified,
                request.Agent.RequestedBlueprintObjectId,
                objectId,
                clientId);
            VerifyManagerApplications(verified, context.ManagerApplicationIds, allowAdditional: true);
        }
        else
        {
            ValidateGatewayBlueprint(
                verified,
                context.BlueprintDisplayName,
                context.BlueprintKey,
                objectId,
                clientId);
            VerifyManagerApplications(verified, context.ManagerApplicationIds, allowAdditional: false);
        }

        if (!await VerifyBlueprintRelationshipsAfterMutationAsync(
                objectId,
                context.OwnerObjectId,
                requireOwnerAndSponsor: !useExisting,
                cancellationToken))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The blueprint owner and sponsor relationships couldn't be verified.",
                requiresManualIntervention: true);
        }

        return Complete(
            request,
            state with
            {
                BlueprintObjectId = objectId,
                BlueprintClientId = clientId
            },
            useExisting
                ? "ExistingAgentIdentityBlueprintVerified"
                : "GatewayAgentIdentityBlueprintVerified");
    }

    private async Task<GraphApplication?> VerifyBlueprintAfterMutationAsync(
        string objectId,
        CancellationToken cancellationToken)
    {
        foreach (var delay in _postMutationVerificationLookupDelays)
        {
            if (delay > TimeSpan.Zero)
                await Task.Delay(delay, cancellationToken);

            try
            {
                var blueprint = await _graph.GetBlueprintAsync(
                    objectId,
                    cancellationToken);
                if (blueprint is not null)
                    return blueprint;
            }
            catch (Agent365ProvisioningException exception)
                when (IsRetryableVerificationRead(exception))
            {
                // Microsoft Graph can return a short-lived 404 after a successful
                // typed-blueprint create. Re-read the exact returned object ID only.
            }
        }

        return null;
    }

    private async Task<bool> VerifyBlueprintRelationshipsAfterMutationAsync(
        string objectId,
        Guid ownerObjectId,
        bool requireOwnerAndSponsor,
        CancellationToken cancellationToken)
    {
        foreach (var delay in _postMutationVerificationLookupDelays)
        {
            if (delay > TimeSpan.Zero)
                await Task.Delay(delay, cancellationToken);

            try
            {
                var owners = await _graph.ListBlueprintOwnerIdsAsync(
                    objectId,
                    cancellationToken);
                var sponsors = await _graph.ListBlueprintSponsorIdsAsync(
                    objectId,
                    cancellationToken);
                if (sponsors.Count > 0 &&
                    (!requireOwnerAndSponsor ||
                     (owners.Contains(ownerObjectId) && sponsors.Contains(ownerObjectId))))
                {
                    return true;
                }
            }
            catch (Agent365ProvisioningException exception)
                when (IsRetryableVerificationRead(exception))
            {
                // Retry the bounded exact relationship reads without reposting.
            }
        }

        return false;
    }

    private async Task<Agent365ProvisioningStepResult> ConfigureGatewayFederationAsync(
        Agent365ProvisioningStepRequest request,
        ProvisioningContext context,
        CancellationToken cancellationToken)
    {
        var state = request.State;
        var blueprintObjectId = RequiredStateGuid(
            state.BlueprintObjectId,
            "The blueprint object ID is required before configuring federation.");
        RequiredStateGuid(
            state.BlueprintClientId,
            "The blueprint client ID is required before configuring federation.");

        var gatewayManagedIdentityPrincipalId =
            await _graph.GetCallerPrincipalObjectIdAsync(cancellationToken);
        if (gatewayManagedIdentityPrincipalId != context.GatewayManagedIdentityPrincipalId)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_CONFIGURATION_INVALID,
                "The Microsoft Graph caller doesn't match the configured Gateway managed identity.");
        }

        if (!MatchesOptionalGuid(
                state.GatewayManagedIdentityPrincipalId,
                gatewayManagedIdentityPrincipalId))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The persisted Gateway managed identity doesn't match the verified Microsoft Graph caller.",
                requiresManualIntervention: true);
        }

        var gatewayCredentialId = await EnsureFederatedCredentialAsync(
            blueprintObjectId,
            "a365-gateway",
            gatewayManagedIdentityPrincipalId,
            context.TenantId,
            cancellationToken);

        return Complete(
            request,
            state with
            {
                GatewayManagedIdentityPrincipalId = gatewayManagedIdentityPrincipalId.ToString("D"),
                GatewayFederatedCredentialId = gatewayCredentialId
            },
            "BlueprintGatewayFederationVerified");
    }

    private async Task<string> EnsureFederatedCredentialAsync(
        Guid blueprintObjectId,
        string namePrefix,
        Guid managedIdentityPrincipalId,
        Guid tenantId,
        CancellationToken cancellationToken)
    {
        var name = $"{namePrefix}-{managedIdentityPrincipalId:N}";
        var issuer = $"https://login.microsoftonline.com/{tenantId:D}/v2.0";
        var subject = managedIdentityPrincipalId.ToString("D");
        var credentials = await _graph.ListFederatedIdentityCredentialsAsync(
            blueprintObjectId.ToString("D"),
            cancellationToken);
        var named = credentials
            .Where(candidate => string.Equals(candidate.Name, name, StringComparison.Ordinal))
            .ToList();
        string? createdCredentialId = null;

        if (named.Count == 0)
        {
            try
            {
                var created = await _graph.CreateFederatedIdentityCredentialAsync(
                    blueprintObjectId.ToString("D"),
                    name,
                    issuer,
                    subject,
                    cancellationToken);
                ValidateFederatedCredential(created, name, issuer, subject);
                createdCredentialId = RequiredDependencyIdentifier(
                    created.Id,
                    "The created blueprint federated credential returned an invalid ID.");
            }
            catch (Agent365ProvisioningException exception)
            {
                GraphFederatedIdentityCredential? recovered = null;
                foreach (var delay in RecoveryLookupDelays)
                {
                    if (delay > TimeSpan.Zero)
                        await Task.Delay(delay, cancellationToken);

                    credentials = await _graph.ListFederatedIdentityCredentialsAsync(
                        blueprintObjectId.ToString("D"),
                        cancellationToken);
                    var recoveredCandidates = credentials
                        .Where(candidate =>
                            string.Equals(candidate.Name, name, StringComparison.Ordinal))
                        .ToList();
                    if (recoveredCandidates.Count > 1)
                    {
                        throw Failure(
                            ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                            "The blueprint federated credential couldn't be recovered uniquely.",
                            requiresManualIntervention: true);
                    }

                    recovered = recoveredCandidates.Count == 1
                        ? recoveredCandidates[0]
                        : null;
                    if (recovered is not null)
                        break;
                }

                if (recovered is null)
                {
                    if (CanRecoverCreate(exception))
                        throw AmbiguousCreate();

                    throw;
                }
            }

            foreach (var delay in _federatedCredentialVerificationLookupDelays)
            {
                if (delay > TimeSpan.Zero)
                    await Task.Delay(delay, cancellationToken);

                credentials = await _graph.ListFederatedIdentityCredentialsAsync(
                    blueprintObjectId.ToString("D"),
                    cancellationToken);
                named = credentials
                    .Where(candidate =>
                        string.Equals(candidate.Name, name, StringComparison.Ordinal))
                    .ToList();
                if (named.Count > 0)
                    break;
            }
        }

        if (named.Count != 1)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                "The blueprint federated credential couldn't be verified uniquely.",
                requiresManualIntervention: true);
        }

        ValidateFederatedCredential(named[0], name, issuer, subject);
        var verifiedCredentialId = RequiredDependencyIdentifier(
            named[0].Id,
            "The blueprint federated credential returned an invalid ID.");
        if (createdCredentialId is not null &&
            !string.Equals(createdCredentialId, verifiedCredentialId, StringComparison.Ordinal))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                "The created blueprint federated credential couldn't be matched to its verified ID.",
                requiresManualIntervention: true);
        }

        return verifiedCredentialId;
    }

    private static void ValidateFederatedCredential(
        GraphFederatedIdentityCredential credential,
        string expectedName,
        string expectedIssuer,
        string expectedSubject)
    {
        if (string.IsNullOrWhiteSpace(credential.Id) ||
            !string.Equals(credential.Name, expectedName, StringComparison.Ordinal) ||
            !string.Equals(credential.Issuer, expectedIssuer, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(credential.Subject, expectedSubject, StringComparison.OrdinalIgnoreCase) ||
            credential.Audiences is null ||
            credential.Audiences.Count != 1 ||
            !string.Equals(
                credential.Audiences[0],
                "api://AzureADTokenExchange",
                StringComparison.Ordinal))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The blueprint federated credential doesn't match the managed identity binding.",
                requiresManualIntervention: true);
        }
    }

    private async Task<Agent365ProvisioningStepResult> EnsureBlueprintPrincipalAsync(
        Agent365ProvisioningStepRequest request,
        ProvisioningContext context,
        CancellationToken cancellationToken)
    {
        var state = request.State;
        var blueprintClientId = RequiredStateGuid(
            state.BlueprintClientId,
            "The blueprint client ID is required before creating its principal.");
        GraphServicePrincipal? principal;

        if (!string.IsNullOrWhiteSpace(state.BlueprintPrincipalObjectId))
        {
            principal = await _graph.GetBlueprintPrincipalAsync(
                state.BlueprintPrincipalObjectId,
                cancellationToken);
        }
        else
        {
            principal = await _graph.GetBlueprintPrincipalByAppIdAsync(
                blueprintClientId.ToString("D"),
                cancellationToken);

            if (principal is null)
            {
                try
                {
                    principal = await _graph.CreateBlueprintPrincipalAsync(
                        blueprintClientId.ToString("D"),
                        cancellationToken);
                }
                catch (Agent365ProvisioningException exception)
                {
                    principal = await RecoverLookupAsync(
                        () => _graph.GetBlueprintPrincipalByAppIdAsync(
                            blueprintClientId.ToString("D"),
                            cancellationToken),
                        cancellationToken);

                    if (principal is null)
                    {
                        if (CanRecoverCreate(exception))
                            throw AmbiguousCreate();

                        throw;
                    }
                }
            }
        }

        var principalObjectId = ValidateServicePrincipal(
            principal,
            blueprintClientId,
            state.BlueprintPrincipalObjectId);
        await VerifyBlueprintPrincipalAsync(
            principalObjectId,
            blueprintClientId,
            cancellationToken);

        return Complete(
            request,
            state with { BlueprintPrincipalObjectId = principalObjectId },
            "AgentIdentityBlueprintPrincipalVerified");
    }

    private async Task<Agent365ProvisioningStepResult> CreateAgentIdentityAsync(
        Agent365ProvisioningStepRequest request,
        ProvisioningContext context,
        CancellationToken cancellationToken)
    {
        var state = request.State;
        var blueprintClientId = RequiredStateGuid(
            state.BlueprintClientId,
            "The blueprint client ID is required before creating an Agent Identity.");
        RequiredStateGuid(
            state.BlueprintPrincipalObjectId,
            "The blueprint principal ID is required before creating an Agent Identity.");
        GraphServicePrincipal? identity;
        var verifiedAfterMutation = false;

        if (!string.IsNullOrWhiteSpace(state.AgentIdentityObjectId))
        {
            identity = await _graph.GetAgentIdentityAsync(
                state.AgentIdentityObjectId,
                cancellationToken);
        }
        else
        {
            identity = await _graph.FindAgentIdentityAsync(
                context.AgentIdentityDisplayName,
                blueprintClientId.ToString("D"),
                cancellationToken);

            if (identity is null)
            {
                GraphServicePrincipal? createdIdentity;
                string? createdObjectId = null;
                try
                {
                    createdIdentity = await _graph.CreateAgentIdentityAsync(
                        context.AgentIdentityDisplayName,
                        blueprintClientId.ToString("D"),
                        context.OwnerObjectId,
                        cancellationToken);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw PostMutationCancellation("Agent Identity");
                }
                catch (Agent365ProvisioningException exception)
                {
                    if (!CanRecoverCreate(exception))
                        throw;

                    createdIdentity = null;
                }

                if (createdIdentity is not null)
                {
                    createdObjectId = RequiredDependencyGuid(
                        createdIdentity.Id,
                        "The created Agent Identity returned an invalid object ID.")
                        .ToString("D");
                    ValidateAgentIdentity(
                        createdIdentity,
                        blueprintClientId,
                        context.AgentIdentityDisplayName,
                        createdObjectId,
                        expectedClientId: null);
                }

                try
                {
                    identity = await VerifyAgentIdentityAfterMutationAsync(
                        createdObjectId,
                        context.AgentIdentityDisplayName,
                        blueprintClientId,
                        context.OwnerObjectId,
                        cancellationToken);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw PostMutationCancellation("Agent Identity");
                }

                verifiedAfterMutation = true;
            }
        }

        var (identityObjectId, identityClientId) = ValidateAgentIdentity(
            identity,
            blueprintClientId,
            context.AgentIdentityDisplayName,
            state.AgentIdentityObjectId,
            state.AgentIdentityClientId);
        if (!verifiedAfterMutation)
        {
            identity = await _graph.GetAgentIdentityAsync(
                identityObjectId,
                cancellationToken)
                ?? throw Failure(
                    ErrorCodes.PROVISIONING_STATE_INVALID,
                    "The Agent Identity couldn't be verified.",
                    requiresManualIntervention: true);
            ValidateAgentIdentity(
                identity,
                blueprintClientId,
                context.AgentIdentityDisplayName,
                identityObjectId,
                identityClientId);
        }

        if (!HasSponsor(identity!, context.OwnerObjectId))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The Agent Identity sponsor relationship couldn't be verified.",
                requiresManualIntervention: true);
        }

        return Complete(
            request,
            state with
            {
                AgentIdentityObjectId = identityObjectId,
                AgentIdentityClientId = identityClientId
            },
            "AgentIdentityVerified");
    }

    private async Task<GraphServicePrincipal> VerifyAgentIdentityAfterMutationAsync(
        string? createdObjectId,
        string expectedDisplayName,
        Guid blueprintClientId,
        Guid ownerObjectId,
        CancellationToken cancellationToken)
    {
        foreach (var delay in _postMutationVerificationLookupDelays)
        {
            if (delay > TimeSpan.Zero)
                await Task.Delay(delay, cancellationToken);

            string? candidateObjectId = createdObjectId;
            try
            {
                if (string.IsNullOrWhiteSpace(candidateObjectId))
                {
                    var discovered = await _graph.FindAgentIdentityAsync(
                        expectedDisplayName,
                        blueprintClientId.ToString("D"),
                        cancellationToken);
                    if (discovered is null)
                        continue;

                    var discoveredIdentity = ValidateAgentIdentity(
                        discovered,
                        blueprintClientId,
                        expectedDisplayName,
                        expectedObjectId: null,
                        expectedClientId: null);
                    candidateObjectId = discoveredIdentity.ObjectId;
                }

                var candidate = await _graph.GetAgentIdentityAsync(
                    candidateObjectId,
                    cancellationToken);
                if (candidate is null)
                    continue;

                ValidateAgentIdentity(
                    candidate,
                    blueprintClientId,
                    expectedDisplayName,
                    candidateObjectId,
                    candidateObjectId);
                if (HasSponsor(candidate, ownerObjectId))
                    return candidate;
            }
            catch (Agent365ProvisioningException exception)
                when (IsRetryableVerificationRead(exception))
            {
                continue;
            }
        }

        throw Failure(
            ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
            "The created Agent Identity couldn't be verified after bounded read-only reconciliation.",
            requiresManualIntervention: true);
    }

    private async Task<Agent365ProvisioningStepResult> VerifyAgent365ConnectionAsync(
        Agent365ProvisioningStepRequest request,
        ProvisioningContext context,
        CancellationToken cancellationToken)
    {
        var state = request.State;
        var blueprintObjectId = RequiredStateGuid(
            state.BlueprintObjectId,
            "The blueprint object ID is required for the final verification.");
        var blueprintClientId = RequiredStateGuid(
            state.BlueprintClientId,
            "The blueprint client ID is required for the final verification.");
        var blueprintPrincipalObjectId = RequiredStateGuid(
            state.BlueprintPrincipalObjectId,
            "The blueprint principal object ID is required for the final verification.");
        var gatewayManagedIdentityPrincipalId = RequiredStateGuid(
            state.GatewayManagedIdentityPrincipalId,
            "The Gateway managed identity principal ID is required for the final verification.");
        if (gatewayManagedIdentityPrincipalId != context.GatewayManagedIdentityPrincipalId)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The Gateway managed identity no longer matches the trusted configuration.",
                requiresManualIntervention: true);
        }

        var agentIdentityObjectId = RequiredStateGuid(
            state.AgentIdentityObjectId,
            "The Agent Identity object ID is required for the final verification.");
        var agentIdentityClientId = RequiredStateGuid(
            state.AgentIdentityClientId,
            "The Agent Identity client ID is required for the final verification.");
        var observabilityAssignmentId = RequiredDependencyIdentifier(
            state.ObservabilityAppRoleAssignmentId,
            "The Agent 365 observability app-role assignment is required for the final verification.");
        _ = RequiredDependencyIdentifier(
            state.Agent365RegistrationId,
            "The Agent 365 registration is required for the final verification.");
        if (!string.Equals(
                state.RegistryAuthenticationMode,
                Agent365Options.DelegatedAdministratorAuthenticationMode,
                StringComparison.Ordinal))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The Agent 365 registration was not created with the required delegated administrator flow.",
                requiresManualIntervention: true);
        }

        _ = RequiredStateGuid(
            state.RegistryCreatedByObjectId,
            "The delegated Agent 365 Registry creator object ID is required for final verification.");
        if (state.Agent365RegistrationAcceptedAtUtc is null &&
            state.Agent365RegistrationVerifiedAtUtc is null)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The delegated Agent 365 Registry record has no persisted accepted-create evidence.",
                requiresManualIntervention: true);
        }

        var gatewayFederatedCredentialId = RequiredDependencyIdentifier(
            state.GatewayFederatedCredentialId,
            "The Gateway federated credential is required for the final verification.");

        var blueprint = await _graph.GetBlueprintAsync(
            blueprintObjectId.ToString("D"),
            cancellationToken)
            ?? throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The selected Agent Identity blueprint no longer exists.",
                requiresManualIntervention: true);
        if (!MatchesOptionalGuid(blueprint.AppId, blueprintClientId))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The selected Agent Identity blueprint no longer matches the persisted client ID.",
                requiresManualIntervention: true);
        }

        var blueprintPrincipal = await _graph.GetBlueprintPrincipalAsync(
            blueprintPrincipalObjectId.ToString("D"),
            cancellationToken);
        ValidateServicePrincipal(
            blueprintPrincipal,
            blueprintClientId,
            blueprintPrincipalObjectId.ToString("D"));

        var identity = await _graph.GetAgentIdentityAsync(
            agentIdentityObjectId.ToString("D"),
            cancellationToken);
        ValidateAgentIdentity(
            identity,
            blueprintClientId,
            context.AgentIdentityDisplayName,
            agentIdentityObjectId.ToString("D"),
            agentIdentityClientId.ToString("D"));

        await EnsureApplicationRoleAssignmentAsync(
            agentIdentityObjectId,
            RequiredOptionGuid(_options.ObservabilityApplicationClientId),
            _options.ObservabilityAppRoleValue,
            observabilityAssignmentId,
            "Agent 365 observability",
            cancellationToken);

        var credentials = await _graph.ListFederatedIdentityCredentialsAsync(
            blueprintObjectId.ToString("D"),
            cancellationToken);
        var graphCallerPrincipalId =
            await _graph.GetCallerPrincipalObjectIdAsync(cancellationToken);
        if (graphCallerPrincipalId != gatewayManagedIdentityPrincipalId)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The Microsoft Graph caller no longer matches the persisted Gateway managed identity.",
                requiresManualIntervention: true);
        }

        var gatewayCredentials = credentials
            .Where(credential => string.Equals(
                credential.Id,
                gatewayFederatedCredentialId,
                StringComparison.OrdinalIgnoreCase))
            .ToList();
        if (gatewayCredentials.Count != 1)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The Blueprint Gateway federation couldn't be reverified uniquely.",
                requiresManualIntervention: true);
        }

        var issuer = $"https://login.microsoftonline.com/{context.TenantId:D}/v2.0";
        ValidateFederatedCredential(
            gatewayCredentials[0],
            $"a365-gateway-{gatewayManagedIdentityPrincipalId:N}",
            issuer,
            gatewayManagedIdentityPrincipalId.ToString("D"));

        if (_observabilityTokenProvider is null)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_CONFIGURATION_INVALID,
                "The Agent 365 observability token proof isn't configured.",
                requiresManualIntervention: true);
        }

        await VerifyObservabilityTokenAfterPropagationAsync(
            agentIdentityClientId,
            blueprintClientId,
            context.TenantId,
            _observabilityTokenProvider,
            cancellationToken);

        return Complete(
            request,
            state with { Agent365ConnectionVerifiedAtUtc = DateTimeOffset.UtcNow },
            "Agent365ObservabilityTokenAndConnectionVerified");
    }

    private async Task VerifyObservabilityTokenAfterPropagationAsync(
        Guid agentIdentityClientId,
        Guid blueprintClientId,
        Guid tenantId,
        IAgent365ObservabilityTokenProvider tokenProvider,
        CancellationToken cancellationToken)
    {
        var missingRole = false;
        foreach (var delay in _postMutationVerificationLookupDelays)
        {
            if (delay > TimeSpan.Zero)
                await Task.Delay(delay, cancellationToken);

            try
            {
                var token = await tokenProvider.GetTokenAsync(
                    agentIdentityClientId.ToString("D"),
                    blueprintClientId.ToString("D"),
                    tenantId.ToString("D"),
                    cancellationToken);
                if (string.IsNullOrWhiteSpace(token.Token) ||
                    token.ExpiresOn <= DateTimeOffset.UtcNow)
                {
                    throw Failure(
                        ErrorCodes.PROVISIONING_CONFIGURATION_INVALID,
                        "The Agent 365 observability token proof returned an invalid token.",
                        requiresManualIntervention: true);
                }

                return;
            }
            catch (Agent365ObservabilityTransientException)
            {
                missingRole = false;
            }
            catch (Agent365ObservabilityConfigurationException exception)
                when (string.Equals(exception.Code, "MissingOtelWriteRole", StringComparison.Ordinal))
            {
                missingRole = true;
            }
            catch (Agent365ObservabilityConfigurationException exception)
            {
                _logger.LogWarning(
                    "Agent 365 observability token proof failed with safe diagnostic code {TokenProofCode}",
                    exception.Code);
                throw Failure(
                    ErrorCodes.PROVISIONING_CONFIGURATION_INVALID,
                    "The Agent 365 observability token proof did not match the expected identity.",
                    requiresManualIntervention: true);
            }
        }

        throw Failure(
            ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE,
            missingRole
                ? "The Agent 365 observability role is not visible in the Agent Identity token yet."
                : "The Agent 365 observability token proof is temporarily unavailable.",
            isTransient: true);
    }

    private ProvisioningContext ValidatePreflight(Agent365ProvisioningStepRequest request)
    {
        if (request.Agent is null || request.State is null ||
            request.Agent.AgentRegistrationId == Guid.Empty ||
            string.IsNullOrWhiteSpace(request.Agent.Name) ||
            string.IsNullOrWhiteSpace(request.Agent.ExternalAgentId))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_CONFIGURATION_INVALID,
                "The provisioning request is missing required values.");
        }

        if (!string.Equals(request.Agent.Environment, "Development", StringComparison.OrdinalIgnoreCase))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_PREVIEW_DISABLED,
                "DirectRegistryPreview is restricted to the Development environment.");
        }

        var managerApplicationIds = ParseManagerApplicationIds();

        if (managerApplicationIds.Count == 0)
        {
            throw Failure(
                ErrorCodes.AGENT365_PLATFORM_ACCEPTANCE_UNCONFIGURED,
                "Agent 365 platform manager applications aren't configured.");
        }

        var tenantId = RequiredOptionGuid(_options.TenantId);
        var ownerObjectId = RequiredStateGuid(
            request.Agent.OwnerObjectId,
            "The accountable owner object ID is invalid.");
        RequiredOptionGuid(_options.ObservabilityApplicationClientId);
        var gatewayManagedIdentityPrincipalId = RequiredOptionGuid(
            _options.ProvisioningManagedIdentityPrincipalId);
        var useExistingBlueprint = string.Equals(
            request.Agent.BlueprintSelectionMode,
            "UseExisting",
            StringComparison.Ordinal);
        var createNewBlueprint = string.Equals(
            request.Agent.BlueprintSelectionMode,
            "CreateNew",
            StringComparison.Ordinal);
        if ((!useExistingBlueprint && !createNewBlueprint) ||
            (useExistingBlueprint &&
             (!Guid.TryParse(request.Agent.RequestedBlueprintObjectId, out var selectedBlueprintId) ||
              selectedBlueprintId == Guid.Empty)) ||
            (createNewBlueprint &&
             string.IsNullOrWhiteSpace(request.Agent.RequestedBlueprintDisplayName)))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_CONFIGURATION_INVALID,
                "The Agent Identity blueprint selection is invalid.");
        }

        var blueprintDisplayName = createNewBlueprint
            ? SanitizeRequired(request.Agent.RequestedBlueprintDisplayName!, 256)
            : "Selected Agent Identity blueprint";
        var blueprintKey = createNewBlueprint
            ? BuildBlueprintKey(request.Agent.Environment, blueprintDisplayName)
            : "selected";

        if ((!string.IsNullOrWhiteSpace(_options.ProvisioningManagedIdentityClientId) &&
             (!Guid.TryParse(_options.ProvisioningManagedIdentityClientId, out var managedIdentityClientId) ||
              managedIdentityClientId == Guid.Empty)) ||
            _options.ProvisioningHttpTimeoutSeconds is < 1 or > 120 ||
            string.IsNullOrWhiteSpace(_options.ObservabilityAppRoleValue))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_CONFIGURATION_INVALID,
                "The Agent 365 provisioning options aren't valid.");
        }

        return new ProvisioningContext(
            tenantId,
            ownerObjectId,
            managerApplicationIds,
            gatewayManagedIdentityPrincipalId,
            blueprintDisplayName,
            blueprintKey,
            BuildDisplayName("Identity", request.Agent.Name, request.Agent.AgentRegistrationId));
    }

    private IReadOnlyList<Guid> ParseManagerApplicationIds()
    {
        if (_options.ManagerApplicationIds is null || _options.ManagerApplicationIds.Length == 0)
            return [];

        if (_options.ManagerApplicationIds.Length > 10)
        {
            throw Failure(
                ErrorCodes.AGENT365_PLATFORM_ACCEPTANCE_UNCONFIGURED,
                "Too many Agent 365 platform manager applications are configured.");
        }

        var values = new HashSet<Guid>();
        foreach (var value in _options.ManagerApplicationIds)
        {
            if (!Guid.TryParse(value, out var parsed) || parsed == Guid.Empty)
            {
                throw Failure(
                    ErrorCodes.AGENT365_PLATFORM_ACCEPTANCE_UNCONFIGURED,
                    "Agent 365 platform manager applications aren't configured correctly.");
            }

            values.Add(parsed);
        }

        return values.ToList();
    }

    private static (string ObjectId, string ClientId) ValidateSelectedBlueprint(
        GraphApplication? blueprint,
        string? requestedObjectId,
        string? expectedObjectId,
        string? expectedClientId)
    {
        if (blueprint is null ||
            !Guid.TryParse(blueprint.Id, out var objectId) || objectId == Guid.Empty ||
            !Guid.TryParse(blueprint.AppId, out var clientId) || clientId == Guid.Empty ||
            !MatchesOptionalGuid(requestedObjectId, objectId) ||
            !MatchesOptionalGuid(expectedObjectId, objectId) ||
            !MatchesOptionalGuid(expectedClientId, clientId))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The selected Agent Identity blueprint couldn't be verified.",
                requiresManualIntervention: true);
        }

        return (objectId.ToString("D"), clientId.ToString("D"));
    }

    private static (string ObjectId, string ClientId) ValidateGatewayBlueprint(
        GraphApplication? blueprint,
        string expectedDisplayName,
        string blueprintKey,
        string? expectedObjectId,
        string? expectedClientId)
    {
        if (blueprint is null ||
            !Guid.TryParse(blueprint.Id, out var objectId) || objectId == Guid.Empty ||
            !Guid.TryParse(blueprint.AppId, out var clientId) || clientId == Guid.Empty ||
            !string.Equals(blueprint.DisplayName, expectedDisplayName, StringComparison.Ordinal) ||
            !(blueprint.Tags ?? []).Contains("A365CustomGateway", StringComparer.Ordinal) ||
            !(blueprint.Tags ?? []).Contains($"GatewayBlueprint:{blueprintKey}", StringComparer.Ordinal) ||
            !MatchesOptionalGuid(expectedObjectId, objectId) ||
            !MatchesOptionalGuid(expectedClientId, clientId))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                "The Gateway-managed Agent Identity blueprint couldn't be matched uniquely.",
                requiresManualIntervention: true);
        }

        return (objectId.ToString("D"), clientId.ToString("D"));
    }

    private static string ValidateServicePrincipal(
        GraphServicePrincipal? principal,
        Guid expectedApplicationClientId,
        string? expectedObjectId)
    {
        if (principal is null ||
            !Guid.TryParse(principal.Id, out var objectId) || objectId == Guid.Empty ||
            !Guid.TryParse(principal.AppId, out var appId) ||
            appId != expectedApplicationClientId ||
            !MatchesOptionalGuid(expectedObjectId, objectId))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The Microsoft service principal couldn't be verified.",
                requiresManualIntervention: true);
        }

        return objectId.ToString("D");
    }

    private async Task VerifyBlueprintPrincipalAsync(
        string objectId,
        Guid applicationClientId,
        CancellationToken cancellationToken)
    {
        foreach (var delay in _postMutationVerificationLookupDelays)
        {
            if (delay > TimeSpan.Zero)
                await Task.Delay(delay, cancellationToken);

            try
            {
                var principal = await _graph.GetBlueprintPrincipalAsync(
                    objectId,
                    cancellationToken);
                if (principal is null)
                    continue;

                ValidateServicePrincipal(principal, applicationClientId, objectId);
                return;
            }
            catch (Agent365ProvisioningException exception)
                when (IsRetryableVerificationRead(exception))
            {
                // Microsoft Graph can return a short-lived 404 after creating
                // the typed blueprint principal. Re-read the returned ID only.
            }
        }

        throw Failure(
            ErrorCodes.PROVISIONING_STATE_INVALID,
            "The Agent Identity blueprint principal couldn't be verified.",
            requiresManualIntervention: true);
    }

    private static (string ObjectId, string ClientId) ValidateAgentIdentity(
        GraphServicePrincipal? identity,
        Guid blueprintClientId,
        string expectedDisplayName,
        string? expectedObjectId,
        string? expectedClientId)
    {
        if (identity is null ||
            !Guid.TryParse(identity.Id, out var objectId) || objectId == Guid.Empty ||
            !Guid.TryParse(identity.AppId, out var clientId) || clientId == Guid.Empty ||
            clientId != objectId ||
            !Guid.TryParse(identity.AgentIdentityBlueprintId, out var relatedBlueprintClientId) ||
            relatedBlueprintClientId != blueprintClientId ||
            !string.Equals(identity.DisplayName, expectedDisplayName, StringComparison.Ordinal) ||
            !MatchesOptionalGuid(expectedObjectId, objectId) ||
            !MatchesOptionalGuid(expectedClientId, clientId))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                "The Agent Identity couldn't be matched to its blueprint.",
                requiresManualIntervention: true);
        }

        return (objectId.ToString("D"), clientId.ToString("D"));
    }

    private static bool HasSponsor(GraphServicePrincipal identity, Guid expectedSponsorId)
    {
        return (identity.Sponsors ?? [])
            .Select(sponsor => sponsor.Id)
            .Any(id => Guid.TryParse(id, out var parsed) && parsed == expectedSponsorId);
    }

    private static void VerifyManagerApplications(
        GraphApplication blueprint,
        IReadOnlyList<Guid> expectedManagerApplicationIds,
        bool allowAdditional)
    {
        var actual = (blueprint.ManagerApplications ?? []).ToHashSet();
        var expected = expectedManagerApplicationIds.ToHashSet();
        if (allowAdditional ? !expected.IsSubsetOf(actual) : !actual.SetEquals(expected))
        {
            throw Failure(
                ErrorCodes.AGENT365_PLATFORM_ACCEPTANCE_UNCONFIGURED,
                allowAdditional
                    ? "The selected blueprint is missing a configured Agent 365 platform manager."
                    : "The blueprint manager applications don't exactly match the configured Agent 365 platform managers.",
                requiresManualIntervention: true);
        }
    }

    private static List<GraphAppRoleAssignment> FindMatchingAssignments(
        IReadOnlyList<GraphAppRoleAssignment> assignments,
        Guid principalId,
        Guid resourceId,
        Guid appRoleId)
    {
        return assignments
            .Where(assignment =>
                assignment.PrincipalId == principalId &&
                assignment.ResourceId == resourceId &&
                assignment.AppRoleId == appRoleId)
            .ToList();
    }

    private static void ValidateAssignment(
        GraphAppRoleAssignment assignment,
        Guid principalId,
        Guid resourceId,
        Guid appRoleId)
    {
        if (string.IsNullOrWhiteSpace(assignment.Id) ||
            assignment.PrincipalId != principalId ||
            assignment.ResourceId != resourceId ||
            assignment.AppRoleId != appRoleId)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                "Microsoft Graph returned an invalid app-role assignment result.",
                requiresManualIntervention: true);
        }
    }

    private async Task<GraphAppRoleAssignment> VerifyApplicationRoleAssignmentAfterMutationAsync(
        Guid principalId,
        Guid resourceId,
        Guid appRoleId,
        string? createdAssignmentId,
        string resourceName,
        CancellationToken cancellationToken)
    {
        foreach (var delay in _postMutationVerificationLookupDelays)
        {
            if (delay > TimeSpan.Zero)
                await Task.Delay(delay, cancellationToken);

            IReadOnlyList<GraphAppRoleAssignment> assignments;
            try
            {
                assignments = await _graph.ListAppRoleAssignmentsAsync(
                    principalId.ToString("D"),
                    cancellationToken);
            }
            catch (Agent365ProvisioningException exception)
                when (IsRetryableVerificationRead(exception))
            {
                continue;
            }

            var matches = FindMatchingAssignments(assignments, principalId, resourceId, appRoleId);
            if (matches.Count > 1)
            {
                throw Failure(
                    ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                    $"The {resourceName} app-role assignment couldn't be verified uniquely.",
                    requiresManualIntervention: true);
            }

            if (createdAssignmentId is null)
            {
                if (matches.Count == 1 && !string.IsNullOrWhiteSpace(matches[0].Id))
                    return matches[0];

                continue;
            }

            var knownIdMatches = assignments
                .Where(assignment => string.Equals(
                    assignment.Id,
                    createdAssignmentId,
                    StringComparison.Ordinal))
                .ToList();
            if (knownIdMatches.Count > 1)
            {
                throw Failure(
                    ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                    $"The created {resourceName} app-role assignment ID wasn't unique.",
                    requiresManualIntervention: true);
            }

            if (knownIdMatches.Count == 1)
            {
                ValidateAssignment(knownIdMatches[0], principalId, resourceId, appRoleId);
                if (matches.Count != 1)
                {
                    throw Failure(
                        ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                        $"The created {resourceName} app-role assignment couldn't be verified uniquely.",
                        requiresManualIntervention: true);
                }

                return knownIdMatches[0];
            }

            if (matches.Count == 1)
            {
                throw Failure(
                    ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                    $"The created {resourceName} app-role assignment couldn't be matched to its verified ID.",
                    requiresManualIntervention: true);
            }
        }

        throw Failure(
            ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
            $"The created {resourceName} app-role assignment couldn't be verified after bounded read-only reconciliation.",
            requiresManualIntervention: true);
    }

    private async Task<IReadOnlyList<GraphAppRoleAssignment>>
        ListAppRoleAssignmentsAfterPrincipalPropagationAsync(
            Guid principalId,
            CancellationToken cancellationToken)
    {
        Agent365ProvisioningException? lastNotFound = null;
        foreach (var delay in _postMutationVerificationLookupDelays)
        {
            if (delay > TimeSpan.Zero)
                await Task.Delay(delay, cancellationToken);

            try
            {
                return await _graph.ListAppRoleAssignmentsAsync(
                    principalId.ToString("D"),
                    cancellationToken);
            }
            catch (Agent365ProvisioningException exception)
                when (string.Equals(
                    exception.ErrorCode,
                    "MICROSOFT_GRAPH_RESOURCE_NOT_FOUND",
                    StringComparison.Ordinal))
            {
                lastNotFound = exception;
            }
        }

        throw lastNotFound ?? Failure(
            ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE,
            "The service-principal app-role assignment relationship is not available yet.",
            isTransient: true);
    }

    private static Agent365ProvisioningException AmbiguousCreate()
    {
        return Failure(
            ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
            "The Microsoft resource create outcome is unknown and requires manual verification.",
            requiresManualIntervention: true);
    }

    private static Agent365ProvisioningException PostMutationCancellation(string resourceName)
    {
        return Failure(
            ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
            $"The {resourceName} create or verification was canceled after the mutation boundary and requires manual verification.",
            requiresManualIntervention: true);
    }

    private static bool CanRecoverCreate(Agent365ProvisioningException exception)
    {
        return exception.IsTransient || exception.RequiresManualIntervention ||
            exception.ErrorCode == "MICROSOFT_GRAPH_CONFLICT";
    }

    private static bool IsRetryableVerificationRead(Agent365ProvisioningException exception)
    {
        return exception.IsTransient ||
            string.Equals(
                exception.ErrorCode,
                "MICROSOFT_GRAPH_RESOURCE_NOT_FOUND",
                StringComparison.Ordinal);
    }

    private static async Task<T?> RecoverLookupAsync<T>(
        Func<Task<T?>> lookup,
        CancellationToken cancellationToken)
        where T : class
    {
        foreach (var delay in RecoveryLookupDelays)
        {
            if (delay > TimeSpan.Zero)
                await Task.Delay(delay, cancellationToken);

            var result = await lookup();
            if (result is not null)
                return result;
        }

        return null;
    }

    private static Agent365ProvisioningStepResult Complete(
        Agent365ProvisioningStepRequest request,
        Agent365ProvisioningState state,
        string evidence)
    {
        return new Agent365ProvisioningStepResult(
            request.StepType,
            state,
            evidence);
    }

    private static void RequirePair(string? first, string? second, string summary)
    {
        if (string.IsNullOrWhiteSpace(first) || string.IsNullOrWhiteSpace(second))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                summary,
                requiresManualIntervention: true);
        }
    }

    private static bool HasEither(string? first, string? second)
    {
        return !string.IsNullOrWhiteSpace(first) || !string.IsNullOrWhiteSpace(second);
    }

    private static Guid RequiredStateGuid(string? value, string summary)
    {
        if (!Guid.TryParse(value, out var parsed) || parsed == Guid.Empty)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_STATE_INVALID,
                summary,
                requiresManualIntervention: true);
        }

        return parsed;
    }

    private static Guid RequiredDependencyGuid(string? value, string summary)
    {
        if (!Guid.TryParse(value, out var parsed) || parsed == Guid.Empty)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                summary,
                requiresManualIntervention: true);
        }

        return parsed;
    }

    private static string RequiredDependencyIdentifier(string? value, string summary)
    {
        var normalized = value?.Trim();
        if (string.IsNullOrEmpty(normalized) ||
            normalized.Length > 512 ||
            normalized.Any(char.IsControl))
        {
            throw Failure(
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                summary,
                requiresManualIntervention: true);
        }

        return normalized;
    }

    private static Guid RequiredOptionGuid(string? value)
    {
        if (!Guid.TryParse(value, out var parsed) || parsed == Guid.Empty)
        {
            throw Failure(
                ErrorCodes.PROVISIONING_CONFIGURATION_INVALID,
                "A required Agent 365 provisioning option isn't a valid identifier.");
        }

        return parsed;
    }

    private static bool MatchesOptionalGuid(string? expected, Guid actual)
    {
        return string.IsNullOrWhiteSpace(expected) ||
            (Guid.TryParse(expected, out var parsed) && parsed == actual);
    }

    private static string BuildDisplayName(string resourceType, string name, Guid registrationId)
    {
        var suffix = $" - {registrationId:N}";
        var prefix = $"A365 {resourceType} - ";
        var available = 256 - prefix.Length - suffix.Length;
        return prefix + SanitizeRequired(name, Math.Max(1, available)) + suffix;
    }

    private static string BuildBlueprintKey(string environment, string displayName)
    {
        var material = $"{environment.Trim().ToUpperInvariant()}\n{displayName.Trim()}";
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(material));
        return Convert.ToHexString(digest)[..24].ToLowerInvariant();
    }

    private static string SanitizeRequired(string? value, int maximumLength)
    {
        return SanitizeOptional(value, maximumLength)
            ?? throw Failure(
                ErrorCodes.PROVISIONING_CONFIGURATION_INVALID,
                "A required provisioning value is empty.");
    }

    private static string? SanitizeOptional(string? value, int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value))
            return null;

        var chars = value.Trim()
            .Select(character => char.IsControl(character) ? ' ' : character)
            .Take(maximumLength)
            .ToArray();
        var result = new string(chars).Trim();
        return result.Length == 0 ? null : result;
    }

    private static Agent365ProvisioningException NormalizeDependencyFailure(
        Agent365ProvisioningException exception)
    {
        if (exception.ErrorCode is ErrorCodes.PROVISIONING_CONFIGURATION_INVALID or
            ErrorCodes.PROVISIONING_PREVIEW_DISABLED or
            ErrorCodes.PROVISIONING_STATE_INVALID or
            ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT or
            ErrorCodes.PROVISIONING_STEP_NOT_IMPLEMENTED or
            ErrorCodes.PROVISIONING_DISABLED or
            ErrorCodes.AGENT365_REGISTRY_ACTION_REQUIRED or
            ErrorCodes.AGENT365_PLATFORM_ACCEPTANCE_UNCONFIGURED)
        {
            return exception;
        }

        if (exception.ErrorCode.Contains("FORBIDDEN", StringComparison.Ordinal) ||
            exception.ErrorCode.Contains("UNAUTHORIZED", StringComparison.Ordinal) ||
            exception.ErrorCode.Contains("ACCESS_DENIED", StringComparison.Ordinal))
        {
            return Failure(
                ErrorCodes.PROVISIONING_DEPENDENCY_FORBIDDEN,
                exception.SafeSummary);
        }

        if (exception.RequiresManualIntervention ||
            exception.ErrorCode.Contains("OUTCOME_UNKNOWN", StringComparison.Ordinal) ||
            exception.ErrorCode.Contains("RESPONSE_INVALID", StringComparison.Ordinal))
        {
            return Failure(
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                exception.SafeSummary,
                requiresManualIntervention: true);
        }

        if (exception.ErrorCode.Contains("THROTT", StringComparison.Ordinal))
        {
            return Failure(
                ErrorCodes.PROVISIONING_DEPENDENCY_THROTTLED,
                exception.SafeSummary,
                isTransient: true);
        }

        if (exception.IsTransient ||
            exception.ErrorCode.Contains("NETWORK", StringComparison.Ordinal) ||
            exception.ErrorCode.Contains("TIMEOUT", StringComparison.Ordinal))
        {
            return Failure(
                ErrorCodes.PROVISIONING_DEPENDENCY_UNAVAILABLE,
                exception.SafeSummary,
                isTransient: true);
        }

        return Failure(
            ErrorCodes.PROVISIONING_CONFIGURATION_INVALID,
            exception.SafeSummary);
    }

    private static Agent365ProvisioningException Failure(
        string errorCode,
        string safeSummary,
        bool isTransient = false,
        bool requiresManualIntervention = false)
    {
        return new Agent365ProvisioningException(
            errorCode,
            safeSummary,
            isTransient,
            requiresManualIntervention);
    }

    private sealed record ProvisioningContext(
        Guid TenantId,
        Guid OwnerObjectId,
        IReadOnlyList<Guid> ManagerApplicationIds,
        Guid GatewayManagedIdentityPrincipalId,
        string BlueprintDisplayName,
        string BlueprintKey,
        string AgentIdentityDisplayName);
}
