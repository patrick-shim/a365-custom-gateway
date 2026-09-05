namespace Gateway.Domain.Enums;

public enum ProtectionAdminOperationType
{
    ConnectPurviewTenant,
    RefreshSensitiveInformationTypes,
    CreateOrUpdateKnowYourData,
    CreateOrUpdateDlpProfile,
    ReconcileDlpProfile,
    ValidateDlpRuntime,
    UpdateProtectionDefaults,
    CompletePurviewTenantConnection
}

public enum ProtectionAdminTargetType
{
    PurviewTenantConnection,
    SensitiveInformationTypeInventory,
    KnowYourDataConfiguration,
    DlpProfile,
    SystemConfiguration
}

public enum ProtectionAdminOperationStatus
{
    Pending,
    AwaitingConfirmation,
    AwaitingAdministrator,
    Submitted,
    Running,
    PendingPropagation,
    Completed,
    Failed,
    RequiresManualIntervention,
    Cancelled
}

public enum ProtectionAdminStepType
{
    // Values are persisted by protection administration workflow v1.
    // Never reorder, reuse, or merge these with registration provisioning stages.
    ValidateReviewedIntent = 0,
    DiscoverProviderState = 1,
    ApplyReviewedMutation = 2,
    RecordExactReadback = 3,
    VerifyPropagation = 4,
    AttestTokenRoles = 5,
    ValidateRuntimeVerdict = 6,
    Complete = 7
}

public enum ProtectionAdminStepStatus
{
    Pending,
    AwaitingConfirmation,
    AwaitingAdministrator,
    Running,
    PendingPropagation,
    Completed,
    Failed,
    RequiresManualIntervention,
    Skipped
}

public enum ProtectionRetryDisposition
{
    NotApplicable,
    Retryable,
    Exhausted,
    RequiresManualIntervention
}
