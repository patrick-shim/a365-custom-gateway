using Bunit;
using Bunit.TestDoubles;
using FluentAssertions;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Services;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.Components.Web;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.FluentUI.AspNetCore.Components;
using NSubstitute;

namespace Gateway.AdminUi.Tests.Components;

public sealed class OperationStatusPageTests : BunitContext
{
    private readonly IGatewayApiClient _api = Substitute.For<IGatewayApiClient>();
    private readonly BunitAuthorizationContext _authorization;

    public OperationStatusPageTests()
    {
        Services.AddFluentUIComponents();
        Services.AddSingleton(_api);
        JSInterop.Mode = JSRuntimeMode.Loose;

        _authorization = AddAuthorization();
        _authorization.SetAuthorized("Operator user");
        _authorization.SetRoles(GatewayRoles.Operator);
    }

    [Fact]
    public void TerminalOperation_IsLoadedOnceAndStopsAutomaticPolling()
    {
        var operationId = Guid.NewGuid();
        var agentId = Guid.NewGuid();
        _api.GetOperationStatusAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(new OperationStatusDto(
                operationId,
                "RegisterAgent",
                "Completed",
                CurrentStep: null,
                PercentComplete: 100,
                agentId,
                StartedAtUtc: DateTime.UtcNow.AddMinutes(-2),
                CompletedAtUtc: DateTime.UtcNow.AddMinutes(-1),
                Error: null,
                Steps: []));

        var cut = Render<OperationStatus>(parameters => parameters
            .Add(component => component.OperationId, operationId));

        cut.WaitForAssertion(() =>
        {
            cut.Find(".status-pill").TextContent.Should().Contain("Completed");
            cut.Markup.Should().Contain("reached a terminal state");
            cut.Markup.Should().Contain("Automatic updates</span><strong>Stopped");
            _api.Received(1).GetOperationStatusAsync(
                operationId,
                Arg.Any<CancellationToken>());
        });
    }

    [Fact]
    public void FailedOperation_DoesNotRenderRawWorkerExceptionText()
    {
        const string sensitiveWorkerMessage = "Bearer sensitive-token from https://internal.example";
        var operationId = Guid.NewGuid();
        var agentId = Guid.NewGuid();
        _api.GetOperationStatusAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(new OperationStatusDto(
                operationId,
                "RegisterAgent",
                "Failed",
                "CreateResources",
                45,
                agentId,
                DateTime.UtcNow.AddMinutes(-2),
                DateTime.UtcNow.AddMinutes(-1),
                new OperationErrorDto("PROVISIONING_FAILED", sensitiveWorkerMessage),
                Steps: []));

        var cut = Render<OperationStatus>(parameters => parameters
            .Add(component => component.OperationId, operationId));

        cut.WaitForAssertion(() =>
        {
            cut.Markup.Should().Contain("PROVISIONING_FAILED");
            cut.Markup.Should().Contain("raw exception text is intentionally not displayed");
            cut.Markup.Should().NotContain(sensitiveWorkerMessage);
        });
    }

    [Fact]
    public void CurrentWorkflow_GroupsVerifiedStepsIntoThreeFunctionalAreas()
    {
        var operationId = Guid.NewGuid();
        var agentId = Guid.NewGuid();
        var completedAtUtc = DateTime.UtcNow.AddMinutes(-1);
        _api.GetOperationStatusAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(new OperationStatusDto(
                operationId,
                "RegisterAgent",
                "Completed",
                CurrentStep: null,
                PercentComplete: 100,
                agentId,
                StartedAtUtc: DateTime.UtcNow.AddMinutes(-2),
                CompletedAtUtc: completedAtUtc,
                Error: null,
                Steps:
                [
                    new OperationStepDto("ResolveBlueprint", "Completed", completedAtUtc),
                    new OperationStepDto("EnsureBlueprintPrincipal", "Completed", completedAtUtc),
                    new OperationStepDto("ConfigureGatewayFederation", "Completed", completedAtUtc),
                    new OperationStepDto("CreateAgentIdentity", "Completed", completedAtUtc),
                    new OperationStepDto("AssignAgent365Access", "Completed", completedAtUtc),
                    new OperationStepDto("RegisterAgent", "Completed", completedAtUtc),
                    new OperationStepDto("VerifyAgent365Connection", "Completed", completedAtUtc)
                ],
                WorkflowVersion: 2,
                Legacy: false,
                ReplaySupported: true,
                PollingRecommended: false));

        var cut = Render<OperationStatus>(parameters => parameters
            .Add(component => component.OperationId, operationId));

        cut.WaitForAssertion(() =>
        {
            cut.Markup.Should().Contain("1. Blueprint");
            cut.Markup.Should().Contain("2. Agent ID");
            cut.Markup.Should().Contain("3. Agent 365 connection");
            cut.Markup.Should().Contain("Configure Gateway federation");
            cut.Markup.Should().Contain("Assign Agent 365 observability access");
            cut.Markup.Should().Contain("Verify Agent 365 connection");
            cut.Markup.Should().Contain("Register Agent 365 record (preview)");
            cut.Markup.Should().NotContain("Historical legacy workflow");
        });
    }

    [Fact]
    public void LegacyPendingWorkflow_ShowsRawRecordedStepsAndDoesNotKeepPolling()
    {
        var operationId = Guid.NewGuid();
        var agentId = Guid.NewGuid();
        _api.GetOperationStatusAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(new OperationStatusDto(
                operationId,
                "RegisterAgent",
                "Pending",
                "CreateAppRegistration",
                PercentComplete: 0,
                agentId,
                StartedAtUtc: DateTime.UtcNow.AddDays(-1),
                CompletedAtUtc: null,
                Error: null,
                Steps:
                [
                    new OperationStepDto("CreateAppRegistration", "Pending", null),
                    new OperationStepDto("CreateServicePrincipal", "Pending", null)
                ],
                WorkflowVersion: 1,
                Legacy: true,
                ReplaySupported: false,
                PollingRecommended: false));

        var cut = Render<OperationStatus>(parameters => parameters
            .Add(component => component.OperationId, operationId));

        cut.WaitForAssertion(() =>
        {
            cut.Markup.Should().Contain("Historical legacy workflow");
            cut.Markup.Should().Contain("Historical recorded steps");
            cut.Markup.Should().Contain("<code>CreateAppRegistration</code>");
            cut.Markup.Should().Contain("<code>CreateServicePrincipal</code>");
            cut.Markup.Should().Contain("Use Check status for a one-time refresh");
            cut.Markup.Should().Contain("Automatic updates</span><strong>Stopped");
            _api.Received(1).GetOperationStatusAsync(
                operationId,
                Arg.Any<CancellationToken>());
        });
    }

    [Fact]
    public void CurrentWorkflowWithAmbiguousMutation_DisablesReplayAndExplainsReconciliation()
    {
        var operationId = Guid.NewGuid();
        var agentId = Guid.NewGuid();
        _api.GetOperationStatusAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(new OperationStatusDto(
                operationId,
                "RegisterAgent",
                "RequiresManualIntervention",
                "RegisterAgent",
                PercentComplete: 71,
                agentId,
                StartedAtUtc: DateTime.UtcNow.AddMinutes(-2),
                CompletedAtUtc: DateTime.UtcNow.AddMinutes(-1),
                Error: new OperationErrorDto("PROVISIONING_AMBIGUOUS_RESULT", "Safe public message"),
                Steps:
                [
                    new OperationStepDto("RegisterAgent", "Running", null)
                ],
                WorkflowVersion: 2,
                Legacy: false,
                ReplaySupported: false,
                PollingRecommended: false));

        var cut = Render<OperationStatus>(parameters => parameters
            .Add(component => component.OperationId, operationId));

        cut.WaitForAssertion(() =>
        {
            cut.Markup.Should().Contain("This operation is not replayable");
            cut.Markup.Should().Contain("Do not retry or replay it");
            cut.Markup.Should().Contain("will not risk creating a duplicate resource");
            _api.Received(1).GetOperationStatusAsync(
                operationId,
                Arg.Any<CancellationToken>());
        });
    }

    [Fact]
    public void InFlightRegistryCreate_IsRefreshOnlyAndExplicitlyNonReplayable()
    {
        var operationId = Guid.NewGuid();
        var agentId = Guid.NewGuid();
        _api.GetOperationStatusAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(new OperationStatusDto(
                operationId,
                "ProvisionAgent",
                "Running",
                "RegisterAgent",
                PercentComplete: 71,
                agentId,
                StartedAtUtc: DateTime.UtcNow.AddMinutes(-2),
                CompletedAtUtc: null,
                Error: null,
                Steps:
                [
                    new OperationStepDto("RegisterAgent", "Running", null)
                ],
                WorkflowVersion: 2,
                Legacy: false,
                ReplaySupported: false,
                PollingRecommended: true));

        var cut = Render<OperationStatus>(parameters => parameters
            .Add(component => component.OperationId, operationId));

        cut.WaitForAssertion(() =>
        {
            cut.Markup.Should().Contain("This operation is not replayable");
            cut.Markup.Should().Contain("Do not retry or replay it");
            cut.Markup.Should().Contain("Automatic updates are active");
            cut.FindAll("fluent-button")
                .Should().NotContain(button => button.TextContent.Contains("Retry provisioning"));
        });
    }

    [Fact]
    public async Task RequiredRegistrationAction_AdministratorConfirmsOnce_AndPollingResumes()
    {
        _authorization.SetAuthorized("Administrator user");
        _authorization.SetRoles(GatewayRoles.Administrator);
        var operationId = Guid.NewGuid();
        var agentId = Guid.NewGuid();
        var awaitingAction = new OperationStatusDto(
            operationId,
            "ProvisionAgent",
            "WaitingForAdministrator",
            "RegisterAgent",
            PercentComplete: 71,
            agentId,
            StartedAtUtc: DateTime.UtcNow.AddMinutes(-2),
            CompletedAtUtc: null,
            Error: null,
            Steps: [new OperationStepDto("RegisterAgent", "Pending", null)],
            WorkflowVersion: 2,
            Legacy: false,
            ReplaySupported: false,
            PollingRecommended: false,
            RequiredAction: "CompleteAgent365Registration");
        var completed = awaitingAction with
        {
            Status = "Completed",
            CurrentStep = null,
            PercentComplete = 100,
            CompletedAtUtc = DateTime.UtcNow,
            RequiredAction = null,
            Steps = [new OperationStepDto("RegisterAgent", "Completed", DateTime.UtcNow)]
        };
        _api.GetOperationStatusAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(awaitingAction, completed);
        var completion = new TaskCompletionSource<CompleteAgent365RegistrationResponse>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        _api.CompleteAgent365RegistrationAsync(
                operationId,
                Arg.Any<CancellationToken>())
            .Returns(completion.Task);

        var cut = Render<OperationStatus>(parameters => parameters
            .Add(component => component.OperationId, operationId));

        var actionButton = cut.WaitForElement(".registry-action-controls fluent-button");
        cut.Markup.Should().Contain("Administrator action required");
        cut.Markup.Should().Contain("No JSON upload is required");
        cut.Markup.Should().Contain("never asks for, receives, or displays a Microsoft Graph access token");

        await actionButton.ClickAsync(new MouseEventArgs());
        var confirmButton = cut.FindAll(".confirm-panel fluent-button").Last();
        var firstSubmission = confirmButton.ClickAsync(new MouseEventArgs());

        cut.WaitForAssertion(() =>
        {
            _api.Received(1).CompleteAgent365RegistrationAsync(
                operationId,
                Arg.Any<CancellationToken>());
            cut.Markup.Should().Contain("Working…");
        });

        var duplicateSubmission = confirmButton.ClickAsync(new MouseEventArgs());
        await duplicateSubmission.WaitAsync(TimeSpan.FromSeconds(2));
        _ = _api.Received(1).CompleteAgent365RegistrationAsync(
            operationId,
            Arg.Any<CancellationToken>());

        completion.SetResult(new CompleteAgent365RegistrationResponse(
            operationId,
            agentId,
            Guid.NewGuid().ToString("D"),
            "Running"));
        await firstSubmission.WaitAsync(TimeSpan.FromSeconds(2));

        cut.WaitForAssertion(() =>
        {
            _api.Received(2).GetOperationStatusAsync(
                operationId,
                Arg.Any<CancellationToken>());
            cut.Find(".status-pill").TextContent.Should().Contain("Completed");
            cut.Markup.Should().NotContain("Administrator action required");
        });
    }

    [Fact]
    public void AvailableRegistrationAction_AdministratorCompletesAutomaticallyOnce()
    {
        _authorization.SetAuthorized("Administrator user");
        _authorization.SetRoles(GatewayRoles.Administrator);
        var operationId = Guid.NewGuid();
        var agentId = Guid.NewGuid();
        var awaitingAction = new OperationStatusDto(
            operationId,
            "ProvisionAgent",
            "WaitingForAdministrator",
            "RegisterAgent",
            PercentComplete: 71,
            agentId,
            StartedAtUtc: DateTime.UtcNow.AddMinutes(-2),
            CompletedAtUtc: null,
            Error: null,
            Steps: [new OperationStepDto("RegisterAgent", "Pending", null)],
            WorkflowVersion: 3,
            Legacy: false,
            ReplaySupported: false,
            PollingRecommended: false,
            RequiredAction: "CompleteAgent365Registration",
            Agent365RegistrationCompletionAvailable: true);
        var completed = awaitingAction with
        {
            Status = "Completed",
            CurrentStep = null,
            PercentComplete = 100,
            CompletedAtUtc = DateTime.UtcNow,
            RequiredAction = null,
            Agent365RegistrationCompletionAvailable = false,
            Steps = [new OperationStepDto("RegisterAgent", "Completed", DateTime.UtcNow)]
        };
        _api.GetOperationStatusAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(awaitingAction, completed);
        _api.CompleteAgent365RegistrationAsync(
                operationId,
                Arg.Any<CancellationToken>())
            .Returns(new CompleteAgent365RegistrationResponse(
                operationId,
                agentId,
                Guid.NewGuid().ToString("D"),
                "Running"));

        var cut = Render<OperationStatus>(parameters => parameters
            .Add(component => component.OperationId, operationId));

        cut.WaitForAssertion(() =>
        {
            _api.Received(1).CompleteAgent365RegistrationAsync(
                operationId,
                Arg.Any<CancellationToken>());
            _api.Received(2).GetOperationStatusAsync(
                operationId,
                Arg.Any<CancellationToken>());
            cut.Markup.Should().Contain("Completed");
        });
    }

    [Fact]
    public void RequiredRegistrationAction_OperatorSeesHandoffWithoutAdministratorButton()
    {
        var operationId = Guid.NewGuid();
        var agentId = Guid.NewGuid();
        _api.GetOperationStatusAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(new OperationStatusDto(
                operationId,
                "ProvisionAgent",
                "WaitingForAdministrator",
                "RegisterAgent",
                PercentComplete: 71,
                agentId,
                StartedAtUtc: DateTime.UtcNow.AddMinutes(-2),
                CompletedAtUtc: null,
                Error: null,
                Steps: [new OperationStepDto("RegisterAgent", "Pending", null)],
                WorkflowVersion: 2,
                Legacy: false,
                ReplaySupported: false,
                PollingRecommended: false,
                RequiredAction: "CompleteAgent365Registration"));

        var cut = Render<OperationStatus>(parameters => parameters
            .Add(component => component.OperationId, operationId));

        cut.WaitForAssertion(() =>
        {
            cut.Markup.Should().Contain("Administrator action required");
            cut.Markup.Should().Contain("ask a Gateway Administrator");
            cut.FindAll("fluent-button")
                .Should().NotContain(button =>
                    button.TextContent.Contains("Complete Agent 365 registration"));
            _api.DidNotReceiveWithAnyArgs()
                .CompleteAgent365RegistrationAsync(default);
        });
    }

    [Fact]
    public async Task RegistrationActionFailure_ShowsSafeConsentAndConditionalAccessGuidance()
    {
        _authorization.SetAuthorized("Administrator user");
        _authorization.SetRoles(GatewayRoles.Administrator);
        var operationId = Guid.NewGuid();
        var agentId = Guid.NewGuid();
        _api.GetOperationStatusAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(new OperationStatusDto(
                operationId,
                "ProvisionAgent",
                "WaitingForAdministrator",
                "RegisterAgent",
                PercentComplete: 71,
                agentId,
                StartedAtUtc: DateTime.UtcNow.AddMinutes(-2),
                CompletedAtUtc: null,
                Error: null,
                Steps: [new OperationStepDto("RegisterAgent", "Pending", null)],
                WorkflowVersion: 2,
                Legacy: false,
                ReplaySupported: false,
                PollingRecommended: false,
                RequiredAction: "CompleteAgent365Registration"));
        const string sensitiveInnerMessage = "Bearer raw-graph-token-value";
        _api.CompleteAgent365RegistrationAsync(
                operationId,
                Arg.Any<CancellationToken>())
            .Returns(Task.FromException<CompleteAgent365RegistrationResponse>(
                new GatewayApiException(
                    System.Net.HttpStatusCode.Unauthorized,
                    "Additional Microsoft Entra authorization is required",
                    sensitiveInnerMessage,
                    "https://gateway.example.com/problems/delegated-authorization-required",
                    $"/api/v1/operations/{operationId:D}:complete-agent365-registration",
                    "AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED",
                    "challenge-correlation",
                    new Dictionary<string, string[]>(),
                    null,
                    requiresUserInteraction: true,
                    hasClaimsChallenge: true,
                    requiredScopes:
                    [
                        "https://graph.microsoft.com/AgentRegistration.ReadWrite.All",
                        "https://graph.microsoft.com/AgentRegistration.Read.All"
                    ])));

        var cut = Render<OperationStatus>(parameters => parameters
            .Add(component => component.OperationId, operationId));
        await cut.WaitForElement(".registry-action-controls fluent-button")
            .ClickAsync(new MouseEventArgs());
        await cut.FindAll(".confirm-panel fluent-button").Last()
            .ClickAsync(new MouseEventArgs());

        cut.WaitForAssertion(() =>
        {
            cut.Find(".error-panel").TextContent.Should().Contain("Sign in again");
            cut.Markup.Should().Contain("Conditional Access interaction required");
            cut.Markup.Should().Contain("Conditional Access");
            cut.Markup.Should().Contain("AgentRegistration.ReadWrite.All");
            cut.Markup.Should().Contain("AgentRegistration.Read.All");
            cut.Markup.Should().NotContain(sensitiveInnerMessage);
            cut.Markup.Should().Contain("no automatic retry was attempted");
        });
    }

    [Fact]
    public async Task AcceptedRegistrationAction_RemainsDisabledWhenFollowUpPollingFails()
    {
        _authorization.SetAuthorized("Administrator user");
        _authorization.SetRoles(GatewayRoles.Administrator);
        var operationId = Guid.NewGuid();
        var agentId = Guid.NewGuid();
        var awaitingAction = new OperationStatusDto(
            operationId,
            "ProvisionAgent",
            "WaitingForAdministrator",
            "RegisterAgent",
            PercentComplete: 71,
            agentId,
            StartedAtUtc: DateTime.UtcNow.AddMinutes(-2),
            CompletedAtUtc: null,
            Error: null,
            Steps: [new OperationStepDto("RegisterAgent", "Pending", null)],
            WorkflowVersion: 2,
            Legacy: false,
            ReplaySupported: false,
            PollingRecommended: false,
            RequiredAction: "CompleteAgent365Registration");
        _api.GetOperationStatusAsync(operationId, Arg.Any<CancellationToken>())
            .Returns(
                Task.FromResult(awaitingAction),
                Task.FromException<OperationStatusDto>(
                    new GatewayApiTransportException(
                        "The Gateway API could not be reached.",
                        "poll-correlation",
                        new HttpRequestException("Synthetic test failure."))));
        _api.CompleteAgent365RegistrationAsync(
                operationId,
                Arg.Any<CancellationToken>())
            .Returns(new CompleteAgent365RegistrationResponse(
                operationId,
                agentId,
                Guid.NewGuid().ToString("D"),
                "Running"));

        var cut = Render<OperationStatus>(parameters => parameters
            .Add(component => component.OperationId, operationId));
        await cut.WaitForElement(".registry-action-controls fluent-button")
            .ClickAsync(new MouseEventArgs());
        await cut.FindAll(".confirm-panel fluent-button").Last()
            .ClickAsync(new MouseEventArgs());

        cut.WaitForAssertion(() =>
        {
            var actionButton = cut.Find(".registry-action-controls fluent-button");
            actionButton.TextContent.Should().Contain("Registration submitted");
            actionButton.HasAttribute("disabled").Should().BeTrue();
            cut.Markup.Should().Contain("Automatic status checks are following");
            cut.Markup.Should().Contain("poll-correlation");
            _api.Received(1).CompleteAgent365RegistrationAsync(
                operationId,
                Arg.Any<CancellationToken>());
        });
    }
}
