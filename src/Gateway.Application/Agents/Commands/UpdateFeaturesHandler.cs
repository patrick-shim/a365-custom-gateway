using System.Text.Json;
using Gateway.Application.Common;
using Gateway.Application.Exceptions;
using Gateway.Application.Protection;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using MediatR;

namespace Gateway.Application.Agents.Commands;

internal sealed class UpdateFeaturesHandler : IRequestHandler<UpdateFeaturesCommand, UpdateFeaturesResponse>
{
    private readonly IAgentRepository _agentRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IPurviewPolicyClient _purviewPolicyClient;
    private readonly IPromptShieldClient _promptShieldClient;
    private readonly IUnitOfWork _unitOfWork;
    private readonly ProtectionEffectiveFeatureEvaluator? _protectionFeatures;
    private readonly IIdempotencyService? _idempotencyService;

    public UpdateFeaturesHandler(
        IAgentRepository agentRepository,
        IAuditEventRepository auditEventRepository,
        IPurviewPolicyClient purviewPolicyClient,
        IPromptShieldClient promptShieldClient,
        IUnitOfWork unitOfWork,
        ProtectionEffectiveFeatureEvaluator? protectionFeatures = null,
        IIdempotencyService? idempotencyService = null)
    {
        _agentRepository = agentRepository;
        _auditEventRepository = auditEventRepository;
        _purviewPolicyClient = purviewPolicyClient;
        _promptShieldClient = promptShieldClient;
        _unitOfWork = unitOfWork;
        _protectionFeatures = protectionFeatures;
        _idempotencyService = idempotencyService;
    }

    public async Task<UpdateFeaturesResponse> Handle(UpdateFeaturesCommand request, CancellationToken cancellationToken)
    {
        var agent = await _agentRepository.GetByIdAsync(request.AgentId, cancellationToken)
            ?? throw new NotFoundException("AgentRegistration", request.AgentId);
        var idempotencyKey = request.IdempotencyKey?.ToString("D");
        var requestHash = idempotencyKey is null
            ? null
            : IdempotencyRequestHasher.Compute(request);
        await using var idempotencyLease =
            idempotencyKey is not null && _idempotencyService is not null
                ? await _idempotencyService.AcquireScopeAsync(
                    agent.Id,
                    $"/api/v1/agents/{agent.Id:D}/features",
                    idempotencyKey,
                    cancellationToken)
                : null;
        if (idempotencyLease is not null)
        {
            var existing = await _idempotencyService!.GetAsync(
                agent.Id,
                $"/api/v1/agents/{agent.Id:D}/features",
                idempotencyKey!,
                DateTime.UtcNow,
                cancellationToken);
            if (existing is not null)
            {
                if (!string.Equals(
                        existing.RequestBodyHash,
                        requestHash,
                        StringComparison.Ordinal))
                {
                    throw new ConflictException(
                        "The Idempotency-Key was already used for a different feature mutation.",
                        Gateway.Contracts.ErrorCodes.IDEMPOTENCY_CONFLICT);
                }

                var replay = JsonSerializer.Deserialize<UpdateFeaturesResponse>(
                    existing.ResponseBody)!;
                await idempotencyLease.CompleteAsync(cancellationToken);
                return replay;
            }
        }

        if (request.ExpectedRowVersion is not null)
        {
            ProtectionRowVersion.EnsureMatches(
                request.ExpectedRowVersion,
                resourceExists: true,
                agent.RowVersion,
                agent.Id,
                agent.UpdatedAtUtc);
        }

        if (agent.Status is not AgentStatus.Active and not AgentStatus.Disabled)
        {
            throw new InvalidStateTransitionException(agent.Status.ToString(), "UpdateFeatures");
        }

        if (request.ObservabilityMode is not null ||
            request.Agent365ObservabilityEnabled is not null ||
            request.AzureMonitorExportEnabled is not null)
        {
            if (!ObservabilityModeExtensions.TryResolve(
                    request.ObservabilityMode,
                    request.Agent365ObservabilityEnabled,
                    request.AzureMonitorExportEnabled,
                    agent.FeatureConfiguration.ObservabilityMode,
                    out var observabilityMode))
            {
                throw new ValidationException(new Dictionary<string, string[]>
                {
                    ["ObservabilityMode"] =
                    ["Legacy and destination-specific observability settings must describe the same destinations."]
                });
            }

            agent.FeatureConfiguration.ObservabilityMode = observabilityMode;
        }

        var purviewEnabled = request.PurviewEnabled
            ?? agent.FeatureConfiguration.PurviewEnabled;
        var purviewMode = request.PurviewMode is null
            ? agent.FeatureConfiguration.PurviewMode
            : Enum.Parse<PurviewMode>(request.PurviewMode);
        if (purviewEnabled && !_purviewPolicyClient.IsEnabled)
        {
            throw new DomainException(
                "Purview cannot be enabled because it is not configured for this Gateway deployment.",
                Gateway.Contracts.ErrorCodes.UNSUPPORTED_FEATURE_CONFIGURATION);
        }

        if (purviewEnabled &&
            _protectionFeatures is null)
        {
            throw new DomainException(
                "Purview capability and profile readiness cannot be verified.",
                Gateway.Contracts.ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE);
        }

        if (purviewEnabled)
        {
            if (!Guid.TryParse(
                    agent.BlueprintId,
                    out var blueprintApplicationId) ||
                blueprintApplicationId == Guid.Empty)
            {
                throw new DomainException(
                    "Purview cannot be enabled until the registration has a resolved blueprint application.",
                    Gateway.Contracts.ErrorCodes.PURVIEW_DLP_PROFILE_NOT_READY);
            }

            var selection = request.PurviewDlpProfile;
            if (selection is null &&
                agent.RequestedPurviewPolicyProfileId is { } selectedProfileId)
            {
                selection = new PurviewDlpProfileSelectionDto(
                    selectedProfileId,
                    blueprintApplicationId);
            }

            var profile =
                await _protectionFeatures!.RequireReadyProfileAsync(
                    blueprintApplicationId,
                    selection,
                    cancellationToken);
            if (purviewMode is not null && profile.Mode != purviewMode)
            {
                throw new DomainException(
                    "The selected DLP profile mode does not match the requested registration mode.",
                    Gateway.Contracts.ErrorCodes.PURVIEW_DLP_PROFILE_NOT_READY);
            }

            agent.RequestedPurviewPolicyProfileId = profile.Id.Value;
        }

        agent.FeatureConfiguration.PurviewEnabled = purviewEnabled;
        agent.FeatureConfiguration.PurviewMode = purviewEnabled
            ? purviewMode ?? _purviewPolicyClient.DefaultMode
            : purviewMode;
        var promptShieldEnabled = request.PromptShieldEnabled
            ?? agent.FeatureConfiguration.PromptShieldEnabled;
        if (promptShieldEnabled && !_promptShieldClient.IsEnabled)
        {
            throw new DomainException(
                "Prompt Shields cannot be enabled because Azure AI Content Safety is not configured for this Gateway deployment.",
                Gateway.Contracts.ErrorCodes.UNSUPPORTED_FEATURE_CONFIGURATION);
        }
        if (promptShieldEnabled && _protectionFeatures is null)
        {
            throw new DomainException(
                "Prompt Shields capability readiness cannot be verified.",
                Gateway.Contracts.ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE);
        }
        if (promptShieldEnabled)
        {
            await _protectionFeatures!.EnsurePromptShieldReadyAsync(
                cancellationToken);
        }
        agent.FeatureConfiguration.PromptShieldEnabled = promptShieldEnabled;

        agent.FeatureConfiguration.UpdatedAtUtc = DateTime.UtcNow;
        agent.UpdatedAtUtc = DateTime.UtcNow;
        agent.UpdatedByObjectId = request.CallerObjectId;

        var auditEvent = new Domain.Entities.AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "FeaturesUpdated",
            PerformedByObjectId = request.CallerObjectId,
            OccurredAtUtc = DateTime.UtcNow
        };
        await _auditEventRepository.AddAsync(auditEvent, cancellationToken);

        await _unitOfWork.SaveChangesAsync(cancellationToken);

        var destinations = agent.FeatureConfiguration.ObservabilityMode.ToDestinations();
        var responseFeatures = _protectionFeatures is null
            ? new AgentFeaturesDto(
                agent.FeatureConfiguration.ObservabilityMode.ToString(),
                agent.FeatureConfiguration.PurviewEnabled,
                agent.FeatureConfiguration.PurviewMode?.ToString(),
                destinations.Agent365ObservabilityEnabled,
                destinations.AzureMonitorExportEnabled,
                agent.FeatureConfiguration.PromptShieldEnabled)
            : await _protectionFeatures.ToDtoAsync(
                agent,
                cancellationToken);

        var response = new UpdateFeaturesResponse(
            agent.Id,
            responseFeatures,
            agent.FeatureConfiguration.UpdatedAtUtc);
        if (idempotencyLease is not null)
        {
            await _idempotencyService!.SaveAsync(new IdempotencyRecord
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agent.Id,
                IdempotencyKey = idempotencyKey!,
                RequestBodyHash = requestHash!,
                Endpoint = $"/api/v1/agents/{agent.Id:D}/features",
                ResponseStatusCode = 200,
                ResponseBody = JsonSerializer.Serialize(response),
                CreatedAtUtc = DateTime.UtcNow,
                ExpiresAtUtc = default
            }, cancellationToken);
            await _unitOfWork.SaveChangesAsync(cancellationToken);
            await idempotencyLease.CompleteAsync(cancellationToken);
        }

        return response;
    }
}
