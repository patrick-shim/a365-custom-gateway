using Gateway.Contracts.Dtos;

namespace Gateway.Application.Protection;

internal static class PurviewCompanionLaunchContract
{
    public const string ScriptRelativePath =
        "Automation/Connect-PurviewTenant.ps1";

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
