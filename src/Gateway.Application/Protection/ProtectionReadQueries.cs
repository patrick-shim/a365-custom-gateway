using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Responses;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using MediatR;

namespace Gateway.Application.Protection;

public sealed record GetProtectionCapabilitiesQuery(ProtectionActor Actor)
    : IRequest<ProtectionCapabilitiesResponse>;

public sealed record GetPurviewTenantConnectionQuery(ProtectionActor Actor)
    : IRequest<PurviewTenantConnectionResponse>;

public sealed record GetPurviewSensitiveInformationTypesQuery(ProtectionActor Actor)
    : IRequest<PurviewSensitiveInformationTypeListResponse>;

public sealed record GetPurviewKnowYourDataQuery(ProtectionActor Actor)
    : IRequest<PurviewKnowYourDataResponse>;

public sealed record ListPurviewDlpProfilesQuery(ProtectionActor Actor)
    : IRequest<PurviewDlpProfileListResponse>;

public sealed record GetProtectionAdminOperationQuery(
    ProtectionActor Actor,
    Guid OperationId) : IRequest<ProtectionAdminOperationResponse>;

internal sealed class ProtectionReadQueriesHandler :
    IRequestHandler<GetProtectionCapabilitiesQuery, ProtectionCapabilitiesResponse>,
    IRequestHandler<GetPurviewTenantConnectionQuery, PurviewTenantConnectionResponse>,
    IRequestHandler<
        GetPurviewSensitiveInformationTypesQuery,
        PurviewSensitiveInformationTypeListResponse>,
    IRequestHandler<GetPurviewKnowYourDataQuery, PurviewKnowYourDataResponse>,
    IRequestHandler<ListPurviewDlpProfilesQuery, PurviewDlpProfileListResponse>,
    IRequestHandler<GetProtectionAdminOperationQuery, ProtectionAdminOperationResponse>
{
    private readonly IProtectionCapabilityRepository _capabilities;
    private readonly IPurviewTenantConnectionRepository _connections;
    private readonly IPurviewSensitiveInformationTypeSnapshotRepository _inventory;
    private readonly IPurviewKnowYourDataConfigurationRepository _knowYourData;
    private readonly IPurviewDlpProfileRepository _profiles;
    private readonly IProtectionAdminOperationRepository _operations;
    private readonly TimeProvider _timeProvider;
    private readonly ProtectionEffectiveFeatureEvaluator _features;

    public ProtectionReadQueriesHandler(
        IProtectionCapabilityRepository capabilities,
        IPurviewTenantConnectionRepository connections,
        IPurviewSensitiveInformationTypeSnapshotRepository inventory,
        IPurviewKnowYourDataConfigurationRepository knowYourData,
        IPurviewDlpProfileRepository profiles,
        IProtectionAdminOperationRepository operations,
        TimeProvider timeProvider,
        ProtectionEffectiveFeatureEvaluator features)
    {
        _capabilities = capabilities;
        _connections = connections;
        _inventory = inventory;
        _knowYourData = knowYourData;
        _profiles = profiles;
        _operations = operations;
        _timeProvider = timeProvider;
        _features = features;
    }

    public async Task<ProtectionCapabilitiesResponse> Handle(
        GetProtectionCapabilitiesQuery request,
        CancellationToken cancellationToken)
    {
        var capabilities = await _capabilities.ListAsync(cancellationToken);
        return new ProtectionCapabilitiesResponse(
            capabilities.Select(ProtectionAdministrationMapper.ToDto).ToArray());
    }

    public async Task<PurviewTenantConnectionResponse> Handle(
        GetPurviewTenantConnectionQuery request,
        CancellationToken cancellationToken)
    {
        var connection = await _connections.GetByTenantIdAsync(
            new EntraTenantId(request.Actor.TenantId),
            cancellationToken);
        return new PurviewTenantConnectionResponse(
            connection is null
                ? null
                : ProtectionAdministrationMapper.ToDto(connection));
    }

    public async Task<PurviewSensitiveInformationTypeListResponse> Handle(
        GetPurviewSensitiveInformationTypesQuery request,
        CancellationToken cancellationToken)
    {
        var tenantId = new EntraTenantId(request.Actor.TenantId);
        var connection = await _connections.GetByTenantIdAsync(
            tenantId,
            cancellationToken);
        var utcNow = _timeProvider.GetUtcNow().UtcDateTime;
        if (connection?.ActiveInventoryGenerationId is null ||
            !connection.IsUsableAt(utcNow))
        {
            throw new DomainException(
                "The Purview tenant has no current sensitive-information-type inventory.",
                ErrorCodes.PURVIEW_INVENTORY_STALE);
        }

        var generation = await _inventory.GetGenerationAsync(
            connection.ActiveInventoryGenerationId.Value,
            cancellationToken);
        if (generation is null || generation.TenantId != tenantId)
        {
            throw new DomainException(
                "The Purview sensitive-information-type inventory is unavailable.",
                ErrorCodes.PURVIEW_INVENTORY_STALE);
        }

        return new PurviewSensitiveInformationTypeListResponse(
            generation.Id.Value,
            generation.TenantId.Value,
            generation.RetrievedAtUtc,
            generation.ExpiresAtUtc,
            generation.IsExpired(utcNow),
            generation.Items
                .OrderBy(item => item.SortOrder)
                .Select(item => new Contracts.Dtos.PurviewSensitiveInformationTypeDto(
                    item.SensitiveInformationTypeId.Value,
                    item.ExactName,
                    item.Publisher))
                .ToArray());
    }

    public async Task<PurviewKnowYourDataResponse> Handle(
        GetPurviewKnowYourDataQuery request,
        CancellationToken cancellationToken)
    {
        var configuration = await _knowYourData.GetByTenantIdAsync(
            new EntraTenantId(request.Actor.TenantId),
            cancellationToken);
        return new PurviewKnowYourDataResponse(
            configuration is null
                ? null
                : ProtectionAdministrationMapper.ToDto(configuration));
    }

    public async Task<PurviewDlpProfileListResponse> Handle(
        ListPurviewDlpProfilesQuery request,
        CancellationToken cancellationToken)
    {
        var profiles = await _profiles.ListAsync(cancellationToken);
        var authorized = new List<Contracts.Dtos.PurviewDlpProfileDto>();
        foreach (var profile in profiles)
        {
            var connection = await _connections.GetByIdAsync(
                profile.PurviewTenantConnectionId,
                cancellationToken);
            if (connection?.TenantId.Value == request.Actor.TenantId)
            {
                authorized.Add(
                    await _features.ToProfileDtoAsync(profile, cancellationToken));
            }
        }

        return new PurviewDlpProfileListResponse(authorized);
    }

    public async Task<ProtectionAdminOperationResponse> Handle(
        GetProtectionAdminOperationQuery request,
        CancellationToken cancellationToken)
    {
        var operation = await _operations.GetByIdAsync(
            request.OperationId,
            cancellationToken);
        if (operation is null ||
            operation.TenantId.Value != request.Actor.TenantId)
        {
            throw new NotFoundException("ProtectionAdminOperation", request.OperationId);
        }

        return new ProtectionAdminOperationResponse(
            ProtectionAdministrationMapper.ToDto(
                operation,
                _timeProvider.GetUtcNow().UtcDateTime));
    }
}
