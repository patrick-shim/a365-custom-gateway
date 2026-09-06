using FluentAssertions;
using Gateway.Contracts.Messages;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;

namespace Gateway.ArchitectureTests.ProtectionAdmin;

public sealed class ProtectionAdminIsolationTests
{
    [Fact]
    public void AdministrationQueue_IsExactAndSeparateFromRegistrationV3()
    {
        ProtectionAdminQueueContract.QueueName.Should().Be("gateway-protection-admin-v1");
        ProtectionAdminQueueContract.QueueName.Should().NotBe("gateway-provisioning-v3");

        var service = ReadWorkerFile("ProtectionAdminWorkerService.cs");
        service.Should().Contain("ProtectionAdminQueueContract.QueueName");
        service.Should().NotContain("\"gateway-provisioning-v3\"");
    }

    [Fact]
    public void RegistrationHandler_DoesNotOwnProtectionPolicyAuthoring()
    {
        var handler = ReadWorkerFile("ProvisioningMessageHandler.cs");

        handler.Should().NotContain("EnsureProfileAssignmentAsync");
        handler.Should().NotContain("VerifyProfileAssignmentAsync");
        handler.Should().NotContain("EnsurePurviewPolicyAssignmentAsync");
        handler.Should().NotContain("VerifyPurviewPolicyAssignmentAsync");
        handler.Should().NotContain("_purviewPolicyProvisioningClient");
        handler.Should().NotContain("ValidatePersistedPurviewState");
        typeof(Gateway.Provisioning.Worker.ProvisioningMessageHandler)
            .GetConstructors()
            .SelectMany(constructor => constructor.GetParameters())
            .Select(parameter => parameter.ParameterType)
            .Should()
            .NotContain(
                typeof(Gateway.Domain.Interfaces.IPurviewPolicyProvisioningClient));
    }

    [Fact]
    public void AdministrationWorkflow_DoesNotAlterSevenRegistrationStages()
    {
        ProvisioningWorkflow.CurrentVersion.Should().Be(3);
        ProvisioningWorkflow.CurrentSteps.Should().Equal(
            ProvisioningStepType.ResolveBlueprint,
            ProvisioningStepType.EnsureBlueprintPrincipal,
            ProvisioningStepType.ConfigureGatewayFederation,
            ProvisioningStepType.CreateAgentIdentity,
            ProvisioningStepType.AssignAgent365Access,
            ProvisioningStepType.RegisterAgent,
            ProvisioningStepType.VerifyAgent365Connection);

        ProtectionAdminWorkflow.CurrentVersion.Should().Be(1);
        ProtectionAdminWorkflow.CurrentSteps.Should().Equal(
            ProtectionAdminStepType.ValidateReviewedIntent,
            ProtectionAdminStepType.DiscoverProviderState,
            ProtectionAdminStepType.ApplyReviewedMutation,
            ProtectionAdminStepType.RecordExactReadback,
            ProtectionAdminStepType.VerifyPropagation,
            ProtectionAdminStepType.AttestTokenRoles,
            ProtectionAdminStepType.ValidateRuntimeVerdict,
            ProtectionAdminStepType.Complete);
    }

    [Fact]
    public void RuntimeValidationEvidence_ContainsNoContentOrProviderBodies()
    {
        var forbidden = new[]
        {
            "Token",
            "CertificateBytes",
            "CertificatePassword",
            "PrivateKey",
            "Prompt",
            "Response",
            "Content",
            "ProviderBody"
        };

        typeof(Gateway.Provisioning.Worker.PurviewRuntimeValidationResult)
            .GetProperties()
            .Select(property => property.Name)
            .Should()
            .NotContain(name => forbidden.Any(value =>
                name.Contains(value, StringComparison.OrdinalIgnoreCase)));

        typeof(Gateway.Provisioning.Worker.PurviewConnectionVerificationEvidence)
            .GetProperties()
            .Select(property => property.Name)
            .Should()
            .NotContain(name => forbidden.Any(value =>
                name.Contains(value, StringComparison.OrdinalIgnoreCase)));
    }

    [Fact]
    public void ConnectionVerification_UsesPreparedCertificateAndExactProviderReadback()
    {
        var dependencyInjection = ReadWorkerFile("DependencyInjection.cs");
        var handler = ReadWorkerFile("ProtectionAdminMessageHandler.cs");
        var provider = ReadWorkerFile(
            "PowerShellPurviewConnectionVerificationProvider.cs");
        var script = ReadWorkerFile(
            "Automation",
            "Verify-PurviewTenantConnection.ps1");

        dependencyInjection.Should().Contain(
            "IPurviewConnectionVerificationProvider");
        dependencyInjection.Should().Contain(
            "RemotePurviewConnectionVerificationProvider");
        handler.Should().Contain("PendingVerification");
        handler.Should().Contain("DiscoverConnectionProviderStateAsync");
        handler.Should().Contain("RecordConnectionProviderReadbackAsync");
        handler.Should().Contain(
            "PurviewAutomationCapabilityBindingValidator.Bind");
        provider.Should().Contain("ManagedIdentityCredential");
        provider.Should().Contain("SecretClient");
        provider.Should().Contain(
            "PurviewAutomationCapabilityBindingValidator.Bind");
        provider.Should().Contain("secret.Value.Properties.Id");
        provider.Should().Contain("IsExactProviderCertificateId");
        provider.Should().Contain("\"-AutomationServicePrincipalObjectId\"");
        provider.Should().NotContain("DefaultAzureCredential");
        provider.Should().NotContain("ClientSecretCredential");
        script.Should().Contain("Connect-IPPSSession");
        script.Should().Contain("-AppId");
        script.Should().Contain("-Certificate");
        script.Should().Contain("Get-ConnectionInformation");
        script.Should().Contain("-Name 'AppId'");
        script.Should().Contain("Get-ServicePrincipal");
        script.Should().Contain("$AutomationServicePrincipalObjectId");
        script.Should().Contain("Get-User");
        script.Should().Contain("Get-DlpSensitiveInformationType");
        script.Should().NotContain("-AccessToken");
    }

    [Fact]
    public void WorkerRequiredActions_AreExactUiContractCodes()
    {
        var handler = ReadWorkerFile("ProtectionAdminMessageHandler.cs");

        handler.Should().Contain("\"WaitForPropagation\"");
        handler.Should().Contain("\"Reconcile\"");
        handler.Should().Contain("\"ValidateRuntime\"");
        handler.Should().Contain("\"Retry\"");
        handler.Should().NotContain("\"WaitForVerifiedPropagation\"");
        handler.Should().NotContain("\"WaitForManagedIdentityTokenRoles\"");
        handler.Should().NotContain("\"ReviewExactProviderState\"");
        handler.Should().NotContain("\"ReviewOperationFailure\"");
    }

    private static string ReadWorkerFile(params string[] segments) =>
        File.ReadAllText(Path.Combine(
            [
                FindRepositoryRoot(),
                "src",
                "Gateway.Provisioning.Worker",
                .. segments
            ]));

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null &&
               !File.Exists(Path.Combine(directory.FullName, "AGENTS.md")))
        {
            directory = directory.Parent;
        }

        return directory?.FullName
            ?? throw new DirectoryNotFoundException("Repository root not found.");
    }
}
