SET XACT_ABORT ON;
BEGIN TRANSACTION;

DECLARE @LockResult int;
EXEC @LockResult = sys.sp_getapplock
    @Resource = N'A365Gateway:Migration:PurviewRuntimeTests',
    @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 60000;
IF @LockResult < 0
    THROW 50000, 'Could not serialize Purview runtime test migration; no data was changed.', 1;
IF OBJECT_ID(N'dbo.ProtectionAdminOperations', N'U') IS NULL
   OR COL_LENGTH(N'dbo.PurviewDlpProfiles', N'SensitiveInformationTypesJson') IS NULL
    THROW 50001, 'Purview configuration intent migration is required; no data was changed.', 1;

DECLARE @NewProofSchema bit = CASE
    WHEN COL_LENGTH(N'dbo.PurviewDlpProfiles', N'RuntimeBehaviorSuiteHash') IS NULL
      OR COL_LENGTH(N'dbo.PurviewDlpProfiles', N'RuntimeBehaviorCertificationOperationId') IS NULL
    THEN 1 ELSE 0 END;
IF COL_LENGTH(N'dbo.ProtectionAdminOperations', N'RuntimeTestConsentJson') IS NULL
    ALTER TABLE dbo.ProtectionAdminOperations ADD [RuntimeTestConsentJson] nvarchar(max) NULL;
IF COL_LENGTH(N'dbo.ProtectionAdminOperations', N'RuntimeTestResultJson') IS NULL
    ALTER TABLE dbo.ProtectionAdminOperations ADD [RuntimeTestResultJson] nvarchar(max) NULL;
IF COL_LENGTH(N'dbo.ProtectionAdminOperations', N'RuntimeTestSuiteHash') IS NULL
    ALTER TABLE dbo.ProtectionAdminOperations ADD [RuntimeTestSuiteHash] nvarchar(71) NULL;
IF COL_LENGTH(N'dbo.ProtectionAdminOperations', N'RuntimeTestConfigurationFingerprint') IS NULL
    ALTER TABLE dbo.ProtectionAdminOperations ADD [RuntimeTestConfigurationFingerprint] nvarchar(71) NULL;
IF COL_LENGTH(N'dbo.PurviewDlpProfiles', N'RuntimeBehaviorSuiteHash') IS NULL
    ALTER TABLE dbo.PurviewDlpProfiles ADD [RuntimeBehaviorSuiteHash] nvarchar(71) NULL;
IF COL_LENGTH(N'dbo.PurviewDlpProfiles', N'RuntimeBehaviorVerifiedUntilUtc') IS NULL
    ALTER TABLE dbo.PurviewDlpProfiles ADD [RuntimeBehaviorVerifiedUntilUtc] datetime2 NULL;
IF COL_LENGTH(N'dbo.PurviewDlpProfiles', N'RuntimeBehaviorCertificationOperationId') IS NULL
    ALTER TABLE dbo.PurviewDlpProfiles ADD [RuntimeBehaviorCertificationOperationId] uniqueidentifier NULL;

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ProtectionAdminOperations_RuntimeTestConsent')
    EXEC(N'ALTER TABLE dbo.ProtectionAdminOperations WITH CHECK ADD CONSTRAINT [CK_ProtectionAdminOperations_RuntimeTestConsent]
        CHECK (RuntimeTestConsentJson IS NULL OR (ISJSON(RuntimeTestConsentJson) = 1 AND DATALENGTH(RuntimeTestConsentJson) <= 524288))');
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ProtectionAdminOperations_RuntimeTestResult')
    EXEC(N'ALTER TABLE dbo.ProtectionAdminOperations WITH CHECK ADD CONSTRAINT [CK_ProtectionAdminOperations_RuntimeTestResult]
        CHECK (RuntimeTestResultJson IS NULL OR (ISJSON(RuntimeTestResultJson) = 1 AND DATALENGTH(RuntimeTestResultJson) <= 131072))');
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.ProtectionAdminOperations') AND name = N'IX_ProtectionAdminOperations_RuntimeTestSuite')
    EXEC(N'CREATE INDEX [IX_ProtectionAdminOperations_RuntimeTestSuite] ON dbo.ProtectionAdminOperations
        (RuntimeTestConfigurationFingerprint, RuntimeTestSuiteHash, StartedAtUtc)
        WHERE [Type] = N''TestDlpRuntime'' AND RuntimeTestSuiteHash IS NOT NULL');

-- A legacy fixed-card probe is not a reviewed arbitrary-SIT suite. Require fresh approval,
-- without changing provider policy, selected thresholds, registration, or non-enforcing modes.
IF @NewProofSchema = 1
    EXEC(N'UPDATE dbo.PurviewDlpProfiles SET RuntimeAllowVerifiedAtUtc = NULL,
        RuntimeBlockVerifiedAtUtc = NULL, RuntimeBehaviorSuiteHash = NULL,
        RuntimeBehaviorVerifiedUntilUtc = NULL, RuntimeBehaviorCertificationOperationId = NULL, Status = N''PendingPropagation'',
        ReadinessJson = JSON_MODIFY(ReadinessJson, ''$.runtimeVerdict'', ''NotChecked''),
        LastFailureCode = N''PURVIEW_RUNTIME_SAMPLES_REQUIRED''
        WHERE Mode = N''Enforce''');
COMMIT TRANSACTION;
