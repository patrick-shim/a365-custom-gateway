SET XACT_ABORT ON;
BEGIN TRANSACTION;

DECLARE @LockResult int;
EXEC @LockResult = sys.sp_getapplock
    @Resource = N'A365Gateway:Migration:PromptReceiptProtectionContext',
    @LockMode = N'Exclusive',
    @LockOwner = N'Transaction',
    @LockTimeout = 60000;
IF @LockResult < 0
    THROW 50000, 'Could not serialize prompt receipt protection context migration; no data was changed.', 1;

IF OBJECT_ID(N'dbo.AgentRegistrations', N'U') IS NULL
   OR OBJECT_ID(N'dbo.PromptEvaluationRecords', N'U') IS NULL
   OR COL_LENGTH(N'dbo.PurviewDlpProfiles', N'PolicyMode') IS NULL
    THROW 50001, 'Prompt protection and Purview configuration intent schemas are required; no data was changed.', 1;

IF COL_LENGTH(N'dbo.AgentRegistrations', N'ProtectionRevision') IS NULL
    ALTER TABLE dbo.AgentRegistrations ADD [ProtectionRevision] uniqueidentifier NOT NULL
        CONSTRAINT DF_AgentRegistrations_ProtectionRevision DEFAULT NEWID() WITH VALUES;
IF COL_LENGTH(N'dbo.PromptEvaluationRecords', N'ProtectionRevision') IS NULL
    ALTER TABLE dbo.PromptEvaluationRecords ADD [ProtectionRevision] uniqueidentifier NULL;
IF COL_LENGTH(N'dbo.PromptEvaluationRecords', N'ProtectionContextHash') IS NULL
    ALTER TABLE dbo.PromptEvaluationRecords ADD [ProtectionContextHash] varchar(64) NULL;
IF COL_LENGTH(N'dbo.PromptEvaluationRecords', N'PromptShieldRequired') IS NULL
    ALTER TABLE dbo.PromptEvaluationRecords ADD [PromptShieldRequired] bit NULL;
IF COL_LENGTH(N'dbo.PromptEvaluationRecords', N'EvaluatedPurviewPolicyMode') IS NULL
    ALTER TABLE dbo.PromptEvaluationRecords ADD [EvaluatedPurviewPolicyMode] nvarchar(32) NULL;

-- Historical receipts deliberately remain unbound. Never manufacture protection evidence during upgrade.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_AgentRegistrations_ProtectionRevision')
    EXEC(N'ALTER TABLE dbo.AgentRegistrations WITH CHECK ADD CONSTRAINT [CK_AgentRegistrations_ProtectionRevision]
        CHECK ([ProtectionRevision] <> ''00000000-0000-0000-0000-000000000000'')');
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_PromptEvaluationRecords_ProtectionBinding')
    EXEC(N'ALTER TABLE dbo.PromptEvaluationRecords WITH CHECK ADD CONSTRAINT [CK_PromptEvaluationRecords_ProtectionBinding] CHECK
        (([ProtectionRevision] IS NULL AND [ProtectionContextHash] IS NULL AND [PromptShieldRequired] IS NULL AND [EvaluatedPurviewPolicyMode] IS NULL) OR
         ([ProtectionRevision] IS NOT NULL AND [ProtectionRevision] <> ''00000000-0000-0000-0000-000000000000'' AND
          [ProtectionContextHash] IS NOT NULL AND DATALENGTH([ProtectionContextHash]) = 64 AND
          [ProtectionContextHash] COLLATE Latin1_General_100_BIN2 NOT LIKE ''%[^0-9a-f]%'' AND [PromptShieldRequired] IS NOT NULL AND
          [EvaluatedPurviewPolicyMode] IS NOT NULL AND [EvaluatedPurviewPolicyMode] IN (N''Disabled'', N''SimulationWithTips'', N''SimulationWithoutTips'', N''Enforce'') AND
          ([Outcome] <> N''Allowed'' OR (([PromptShieldRequired] = 0 OR [PromptShieldDecision] = N''Allowed'') AND
           ([EvaluatedPurviewPolicyMode] <> N''Enforce'' OR [PurviewDecision] = N''Allowed'')))))');

COMMIT TRANSACTION;
