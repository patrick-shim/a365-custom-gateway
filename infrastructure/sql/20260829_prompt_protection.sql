SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF COL_LENGTH('dbo.AgentFeatureConfigurations', 'PromptShieldEnabled') IS NULL
BEGIN
    ALTER TABLE dbo.AgentFeatureConfigurations
        ADD PromptShieldEnabled bit NOT NULL
            CONSTRAINT DF_AgentFeatureConfigurations_PromptShieldEnabled DEFAULT (0);
END;

IF COL_LENGTH('dbo.SystemConfigurations', 'DefaultPromptShieldEnabled') IS NULL
BEGIN
    ALTER TABLE dbo.SystemConfigurations
        ADD DefaultPromptShieldEnabled bit NOT NULL
            CONSTRAINT DF_SystemConfigurations_DefaultPromptShieldEnabled DEFAULT (0);
END;

IF OBJECT_ID('dbo.PromptEvaluationRecords', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PromptEvaluationRecords
    (
        Id uniqueidentifier NOT NULL,
        AgentRegistrationId uniqueidentifier NOT NULL,
        ExternalInteractionId nvarchar(256) NOT NULL,
        TenantUserObjectId nvarchar(36) NOT NULL,
        PromptHashSalt varbinary(32) NOT NULL,
        PromptHash varbinary(32) NOT NULL,
        Outcome nvarchar(20) NOT NULL,
        PromptShieldDecision nvarchar(20) NOT NULL,
        PurviewDecision nvarchar(40) NOT NULL,
        CorrelationId nvarchar(64) NOT NULL,
        CreatedAtUtc datetime2 NOT NULL,
        ExpiresAtUtc datetime2 NOT NULL,
        ConsumedAtUtc datetime2 NULL,
        RowVersion rowversion NOT NULL,
        CONSTRAINT PK_PromptEvaluationRecords PRIMARY KEY (Id),
        CONSTRAINT FK_PromptEvaluationRecords_AgentRegistrations_AgentRegistrationId
            FOREIGN KEY (AgentRegistrationId) REFERENCES dbo.AgentRegistrations(Id) ON DELETE CASCADE
    );

    CREATE INDEX IX_PromptEvaluationRecords_AgentRegistrationId_ExternalInteractionId
        ON dbo.PromptEvaluationRecords(AgentRegistrationId, ExternalInteractionId);
    CREATE INDEX IX_PromptEvaluationRecords_ExpiresAtUtc
        ON dbo.PromptEvaluationRecords(ExpiresAtUtc);
END;

COMMIT TRANSACTION;
