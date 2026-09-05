SET XACT_ABORT ON;
BEGIN TRANSACTION;

DECLARE @LockResult int;
EXEC @LockResult = sys.sp_getapplock
    @Resource = N'A365Gateway:Migration:ProtectionGovernanceV1',
    @LockMode = N'Exclusive',
    @LockOwner = N'Transaction',
    @LockTimeout = 60000;

IF @LockResult < 0
BEGIN
    THROW 50000, 'Could not serialize the protection governance v1 migration; no data was changed.', 1;
END;

IF OBJECT_ID(N'dbo.PurviewPolicyProfiles', N'U') IS NULL
   OR OBJECT_ID(N'dbo.OutboxMessages', N'U') IS NULL
BEGIN
    THROW 50001, 'The legacy Purview profile or outbox prerequisite is missing; no data was changed.', 1;
END;

IF EXISTS
(
    SELECT 1
    FROM [dbo].[PurviewPolicyProfiles]
    WHERE ISJSON([BlueprintApplicationIdsJson]) <> 1
       OR LEFT(LTRIM([BlueprintApplicationIdsJson]), 1) <> N'['
       OR [Mode] NOT IN (N'AuditOnly', N'Enforce')
)
BEGIN
    THROW 50002, 'A legacy Purview profile is malformed and requires review; no data was changed.', 1;
END;

IF EXISTS
(
    SELECT 1
    FROM [dbo].[PurviewPolicyProfiles] AS profiles
    CROSS APPLY OPENJSON(profiles.[BlueprintApplicationIdsJson]) AS blueprints
    WHERE blueprints.[type] <> 1
       OR TRY_CONVERT(uniqueidentifier, blueprints.[value]) IS NULL
       OR TRY_CONVERT(uniqueidentifier, blueprints.[value]) =
            CONVERT(uniqueidentifier, N'00000000-0000-0000-0000-000000000000')
)
BEGIN
    THROW 50003, 'A legacy Purview blueprint list is not a GUID-only array and requires review; no data was changed.', 1;
END;

DECLARE @ExistingTargetTableCount int =
    IIF(OBJECT_ID(N'dbo.ProtectionCapabilities', N'U') IS NULL, 0, 1) +
    IIF(OBJECT_ID(N'dbo.PurviewTenantConnections', N'U') IS NULL, 0, 1) +
    IIF(OBJECT_ID(N'dbo.PurviewSensitiveInformationTypeSnapshotGenerations', N'U') IS NULL, 0, 1) +
    IIF(OBJECT_ID(N'dbo.PurviewSensitiveInformationTypeSnapshots', N'U') IS NULL, 0, 1) +
    IIF(OBJECT_ID(N'dbo.PurviewKnowYourDataConfigurations', N'U') IS NULL, 0, 1) +
    IIF(OBJECT_ID(N'dbo.PurviewDlpProfiles', N'U') IS NULL, 0, 1) +
    IIF(OBJECT_ID(N'dbo.LegacyProtectionPolicyCandidates', N'U') IS NULL, 0, 1) +
    IIF(OBJECT_ID(N'dbo.ProtectionAdminOperations', N'U') IS NULL, 0, 1) +
    IIF(OBJECT_ID(N'dbo.ProtectionAdminOperationSteps', N'U') IS NULL, 0, 1);

IF @ExistingTargetTableCount NOT IN (0, 9)
BEGIN
    THROW 50004, 'The protection governance schema is partial and requires review; no data was changed.', 1;
END;

IF @ExistingTargetTableCount = 9
   AND
   (
       COL_LENGTH(N'dbo.ProtectionCapabilities', N'ResourceIdentifiersJson') IS NULL
       OR COL_LENGTH(N'dbo.PurviewKnowYourDataConfigurations', N'GroupId') IS NULL
       OR COL_LENGTH(N'dbo.PurviewDlpProfiles', N'BlueprintApplicationId') IS NULL
       OR COL_LENGTH(N'dbo.LegacyProtectionPolicyCandidates', N'BindingStatus') IS NULL
       OR COL_LENGTH(N'dbo.ProtectionAdminOperations', N'AcceptedRequestHash') IS NULL
       OR COL_LENGTH(N'dbo.ProtectionAdminOperations', N'ResultJson') IS NULL
       OR COL_LENGTH(N'dbo.ProtectionAdminOperations', N'ConfirmationVerifierJson') IS NULL
       OR COL_LENGTH(N'dbo.ProtectionAdminOperationSteps', N'OrderIndex') IS NULL
   )
BEGIN
    THROW 50005, 'The existing protection governance schema is incompatible and requires review; no data was changed.', 1;
END;

IF @ExistingTargetTableCount = 0
BEGIN
    CREATE TABLE [dbo].[ProtectionCapabilities]
    (
        [Id] uniqueidentifier NOT NULL,
        [Kind] nvarchar(40) NOT NULL,
        [Status] nvarchar(32) NOT NULL,
        [ResourceIdentifiersJson] nvarchar(4000) NOT NULL,
        [LastReadbackAtUtc] datetime2 NULL,
        [LastFailureCode] nvarchar(64) NULL,
        [CreatedAtUtc] datetime2 NOT NULL,
        [UpdatedAtUtc] datetime2 NOT NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_ProtectionCapabilities] PRIMARY KEY ([Id])
    );
    CREATE UNIQUE INDEX [IX_ProtectionCapabilities_Kind]
        ON [dbo].[ProtectionCapabilities] ([Kind]);
    CREATE INDEX [IX_ProtectionCapabilities_Status]
        ON [dbo].[ProtectionCapabilities] ([Status]);

    CREATE TABLE [dbo].[PurviewTenantConnections]
    (
        [Id] uniqueidentifier NOT NULL,
        [TenantId] uniqueidentifier NOT NULL,
        [Status] nvarchar(32) NOT NULL,
        [AuthorityApplicationId] uniqueidentifier NULL,
        [AuthorityServicePrincipalObjectId] uniqueidentifier NULL,
        [AuthorityKind] nvarchar(64) NULL,
        [ActiveInventoryGenerationId] uniqueidentifier NULL,
        [AuthorizedAtUtc] datetime2 NULL,
        [ExpiresAtUtc] datetime2 NULL,
        [LastVerifiedAtUtc] datetime2 NULL,
        [LastFailureCode] nvarchar(64) NULL,
        [CreatedByObjectId] nvarchar(64) NOT NULL,
        [CreatedAtUtc] datetime2 NOT NULL,
        [UpdatedAtUtc] datetime2 NOT NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_PurviewTenantConnections] PRIMARY KEY ([Id])
    );
    CREATE UNIQUE INDEX [IX_PurviewTenantConnections_TenantId]
        ON [dbo].[PurviewTenantConnections] ([TenantId]);
    CREATE INDEX [IX_PurviewTenantConnections_Status]
        ON [dbo].[PurviewTenantConnections] ([Status]);
    CREATE UNIQUE INDEX [IX_PurviewTenantConnections_ActiveInventoryGenerationId]
        ON [dbo].[PurviewTenantConnections] ([ActiveInventoryGenerationId])
        WHERE [ActiveInventoryGenerationId] IS NOT NULL;

    CREATE TABLE [dbo].[PurviewSensitiveInformationTypeSnapshotGenerations]
    (
        [Id] uniqueidentifier NOT NULL,
        [PurviewTenantConnectionId] uniqueidentifier NOT NULL,
        [TenantId] uniqueidentifier NOT NULL,
        [RetrievedAtUtc] datetime2 NOT NULL,
        [ExpiresAtUtc] datetime2 NOT NULL,
        [ItemCount] int NOT NULL,
        [CreatedAtUtc] datetime2 NOT NULL,
        CONSTRAINT [PK_PurviewSensitiveInformationTypeSnapshotGenerations] PRIMARY KEY ([Id]),
        CONSTRAINT [CK_PurviewSitSnapshotGenerations_Expiration]
            CHECK ([ExpiresAtUtc] > [RetrievedAtUtc]),
        CONSTRAINT [CK_PurviewSitSnapshotGenerations_ItemCount]
            CHECK ([ItemCount] >= 0),
        CONSTRAINT [FK_PurviewSensitiveInformationTypeSnapshotGenerations_PurviewTenantConnections_PurviewTenantConnectionId]
            FOREIGN KEY ([PurviewTenantConnectionId])
            REFERENCES [dbo].[PurviewTenantConnections] ([Id])
            ON DELETE NO ACTION
    );
    CREATE INDEX [IX_PurviewSensitiveInformationTypeSnapshotGenerations_TenantId_RetrievedAtUtc]
        ON [dbo].[PurviewSensitiveInformationTypeSnapshotGenerations]
        ([TenantId], [RetrievedAtUtc] DESC);
    CREATE INDEX [IX_PurviewSensitiveInformationTypeSnapshotGenerations_PurviewTenantConnectionId]
        ON [dbo].[PurviewSensitiveInformationTypeSnapshotGenerations]
        ([PurviewTenantConnectionId]);
    ALTER TABLE [dbo].[PurviewTenantConnections] WITH CHECK
        ADD CONSTRAINT [FK_PurviewTenantConnections_PurviewSensitiveInformationTypeSnapshotGenerations_ActiveInventoryGenerationId]
        FOREIGN KEY ([ActiveInventoryGenerationId])
        REFERENCES [dbo].[PurviewSensitiveInformationTypeSnapshotGenerations] ([Id])
        ON DELETE NO ACTION;

    CREATE TABLE [dbo].[PurviewSensitiveInformationTypeSnapshots]
    (
        [Id] uniqueidentifier NOT NULL,
        [GenerationId] uniqueidentifier NOT NULL,
        [SensitiveInformationTypeId] uniqueidentifier NOT NULL,
        [ExactName] nvarchar(256) NOT NULL,
        [Publisher] nvarchar(256) NOT NULL,
        [SortOrder] int NOT NULL,
        CONSTRAINT [PK_PurviewSensitiveInformationTypeSnapshots] PRIMARY KEY ([Id]),
        CONSTRAINT [CK_PurviewSitSnapshots_SortOrder] CHECK ([SortOrder] >= 0),
        CONSTRAINT [FK_PurviewSensitiveInformationTypeSnapshots_PurviewSensitiveInformationTypeSnapshotGenerations_GenerationId]
            FOREIGN KEY ([GenerationId])
            REFERENCES [dbo].[PurviewSensitiveInformationTypeSnapshotGenerations] ([Id])
            ON DELETE CASCADE
    );
    CREATE UNIQUE INDEX [IX_PurviewSensitiveInformationTypeSnapshots_GenerationId_SensitiveInformationTypeId]
        ON [dbo].[PurviewSensitiveInformationTypeSnapshots]
        ([GenerationId], [SensitiveInformationTypeId]);
    CREATE UNIQUE INDEX [IX_PurviewSensitiveInformationTypeSnapshots_GenerationId_SortOrder]
        ON [dbo].[PurviewSensitiveInformationTypeSnapshots]
        ([GenerationId], [SortOrder]);

    CREATE TABLE [dbo].[PurviewKnowYourDataConfigurations]
    (
        [Id] uniqueidentifier NOT NULL,
        [PurviewTenantConnectionId] uniqueidentifier NOT NULL,
        [ScopeType] nvarchar(16) NOT NULL
            CONSTRAINT [DF_PurviewKyd_ScopeType] DEFAULT N'Group',
        [GroupId] uniqueidentifier NOT NULL
            CONSTRAINT [DF_PurviewKyd_GroupId]
            DEFAULT 'ee1680d0-702f-4090-b26c-c49091e86531',
        [EnforcementPlane] nvarchar(16) NOT NULL
            CONSTRAINT [DF_PurviewKyd_EnforcementPlane] DEFAULT N'Application',
        [InventoryGenerationId] uniqueidentifier NOT NULL,
        [SensitiveInformationTypeId] uniqueidentifier NOT NULL,
        [SensitiveInformationTypeName] nvarchar(256) NOT NULL,
        [Mode] nvarchar(16) NOT NULL,
        [ActivitiesJson] nvarchar(256) NOT NULL,
        [IngestionEnabled] bit NOT NULL,
        [Status] nvarchar(32) NOT NULL,
        [ReadbackStatus] nvarchar(24) NOT NULL,
        [CollectionPolicyProviderId] nvarchar(256) NULL,
        [LastReadbackAtUtc] datetime2 NULL,
        [LastFailureCode] nvarchar(64) NULL,
        [CreatedAtUtc] datetime2 NOT NULL,
        [UpdatedAtUtc] datetime2 NOT NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_PurviewKnowYourDataConfigurations] PRIMARY KEY ([Id]),
        CONSTRAINT [CK_PurviewKyd_ScopeType] CHECK ([ScopeType] = N'Group'),
        CONSTRAINT [CK_PurviewKyd_GroupId]
            CHECK ([GroupId] = 'ee1680d0-702f-4090-b26c-c49091e86531'),
        CONSTRAINT [CK_PurviewKyd_EnforcementPlane]
            CHECK ([EnforcementPlane] = N'Application'),
        CONSTRAINT [FK_PurviewKnowYourDataConfigurations_PurviewTenantConnections_PurviewTenantConnectionId]
            FOREIGN KEY ([PurviewTenantConnectionId])
            REFERENCES [dbo].[PurviewTenantConnections] ([Id])
            ON DELETE NO ACTION,
        CONSTRAINT [FK_PurviewKnowYourDataConfigurations_PurviewSensitiveInformationTypeSnapshotGenerations_InventoryGenerationId]
            FOREIGN KEY ([InventoryGenerationId])
            REFERENCES [dbo].[PurviewSensitiveInformationTypeSnapshotGenerations] ([Id])
            ON DELETE NO ACTION
    );
    CREATE UNIQUE INDEX [IX_PurviewKnowYourDataConfigurations_PurviewTenantConnectionId]
        ON [dbo].[PurviewKnowYourDataConfigurations] ([PurviewTenantConnectionId]);
    CREATE INDEX [IX_PurviewKnowYourDataConfigurations_CollectionPolicyProviderId]
        ON [dbo].[PurviewKnowYourDataConfigurations] ([CollectionPolicyProviderId])
        WHERE [CollectionPolicyProviderId] IS NOT NULL;
    CREATE INDEX [IX_PurviewKnowYourDataConfigurations_InventoryGenerationId]
        ON [dbo].[PurviewKnowYourDataConfigurations] ([InventoryGenerationId]);
    CREATE INDEX [IX_PurviewKnowYourDataConfigurations_Status]
        ON [dbo].[PurviewKnowYourDataConfigurations] ([Status]);

    CREATE TABLE [dbo].[PurviewDlpProfiles]
    (
        [Id] uniqueidentifier NOT NULL,
        [PurviewTenantConnectionId] uniqueidentifier NOT NULL,
        [BlueprintApplicationId] uniqueidentifier NOT NULL,
        [DisplayName] nvarchar(200) NOT NULL,
        [InventoryGenerationId] uniqueidentifier NOT NULL,
        [SensitiveInformationTypeSnapshotExpiresAtUtc] datetime2 NOT NULL,
        [SensitiveInformationTypeId] uniqueidentifier NOT NULL,
        [SensitiveInformationTypeName] nvarchar(256) NOT NULL,
        [Mode] nvarchar(16) NOT NULL,
        [ActivitiesJson] nvarchar(256) NOT NULL,
        [ActionsJson] nvarchar(1024) NOT NULL,
        [ScopeType] nvarchar(16) NOT NULL
            CONSTRAINT [DF_PurviewDlpProfiles_ScopeType] DEFAULT N'Individual',
        [EnforcementPlane] nvarchar(16) NOT NULL
            CONSTRAINT [DF_PurviewDlpProfiles_EnforcementPlane] DEFAULT N'Application',
        [Status] nvarchar(32) NOT NULL,
        [ReadinessJson] nvarchar(512) NOT NULL,
        [DlpPolicyProviderId] nvarchar(256) NULL,
        [DlpRuleProviderId] nvarchar(256) NULL,
        [LastReadbackAtUtc] datetime2 NULL,
        [PropagationVerifiedAtUtc] datetime2 NULL,
        [TokenRolesVerifiedAtUtc] datetime2 NULL,
        [RuntimeAllowVerifiedAtUtc] datetime2 NULL,
        [RuntimeBlockVerifiedAtUtc] datetime2 NULL,
        [LastFailureCode] nvarchar(64) NULL,
        [CreatedAtUtc] datetime2 NOT NULL,
        [UpdatedAtUtc] datetime2 NOT NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_PurviewDlpProfiles] PRIMARY KEY ([Id]),
        CONSTRAINT [CK_PurviewDlpProfiles_ScopeType]
            CHECK ([ScopeType] = N'Individual'),
        CONSTRAINT [CK_PurviewDlpProfiles_EnforcementPlane]
            CHECK ([EnforcementPlane] = N'Application'),
        CONSTRAINT [FK_PurviewDlpProfiles_PurviewTenantConnections_PurviewTenantConnectionId]
            FOREIGN KEY ([PurviewTenantConnectionId])
            REFERENCES [dbo].[PurviewTenantConnections] ([Id])
            ON DELETE NO ACTION,
        CONSTRAINT [FK_PurviewDlpProfiles_PurviewSensitiveInformationTypeSnapshotGenerations_InventoryGenerationId]
            FOREIGN KEY ([InventoryGenerationId])
            REFERENCES [dbo].[PurviewSensitiveInformationTypeSnapshotGenerations] ([Id])
            ON DELETE NO ACTION
    );
    CREATE UNIQUE INDEX [IX_PurviewDlpProfiles_BlueprintApplicationId]
        ON [dbo].[PurviewDlpProfiles] ([BlueprintApplicationId]);
    CREATE INDEX [IX_PurviewDlpProfiles_DlpPolicyProviderId]
        ON [dbo].[PurviewDlpProfiles] ([DlpPolicyProviderId])
        WHERE [DlpPolicyProviderId] IS NOT NULL;
    CREATE INDEX [IX_PurviewDlpProfiles_DlpRuleProviderId]
        ON [dbo].[PurviewDlpProfiles] ([DlpRuleProviderId])
        WHERE [DlpRuleProviderId] IS NOT NULL;
    CREATE INDEX [IX_PurviewDlpProfiles_PurviewTenantConnectionId]
        ON [dbo].[PurviewDlpProfiles] ([PurviewTenantConnectionId]);
    CREATE INDEX [IX_PurviewDlpProfiles_InventoryGenerationId]
        ON [dbo].[PurviewDlpProfiles] ([InventoryGenerationId]);
    CREATE INDEX [IX_PurviewDlpProfiles_Status]
        ON [dbo].[PurviewDlpProfiles] ([Status]);

    CREATE TABLE [dbo].[LegacyProtectionPolicyCandidates]
    (
        [Id] uniqueidentifier NOT NULL,
        [LegacySourceProfileId] uniqueidentifier NOT NULL,
        [CandidateKind] nvarchar(32) NOT NULL,
        [BindingStatus] nvarchar(16) NOT NULL
            CONSTRAINT [DF_LegacyProtectionPolicyCandidates_BindingStatus]
            DEFAULT N'Unbound',
        [ReviewStatus] nvarchar(32) NOT NULL
            CONSTRAINT [DF_LegacyProtectionPolicyCandidates_ReviewStatus]
            DEFAULT N'ReviewRequired',
        [BlueprintApplicationId] uniqueidentifier NULL,
        [ScopeType] nvarchar(16) NOT NULL,
        [LocationId] uniqueidentifier NOT NULL,
        [EnforcementPlane] nvarchar(16) NOT NULL
            CONSTRAINT [DF_LegacyProtectionPolicyCandidates_EnforcementPlane]
            DEFAULT N'Application',
        [DisplayName] nvarchar(200) NOT NULL,
        [LegacyTemplate] nvarchar(64) NOT NULL,
        [Mode] nvarchar(32) NOT NULL,
        [LegacyStatus] nvarchar(32) NOT NULL,
        [CollectionPolicyProviderId] nvarchar(256) NULL,
        [DlpPolicyProviderId] nvarchar(256) NULL,
        [DlpRuleProviderId] nvarchar(256) NULL,
        [LegacyVerifiedAtUtc] datetime2 NULL,
        [LegacyFailureCode] nvarchar(64) NULL,
        [CreatedByObjectId] nvarchar(64) NOT NULL,
        [CreatedAtUtc] datetime2 NOT NULL,
        [UpdatedAtUtc] datetime2 NOT NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_LegacyProtectionPolicyCandidates] PRIMARY KEY ([Id]),
        CONSTRAINT [CK_LegacyProtectionPolicyCandidates_BindingStatus]
            CHECK ([BindingStatus] = N'Unbound'),
        CONSTRAINT [CK_LegacyProtectionPolicyCandidates_ReviewStatus]
            CHECK ([ReviewStatus] = N'ReviewRequired'),
        CONSTRAINT [CK_LegacyProtectionPolicyCandidates_EnforcementPlane]
            CHECK ([EnforcementPlane] = N'Application'),
        CONSTRAINT [CK_LegacyProtectionPolicyCandidates_Scope]
            CHECK
            (
                (
                    [CandidateKind] = N'KnowYourData'
                    AND [ScopeType] = N'Group'
                    AND [BlueprintApplicationId] IS NULL
                    AND [LocationId] =
                        'ee1680d0-702f-4090-b26c-c49091e86531'
                )
                OR
                (
                    [CandidateKind] = N'DlpProfile'
                    AND [ScopeType] = N'Individual'
                    AND [BlueprintApplicationId] IS NOT NULL
                    AND [LocationId] = [BlueprintApplicationId]
                )
            ),
        CONSTRAINT [FK_LegacyProtectionPolicyCandidates_PurviewPolicyProfiles_LegacySourceProfileId]
            FOREIGN KEY ([LegacySourceProfileId])
            REFERENCES [dbo].[PurviewPolicyProfiles] ([Id])
            ON DELETE NO ACTION
    );
    CREATE UNIQUE INDEX [IX_LegacyProtectionPolicyCandidates_LegacySourceProfileId_CandidateKind_LocationId]
        ON [dbo].[LegacyProtectionPolicyCandidates]
        ([LegacySourceProfileId], [CandidateKind], [LocationId]);
    CREATE INDEX [IX_LegacyProtectionPolicyCandidates_BlueprintApplicationId]
        ON [dbo].[LegacyProtectionPolicyCandidates] ([BlueprintApplicationId])
        WHERE [BlueprintApplicationId] IS NOT NULL;
    CREATE INDEX [IX_LegacyProtectionPolicyCandidates_BindingStatus_ReviewStatus]
        ON [dbo].[LegacyProtectionPolicyCandidates] ([BindingStatus], [ReviewStatus]);

    CREATE TABLE [dbo].[ProtectionAdminOperations]
    (
        [Id] uniqueidentifier NOT NULL,
        [WorkflowVersion] int NOT NULL
            CONSTRAINT [DF_ProtectionAdminOperations_WorkflowVersion] DEFAULT 1,
        [Type] nvarchar(48) NOT NULL,
        [Status] nvarchar(40) NOT NULL,
        [TenantId] uniqueidentifier NOT NULL,
        [ActorObjectId] nvarchar(64) NOT NULL,
        [TargetType] nvarchar(48) NOT NULL,
        [TargetIdentifier] nvarchar(256) NOT NULL,
        [ReviewedPayloadHash] nvarchar(71) NOT NULL,
        [AcceptedRequestHash] nvarchar(71) NULL,
        [ResultJson] nvarchar(4000) NULL,
        [IdempotencyKey] uniqueidentifier NOT NULL,
        [ExpectedRowVersion] varbinary(8) NOT NULL,
        [ConfirmationVerifierJson] nvarchar(2048) NULL,
        [RetryDisposition] nvarchar(40) NOT NULL,
        [AttemptCount] int NOT NULL,
        [MaximumAttempts] int NOT NULL,
        [NextAttemptAtUtc] datetime2 NULL,
        [CorrelationId] uniqueidentifier NOT NULL,
        [ReadbackReferenceId] uniqueidentifier NULL,
        [LastFailureCode] nvarchar(64) NULL,
        [RequiredAction] nvarchar(512) NULL,
        [CreatedAtUtc] datetime2 NOT NULL,
        [StartedAtUtc] datetime2 NULL,
        [CompletedAtUtc] datetime2 NULL,
        [UpdatedAtUtc] datetime2 NOT NULL,
        [RowVersion] rowversion NOT NULL,
        CONSTRAINT [PK_ProtectionAdminOperations] PRIMARY KEY ([Id]),
        CONSTRAINT [CK_ProtectionAdminOperations_Attempts]
            CHECK ([AttemptCount] >= 0 AND [MaximumAttempts] > 0 AND [AttemptCount] <= [MaximumAttempts]),
        CONSTRAINT [CK_ProtectionAdminOperations_WorkflowVersion]
            CHECK ([WorkflowVersion] = 1)
    );
    CREATE UNIQUE INDEX [IX_ProtectionAdminOperations_TenantId_IdempotencyKey]
        ON [dbo].[ProtectionAdminOperations] ([TenantId], [IdempotencyKey]);
    CREATE UNIQUE INDEX [IX_ProtectionAdminOperations_CorrelationId]
        ON [dbo].[ProtectionAdminOperations] ([CorrelationId]);
    CREATE INDEX [IX_ProtectionAdminOperations_Status_NextAttemptAtUtc]
        ON [dbo].[ProtectionAdminOperations] ([Status], [NextAttemptAtUtc])
        WHERE [Status] IN (N'Pending', N'Running', N'PendingPropagation');

    CREATE TABLE [dbo].[ProtectionAdminOperationSteps]
    (
        [Id] uniqueidentifier NOT NULL,
        [ProtectionAdminOperationId] uniqueidentifier NOT NULL,
        [StepType] nvarchar(40) NOT NULL,
        [Status] nvarchar(40) NOT NULL,
        [OrderIndex] int NOT NULL,
        [AttemptCount] int NOT NULL,
        [RetryDisposition] nvarchar(40) NOT NULL,
        [NextAttemptAtUtc] datetime2 NULL,
        [ReadbackReferenceId] uniqueidentifier NULL,
        [FailureCode] nvarchar(64) NULL,
        [StartedAtUtc] datetime2 NULL,
        [CompletedAtUtc] datetime2 NULL,
        CONSTRAINT [PK_ProtectionAdminOperationSteps] PRIMARY KEY ([Id]),
        CONSTRAINT [CK_ProtectionAdminOperationSteps_OrderIndex]
            CHECK ([OrderIndex] >= 0),
        CONSTRAINT [CK_ProtectionAdminOperationSteps_AttemptCount]
            CHECK ([AttemptCount] >= 0),
        CONSTRAINT [FK_ProtectionAdminOperationSteps_ProtectionAdminOperations_ProtectionAdminOperationId]
            FOREIGN KEY ([ProtectionAdminOperationId])
            REFERENCES [dbo].[ProtectionAdminOperations] ([Id])
            ON DELETE CASCADE
    );
    CREATE UNIQUE INDEX [IX_ProtectionAdminOperationSteps_ProtectionAdminOperationId_OrderIndex]
        ON [dbo].[ProtectionAdminOperationSteps]
        ([ProtectionAdminOperationId], [OrderIndex]);
    CREATE INDEX [IX_ProtectionAdminOperationSteps_Status_NextAttemptAtUtc]
        ON [dbo].[ProtectionAdminOperationSteps] ([Status], [NextAttemptAtUtc])
        WHERE [Status] IN (N'Pending', N'Running', N'PendingPropagation');
END;

IF COL_LENGTH(N'dbo.OutboxMessages', N'Destination') IS NULL
BEGIN
    ALTER TABLE [dbo].[OutboxMessages]
        ADD [Destination] nvarchar(128) NOT NULL
            CONSTRAINT [DF_OutboxMessages_Destination]
            DEFAULT N'gateway-provisioning-v3' WITH VALUES;
END;
ELSE IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[columns]
    WHERE [object_id] = OBJECT_ID(N'dbo.OutboxMessages', N'U')
      AND [name] = N'Destination'
      AND [is_nullable] = 0
      AND [max_length] = 256
)
BEGIN
    THROW 50006, 'The existing outbox destination column is incompatible; no data was changed.', 1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM [sys].[indexes]
    WHERE [object_id] = OBJECT_ID(N'dbo.OutboxMessages', N'U')
      AND [name] = N'IX_OutboxMessages_Destination_Status_NextRetryAtUtc'
)
BEGIN
    CREATE INDEX [IX_OutboxMessages_Destination_Status_NextRetryAtUtc]
        ON [dbo].[OutboxMessages] ([Destination], [Status], [NextRetryAtUtc])
        WHERE [Status] IN ('Pending', 'Processing');
END;

-- Legacy combined rows are retained unchanged. Migration records only
-- tenantless Unbound/ReviewRequired evidence candidates and performs no provider
-- mutation. A later reviewed API flow creates exact real-tenant active records;
-- these retained candidates never become active policy authority.
INSERT INTO [dbo].[LegacyProtectionPolicyCandidates]
(
    [Id], [LegacySourceProfileId], [CandidateKind], [BindingStatus],
    [ReviewStatus], [BlueprintApplicationId], [ScopeType], [LocationId],
    [EnforcementPlane], [DisplayName], [LegacyTemplate], [Mode],
    [LegacyStatus], [CollectionPolicyProviderId], [DlpPolicyProviderId],
    [DlpRuleProviderId], [LegacyVerifiedAtUtc], [LegacyFailureCode],
    [CreatedByObjectId], [CreatedAtUtc], [UpdatedAtUtc]
)
SELECT
    NEWID(), profiles.[Id], N'KnowYourData', N'Unbound',
    N'ReviewRequired', NULL, N'Group',
    CONVERT(uniqueidentifier, N'ee1680d0-702f-4090-b26c-c49091e86531'),
    N'Application', profiles.[DisplayName], profiles.[Template], profiles.[Mode],
    profiles.[Status], profiles.[CollectionPolicyId], NULL, NULL,
    profiles.[VerifiedAtUtc], profiles.[LastErrorCode],
    profiles.[CreatedByObjectId], profiles.[CreatedAtUtc], profiles.[UpdatedAtUtc]
FROM [dbo].[PurviewPolicyProfiles] AS profiles
WHERE NOT EXISTS
(
    SELECT 1
    FROM [dbo].[LegacyProtectionPolicyCandidates] AS candidates
    WHERE candidates.[LegacySourceProfileId] = profiles.[Id]
      AND candidates.[CandidateKind] = N'KnowYourData'
      AND candidates.[LocationId] =
            CONVERT(uniqueidentifier, N'ee1680d0-702f-4090-b26c-c49091e86531')
);

INSERT INTO [dbo].[LegacyProtectionPolicyCandidates]
(
    [Id], [LegacySourceProfileId], [CandidateKind], [BindingStatus],
    [ReviewStatus], [BlueprintApplicationId], [ScopeType], [LocationId],
    [EnforcementPlane], [DisplayName], [LegacyTemplate], [Mode],
    [LegacyStatus], [CollectionPolicyProviderId], [DlpPolicyProviderId],
    [DlpRuleProviderId], [LegacyVerifiedAtUtc], [LegacyFailureCode],
    [CreatedByObjectId], [CreatedAtUtc], [UpdatedAtUtc]
)
SELECT
    NEWID(), profiles.[Id], N'DlpProfile', N'Unbound',
    N'ReviewRequired', blueprints.[BlueprintApplicationId], N'Individual',
    blueprints.[BlueprintApplicationId], N'Application',
    profiles.[DisplayName], profiles.[Template], profiles.[Mode],
    profiles.[Status], NULL, profiles.[DlpPolicyId], profiles.[DlpRuleId],
    profiles.[VerifiedAtUtc], profiles.[LastErrorCode],
    profiles.[CreatedByObjectId], profiles.[CreatedAtUtc], profiles.[UpdatedAtUtc]
FROM [dbo].[PurviewPolicyProfiles] AS profiles
CROSS APPLY
(
    SELECT DISTINCT
        TRY_CONVERT(uniqueidentifier, values_by_blueprint.[value])
            AS [BlueprintApplicationId]
    FROM OPENJSON(profiles.[BlueprintApplicationIdsJson]) AS values_by_blueprint
) AS blueprints
WHERE NOT EXISTS
(
    SELECT 1
    FROM [dbo].[LegacyProtectionPolicyCandidates] AS candidates
    WHERE candidates.[LegacySourceProfileId] = profiles.[Id]
      AND candidates.[CandidateKind] = N'DlpProfile'
      AND candidates.[LocationId] = blueprints.[BlueprintApplicationId]
);

COMMIT TRANSACTION;
