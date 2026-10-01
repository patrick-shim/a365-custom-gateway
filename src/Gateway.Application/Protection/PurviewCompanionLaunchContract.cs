using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;

namespace Gateway.Application.Protection;

internal static class PurviewCompanionLaunchContract
{
    public const string ScriptRelativePath =
        "Automation/Connect-PurviewTenant.ps1";

    public static PurviewCompanionLaunchDto Read(ProtectionAdminOperation operation)
    {
        if (string.IsNullOrWhiteSpace(operation.ResultJson))
        {
            throw new DomainException(
                "The companion launch binding is unavailable.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }

        var launch = JsonSerializer.Deserialize<ProtectionOperationAcceptedResponse>(
            operation.ResultJson)?.CompanionLaunch;
        if (launch is null ||
            launch.OperationId != operation.Id ||
            launch.InventoryGenerationId == Guid.Empty ||
            launch.ExpiresAtUtc.Offset != TimeSpan.Zero ||
            !Guid.TryParse(operation.ActorObjectId, out var actor) ||
            actor == Guid.Empty)
        {
            throw new DomainException(
                "The companion launch binding is invalid.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }

        var expected = Create(operation.Id, operation.TenantId.Value, actor,
            launch.InventoryGenerationId, launch.ExpiresAtUtc);
        if (launch.ScriptRelativePath != expected.ScriptRelativePath ||
            launch.Arguments is null ||
            !launch.Arguments.SequenceEqual(expected.Arguments, StringComparer.Ordinal))
        {
            throw new DomainException(
                "The companion launch arguments do not match the accepted operation.",
                ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        }
        return expected;
    }

    public static PurviewCompanionLaunchDto Create(
        Guid operationId,
        Guid tenantId,
        Guid administratorObjectId,
        Guid inventoryGenerationId,
        DateTimeOffset expiresAtUtc)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(operationId, Guid.Empty);
        ArgumentOutOfRangeException.ThrowIfEqual(tenantId, Guid.Empty);
        ArgumentOutOfRangeException.ThrowIfEqual(
            administratorObjectId,
            Guid.Empty);
        ArgumentOutOfRangeException.ThrowIfEqual(
            inventoryGenerationId,
            Guid.Empty);
        if (expiresAtUtc.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException(
                "Companion launch expiry must use the UTC offset.",
                nameof(expiresAtUtc));
        }

        return new PurviewCompanionLaunchDto(
            operationId,
            inventoryGenerationId,
            expiresAtUtc,
            ScriptRelativePath,
            [
                "-NoLogo",
                "-NoProfile",
                "-File",
                ScriptRelativePath,
                "-OperationId",
                operationId.ToString("D"),
                "-TenantId",
                tenantId.ToString("D"),
                "-AdministratorObjectId",
                administratorObjectId.ToString("D"),
                "-InventoryGenerationId",
                inventoryGenerationId.ToString("D"),
                "-ExpiresAtUtc",
                expiresAtUtc.ToString("O")
            ]);
    }
}
