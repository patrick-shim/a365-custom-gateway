SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF COL_LENGTH(N'dbo.AgentRegistrations', N'BlueprintSelectionMode') IS NULL
BEGIN
    ALTER TABLE [dbo].[AgentRegistrations]
        ADD [BlueprintSelectionMode] nvarchar(32) NOT NULL
            CONSTRAINT [DF_AgentRegistrations_BlueprintSelectionMode]
            DEFAULT N'Legacy' WITH VALUES;
END;

IF COL_LENGTH(N'dbo.AgentRegistrations', N'AgentIdentityObjectId') IS NULL
BEGIN
    ALTER TABLE [dbo].[AgentRegistrations]
        ADD [AgentIdentityObjectId] nvarchar(64) NULL;
END;

IF COL_LENGTH(N'dbo.AgentRegistrations', N'BlueprintObjectId') IS NULL
BEGIN
    ALTER TABLE [dbo].[AgentRegistrations]
        ADD [BlueprintObjectId] nvarchar(64) NULL;
END;

IF COL_LENGTH(N'dbo.AgentRegistrations', N'RequestedBlueprintObjectId') IS NULL
BEGIN
    ALTER TABLE [dbo].[AgentRegistrations]
        ADD [RequestedBlueprintObjectId] nvarchar(64) NULL;
END;

IF COL_LENGTH(N'dbo.AgentRegistrations', N'RequestedBlueprintDisplayName') IS NULL
BEGIN
    ALTER TABLE [dbo].[AgentRegistrations]
        ADD [RequestedBlueprintDisplayName] nvarchar(256) NULL;
END;

IF COL_LENGTH(N'dbo.ProvisioningJobs', N'WorkflowVersion') IS NULL
BEGIN
    ALTER TABLE [dbo].[ProvisioningJobs]
        ADD [WorkflowVersion] int NOT NULL
            CONSTRAINT [DF_ProvisioningJobs_WorkflowVersion]
            DEFAULT 1 WITH VALUES;
END;

COMMIT TRANSACTION;
