using System.Text.Json;
using FluentAssertions;
using Gateway.Application.Agents.Commands;
using Gateway.Application.Configuration;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public class RegisterAgentHandlerTests
{
    private const string BlueprintObjectId = "0e6f36da-a880-4612-99af-9f923f7105de";
    private readonly IAgentRepository _agentRepository;
    private readonly IProvisioningJobRepository _provisioningJobRepository;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly ISystemConfigurationRepository _systemConfigurationRepository;
    private readonly IAgentIdentityBlueprintCatalog _blueprintCatalog;
    private readonly IAgentIngressCredentialService _agentIngressCredentialService;
    private readonly IPurviewPolicyClient _purviewPolicyClient;
    private readonly IPurviewPolicyProfileRepository _purviewPolicyProfileRepository;
    private readonly IPurviewPolicyProvisioningClient _purviewPolicyProvisioningClient;
    private readonly IPromptShieldClient _promptShieldClient;
    private readonly IUnitOfWork _unitOfWork;
    private readonly RegisterAgentHandler _handler;

    public RegisterAgentHandlerTests()
    {
        _agentRepository = Substitute.For<IAgentRepository>();
        _provisioningJobRepository = Substitute.For<IProvisioningJobRepository>();
        _outboxRepository = Substitute.For<IOutboxRepository>();
        _auditEventRepository = Substitute.For<IAuditEventRepository>();
        _systemConfigurationRepository = Substitute.For<ISystemConfigurationRepository>();
        _blueprintCatalog = Substitute.For<IAgentIdentityBlueprintCatalog>();
        var blueprintId = Guid.Parse(BlueprintObjectId);
        _blueprintCatalog.ListAsync(Arg.Any<CancellationToken>())
            .Returns([
                new AgentIdentityBlueprintCatalogItem(
                    blueprintId,
                    blueprintId,
                    "Reusable blueprint",
                    IsAgent365Compatible: true,
                    Agent365CompatibilityIssue: null)
            ]);
        _agentIngressCredentialService = Substitute.For<IAgentIngressCredentialService>();
        _purviewPolicyClient = Substitute.For<IPurviewPolicyClient>();
        _purviewPolicyClient.IsEnabled.Returns(true);
        _purviewPolicyProfileRepository = Substitute.For<IPurviewPolicyProfileRepository>();
        _purviewPolicyProvisioningClient = Substitute.For<IPurviewPolicyProvisioningClient>();
        _purviewPolicyProvisioningClient.IsEnabled.Returns(true);
        _promptShieldClient = Substitute.For<IPromptShieldClient>();
        _promptShieldClient.IsEnabled.Returns(true);
        _unitOfWork = Substitute.For<IUnitOfWork>();

        var credential = new AgentIngressCredential
        {
            Id = Guid.NewGuid(),
            ExpiresAtUtc = DateTime.UtcNow.AddDays(365)
        };
        _agentIngressCredentialService
            .Issue(Arg.Any<Guid>(), Arg.Any<string>(), Arg.Any<DateTime>())
            .Returns(new IssuedAgentIngressCredential(credential, "test-gateway-api-key"));

        _handler = new RegisterAgentHandler(
            _agentRepository,
            _provisioningJobRepository,
            _outboxRepository,
            _auditEventRepository,
            _systemConfigurationRepository,
            _blueprintCatalog,
            _agentIngressCredentialService,
            _purviewPolicyClient,
            _purviewPolicyProfileRepository,
            _purviewPolicyProvisioningClient,
            _promptShieldClient,
            _unitOfWork);
    }

    private static RegisterAgentCommand CreateValidCommand() =>
        new(
            ExternalAgentId: "agent-001",
            Name: "Test Agent",
            Description: "A test agent",
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null,
            CallerObjectId: "caller-oid-001",
            Blueprint: new AgentBlueprintSelectionDto(
                "UseExisting",
                BlueprintObjectId,
                null));

    [Fact]
    public async Task Handle_Should_ReturnResponse_When_AgentDoesNotExist()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Should().NotBeNull();
        result.ExternalAgentId.Should().Be("agent-001");
        result.Name.Should().Be("Test Agent");
        result.Status.Should().Be(AgentStatus.Draft.ToString());
        result.AgentId.Should().NotBeEmpty();
        result.OperationId.Should().NotBeEmpty();
        result.GatewayCredential.Should().NotBeNull();
        result.GatewayCredential!.ApiKey.Should().Be("test-gateway-api-key");
    }

    [Fact]
    public async Task Handle_Should_CreateAgentWithDraftStatus_When_Registered()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);

        await _handler.Handle(command, CancellationToken.None);

        await _agentRepository.Received(1).AddAsync(
            Arg.Is<AgentRegistration>(a =>
                a.Status == AgentStatus.Draft &&
                a.Name == "Test Agent" &&
                a.OwnerObjectId == "owner-oid-001" &&
                a.Environment == AgentEnvironment.Development),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_PersistBlueprintSelection_When_Registered()
    {
        AgentRegistration? createdAgent = null;
        var command = CreateValidCommand() with
        {
            Blueprint = new AgentBlueprintSelectionDto(
                "CreateNew",
                null,
                "Shared development blueprint")
        };
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);
        _agentRepository.AddAsync(
                Arg.Do<AgentRegistration>(agent => createdAgent = agent),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        await _handler.Handle(command, CancellationToken.None);

        createdAgent.Should().NotBeNull();
        createdAgent!.BlueprintSelectionMode.Should().Be("CreateNew");
        createdAgent.RequestedBlueprintObjectId.Should().BeNull();
        createdAgent.RequestedBlueprintDisplayName.Should().Be("Shared development blueprint");
        _ = _blueprintCatalog.DidNotReceive()
            .ListAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ShouldRejectIncompatibleExistingBlueprintBeforeCreatingAnything()
    {
        var blueprintId = Guid.Parse(BlueprintObjectId);
        _blueprintCatalog.ListAsync(Arg.Any<CancellationToken>())
            .Returns([
                new AgentIdentityBlueprintCatalogItem(
                    blueprintId,
                    blueprintId,
                    "Legacy blueprint",
                    IsAgent365Compatible: false,
                    Agent365CompatibilityIssue:
                        AgentIdentityBlueprintCompatibilityIssues.MissingRequiredManagerApplications)
            ]);

        var action = () => _handler.Handle(CreateValidCommand(), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(
            ErrorCodes.AGENT_IDENTITY_BLUEPRINT_INCOMPATIBLE);
        await _agentRepository.DidNotReceive()
            .AddAsync(Arg.Any<AgentRegistration>(), Arg.Any<CancellationToken>());
        _ = _agentIngressCredentialService.DidNotReceive().Issue(
            Arg.Any<Guid>(),
            Arg.Any<string>(),
            Arg.Any<DateTime>());
        await _outboxRepository.DidNotReceive()
            .AddAsync(Arg.Any<OutboxMessage>(), Arg.Any<CancellationToken>());
        await _unitOfWork.DidNotReceive()
            .SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ShouldFailClosedWhenSelectedBlueprintIsNoLongerInCatalog()
    {
        _blueprintCatalog.ListAsync(Arg.Any<CancellationToken>())
            .Returns([]);

        var action = () => _handler.Handle(CreateValidCommand(), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(
            ErrorCodes.AGENT_IDENTITY_BLUEPRINT_INCOMPATIBLE);
        await _unitOfWork.DidNotReceive()
            .SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ShouldMapCatalogDependencyFailureWithoutLeakingProviderDetail()
    {
        _blueprintCatalog.ListAsync(Arg.Any<CancellationToken>())
            .Returns(_ => Task.FromException<IReadOnlyList<AgentIdentityBlueprintCatalogItem>>(
                new Agent365ProvisioningException(
                    "MICROSOFT_GRAPH_FORBIDDEN",
                    "Raw provider detail must not escape.")));

        var action = () => _handler.Handle(CreateValidCommand(), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(
            ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_UNAVAILABLE);
        exception.Which.Message.Should().NotContain("Raw provider detail");
        await _unitOfWork.DidNotReceive()
            .SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_CreateProvisioningJob_When_Registered()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);

        await _handler.Handle(command, CancellationToken.None);

        await _provisioningJobRepository.Received(1).AddAsync(
            Arg.Is<ProvisioningJob>(j =>
                j.Type == OperationType.ProvisionAgent &&
                j.Status == JobStatus.Pending &&
                j.WorkflowVersion == ProvisioningWorkflow.CurrentVersion &&
                j.Steps.OrderBy(step => step.OrderIndex)
                    .Select(step => step.StepType)
                    .SequenceEqual(ProvisioningWorkflow.CurrentSteps) &&
                j.Steps.All(step => step.Status == StepStatus.Pending)),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_CreateOutboxMessage_When_Registered()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);

        await _handler.Handle(command, CancellationToken.None);

        await _outboxRepository.Received(1).AddAsync(
            Arg.Is<OutboxMessage>(m =>
                m.MessageType == "ProvisionAgent" &&
                m.Status == OutboxMessageStatus.Pending),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_WriteSharedProvisionAgentMessage_When_Registered()
    {
        AgentRegistration? createdAgent = null;
        ProvisioningJob? createdJob = null;
        OutboxMessage? createdMessage = null;
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);
        _agentRepository.AddAsync(
                Arg.Do<AgentRegistration>(agent => createdAgent = agent),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);
        _provisioningJobRepository.AddAsync(
                Arg.Do<ProvisioningJob>(job => createdJob = job),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);
        _outboxRepository.AddAsync(
                Arg.Do<OutboxMessage>(message => createdMessage = message),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        await _handler.Handle(command, CancellationToken.None);

        createdAgent.Should().NotBeNull();
        createdJob.Should().NotBeNull();
        createdMessage.Should().NotBeNull();
        createdMessage!.MessageType.Should().Be("ProvisionAgent");

        var payload = JsonSerializer.Deserialize<ProvisionAgentMessage>(createdMessage.Payload);
        payload.Should().NotBeNull();
        payload!.AgentRegistrationId.Should().Be(createdAgent!.Id);
        payload.JobId.Should().Be(createdJob!.Id);
        payload.ExpectedStepIndex.Should().Be(0);
    }

    [Fact]
    public async Task Handle_Should_CreateAuditEvent_When_Registered()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);

        await _handler.Handle(command, CancellationToken.None);

        await _auditEventRepository.Received(1).AddAsync(
            Arg.Is<AuditEvent>(e =>
                e.EventType == "AgentRegistered" &&
                e.PerformedByObjectId == "caller-oid-001"),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_CallSaveChangesExactlyOnce_When_Registered()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);

        await _handler.Handle(command, CancellationToken.None);

        await _unitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_ThrowConflictException_When_ExternalAgentIdAlreadyExists()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(true);

        var act = () => _handler.Handle(command, CancellationToken.None);

        var exception = await act.Should().ThrowAsync<ConflictException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.DUPLICATE_EXTERNAL_AGENT_ID);
    }

    [Fact]
    public async Task Handle_Should_NotCallSaveChanges_When_DuplicateDetected()
    {
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(true);

        var act = () => _handler.Handle(command, CancellationToken.None);
        await act.Should().ThrowAsync<ConflictException>();

        await _unitOfWork.DidNotReceive().SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_DefaultToAgent365WithoutAzureMonitor_When_FeaturesAreOmitted()
    {
        AgentRegistration? createdAgent = null;
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);
        _agentRepository.AddAsync(
                Arg.Do<AgentRegistration>(agent => createdAgent = agent),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        await _handler.Handle(command, CancellationToken.None);

        createdAgent.Should().NotBeNull();
        createdAgent!.FeatureConfiguration.ObservabilityMode.Should().Be(ObservabilityMode.Agent365);
        createdAgent.FeatureConfiguration.ObservabilityMode.ToDestinations()
            .Should().Be(new ObservabilityDestinations(true, false));
    }

    [Fact]
    public async Task Handle_Should_EncodeBothDestinations_When_BothAreEnabled()
    {
        AgentRegistration? createdAgent = null;
        var command = CreateValidCommand() with
        {
            Features = new AgentFeaturesDto(
                ObservabilityMode: null,
                PurviewEnabled: null,
                PurviewMode: null,
                Agent365ObservabilityEnabled: true,
                AzureMonitorExportEnabled: true)
        };
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);
        _agentRepository.AddAsync(
                Arg.Do<AgentRegistration>(agent => createdAgent = agent),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        await _handler.Handle(command, CancellationToken.None);

        createdAgent.Should().NotBeNull();
        createdAgent!.FeatureConfiguration.ObservabilityMode
            .Should().Be(ObservabilityMode.Agent365AzureMonitor);
    }

    [Fact]
    public async Task Handle_Should_InheritConfiguredObservabilityDestinations_When_FeaturesAreOmitted()
    {
        AgentRegistration? createdAgent = null;
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);
        _systemConfigurationRepository.GetAsync(Arg.Any<CancellationToken>())
            .Returns(new SystemConfiguration { DefaultObservabilityMode = "GatewayOnly" });
        _agentRepository.AddAsync(
                Arg.Do<AgentRegistration>(agent => createdAgent = agent),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        await _handler.Handle(command, CancellationToken.None);

        createdAgent.Should().NotBeNull();
        createdAgent!.FeatureConfiguration.ObservabilityMode.Should().Be(ObservabilityMode.GatewayOnly);
    }

    [Fact]
    public async Task Handle_Should_FallBackToAgent365_When_ConfiguredModeIsInvalid()
    {
        AgentRegistration? createdAgent = null;
        var command = CreateValidCommand();
        _agentRepository.ExistsAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(false);
        _systemConfigurationRepository.GetAsync(Arg.Any<CancellationToken>())
            .Returns(new SystemConfiguration { DefaultObservabilityMode = "InvalidMode" });
        _agentRepository.AddAsync(
                Arg.Do<AgentRegistration>(agent => createdAgent = agent),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        await _handler.Handle(command, CancellationToken.None);

        createdAgent.Should().NotBeNull();
        createdAgent!.FeatureConfiguration.ObservabilityMode.Should().Be(ObservabilityMode.Agent365);
    }

    [Fact]
    public async Task Handle_ShouldRegisterWithoutCallingPurviewDependencies_WhenPurviewIsOff()
    {
        AgentRegistration? createdAgent = null;
        _purviewPolicyClient.IsEnabled.Returns(false);
        _purviewPolicyProvisioningClient.IsEnabled.Returns(false);
        _purviewPolicyClient.ClearReceivedCalls();
        _purviewPolicyProfileRepository.ClearReceivedCalls();
        _purviewPolicyProvisioningClient.ClearReceivedCalls();
        _agentRepository.AddAsync(
                Arg.Do<AgentRegistration>(agent => createdAgent = agent),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);
        var command = CreateValidCommand() with
        {
            Features = new AgentFeaturesDto("Agent365", false, null)
        };

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Should().NotBeNull();
        createdAgent.Should().NotBeNull();
        createdAgent!.FeatureConfiguration.PurviewEnabled.Should().BeFalse();
        createdAgent.PurviewPolicyProfileId.Should().BeNull();
        _purviewPolicyClient.ReceivedCalls().Should().BeEmpty();
        _purviewPolicyProfileRepository.ReceivedCalls().Should().BeEmpty();
        _purviewPolicyProvisioningClient.ReceivedCalls().Should().BeEmpty();
    }

    [Fact]
    public async Task Handle_ShouldRejectPurviewBeforeCreatingAgent_WhenAdapterIsDisabled()
    {
        _purviewPolicyClient.IsEnabled.Returns(false);
        var command = CreateValidCommand() with
        {
            Features = new AgentFeaturesDto(
                ObservabilityMode: "Agent365",
                PurviewEnabled: true,
                PurviewMode: "Enforce")
        };

        var action = () => _handler.Handle(command, CancellationToken.None);

        var exception = await action.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.UNSUPPORTED_FEATURE_CONFIGURATION);
        await _agentRepository.DidNotReceive()
            .AddAsync(Arg.Any<AgentRegistration>(), Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ShouldCreatePendingPurviewProfileForNewProtectedBlueprint()
    {
        AgentRegistration? createdAgent = null;
        PurviewPolicyProfile? createdProfile = null;
        _agentRepository.AddAsync(
                Arg.Do<AgentRegistration>(agent => createdAgent = agent),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);
        _purviewPolicyProfileRepository.AddAsync(
                Arg.Do<PurviewPolicyProfile>(profile => createdProfile = profile),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        var command = CreateValidCommand() with
        {
            Blueprint = new AgentBlueprintSelectionDto("CreateNew", null, "Protected blueprint"),
            Features = new AgentFeaturesDto("Agent365", true, "Enforce"),
            PurviewPolicyProfile = new PurviewPolicyProfileSelectionDto(
                "CreateNew",
                null,
                "Protected production agents",
                "AllSensitiveInformation")
        };

        await _handler.Handle(command, CancellationToken.None);

        createdProfile.Should().NotBeNull();
        createdProfile!.Status.Should().Be("Pending");
        createdProfile.Mode.Should().Be("Enforce");
        createdProfile.CollectionPolicyName.Should().Contain("Protected production agents");
        createdAgent!.PurviewPolicyProfileId.Should().Be(createdProfile.Id);
        createdAgent.PurviewPolicySelectionMode.Should().Be("CreateNew");
    }
}
