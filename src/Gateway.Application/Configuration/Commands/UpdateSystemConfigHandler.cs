using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Application.Protection;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using MediatR;

namespace Gateway.Application.Configuration.Commands;

internal sealed class UpdateSystemConfigHandler : IRequestHandler<UpdateSystemConfigCommand, SystemConfigDto>
{
    private readonly ISystemConfigurationRepository _configRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IPurviewPolicyClient _purviewPolicyClient;
    private readonly IPromptShieldClient _promptShieldClient;
    private readonly IUnitOfWork _unitOfWork;
    private readonly ProtectionEffectiveFeatureEvaluator? _protectionFeatures;
    private readonly IProtectionAdminOperationRepository? _protectionOperations;

    public UpdateSystemConfigHandler(
        ISystemConfigurationRepository configRepository,
        IAuditEventRepository auditEventRepository,
        IPurviewPolicyClient purviewPolicyClient,
        IPromptShieldClient promptShieldClient,
        IUnitOfWork unitOfWork,
        ProtectionEffectiveFeatureEvaluator? protectionFeatures = null,
        IProtectionAdminOperationRepository? protectionOperations = null)
    {
        _configRepository = configRepository;
        _auditEventRepository = auditEventRepository;
        _purviewPolicyClient = purviewPolicyClient;
        _promptShieldClient = promptShieldClient;
        _unitOfWork = unitOfWork;
        _protectionFeatures = protectionFeatures;
        _protectionOperations = protectionOperations;
    }

    public async Task<SystemConfigDto> Handle(UpdateSystemConfigCommand request, CancellationToken cancellationToken)
    {
        var config = await _configRepository.GetAsync(cancellationToken)
            ?? throw new NotFoundException("SystemConfiguration", "singleton");
        ProtectionAdminOperation? idempotencyOperation = null;
        string? acceptedRequestHash = null;
        if (request.IdempotencyKey is { } idempotencyKey)
        {
            if (request.CallerTenantId is not { } callerTenantId ||
                callerTenantId == Guid.Empty ||
                _protectionOperations is null)
            {
                throw new ProtectionAccessDeniedException();
            }

            acceptedRequestHash =
                ProtectionAcceptedRequestHasher.Compute(request);
            var existing =
                await _protectionOperations.GetByIdempotencyKeyAsync(
                    new EntraTenantId(callerTenantId),
                    new ProtectionIdempotencyKey(idempotencyKey),
                    cancellationToken);
            if (existing is not null)
            {
                if (existing.Type !=
                        ProtectionAdminOperationType.UpdateProtectionDefaults ||
                    existing.TargetType !=
                        ProtectionAdminTargetType.SystemConfiguration ||
                    !string.Equals(
                        existing.TargetIdentifier,
                        config.Id.ToString("D"),
                        StringComparison.Ordinal) ||
                    !string.Equals(
                        existing.ActorObjectId,
                        request.CallerObjectId,
                        StringComparison.Ordinal) ||
                    !string.Equals(
                        existing.AcceptedRequestHash,
                        acceptedRequestHash,
                        StringComparison.Ordinal) ||
                    string.IsNullOrWhiteSpace(existing.ResultJson))
                {
                    throw new ConflictException(
                        "The Idempotency-Key was already used for a different protection-default mutation.",
                        Gateway.Contracts.ErrorCodes.IDEMPOTENCY_CONFLICT);
                }

                return JsonSerializer.Deserialize<SystemConfigDto>(
                           existing.ResultJson)
                    ?? throw new InvalidOperationException(
                        "The stored protection-default idempotency result is invalid.");
            }
        }

        if (request.ExpectedRowVersion is not null)
        {
            ProtectionRowVersion.EnsureMatches(
                request.ExpectedRowVersion,
                resourceExists: true,
                config.RowVersion,
                config.Id,
                config.UpdatedAtUtc);
        }

        var rateLimitPerClient = request.RateLimitPerClient ?? config.RateLimitPerClient;
        var rateLimitPerAgent = request.RateLimitPerAgent ?? config.RateLimitPerAgent;
        var rateLimitGlobal = request.RateLimitGlobal ?? config.RateLimitGlobal;
        if (rateLimitGlobal < Math.Max(rateLimitPerClient, rateLimitPerAgent))
        {
            throw new ValidationException(new Dictionary<string, string[]>
            {
                ["RateLimitGlobal"] =
                ["RateLimitGlobal must be at least as large as RateLimitPerClient and RateLimitPerAgent."]
            });
        }

        if (request.DefaultObservabilityMode is not null ||
            request.DefaultAgent365ObservabilityEnabled is not null ||
            request.DefaultAzureMonitorExportEnabled is not null)
        {
            if (!Enum.TryParse<ObservabilityMode>(
                    config.DefaultObservabilityMode,
                    ignoreCase: false,
                    out var currentMode) ||
                !Enum.IsDefined(currentMode))
            {
                throw new InvalidOperationException("The stored default observability mode is invalid.");
            }

            if (!ObservabilityModeExtensions.TryResolve(
                    request.DefaultObservabilityMode,
                    request.DefaultAgent365ObservabilityEnabled,
                    request.DefaultAzureMonitorExportEnabled,
                    currentMode,
                    out var resolvedMode))
            {
                throw new ValidationException(new Dictionary<string, string[]>
                {
                    ["DefaultObservabilityMode"] =
                    ["Legacy and destination-specific observability settings must describe the same destinations."]
                });
            }

            config.DefaultObservabilityMode = resolvedMode.ToString();
        }
        var defaultPurviewEnabled = request.DefaultPurviewEnabled
            ?? config.DefaultPurviewEnabled;
        var defaultPurviewMode = request.DefaultPurviewMode
            ?? config.DefaultPurviewMode;
        if (defaultPurviewEnabled && !_purviewPolicyClient.IsEnabled)
        {
            throw new DomainException(
                "Purview cannot be enabled because it is not configured for this Gateway deployment.",
                Gateway.Contracts.ErrorCodes.UNSUPPORTED_FEATURE_CONFIGURATION);
        }
        if (defaultPurviewEnabled &&
            (_protectionFeatures is null ||
             !await _protectionFeatures.HasAnyReadyDlpProfileAsync(
                 cancellationToken)))
        {
            throw new DomainException(
                "Purview cannot be the registration default without an exact Ready per-blueprint DLP profile.",
                Gateway.Contracts.ErrorCodes.PURVIEW_DLP_PROFILE_NOT_READY);
        }

        config.DefaultPurviewEnabled = defaultPurviewEnabled;
        config.DefaultPurviewMode = defaultPurviewEnabled
            ? defaultPurviewMode ?? _purviewPolicyClient.DefaultMode.ToString()
            : defaultPurviewMode;
        var defaultPromptShieldEnabled = request.DefaultPromptShieldEnabled
            ?? config.DefaultPromptShieldEnabled;
        if (defaultPromptShieldEnabled && !_promptShieldClient.IsEnabled)
        {
            throw new DomainException(
                "Prompt Shields cannot be enabled because Azure AI Content Safety is not configured for this Gateway deployment.",
                Gateway.Contracts.ErrorCodes.UNSUPPORTED_FEATURE_CONFIGURATION);
        }
        if (defaultPromptShieldEnabled && _protectionFeatures is null)
        {
            throw new DomainException(
                "Prompt Shields capability readiness cannot be verified.",
                Gateway.Contracts.ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE);
        }
        if (defaultPromptShieldEnabled)
        {
            await _protectionFeatures!.EnsurePromptShieldReadyAsync(
                cancellationToken);
        }
        config.DefaultPromptShieldEnabled = defaultPromptShieldEnabled;
        if (request.RetentionDaysIdempotencyRecords is not null)
            config.RetentionDaysIdempotencyRecords = request.RetentionDaysIdempotencyRecords.Value;
        config.RateLimitPerClient = rateLimitPerClient;
        config.RateLimitPerAgent = rateLimitPerAgent;
        config.RateLimitGlobal = rateLimitGlobal;
        config.UpdatedAtUtc = DateTime.UtcNow;

        var auditEvent = new AuditEvent
        {
            Id = Guid.NewGuid(),
            EventType = "SystemConfigUpdated",
            PerformedByObjectId = request.CallerObjectId,
            OccurredAtUtc = DateTime.UtcNow
        };

        await _auditEventRepository.AddAsync(auditEvent, cancellationToken);
        if (request.IdempotencyKey is { } acceptedKey &&
            request.CallerTenantId is { } acceptedTenantId)
        {
            var now = DateTime.UtcNow;
            idempotencyOperation = new ProtectionAdminOperation
            {
                Id = Guid.NewGuid(),
                WorkflowVersion = ProtectionAdminWorkflow.CurrentVersion,
                Type =
                    ProtectionAdminOperationType.UpdateProtectionDefaults,
                Status = ProtectionAdminOperationStatus.Completed,
                TenantId = new EntraTenantId(acceptedTenantId),
                ActorObjectId = request.CallerObjectId,
                TargetType =
                    ProtectionAdminTargetType.SystemConfiguration,
                TargetIdentifier = config.Id.ToString("D"),
                ReviewedPayloadHash = acceptedRequestHash!,
                AcceptedRequestHash = acceptedRequestHash,
                IdempotencyKey =
                    new ProtectionIdempotencyKey(acceptedKey),
                ExpectedRowVersion = ProtectionRowVersion.DecodeExpected(
                    request.ExpectedRowVersion!),
                RetryDisposition =
                    ProtectionRetryDisposition.NotApplicable,
                MaximumAttempts = 1,
                CorrelationId = request.CorrelationId is { } correlationId &&
                    correlationId != Guid.Empty
                    ? correlationId
                    : Guid.NewGuid(),
                CreatedAtUtc = now,
                StartedAtUtc = now,
                CompletedAtUtc = now,
                UpdatedAtUtc = now
            };
            await _protectionOperations!.AddAsync(
                idempotencyOperation,
                cancellationToken);
        }
        await _unitOfWork.SaveChangesAsync(cancellationToken);

        var result = SystemConfigMapper.ToDto(config);
        if (idempotencyOperation is not null)
        {
            idempotencyOperation.ResultJson =
                JsonSerializer.Serialize(result);
            idempotencyOperation.UpdatedAtUtc = DateTime.UtcNow;
            await _unitOfWork.SaveChangesAsync(cancellationToken);
        }

        return result;
    }
}
