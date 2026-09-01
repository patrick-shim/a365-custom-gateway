using FluentAssertions;
using Gateway.Setup.Services;
using System.Text.Json;

namespace Gateway.Setup.Tests.Services;

public sealed class BootstrapOutputSanitizerTests
{
    private const string ReviewedFingerprint =
        "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    private const string CheckpointFingerprint =
        "sha256:1111111122222222111111112222222211111111222222221111111122222222";
    private const string ResumeAuthorizationFingerprint =
        "sha256:9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba";

    [Fact]
    public void TypedPlanFailure_ShowsTheAuthoredBoundaryWithIndeterminateProgress()
    {
        const string line = """
            {"schemaVersion":1,"type":"Warning","message":"Repository or Bicep validation failed. Run gateway doctor, correct the reported tool or source issue, then run Plan again.","data":{"step":"Plan review","category":"planFailure","failureCode":"plan_source","resumable":false}}
            """;

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.Kind.Should().Be(BootstrapProgressKind.Warning);
        result.DisplayLabel.Should().Be("Plan stopped here");
        result.Message.Should().Contain("Bicep validation failed");
        result.ProgressPercent.Should().BeNull();
        result.PlanResultClaimObserved.Should().BeFalse();
        result.PlanFingerprint.Should().BeNull();
    }

    [Fact]
    public void StructuredEvent_RendersOnlyAllowlistedSanitizedFields()
    {
        const string line = """
            {"schemaVersion":1,"type":"PhaseStarted","message":"Deploying resources for operator@example.com from /Users/example/repo","data":{"step":"Azure foundation","index":6,"total":12,"adminUiUrl":"https://admin.example.test/setup?code=discard","unexpected":"do not render"}}
            """;

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.Kind.Should().Be(BootstrapProgressKind.Step);
        result.Message.Should().Be("Deploying resources for [email] from [local-path]");
        result.Step.Should().Be("Azure foundation");
        result.ProgressPercent.Should().Be(42);
        result.VerifiedEndpoints.Should().BeNull("an arbitrary phase event is not verified endpoint evidence");
        result.DeploymentVerificationClaimObserved.Should().BeFalse();
        result.Message.Should().NotContain("unexpected");
        result.Message.Should().NotContain("do not render");
    }

    [Fact]
    public void CanonicalCompletedVerificationEvent_ExposesOnlyValidatedHttpsEndpoints()
    {
        const string line = """
            {"schemaVersion":1,"type":"Result","message":"Bootstrap completed and verified in 00:14:02. Admin UI: https://admin.example.test/?code=discard","data":{"step":"End-to-end deployment verification","category":"deploymentVerified","verified":true,"verificationMode":"Apply","index":19,"total":19,"adminUiUrl":"https://ca-gateway-admin-dev.safe.azurecontainerapps.io/","apiUrl":"https://ca-gateway-api-dev.safe.azurecontainerapps.io/","apiHealthUrl":"https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks","unexpected":"do not render"}}
            """;

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.Kind.Should().Be(BootstrapProgressKind.Success);
        result.DeploymentVerificationClaimObserved.Should().BeTrue();
        result.VerifiedEndpoints.Should().NotBeNull();
        result.VerifiedEndpoints!.VerificationMode.Should().Be(BootstrapVerificationMode.Apply);
        result.VerifiedEndpoints.AdminUiBaseAddress.Should().Be("https://ca-gateway-admin-dev.safe.azurecontainerapps.io/");
        result.VerifiedEndpoints.AdminSetupAddress.Should().Be("https://ca-gateway-admin-dev.safe.azurecontainerapps.io/setup");
        result.VerifiedEndpoints.ApiBaseAddress.Should().Be("https://ca-gateway-api-dev.safe.azurecontainerapps.io/");
        result.VerifiedEndpoints.ApiHealthAddress.Should().Be("https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks");
        result.Message.Should().NotContain("?code=discard");
        result.Message.Should().NotContain("do not render");
    }

    [Theory]
    [InlineData("Gateway deployment completed and verified in 00:14:02; provisioning admission remains closed. Admin UI: https://admin.example.test/", "Apply")]
    [InlineData("Verification passed. Admin UI: https://admin.example.test/", "Verify")]
    public void TypedDeploymentVerification_ExposesTheAdminAddressIndependentlyOfSuccessProse(
        string message,
        string verificationMode)
    {
        var line = JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            type = "Result",
            message,
            data = new
            {
                step = "End-to-end deployment verification",
                category = "deploymentVerified",
                verified = true,
                verificationMode,
                index = 19,
                total = 19,
                adminUiUrl = "https://ca-gateway-admin-dev.safe.azurecontainerapps.io/",
                apiUrl = "https://ca-gateway-api-dev.safe.azurecontainerapps.io/",
                apiHealthUrl = "https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks"
            }
        });

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.DeploymentVerificationClaimObserved.Should().BeTrue();
        result.VerifiedEndpoints.Should().NotBeNull();
        result.VerifiedEndpoints!.VerificationMode.ToString().Should().Be(verificationMode);
        result.VerifiedEndpoints.AdminUiBaseAddress.Should().Be("https://ca-gateway-admin-dev.safe.azurecontainerapps.io/");
        result.VerifiedEndpoints.ApiBaseAddress.Should().Be("https://ca-gateway-api-dev.safe.azurecontainerapps.io/");
        result.VerifiedEndpoints.ApiHealthAddress.Should().Be("https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks");
    }

    [Fact]
    public void DeploymentVerificationMessageWithoutTypedAuthority_DoesNotExposeAnAddress()
    {
        const string line = """
            {"schemaVersion":1,"type":"Result","message":"Gateway deployment completed and verified.","data":{"step":"End-to-end deployment verification","index":19,"total":19,"adminUiUrl":"https://admin.example.test/"}}
            """;

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.DeploymentVerificationClaimObserved.Should().BeFalse();
        result.VerifiedEndpoints.Should().BeNull();
    }

    [Theory]
    [InlineData("Apply", "http://ca-gateway-admin-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks")]
    [InlineData("Apply", "https://ca-gateway-admin-dev.safe.azurecontainerapps.io/setup", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks")]
    [InlineData("Apply", "https://user@ca-gateway-admin-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks")]
    [InlineData("Apply", "https://ca-gateway-admin-dev.safe.azurecontainerapps.io/", "", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks")]
    [InlineData("Apply", "https://ca-gateway-admin-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/?query=unsafe", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks")]
    [InlineData("Apply", "https://ca-gateway-admin-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.other.azurecontainerapps.io/health/checks")]
    [InlineData("Apply", "https://ca-gateway-admin-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/health")]
    [InlineData("Apply", "https://10.0.0.1/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks")]
    [InlineData("Apply", "https://169.254.169.254/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks")]
    [InlineData("Apply", "https://gateway/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks")]
    [InlineData("Apply", "https://ca-gateway-admin-dev.safe.azurecontainerapps.io:8443/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks")]
    [InlineData("Apply", "https://ca-gateway-admin-dev.example.test/", "https://ca-gateway-api-dev.example.test/", "https://ca-gateway-api-dev.example.test/health/checks")]
    [InlineData("Apply", "https://ca-gateway-admin-staging.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks")]
    [InlineData("Resume", "https://ca-gateway-admin-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/", "https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks")]
    public void InvalidTypedDeploymentVerificationClaim_IsObservedButCannotSupplyEndpoints(
        string verificationMode,
        string adminUiUrl,
        string apiUrl,
        string apiHealthUrl)
    {
        var line = JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            type = "Result",
            message = "Gateway deployment completed and verified.",
            data = new
            {
                step = "End-to-end deployment verification",
                category = "deploymentVerified",
                verified = true,
                verificationMode,
                index = 19,
                total = 19,
                adminUiUrl,
                apiUrl,
                apiHealthUrl
            }
        });

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.DeploymentVerificationClaimObserved.Should().BeTrue();
        result.VerifiedEndpoints.Should().BeNull();
        result.Kind.Should().Be(BootstrapProgressKind.Error);
        result.Message.Should().Be(BootstrapOutputSanitizer.InvalidVerificationMessage);
    }

    [Fact]
    public void ConflictingDuplicateEndpointField_IsObservedButCannotSupplyEndpoints()
    {
        const string line = """
            {"schemaVersion":1,"type":"Result","message":"Gateway deployment completed and verified.","data":{"step":"End-to-end deployment verification","category":"deploymentVerified","verified":true,"verificationMode":"Apply","index":19,"total":19,"adminUiUrl":"https://ca-gateway-admin-dev.safe.azurecontainerapps.io/","apiUrl":"https://ca-gateway-api-dev.other.azurecontainerapps.io/","apiUrl":"https://ca-gateway-api-dev.safe.azurecontainerapps.io/","apiHealthUrl":"https://ca-gateway-api-dev.safe.azurecontainerapps.io/health/checks"}}
            """;

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.DeploymentVerificationClaimObserved.Should().BeTrue();
        result.VerifiedEndpoints.Should().BeNull();
        result.Kind.Should().Be(BootstrapProgressKind.Error);
        result.Message.Should().Be(BootstrapOutputSanitizer.InvalidVerificationMessage);
    }

    [Theory]
    [InlineData("plain child output with value abc123", false, BootstrapOutputSanitizer.LegacyMessage)]
    [InlineData("dependency failed: Bearer eyJaaaaaaaaaaa.bbbbbbbbbbb.cccccccc", true, "Bootstrap reported an error. Sensitive or unstructured details were withheld.")]
    [InlineData("{\"schemaVersion\":1,\"type\":\"Info\",\"message\":\"authorization token is abc\",\"data\":{}}", false, BootstrapOutputSanitizer.WithheldMessage)]
    [InlineData("{\"schemaVersion\":1,\"type\":\"result\",\"message\":\"Plan is ready for explicit acceptance.\",\"data\":{}}", false, BootstrapOutputSanitizer.WithheldMessage)]
    [InlineData("{\"arbitrary\":\"secret-value\"}", false, BootstrapOutputSanitizer.WithheldMessage)]
    public void UnsafeOrUnrecognizedOutput_IsNeverRenderedVerbatim(
        string input,
        bool standardError,
        string expected)
    {
        var result = BootstrapOutputSanitizer.Parse(input, standardError);

        result.Message.Should().Be(expected);
        result.Message.Should().NotContain("abc123");
        result.Message.Should().NotContain("secret-value");
        result.Message.Should().NotContain("eyJaaaaaaaaaaa");
    }

    [Fact]
    public void OversizedOutput_IsWithheld()
    {
        var result = BootstrapOutputSanitizer.Parse(new string('x', 4_097), standardError: false);

        result.Kind.Should().Be(BootstrapProgressKind.Withheld);
        result.Message.Should().Be(BootstrapOutputSanitizer.WithheldMessage);
    }

    [Theory]
    [InlineData("PhaseStarted", 3, 8, "Step", 25)]
    [InlineData("PhaseCompleted", 3, 8, "Success", 38)]
    [InlineData("Info", 3, 8, "Information", 38)]
    [InlineData("Warning", 3, 8, "Warning", 38)]
    [InlineData("Result", 8, 8, "Success", 100)]
    public void CanonicalEventEnvelope_IsMappedWithoutReadingUnknownData(
        string type,
        int index,
        int total,
        string expectedKindName,
        int expectedProgress)
    {
        var line = JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            type,
            message = "Reviewed bootstrap event",
            data = new
            {
                step = "Foundation",
                index,
                total,
                rawDependencyBody = "must not render"
            }
        });

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.Kind.Should().Be(Enum.Parse<BootstrapProgressKind>(expectedKindName));
        result.Message.Should().Be("Reviewed bootstrap event");
        result.Step.Should().Be("Foundation");
        result.ProgressPercent.Should().Be(expectedProgress);
        result.Message.Should().NotContain("must not render");
    }

    [Theory]
    [InlineData("Info", "Plan gwabcde-dev-1234; fingerprint sha256:0123456789abcdef", "scope")]
    [InlineData("Info", "Features: Registry preview closed; Content Safety shields enabled (F0); Purview disabled.", "features")]
    [InlineData("Info", "Azure foundation What-If: Create=4, Modify=1; applyReady=True.", "whatIf")]
    [InlineData("Warning", "Boundaries: Azure charges may apply; Registry preview creation remains closed; Entra, Agent 365, and optional Purview require separate administrator handoffs.", "boundaries")]
    public void RealPlanSummaryEnvelope_RemainsReviewable(
        string type,
        string message,
        string category)
    {
        var line = JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            timestampUtc = "2026-08-29T00:00:00Z",
            type,
            message,
            data = new
            {
                step = "Plan review",
                index = 1,
                total = 16,
                category,
                ignoredNestedDetails = new { raw = "must not render" }
            }
        });

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.Kind.Should().NotBe(BootstrapProgressKind.Withheld);
        result.Message.Should().Be(message);
        result.Step.Should().Be("Plan review");
        result.ProgressPercent.Should().BeNull();
        result.Message.Should().NotContain("must not render");
    }

    [Theory]
    [InlineData(true, "Plan is ready for explicit acceptance.")]
    [InlineData(false, "Plan is not apply-ready.")]
    public void ExactPlanResult_ExposesOnlyTheCanonicalApprovalContract(
        bool applyReady,
        string message)
    {
        var line = JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            type = "Result",
            message,
            data = new
            {
                step = "Plan review",
                index = 1,
                total = 16,
                category = "planResult",
                planFingerprint = ReviewedFingerprint,
                applyReady,
                unexpected = "must not render"
            }
        });

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.PlanFingerprint.Should().Be(ReviewedFingerprint);
        result.PlanApplyReady.Should().Be(applyReady);
        result.PlanResultClaimObserved.Should().BeTrue();
        result.ProgressPercent.Should().Be(100);
        result.Message.Should().Be(message);
        result.Message.Should().NotContain("must not render");
    }

    [Fact]
    public void StructuredLookingStandardError_CannotSupplyAnApprovalFingerprint()
    {
        var line = JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            type = "Result",
            message = "Plan is ready for explicit acceptance.",
            data = new
            {
                step = "Plan review",
                index = 1,
                total = 19,
                category = "planResult",
                planFingerprint = ReviewedFingerprint,
                applyReady = true
            }
        });

        var result = BootstrapOutputSanitizer.Parse(line, standardError: true);

        result.Kind.Should().Be(BootstrapProgressKind.Error);
        result.PlanFingerprint.Should().BeNull();
        result.PlanApplyReady.Should().BeNull();
        result.Message.Should().Be("Bootstrap reported an error. Sensitive or unstructured details were withheld.");
    }

    [Theory]
    [InlineData("sha256:ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789")]
    [InlineData("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg")]
    [InlineData("sha256:0123456789abcdef")]
    public void NonCanonicalPlanFingerprint_IsNeverAvailableForMutation(string fingerprint)
    {
        var line = JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            type = "Result",
            message = "Plan is ready for explicit acceptance.",
            data = new
            {
                step = "Plan review",
                index = 1,
                total = 16,
                category = "planResult",
                planFingerprint = fingerprint,
                applyReady = true
            }
        });

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.PlanFingerprint.Should().BeNull();
        result.PlanApplyReady.Should().BeNull();
        result.PlanResultClaimObserved.Should().BeTrue();
        result.Kind.Should().Be(BootstrapProgressKind.Error);
        result.Message.Should().Be(BootstrapOutputSanitizer.InvalidPlanResultMessage);
    }

    [Fact]
    public void TypedPlanClaimWithUnsafeMessage_IsStillObservedAndRejected()
    {
        var line = JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            type = "Result",
            message = "authorization token must never render",
            data = new
            {
                step = "Plan review",
                index = 1,
                total = 19,
                category = "planResult",
                planFingerprint = ReviewedFingerprint,
                applyReady = true
            }
        });

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.PlanResultClaimObserved.Should().BeTrue();
        result.PlanFingerprint.Should().BeNull();
        result.PlanApplyReady.Should().BeNull();
        result.Kind.Should().Be(BootstrapProgressKind.Error);
        result.Message.Should().Be(BootstrapOutputSanitizer.InvalidPlanResultMessage);
        result.Message.Should().NotContain("token must never render");
    }

    [Theory]
    [InlineData("resourceFamily", "Resource family 1/3: Azure Container Apps.", "Azure resource family")]
    [InlineData("imperativeOperation", "Imperative operation 1/2: Entra application creation is a mutation.", "Imperative operation")]
    [InlineData("whatIfChange", "What-If change 1/2: Create /subscriptions/0000/resourceGroups/rg-gwabcde-dev.", "Sanitized What-If change")]
    [InlineData("costBoundary", "Cost boundary 1/2: Azure consumption charges may apply.", "Cost boundary")]
    [InlineData("previewBoundary", "Preview boundary 1/1: Registry preview remains closed.", "Preview boundary")]
    [InlineData("administratorBoundary", "Administrator boundary 1/2: Entra consent requires an official handoff.", "Administrator boundary")]
    [InlineData("notChecked", "Not checked 1/2: tenant license eligibility.", "Not checked by Plan")]
    public void BoundedPlanDetailEvents_AreClearlyLabeledWithoutRenderingArbitraryData(
        string category,
        string message,
        string expectedLabel)
    {
        var line = JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            timestampUtc = "2026-08-29T00:00:00Z",
            type = "Info",
            message,
            data = new
            {
                step = "Plan review",
                index = 1,
                total = 19,
                category,
                position = 1,
                itemTotal = 2,
                resourceFamily = "ignored in favor of bounded message",
                system = "ignored",
                operation = "ignored",
                mutation = true,
                changeType = "ignored",
                resourceId = "ignored",
                detail = "arbitrary-data-sentinel-must-not-render"
            }
        });

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.Kind.Should().Be(BootstrapProgressKind.Information);
        result.DisplayLabel.Should().Be(expectedLabel);
        result.Message.Should().Be(message);
        result.Message.Should().NotContain("arbitrary-data-sentinel");
    }

    [Fact]
    public void ExactResumeReview_ExposesOnlyTheCanonicalReviewAuthorizationContract()
    {
        var line = ResumeReviewLine();

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.Kind.Should().Be(BootstrapProgressKind.Success);
        result.Step.Should().Be("Resume preflight");
        result.ResumeReviewClaimObserved.Should().BeTrue();
        result.ResumeAuthorization.Should().NotBeNull();
        result.ResumeAuthorization!.AcceptedPlanFingerprint.Should().Be(ReviewedFingerprint);
        result.ResumeAuthorization.CheckpointFingerprint.Should().Be(CheckpointFingerprint);
        result.ResumeAuthorization.ResumeAuthorizationFingerprint.Should().Be(ResumeAuthorizationFingerprint);
        result.Message.Should().Be(
            "Resume preflight validated 4 completed checkpoints. Remaining work starts at 'Azure foundation'.");
        result.Message.Should().NotContain("must not render");
        result.PlanFingerprint.Should().BeNull("a Resume review never supplies a Plan acceptance fingerprint");
        result.PlanResultClaimObserved.Should().BeFalse();
        result.DeploymentVerificationClaimObserved.Should().BeFalse();
    }

    [Theory]
    [InlineData("Resume preflight validated 5 completed checkpoints. Remaining work starts at 'Azure foundation'.")]
    [InlineData("Resume preflight validated 4 completed checkpoints. Remaining work starts at 'Container images'.")]
    [InlineData("Resume is authorized.")]
    [InlineData("authorization token must never render")]
    public void ResumeReviewMessageThatDoesNotBindToItsData_IsObservedButAuthorizesNothing(string message)
    {
        var line = ResumeReviewLine(message: message);

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.ResumeReviewClaimObserved.Should().BeTrue();
        result.ResumeAuthorization.Should().BeNull();
        result.Kind.Should().Be(BootstrapProgressKind.Error);
        result.Message.Should().Be(BootstrapOutputSanitizer.InvalidResumeReviewMessage);
        result.Message.Should().NotContain("token must never render");
    }

    [Fact]
    public void ResumeReviewThatClaimsItIsAlreadyAuthorized_IsObservedButAuthorizesNothing()
    {
        var line = ResumeReviewLine(authorized: true);

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.ResumeReviewClaimObserved.Should().BeTrue();
        result.ResumeAuthorization.Should().BeNull();
        result.Kind.Should().Be(BootstrapProgressKind.Error);
        result.Message.Should().Be(BootstrapOutputSanitizer.InvalidResumeReviewMessage);
    }

    [Theory]
    [InlineData("sha256:ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789", null, null)]
    [InlineData("sha256:0123456789abcdef", null, null)]
    [InlineData(null, "sha256:1111111122222222", null)]
    [InlineData(null, "", null)]
    [InlineData(null, null, "sha256:9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcbz")]
    [InlineData(null, null, "not-a-fingerprint")]
    public void NonCanonicalResumeFingerprint_IsNeverAvailableForResume(
        string? acceptedPlanFingerprint,
        string? checkpointFingerprint,
        string? resumeAuthorizationFingerprint)
    {
        var line = ResumeReviewLine(
            acceptedPlanFingerprint: acceptedPlanFingerprint ?? ReviewedFingerprint,
            checkpointFingerprint: checkpointFingerprint ?? CheckpointFingerprint,
            resumeAuthorizationFingerprint: resumeAuthorizationFingerprint ?? ResumeAuthorizationFingerprint);

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.ResumeReviewClaimObserved.Should().BeTrue();
        result.ResumeAuthorization.Should().BeNull();
        result.Kind.Should().Be(BootstrapProgressKind.Error);
        result.Message.Should().Be(BootstrapOutputSanitizer.InvalidResumeReviewMessage);
    }

    [Fact]
    public void ConflictingDuplicateResumeAuthorizationField_IsObservedButAuthorizesNothing()
    {
        const string line = """
            {"schemaVersion":1,"type":"Result","message":"Resume preflight validated 4 completed checkpoints. Remaining work starts at 'Azure foundation'.","data":{"step":"Resume preflight","category":"resumeReview","index":1,"total":19,"completedCount":4,"remainingCount":15,"currentStep":"Azure foundation","acceptedPlanFingerprint":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","checkpointFingerprint":"sha256:1111111122222222111111112222222211111111222222221111111122222222","resumeAuthorizationFingerprint":"sha256:0000000000000000000000000000000000000000000000000000000000000000","resumeAuthorizationFingerprint":"sha256:9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba","authorized":false}}
            """;

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.ResumeReviewClaimObserved.Should().BeTrue();
        result.ResumeAuthorization.Should().BeNull();
        result.Kind.Should().Be(BootstrapProgressKind.Error);
        result.Message.Should().Be(BootstrapOutputSanitizer.InvalidResumeReviewMessage);
    }

    [Fact]
    public void ResumeReviewMissingItsCheckpointBinding_IsObservedButAuthorizesNothing()
    {
        var line = JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            type = "Result",
            message =
                "Resume preflight validated 4 completed checkpoints. Remaining work starts at 'Azure foundation'.",
            data = new
            {
                step = "Resume preflight",
                category = "resumeReview",
                index = 1,
                total = 19,
                completedCount = 4,
                remainingCount = 15,
                currentStep = "Azure foundation",
                acceptedPlanFingerprint = ReviewedFingerprint,
                resumeAuthorizationFingerprint = ResumeAuthorizationFingerprint,
                authorized = false
            }
        });

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.ResumeReviewClaimObserved.Should().BeTrue();
        result.ResumeAuthorization.Should().BeNull();
        result.Kind.Should().Be(BootstrapProgressKind.Error);
        result.Message.Should().Be(BootstrapOutputSanitizer.InvalidResumeReviewMessage);
    }

    [Theory]
    [InlineData(0, 19)]
    [InlineData(2, 19)]
    [InlineData(1, 0)]
    [InlineData(1, 10_001)]
    public void ResumeReviewOutsideItsSinglePreflightPosition_IsObservedButAuthorizesNothing(int index, int total)
    {
        var line = ResumeReviewLine(index: index, total: total);

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.ResumeReviewClaimObserved.Should().BeTrue();
        result.ResumeAuthorization.Should().BeNull();
        result.Kind.Should().Be(BootstrapProgressKind.Error);
        result.Message.Should().Be(BootstrapOutputSanitizer.InvalidResumeReviewMessage);
    }

    [Fact]
    public void StructuredLookingStandardErrorResumeReview_CannotAuthorizeResume()
    {
        var line = ResumeReviewLine();

        var result = BootstrapOutputSanitizer.Parse(line, standardError: true);

        result.Kind.Should().Be(BootstrapProgressKind.Error);
        result.ResumeReviewClaimObserved.Should().BeFalse();
        result.ResumeAuthorization.Should().BeNull();
        result.Message.Should().Be("Bootstrap reported an error. Sensitive or unstructured details were withheld.");
    }

    [Theory]
    [InlineData("Resume preflight", "resumeAuthorization")]
    [InlineData("Plan review", "resumeReview")]
    [InlineData("Resume preflight", "planResult")]
    public void ResumeAuthorizationOutsideTheTypedReviewContract_IsNotAReviewClaim(string step, string category)
    {
        var line = ResumeReviewLine(step: step, category: category);

        var result = BootstrapOutputSanitizer.Parse(line, standardError: false);

        result.ResumeReviewClaimObserved.Should().BeFalse();
        result.ResumeAuthorization.Should().BeNull();
    }

    private static string ResumeReviewLine(
        string? message = null,
        string step = "Resume preflight",
        string category = "resumeReview",
        int index = 1,
        int total = 19,
        int completedCount = 4,
        int remainingCount = 15,
        string currentStep = "Azure foundation",
        string acceptedPlanFingerprint = ReviewedFingerprint,
        string checkpointFingerprint = CheckpointFingerprint,
        string resumeAuthorizationFingerprint = ResumeAuthorizationFingerprint,
        bool authorized = false) =>
        JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            timestampUtc = "2026-08-29T00:00:00Z",
            type = "Result",
            message = message ??
                $"Resume preflight validated {completedCount} completed checkpoints. " +
                $"Remaining work starts at '{currentStep}'.",
            data = new
            {
                step,
                category,
                index,
                total,
                completedCount,
                remainingCount,
                currentStep,
                acceptedPlanFingerprint,
                checkpointFingerprint,
                resumeAuthorizationFingerprint,
                authorized,
                unexpected = "must not render"
            }
        });
}
