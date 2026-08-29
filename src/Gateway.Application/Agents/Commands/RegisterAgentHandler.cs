using System.Text.Json;
using Gateway.Application.Configuration;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Messages;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using MediatR;

namespace Gateway.Application.Agents.Commands;

internal sealed class RegisterAgentHandler : IRequestHandler<RegisterAgentCommand, RegisterAgentResponse>
{
    private readonly IAgentRepository _agentRepository;
    private readonly IProvisioningJobRepository _provisioningJobRepository;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly ISystemConfigurationRepository _systemConfigurationRepository;
    private readonly IAgentIdentityBlueprintCatalog _blueprintCatalog;
    private readonly IAgentIngressCredentialService _agentIngressCredentialService;
    private readonly IPurviewPolicyClient _purviewPolicyClient;
    private readonly IPurviewPolicyProfileRepository _purviewPolicyProfileRepository;
    private readonly IPurviewPolicyProvisioningClient _purviewPolicyProvisioningClient;
    private readonly IUnitOfWork _unitOfWork;

    public RegisterAgentHandler(
        IAgentRepository agentRepository,
        IProvisioningJobRepository provisioningJobRepository,
        IOutboxRepository outboxRepository,
        IAuditEventRepository auditEventRepository,
        ISystemConfigurationRepository systemConfigurationRepository,
        IAgentIdentityBlueprintCatalog blueprintCatalog,
        IAgentIngressCredentialService agentIngressCredentialService,
        IPurviewPolicyClient purviewPolicyClient,
        IPurviewPolicyProfileRepository purviewPolicyProfileRepository,
        IPurviewPolicyProvisioningClient purviewPolicyProvisioningClient,
        IUnitOfWork unitOfWork)
    {
        _agentRepository = agentRepository;
        _provisioningJobRepository = provisioningJobRepository;
        _outboxRepository = outboxRepository;
        _auditEventRepository = auditEventRepository;
        _systemConfigurationRepository = systemConfigurationRepository;
        _blueprintCatalog = blueprintCatalog;
        _agentIngressCredentialService = agentIngressCredentialService;
        _purviewPolicyClient = purviewPolicyClient;
        _purviewPolicyProfileRepository = purviewPolicyProfileRepository;
        _purviewPolicyProvisioningClient = purviewPolicyProvisioningClient;
        _unitOfWork = unitOfWork;
    }

    public async Task<RegisterAgentResponse> Handle(RegisterAgentCommand request, CancellationToken cancellationToken)
    {
        var blueprint = request.Blueprint ?? throw new ValidationException(
            new Dictionary<string, string[]> { ["Blueprint"] = ["Blueprint selection is required."] });

        if (await _agentRepository.ExistsAsync(request.ExternalAgentId, cancellationToken))
        {
            throw new ConflictException(
                $"An agent with external ID '{request.ExternalAgentId}' already exists.",
                ErrorCodes.DUPLICATE_EXTERNAL_AGENT_ID);
        }

        if (string.Equals(blueprint.Mode, "UseExisting", StringComparison.Ordinal))
        {
            await EnsureSelectedBlueprintIsCompatibleAsync(
                blueprint.BlueprintObjectId,
                cancellationToken);
        }

        var agent = new AgentRegistration
        {
            Id = Guid.NewGuid(),
            ExternalAgentId = new ExternalAgentId(request.ExternalAgentId),
            Name = request.Name,
            Description = request.Description,
            OwnerObjectId = request.OwnerObjectId,
            Environment = Enum.Parse<AgentEnvironment>(request.Environment),
            Status = AgentStatus.Draft,
            BlueprintSelectionMode = blueprint.Mode,
            RequestedBlueprintObjectId = blueprint.BlueprintObjectId,
            RequestedBlueprintDisplayName = blueprint.DisplayName,
            CreatedAtUtc = DateTime.UtcNow,
            UpdatedAtUtc = DateTime.UtcNow,
            CreatedByObjectId = request.CallerObjectId,
            UpdatedByObjectId = request.CallerObjectId
        };

        var systemConfig = await _systemConfigurationRepository.GetAsync(cancellationToken);
        var observabilityMode = GetDefaultObservabilityMode(systemConfig);
        var purviewEnabled = systemConfig?.DefaultPurviewEnabled ?? false;
        var purviewMode = ParsePurviewMode(systemConfig?.DefaultPurviewMode)
            ?? (purviewEnabled ? _purviewPolicyClient.DefaultMode : null);

        if (request.Features is not null)
        {
            if (!ObservabilityModeExtensions.TryResolve(
                    request.Features.ObservabilityMode,
                    request.Features.Agent365ObservabilityEnabled,
                    request.Features.AzureMonitorExportEnabled,
                    observabilityMode,
                    out observabilityMode))
            {
                throw new ValidationException(new Dictionary<string, string[]>
                {
                    ["Features.ObservabilityMode"] =
                    ["Legacy and destination-specific observability settings must describe the same destinations."]
                });
            }

            if (request.Features.PurviewEnabled is not null)
                purviewEnabled = request.Features.PurviewEnabled.Value;

            if (request.Features.PurviewMode is not null)
                purviewMode = Enum.Parse<PurviewMode>(request.Features.PurviewMode);
        }

        if (purviewEnabled && !_purviewPolicyClient.IsEnabled)
        {
            throw new DomainException(
                "Purview cannot be enabled because it is not configured for this Gateway deployment.",
                ErrorCodes.UNSUPPORTED_FEATURE_CONFIGURATION);
        }

        if (purviewEnabled && purviewMode is null)
            purviewMode = _purviewPolicyClient.DefaultMode;

        PurviewPolicyProfile? purviewProfile = null;
        if (purviewEnabled && string.Equals(blueprint.Mode, "CreateNew", StringComparison.Ordinal))
        {
            if (!_purviewPolicyProvisioningClient.IsEnabled)
            {
                throw new DomainException(
                    "Automated Purview profile assignment is not configured for this Gateway deployment.",
                    ErrorCodes.UNSUPPORTED_FEATURE_CONFIGURATION);
            }

            purviewProfile = await ResolvePurviewProfileAsync(
                request.PurviewPolicyProfile,
                purviewMode!.Value,
                request.CallerObjectId,
                cancellationToken);
            agent.PurviewPolicySelectionMode = request.PurviewPolicyProfile!.Mode;
            agent.RequestedPurviewPolicyProfileId = request.PurviewPolicyProfile.ProfileId;
            agent.RequestedPurviewPolicyDisplayName = request.PurviewPolicyProfile.DisplayName;
            agent.RequestedPurviewPolicyTemplate = request.PurviewPolicyProfile.Template;
            agent.PurviewPolicyProfileId = purviewProfile.Id;
            agent.PurviewPolicyProfile = purviewProfile;
        }

        var features = new AgentFeatureConfiguration
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            ObservabilityMode = observabilityMode,
            PurviewEnabled = purviewEnabled,
            PurviewMode = purviewMode,
            UpdatedAtUtc = DateTime.UtcNow
        };

        agent.FeatureConfiguration = features;

        var job = new ProvisioningJob
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            Type = OperationType.ProvisionAgent,
            Status = JobStatus.Pending,
            PercentComplete = 0,
            WorkflowVersion = ProvisioningWorkflow.CurrentVersion,
            StartedAtUtc = DateTime.UtcNow,
            CreatedAtUtc = DateTime.UtcNow
        };

        var stepTypes = ProvisioningWorkflow.CurrentSteps;
        var steps = new List<ProvisioningJobStep>();
        for (var i = 0; i < stepTypes.Count; i++)
        {
            steps.Add(new ProvisioningJobStep
            {
                Id = Guid.NewGuid(),
                ProvisioningJobId = job.Id,
                StepType = stepTypes[i],
                Status = StepStatus.Pending,
                OrderIndex = i
            });
        }
        job.Steps = steps;

        await _agentRepository.AddAsync(agent, cancellationToken);
        var issuedCredential = _agentIngressCredentialService.Issue(
            agent.Id,
            request.CallerObjectId,
            DateTime.UtcNow);
        await _provisioningJobRepository.AddAsync(job, cancellationToken);

        var outboxMessage = new OutboxMessage
        {
            Id = Guid.NewGuid(),
            MessageType = "ProvisionAgent",
            Payload = JsonSerializer.Serialize(new ProvisionAgentMessage(
                agent.Id,
                job.Id,
                ExpectedStepIndex: 0,
                CorrelationId: null)),
            Status = OutboxMessageStatus.Pending,
            RetryCount = 0,
            CreatedAtUtc = DateTime.UtcNow
        };
        await _outboxRepository.AddAsync(outboxMessage, cancellationToken);

        var auditEvent = new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "AgentRegistered",
            PerformedByObjectId = request.CallerObjectId,
            OccurredAtUtc = DateTime.UtcNow
        };
        await _auditEventRepository.AddAsync(auditEvent, cancellationToken);

        await _auditEventRepository.AddAsync(new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "GatewayCredentialIssued",
            PerformedByObjectId = request.CallerObjectId,
            Details = JsonSerializer.Serialize(new
            {
                credentialId = issuedCredential.Credential.Id,
                expiresAtUtc = issuedCredential.Credential.ExpiresAtUtc
            }),
            OccurredAtUtc = agent.CreatedAtUtc
        }, cancellationToken);

        await _unitOfWork.SaveChangesAsync(cancellationToken);

        return new RegisterAgentResponse(
            agent.Id,
            request.ExternalAgentId,
            agent.Name,
            agent.Status.ToString(),
            job.Id,
            agent.CreatedAtUtc,
            null,
            new AgentGatewayCredentialDto(
                issuedCredential.Credential.Id,
                issuedCredential.ApiKey,
                issuedCredential.Credential.ExpiresAtUtc));
    }

    private async Task<PurviewPolicyProfile> ResolvePurviewProfileAsync(
        PurviewPolicyProfileSelectionDto? selection,
        PurviewMode mode,
        string callerObjectId,
        CancellationToken cancellationToken)
    {
        if (selection is null)
        {
            throw new ValidationException(new Dictionary<string, string[]>
            {
                ["PurviewPolicyProfile"] = ["Select an existing Purview profile or create a new one."]
            });
        }

        if (string.Equals(selection.Mode, "UseExisting", StringComparison.Ordinal))
        {
            var existing = selection.ProfileId is { } existingProfileId
                ? await _purviewPolicyProfileRepository.GetByIdAsync(existingProfileId, cancellationToken)
                : null;
            if (existing is null ||
                !string.Equals(existing.Status, "Ready", StringComparison.Ordinal) ||
                !string.Equals(existing.Mode, mode.ToString(), StringComparison.Ordinal))
            {
                throw new ValidationException(new Dictionary<string, string[]>
                {
                    ["PurviewPolicyProfile.ProfileId"] = ["Select a ready Purview policy profile with the requested audit or enforcement mode."]
                });
            }

            return existing;
        }

        var displayName = selection.DisplayName?.Trim();
        if (string.IsNullOrWhiteSpace(displayName) ||
            await _purviewPolicyProfileRepository.DisplayNameExistsAsync(displayName, cancellationToken))
        {
            throw new ConflictException(
                "A Purview policy profile with that display name already exists.",
                ErrorCodes.PURVIEW_POLICY_PROFILE_CONFLICT);
        }

        var profileId = Guid.NewGuid();
        var providerName = $"A365 Gateway - {displayName} - {profileId:N}";
        var profile = new PurviewPolicyProfile
        {
            Id = profileId,
            DisplayName = displayName,
            Template = "AllSensitiveInformation",
            Mode = mode.ToString(),
            Status = "Pending",
            CollectionPolicyName = $"{providerName} Collection",
            DlpPolicyName = $"{providerName} DLP",
            DlpRuleName = $"{providerName} Rule",
            CreatedAtUtc = DateTime.UtcNow,
            UpdatedAtUtc = DateTime.UtcNow,
            CreatedByObjectId = callerObjectId
        };
        await _purviewPolicyProfileRepository.AddAsync(profile, cancellationToken);
        return profile;
    }

    private static ObservabilityMode GetDefaultObservabilityMode(SystemConfiguration? config)
    {
        return config is not null &&
               Enum.TryParse<ObservabilityMode>(
                   config.DefaultObservabilityMode,
                   ignoreCase: false,
                   out var configuredMode) &&
               Enum.IsDefined(configuredMode)
            ? configuredMode
            : ObservabilityMode.Agent365;
    }

    private static PurviewMode? ParsePurviewMode(string? value) =>
        Enum.TryParse<PurviewMode>(value, ignoreCase: false, out var mode)
        && Enum.IsDefined(mode)
            ? mode
            : null;

    private async Task EnsureSelectedBlueprintIsCompatibleAsync(
        string? blueprintObjectId,
        CancellationToken cancellationToken)
    {
        if (!Guid.TryParse(blueprintObjectId, out var selectedObjectId) ||
            selectedObjectId == Guid.Empty)
        {
            throw IncompatibleBlueprint();
        }

        IReadOnlyList<AgentIdentityBlueprintCatalogItem> blueprints;
        try
        {
            blueprints = await _blueprintCatalog.ListAsync(cancellationToken);
        }
        catch (Agent365ProvisioningException exception)
        {
            var invalidResponse = exception.ErrorCode is
                "MICROSOFT_GRAPH_RESPONSE_INVALID" or
                "MICROSOFT_GRAPH_NEXT_LINK_INVALID" or
                "MICROSOFT_GRAPH_REQUEST_REJECTED" or
                "MICROSOFT_GRAPH_RESOURCE_NOT_FOUND";

            throw new DomainException(
                invalidResponse
                    ? "Microsoft Graph returned an invalid Agent Identity blueprint catalog response."
                    : "The Agent Identity blueprint catalog is temporarily unavailable.",
                invalidResponse
                    ? ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_INVALID_RESPONSE
                    : ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_UNAVAILABLE);
        }

        var matches = blueprints
            .Where(item => item.BlueprintObjectId == selectedObjectId)
            .Take(2)
            .ToArray();
        if (matches.Length > 1)
        {
            throw new DomainException(
                "The Agent Identity blueprint catalog contains duplicate identifiers.",
                ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_INVALID_RESPONSE);
        }

        if (matches.Length == 0 || !matches[0].IsAgent365Compatible)
        {
            throw IncompatibleBlueprint();
        }
    }

    private static DomainException IncompatibleBlueprint() => new(
        "The selected Agent Identity blueprint isn't available for Agent 365 through this Gateway. Choose a compatible blueprint or create a new reusable blueprint.",
        ErrorCodes.AGENT_IDENTITY_BLUEPRINT_INCOMPATIBLE);
}
