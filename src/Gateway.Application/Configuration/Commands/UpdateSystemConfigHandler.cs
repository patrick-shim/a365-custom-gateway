using Gateway.Application.Exceptions;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using MediatR;

namespace Gateway.Application.Configuration.Commands;

internal sealed class UpdateSystemConfigHandler : IRequestHandler<UpdateSystemConfigCommand, SystemConfigDto>
{
    private readonly ISystemConfigurationRepository _configRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IPurviewPolicyClient _purviewPolicyClient;
    private readonly IPromptShieldClient _promptShieldClient;
    private readonly IUnitOfWork _unitOfWork;

    public UpdateSystemConfigHandler(
        ISystemConfigurationRepository configRepository,
        IAuditEventRepository auditEventRepository,
        IPurviewPolicyClient purviewPolicyClient,
        IPromptShieldClient promptShieldClient,
        IUnitOfWork unitOfWork)
    {
        _configRepository = configRepository;
        _auditEventRepository = auditEventRepository;
        _purviewPolicyClient = purviewPolicyClient;
        _promptShieldClient = promptShieldClient;
        _unitOfWork = unitOfWork;
    }

    public async Task<SystemConfigDto> Handle(UpdateSystemConfigCommand request, CancellationToken cancellationToken)
    {
        var config = await _configRepository.GetAsync(cancellationToken)
            ?? throw new NotFoundException("SystemConfiguration", "singleton");

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
        await _unitOfWork.SaveChangesAsync(cancellationToken);

        return SystemConfigMapper.ToDto(config);
    }
}
