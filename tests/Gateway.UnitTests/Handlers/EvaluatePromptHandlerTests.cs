using FluentAssertions;
using Gateway.Application.Common;
using Gateway.Application.Prompts.Commands;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public sealed class EvaluatePromptHandlerTests
{
    private readonly IAgentRepository _agentRepository = Substitute.For<IAgentRepository>();
    private readonly IPromptEvaluationRepository _repository = Substitute.For<IPromptEvaluationRepository>();
    private readonly IPromptShieldClient _promptShield = Substitute.For<IPromptShieldClient>();
    private readonly IPurviewPolicyClient _purview = Substitute.For<IPurviewPolicyClient>();
    private readonly IIdempotencyService _idempotency = Substitute.For<IIdempotencyService>();
    private readonly IIdempotencyScopeLease _lease = Substitute.For<IIdempotencyScopeLease>();
    private readonly IAuditEventRepository _audit = Substitute.For<IAuditEventRepository>();
    private readonly IUnitOfWork _unitOfWork = Substitute.For<IUnitOfWork>();

    public EvaluatePromptHandlerTests()
    {
        _promptShield.IsEnabled.Returns(true);
        _promptShield.ReceiptLifetime.Returns(TimeSpan.FromMinutes(5));
        _idempotency.AcquireScopeAsync(
                Arg.Any<Guid>(),
                Arg.Any<string>(),
                Arg.Any<string>(),
                Arg.Any<CancellationToken>())
            .Returns(_lease);
    }

    [Fact]
    public async Task Handle_IssuesReceiptWhenEnabledChecksAllowPrompt()
    {
        var agent = CreateAgent(promptShieldEnabled: true);
        var command = CreateCommand(agent.Id);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(agent);
        _promptShield.EvaluateAsync(command.Prompt.Content, Arg.Any<PromptShieldSubject>(), Arg.Any<CancellationToken>())
            .Returns(new PromptShieldEvaluationResult(false));
        var handler = CreateHandler();

        var result = await handler.Handle(command, CancellationToken.None);

        result.Allowed.Should().BeTrue();
        result.Decision.Should().Be("PROMPT_ALLOWED");
        result.EvaluationReceiptId.Should().Be(result.EvaluationId);
        await _repository.Received(1).AddAsync(
            Arg.Is<PromptEvaluationRecord>(record =>
                record.Outcome == PromptEvaluationOutcome.Allowed
                && record.PromptHash.Length == 32
                && record.PromptHashSalt.Length == 32),
            Arg.Any<CancellationToken>());
        await _idempotency.Received(1).SaveAsync(
            Arg.Is<IdempotencyRecord>(record =>
                record.Endpoint == IdempotencyRequestHasher.PromptEvaluationEndpoint
                && record.ResponseStatusCode == 200),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ReturnsSafeBlockWithoutReceiptWhenPromptShieldDetectsAttack()
    {
        var agent = CreateAgent(promptShieldEnabled: true);
        var command = CreateCommand(agent.Id);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(agent);
        _promptShield.EvaluateAsync(command.Prompt.Content, Arg.Any<PromptShieldSubject>(), Arg.Any<CancellationToken>())
            .Returns(new PromptShieldEvaluationResult(true));
        var handler = CreateHandler();

        var result = await handler.Handle(command, CancellationToken.None);

        result.Allowed.Should().BeFalse();
        result.Decision.Should().Be(ErrorCodes.PROMPT_BLOCKED_BY_PROMPT_SHIELD);
        result.EvaluationReceiptId.Should().BeNull();
        result.UserMessage.Should().NotContain(command.Prompt.Content);
        await _idempotency.Received(1).SaveAsync(
            Arg.Is<IdempotencyRecord>(record => record.ResponseStatusCode == 403),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_AttributesThePromptShieldCallToTheCallingAgent365Identity()
    {
        var agent = CreateAgent(promptShieldEnabled: true);
        agent.Agent365AgentId = Guid.NewGuid().ToString("D");
        agent.BlueprintId = Guid.NewGuid().ToString("D");
        var command = CreateCommand(agent.Id);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(agent);
        _promptShield.EvaluateAsync(
                command.Prompt.Content,
                Arg.Any<PromptShieldSubject>(),
                Arg.Any<CancellationToken>())
            .Returns(new PromptShieldEvaluationResult(false));
        var handler = CreateHandler();

        await handler.Handle(command, CancellationToken.None);

        // Prompt Shields is a per-agent control, not a blueprint-level one, so the
        // verdict has to name the individual agent identity that made the call.
        await _promptShield.Received(1).EvaluateAsync(
            command.Prompt.Content,
            Arg.Is<PromptShieldSubject>(subject =>
                subject.AgentRegistrationId == agent.Id
                && subject.Agent365AgentId == Guid.Parse(agent.Agent365AgentId!)
                && subject.BlueprintId == Guid.Parse(agent.BlueprintId!)),
            Arg.Any<CancellationToken>());
        await _repository.Received(1).AddAsync(
            Arg.Is<PromptEvaluationRecord>(record =>
                record.Agent365AgentId == Guid.Parse(agent.Agent365AgentId!)
                && record.BlueprintId == Guid.Parse(agent.BlueprintId!)),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_RecordsTheAgent365IdentityAsUnknownRatherThanInventingOne()
    {
        var agent = CreateAgent(promptShieldEnabled: true);
        agent.Agent365AgentId = null;
        agent.BlueprintId = null;
        var command = CreateCommand(agent.Id);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(agent);
        _promptShield.EvaluateAsync(
                command.Prompt.Content,
                Arg.Any<PromptShieldSubject>(),
                Arg.Any<CancellationToken>())
            .Returns(new PromptShieldEvaluationResult(false));
        var handler = CreateHandler();

        var result = await handler.Handle(command, CancellationToken.None);

        // An agent whose Agent 365 provisioning has not completed still gets a real
        // verdict; what it must not get is a fabricated identity on the evidence.
        result.Allowed.Should().BeTrue();
        await _promptShield.Received(1).EvaluateAsync(
            command.Prompt.Content,
            Arg.Is<PromptShieldSubject>(subject =>
                subject.AgentRegistrationId == agent.Id
                && subject.Agent365AgentId == null
                && subject.BlueprintId == null),
            Arg.Any<CancellationToken>());
        await _repository.Received(1).AddAsync(
            Arg.Is<PromptEvaluationRecord>(record =>
                record.Agent365AgentId == null && record.BlueprintId == null),
            Arg.Any<CancellationToken>());
    }

    private EvaluatePromptHandler CreateHandler() => new(
        _agentRepository,
        _repository,
        _promptShield,
        _purview,
        _idempotency,
        _audit,
        _unitOfWork,
        TimeProvider.System,
        NullLogger<EvaluatePromptHandler>.Instance);

    private static AgentRegistration CreateAgent(bool promptShieldEnabled)
    {
        var id = Guid.NewGuid();
        return new AgentRegistration
        {
            Id = id,
            ExternalAgentId = new ExternalAgentId("agent-test"),
            Name = "Test agent",
            OwnerObjectId = Guid.NewGuid().ToString("D"),
            Status = AgentStatus.Active,
            FeatureConfiguration = new AgentFeatureConfiguration
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = id,
                ObservabilityMode = ObservabilityMode.Agent365,
                PromptShieldEnabled = promptShieldEnabled
            }
        };
    }

    private static EvaluatePromptCommand CreateCommand(Guid agentId) => new(
        "agent-test",
        "interaction-test",
        DateTime.UtcNow.AddMinutes(-1),
        new UserContextDto(Guid.NewGuid().ToString("D")),
        new ContentDto("text/plain", "Hello from a test prompt"),
        agentId,
        Guid.NewGuid().ToString("D"));
}
