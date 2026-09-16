SET XACT_ABORT ON;
BEGIN TRANSACTION;

DECLARE @LockResult int;
EXEC @LockResult = sys.sp_getapplock
    @Resource = N'A365Gateway:Migration:PurviewConfigurationIntent',
    @LockMode = N'Exclusive',
    @LockOwner = N'Transaction',
    @LockTimeout = 60000;
IF @LockResult < 0
    THROW 50000, 'Could not serialize Purview configuration intent migration; no data was changed.', 1;

IF OBJECT_ID(N'dbo.PurviewDlpProfiles', N'U') IS NULL
   OR OBJECT_ID(N'dbo.ProtectionAdminOperations', N'U') IS NULL
   OR OBJECT_ID(N'dbo.AgentRegistrations', N'U') IS NULL
    THROW 50001, 'Protection governance v1 is required; no data was changed.', 1;

IF COL_LENGTH(N'dbo.PurviewDlpProfiles', N'PolicyMode') IS NULL
    ALTER TABLE dbo.PurviewDlpProfiles ADD [PolicyMode] nvarchar(32) NULL;
IF COL_LENGTH(N'dbo.PurviewDlpProfiles', N'SensitiveInformationTypesJson') IS NULL
    ALTER TABLE dbo.PurviewDlpProfiles ADD [SensitiveInformationTypesJson] nvarchar(max) NOT NULL
        CONSTRAINT DF_PurviewDlpProfiles_SensitiveInformationTypesJson DEFAULT N'[]';
IF COL_LENGTH(N'dbo.ProtectionAdminOperations', N'DeferredConfigurationJson') IS NULL
    ALTER TABLE dbo.ProtectionAdminOperations ADD [DeferredConfigurationJson] nvarchar(max) NULL;
IF COL_LENGTH(N'dbo.AgentRegistrations', N'PurviewConfigurationOperationId') IS NULL
    ALTER TABLE dbo.AgentRegistrations ADD [PurviewConfigurationOperationId] uniqueidentifier NULL;
IF COL_LENGTH(N'dbo.AgentRegistrations', N'RequestedPurviewPolicyMode') IS NULL
    ALTER TABLE dbo.AgentRegistrations ADD [RequestedPurviewPolicyMode] nvarchar(32) NULL;

-- Preserve legacy Mode strings and exact readback evidence. No provider call or enforcement upgrade.
-- The additive JSON selection supports minCount, maxCount, minConfidence, maxConfidence.
-- Legacy rows intentionally retain absent thresholds (unknown), NEVER 1/-1/75/100 defaults.
-- Omitted legacy thresholds are blocked with PURVIEW_SIT_THRESHOLDS_REVIEW_REQUIRED.
-- Administrators may explicitly review a complete four-field replacement for every SIT.
-- Inventory is not rule evidence; only exact provider readback verifies the replacement.
EXEC(N'
IF EXISTS (SELECT 1 FROM dbo.PurviewDlpProfiles WHERE Mode NOT IN (N''Enforce'', N''AuditOnly''))
    THROW 50002, ''Unrecognized legacy Purview mode requires review.'', 1;
UPDATE dbo.PurviewDlpProfiles
SET PolicyMode = CASE Mode WHEN N''Enforce'' THEN N''Enforce'' ELSE N''SimulationWithoutTips'' END
WHERE PolicyMode IS NULL;
UPDATE profiles
SET SensitiveInformationTypesJson =
    (SELECT profiles.SensitiveInformationTypeId AS id,
            profiles.SensitiveInformationTypeName AS exactName FOR JSON PATH)
FROM dbo.PurviewDlpProfiles AS profiles
WHERE SensitiveInformationTypesJson = N''[]'';
');

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_PurviewDlpProfiles_PolicyModeCompatibility')
    EXEC(N'ALTER TABLE dbo.PurviewDlpProfiles WITH CHECK ADD CONSTRAINT [CK_PurviewDlpProfiles_PolicyModeCompatibility] CHECK
        ((Mode = N''Enforce'' AND PolicyMode = N''Enforce'') OR
         (Mode = N''AuditOnly'' AND PolicyMode IN (N''SimulationWithTips'', N''SimulationWithoutTips'', N''Disabled'')))');
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_PurviewDlpProfiles_SensitiveInformationTypesJson')
    EXEC(N'ALTER TABLE dbo.PurviewDlpProfiles WITH CHECK ADD CONSTRAINT [CK_PurviewDlpProfiles_SensitiveInformationTypesJson]
        CHECK (ISJSON(SensitiveInformationTypesJson) = 1 AND LEFT(LTRIM(SensitiveInformationTypesJson), 1) = N''['')');
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ProtectionAdminOperations_DeferredConfigurationJson')
    EXEC(N'ALTER TABLE dbo.ProtectionAdminOperations WITH CHECK ADD CONSTRAINT [CK_ProtectionAdminOperations_DeferredConfigurationJson]
        CHECK (DeferredConfigurationJson IS NULL OR ISJSON(DeferredConfigurationJson) = 1)');

-- KYD remains fixed Group scope; DLP remains unique per blueprint Individual/Application scope.
COMMIT TRANSACTION;
