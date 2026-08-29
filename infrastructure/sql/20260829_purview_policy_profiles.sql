SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.PurviewPolicyProfiles', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[PurviewPolicyProfiles]
    (
        [Id] uniqueidentifier NOT NULL,
        [DisplayName] nvarchar(200) NOT NULL,
        [Template] nvarchar(64) NOT NULL,
        [Mode] nvarchar(32) NOT NULL,
        [Status] nvarchar(32) NOT NULL,
        [CollectionPolicyName] nvarchar(200) NOT NULL,
        [DlpPolicyName] nvarchar(200) NOT NULL,
        [DlpRuleName] nvarchar(200) NOT NULL,
        [CollectionPolicyId] nvarchar(256) NULL,
        [DlpPolicyId] nvarchar(256) NULL,
        [DlpRuleId] nvarchar(256) NULL,
        [BlueprintApplicationIdsJson] nvarchar(8000) NOT NULL,
        [VerifiedAtUtc] datetime2 NULL,
        [LastErrorCode] nvarchar(64) NULL,
        [CreatedAtUtc] datetime2 NOT NULL,
        [CreatedByObjectId] nvarchar(64) NOT NULL,
        [UpdatedAtUtc] datetime2 NOT NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_PurviewPolicyProfiles] PRIMARY KEY ([Id])
    );
    CREATE UNIQUE INDEX [IX_PurviewPolicyProfiles_DisplayName]
        ON [dbo].[PurviewPolicyProfiles] ([DisplayName]);
    CREATE INDEX [IX_PurviewPolicyProfiles_Status]
        ON [dbo].[PurviewPolicyProfiles] ([Status]);
END;

IF COL_LENGTH(N'dbo.AgentRegistrations', N'PurviewPolicySelectionMode') IS NULL
    ALTER TABLE [dbo].[AgentRegistrations] ADD [PurviewPolicySelectionMode] nvarchar(32) NOT NULL
        CONSTRAINT [DF_AgentRegistrations_PurviewPolicySelectionMode] DEFAULT N'NotRequested';
IF COL_LENGTH(N'dbo.AgentRegistrations', N'RequestedPurviewPolicyProfileId') IS NULL
    ALTER TABLE [dbo].[AgentRegistrations] ADD [RequestedPurviewPolicyProfileId] uniqueidentifier NULL;
IF COL_LENGTH(N'dbo.AgentRegistrations', N'RequestedPurviewPolicyDisplayName') IS NULL
    ALTER TABLE [dbo].[AgentRegistrations] ADD [RequestedPurviewPolicyDisplayName] nvarchar(200) NULL;
IF COL_LENGTH(N'dbo.AgentRegistrations', N'RequestedPurviewPolicyTemplate') IS NULL
    ALTER TABLE [dbo].[AgentRegistrations] ADD [RequestedPurviewPolicyTemplate] nvarchar(64) NULL;
IF COL_LENGTH(N'dbo.AgentRegistrations', N'PurviewPolicyProfileId') IS NULL
    ALTER TABLE [dbo].[AgentRegistrations] ADD [PurviewPolicyProfileId] uniqueidentifier NULL;
IF COL_LENGTH(N'dbo.AgentRegistrations', N'PurviewPolicyAssignmentVerifiedAtUtc') IS NULL
    ALTER TABLE [dbo].[AgentRegistrations] ADD [PurviewPolicyAssignmentVerifiedAtUtc] datetime2 NULL;

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE [name] = N'FK_AgentRegistrations_PurviewPolicyProfiles_PurviewPolicyProfileId')
BEGIN
    ALTER TABLE [dbo].[AgentRegistrations] WITH CHECK ADD CONSTRAINT
        [FK_AgentRegistrations_PurviewPolicyProfiles_PurviewPolicyProfileId]
        FOREIGN KEY ([PurviewPolicyProfileId]) REFERENCES [dbo].[PurviewPolicyProfiles] ([Id]);
END;

COMMIT TRANSACTION;
