using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.IntegrationTests.Fixtures;
using Gateway.TestSupport;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests;

[Collection(SqlServerCollection.Name)]
[Trait("Category", "SqlServer")]
public sealed class RegistrationTests(SqlServerFixture fixture)
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Registration_commits_creator_bound_key_workflow_and_outbox_for_new_or_reused_blueprint(bool reuse)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var blueprintObjectId = Guid.NewGuid();
        var blueprintClientId = Guid.NewGuid();
        var selection = reuse
            ? new AgentBlueprintSelectionDto("UseExisting", blueprintObjectId.ToString("D"), null)
            : new AgentBlueprintSelectionDto("CreateNew", null, "Reusable synthetic blueprint");
        var command = TestData.Registration(blueprint: selection);
        await using var context = database.CreateContext();
        var harness = new GatewaySqlHarness(context);
        if (reuse)
            harness.Catalog.Items = [new(blueprintObjectId, blueprintClientId, "Compatible synthetic blueprint", true, null)];
        var response = await harness.Register().Handle(command, default);

        await using var verify = database.CreateContext();
        var agent = await verify.AgentRegistrations.Include(item => item.FeatureConfiguration).SingleAsync();
        Assert.Equal(response.AgentId, agent.Id);
        Assert.Equal(AgentStatus.Draft, agent.Status);
        Assert.Equal(TestData.Owner, agent.OwnerObjectId);
        Assert.Equal(TestData.Caller, agent.CreatedByObjectId);
        Assert.Equal(TestData.Caller, agent.UpdatedByObjectId);
        Assert.NotEqual(Guid.Empty, agent.ProtectionRevision);
        Assert.Equal(selection.Mode, agent.BlueprintSelectionMode);
        Assert.Equal(selection.BlueprintObjectId, agent.RequestedBlueprintObjectId);
        Assert.Equal(selection.DisplayName, agent.RequestedBlueprintDisplayName);
        Assert.Null(agent.Agent365AgentId);
        Assert.Null(agent.BlueprintId);
        Assert.Null(agent.AgentIdentityObjectId);
        Assert.Null(agent.ExternalClientId);
        Assert.Equal(reuse ? 1 : 0, harness.Catalog.Calls);
        Assert.Equal(0, harness.Shield.Calls);

        var job = await verify.ProvisioningJobs.Include(item => item.Steps).SingleAsync();
        Assert.Equal(response.OperationId, job.Id);
        Assert.Equal(agent.Id, job.AgentRegistrationId);
        Assert.Equal(JobStatus.Pending, job.Status);
        Assert.Equal(ProvisioningWorkflow.CurrentVersion, job.WorkflowVersion);
        Assert.Equal(ProvisioningWorkflow.CurrentSteps, job.Steps.OrderBy(step => step.OrderIndex).Select(step => step.StepType));
        Assert.All(job.Steps, step => Assert.Equal(StepStatus.Pending, step.Status));
        var outbox = await verify.OutboxMessages.SingleAsync();
        Assert.Equal("ProvisionAgent", outbox.MessageType);
        var message = JsonSerializer.Deserialize<ProvisionAgentMessage>(outbox.Payload)!;
        Assert.Equal(agent.Id, message.AgentRegistrationId);
        Assert.Equal(job.Id, message.JobId);

        var credential = await verify.AgentIngressCredentials.SingleAsync();
        var handedOff = Assert.IsType<AgentGatewayCredentialDto>(response.GatewayCredential);
        Assert.Equal(credential.Id, handedOff.KeyId);
        Assert.Equal(TestData.Caller, credential.CreatedByObjectId);
        Assert.Equal(agent.Id, credential.AgentRegistrationId);
        var identity = await new GatewaySqlHarness(verify).Credentials.ValidateAsync(handedOff.ApiKey, DateTime.UtcNow, default);
        Assert.NotNull(identity);
        Assert.Equal(agent.Id, identity.AgentRegistrationId);
        var audit = await verify.AuditEvents.ToListAsync();
        Assert.Equal(2, audit.Count);
        Assert.All(audit, item => Assert.Equal(TestData.Caller, item.PerformedByObjectId));
        Assert.DoesNotContain(handedOff.ApiKey, JsonSerializer.Serialize(audit.Select(item => new
        {
            item.EventType, item.PerformedByObjectId, item.Details
        })));
    }

    [Fact]
    public async Task Repeating_registration_does_not_issue_another_key_or_job_after_a_lost_response()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var command = TestData.Registration();
        await using (var first = database.CreateContext())
            await new GatewaySqlHarness(first).Register().Handle(command, default);
        await using (var retry = database.CreateContext())
        {
            var exception = await Assert.ThrowsAsync<ConflictException>(() =>
                new GatewaySqlHarness(retry).Register().Handle(command, default));
            Assert.Equal(ErrorCodes.DUPLICATE_EXTERNAL_AGENT_ID, exception.ErrorCode);
        }
        await using var verify = database.CreateContext();
        Assert.Equal(1, await verify.AgentRegistrations.CountAsync());
        Assert.Equal(1, await verify.ProvisioningJobs.CountAsync());
        Assert.Equal(1, await verify.AgentIngressCredentials.CountAsync());
        Assert.Equal(1, await verify.OutboxMessages.CountAsync());
        Assert.Equal(2, await verify.AuditEvents.CountAsync());
    }

    [Theory]
    [InlineData("missing", ErrorCodes.AGENT_IDENTITY_BLUEPRINT_INCOMPATIBLE)]
    [InlineData("incompatible", ErrorCodes.AGENT_IDENTITY_BLUEPRINT_INCOMPATIBLE)]
    [InlineData("duplicate", ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_INVALID_RESPONSE)]
    public async Task Reused_blueprint_must_have_one_exact_compatible_catalog_match(string scenario, string errorCode)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var context = database.CreateContext();
        var blueprint = new AgentIdentityBlueprintCatalogItem(Guid.NewGuid(), Guid.NewGuid(), "Synthetic blueprint",
            scenario != "incompatible", null);
        var harness = new GatewaySqlHarness(context);
        harness.Catalog.Items = scenario switch
        {
            "missing" => [],
            "duplicate" => [blueprint, blueprint],
            _ => [blueprint]
        };
        var exception = await Assert.ThrowsAsync<DomainException>(() => harness.Register().Handle(
            TestData.Registration(blueprint: new("UseExisting", blueprint.BlueprintObjectId.ToString("D"), null)), default));
        Assert.Equal(errorCode, exception.ErrorCode);
        Assert.Empty(context.ChangeTracker.Entries());
        Assert.Equal(0, await context.AgentRegistrations.CountAsync());
        Assert.Equal(0, await context.AgentIngressCredentials.CountAsync());
    }

    [Fact]
    public async Task Explicit_local_system_defaults_apply_without_provider_calls()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var context = database.CreateContext();
        var configuration = await context.SystemConfigurations.SingleAsync();
        configuration.DefaultObservabilityMode = "GatewayOnly";
        configuration.DefaultPurviewEnabled = false;
        configuration.DefaultPromptShieldEnabled = false;
        configuration.UpdatedAtUtc = TestData.Now;
        await context.SaveChangesAsync();
        var harness = new GatewaySqlHarness(context);
        var result = await harness.Register().Handle(TestData.Registration() with { Features = null }, default);
        var feature = await context.AgentFeatureConfigurations.SingleAsync(item => item.AgentRegistrationId == result.AgentId);
        Assert.Equal(ObservabilityMode.GatewayOnly, feature.ObservabilityMode);
        Assert.False(feature.PromptShieldEnabled);
        Assert.False(feature.PurviewEnabled);
        Assert.Equal(0, harness.Catalog.Calls);
        Assert.Equal(0, harness.Shield.Calls);
    }

    [Fact]
    public async Task SQL_failure_rolls_back_registration_features_credential_job_steps_audits_and_outbox()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await database.ExecuteAsync("""
            ALTER TABLE dbo.AuditEvents ADD CONSTRAINT CK_M1_RejectRegistrationAudit
            CHECK ([EventType] <> N'AgentRegistered');
            """);
        await using (var context = database.CreateContext())
        {
            var error = await Assert.ThrowsAsync<DbUpdateException>(() =>
                new GatewaySqlHarness(context).Register().Handle(TestData.Registration(), default));
            Assert.Equal(547, Assert.IsType<SqlException>(error.InnerException).Number);
        }
        await using var verify = database.CreateContext();
        Assert.Equal(0, await verify.AgentRegistrations.CountAsync());
        Assert.Equal(0, await verify.AgentFeatureConfigurations.CountAsync());
        Assert.Equal(0, await verify.AgentIngressCredentials.CountAsync());
        Assert.Equal(0, await verify.ProvisioningJobs.CountAsync());
        Assert.Equal(0, await verify.ProvisioningJobSteps.CountAsync());
        Assert.Equal(0, await verify.OutboxMessages.CountAsync());
        Assert.Equal(0, await verify.AuditEvents.CountAsync());
    }
}
