namespace Gateway.Domain.Enums;

public enum PurviewTenantConnectionStatus
{
    NotConnected,
    AwaitingAdministrator,
    PendingVerification,
    Connected,
    Expired,
    VerificationFailed,
    Revoked
}

public enum PurviewPolicyScopeType
{
    Group,
    Individual
}

public enum PurviewEnforcementPlane
{
    Application
}

public enum PurviewKnowYourDataStatus
{
    NotConfigured,
    ReviewRequired,
    Pending,
    VerificationFailed,
    Ready
}

public enum PurviewDlpProfileStatus
{
    Draft,
    ReviewRequired,
    Pending,
    PendingPropagation,
    VerificationFailed,
    Ready
}

public enum PurviewPolicyActivity
{
    UploadText,
    DownloadText
}

public enum PurviewDlpAction
{
    Audit,
    Block
}

public enum PurviewEffectiveEnablementStatus
{
    Disabled,
    BlueprintRequired,
    ProfileRequired,
    ProfileMismatch,
    ProfileNotReady,
    Ready
}
