using FluentAssertions;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using Microsoft.Identity.Web;
using Gateway.LiveVerification;
using System.Text;
using System.Text.Json;

namespace Gateway.SecurityTests;

public class MicrosoftIdentityAudienceTests
{
    private static readonly Guid ApiClientId = Guid.Parse("22222222-2222-4222-8222-222222222222");
    private static readonly Guid TenantId = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid UserObjectId = Guid.Parse("33333333-3333-4333-8333-333333333333");
    private static readonly Guid AuthenticationClientId = Guid.Parse("55555555-5555-4555-8555-555555555555");

    [Fact]
    public void ExplicitV2TokenAudience_ShouldUseBareApiClientIdNotCustomScopeUri()
    {
        const string clientId = "22222222-2222-4222-8222-222222222222";
        const string scopeBaseUri = "api://a365-gateway-safe-dev";
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["EntraId:Instance"] = "https://login.microsoftonline.com/",
                ["EntraId:TenantId"] = "11111111-1111-4111-8111-111111111111",
                ["EntraId:ClientId"] = clientId,
                ["EntraId:Audience"] = clientId
            })
            .Build();
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddSingleton<IConfiguration>(configuration);
        services
            .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddMicrosoftIdentityWebApi(configuration.GetSection("EntraId"));

        using var provider = services.BuildServiceProvider();
        var options = provider
            .GetRequiredService<IOptionsMonitor<JwtBearerOptions>>()
            .Get(JwtBearerDefaults.AuthenticationScheme);

        options.TokenValidationParameters.ValidAudience.Should().Be(clientId);
        options.TokenValidationParameters.ValidAudience.Should().NotBe(scopeBaseUri);
    }

    [Fact]
    public void InteractiveVerificationToken_ShouldRequireExactV2AudienceTenantUserRoleAndScope()
    {
        var token = CreateUnsignedTestJwt(new
        {
            aud = ApiClientId.ToString("D"),
            tid = TenantId.ToString("D"),
            azp = AuthenticationClientId.ToString("D"),
            oid = UserObjectId.ToString("D"),
            roles = new[] { "Gateway.Administrator" },
            scp = "access_as_user"
        });

        var act = () => ControlTokenValidator.Validate(
            token,
            ApiClientId,
            TenantId,
            requireDelegatedUser: true,
            UserObjectId,
            AuthenticationClientId);

        act.Should().NotThrow();
    }

    [Theory]
    [InlineData("aud")]
    [InlineData("tid")]
    [InlineData("azp")]
    [InlineData("oid")]
    [InlineData("roles")]
    [InlineData("scp")]
    public void InteractiveVerificationToken_ShouldRejectEveryAuthorityBoundaryDrift(string drift)
    {
        var token = CreateUnsignedTestJwt(new
        {
            aud = drift == "aud" ? Guid.NewGuid().ToString("D") : ApiClientId.ToString("D"),
            tid = drift == "tid" ? Guid.NewGuid().ToString("D") : TenantId.ToString("D"),
            azp = drift == "azp" ? Guid.NewGuid().ToString("D") : AuthenticationClientId.ToString("D"),
            oid = drift == "oid" ? Guid.NewGuid().ToString("D") : UserObjectId.ToString("D"),
            roles = new[] { drift == "roles" ? "Gateway.Operator" : "Gateway.Administrator" },
            scp = drift == "scp" ? "different_scope" : "access_as_user"
        });

        var act = () => ControlTokenValidator.Validate(
            token,
            ApiClientId,
            TenantId,
            requireDelegatedUser: true,
            UserObjectId,
            AuthenticationClientId);

        act.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void ManagedIdentityVerificationToken_ShouldRejectDelegatedScopeClaims()
    {
        var token = CreateUnsignedTestJwt(new
        {
            aud = ApiClientId.ToString("D"),
            tid = TenantId.ToString("D"),
            roles = new[] { "Gateway.Administrator" },
            scp = "access_as_user"
        });

        var act = () => ControlTokenValidator.Validate(
            token,
            ApiClientId,
            TenantId,
            requireDelegatedUser: false,
            Guid.Empty,
            expectedClientApplicationId: null);

        act.Should().Throw<InvalidOperationException>();
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void InteractiveVerificationToken_ShouldRejectBroadenedRoleOrScopeSets(bool broadenRoles)
    {
        var token = CreateUnsignedTestJwt(new
        {
            aud = ApiClientId.ToString("D"),
            tid = TenantId.ToString("D"),
            azp = AuthenticationClientId.ToString("D"),
            oid = UserObjectId.ToString("D"),
            roles = broadenRoles
                ? new[] { "Gateway.Administrator", "Gateway.Operator" }
                : new[] { "Gateway.Administrator" },
            scp = broadenRoles ? "access_as_user" : "access_as_user unexpected_scope"
        });

        var act = () => ControlTokenValidator.Validate(
            token,
            ApiClientId,
            TenantId,
            requireDelegatedUser: true,
            UserObjectId,
            AuthenticationClientId);

        act.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void VerificationEvidence_ShouldBindIssuanceAndRevocationToTheExactRegistrationAndKey()
    {
        var credentialId = Guid.Parse("44444444-4444-4444-8444-444444444444");
        var issued = new IssueCredentialResponse(
            ApiClientId,
            "agent-safe",
            new GatewayCredential(credentialId, "temporary-in-memory-value", DateTime.UtcNow.AddHours(1)));
        var revoked = new RevokeCredentialResponse(
            ApiClientId,
            new CredentialMetadata(
                credentialId,
                DateTime.UtcNow.AddMinutes(-1),
                DateTime.UtcNow.AddHours(1),
                DateTime.UtcNow),
            AlreadyRevoked: true);

        VerificationEvidenceValidator.ValidateIssuedCredential(issued, ApiClientId, "agent-safe");
        VerificationEvidenceValidator.ValidateRevokedCredential(revoked, ApiClientId, credentialId);

        var wrongIssue = () => VerificationEvidenceValidator.ValidateIssuedCredential(
            issued with { AgentId = Guid.NewGuid() },
            ApiClientId,
            "agent-safe");
        var wrongRevocation = () => VerificationEvidenceValidator.ValidateRevokedCredential(
            revoked with { Credential = revoked.Credential with { KeyId = Guid.NewGuid() } },
            ApiClientId,
            credentialId);
        wrongIssue.Should().Throw<InvalidOperationException>();
        wrongRevocation.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void VerificationEvidence_ShouldRenderOnlyExactDecisionsAndCanonicalCorrelations()
    {
        var correlationId = Guid.Parse("77777777-7777-4777-8777-777777777777");
        var middlewareCorrelationId = Guid.Parse("88888888-8888-4888-8888-888888888888");
        var allowed = new PromptEvaluation(
            Guid.NewGuid(),
            true,
            "PROMPT_ALLOWED",
            "Allowed",
            "AuditLogged",
            correlationId.ToString("D"),
            middlewareCorrelationId.ToString("D"));
        var blocked = new PromptEvaluation(
            null,
            false,
            "PROMPT_BLOCKED_BY_PROMPT_SHIELD",
            "Blocked",
            "AuditLogged",
            correlationId.ToString("D"),
            middlewareCorrelationId.ToString("D"));

        VerificationEvidenceValidator.ValidateAllowedEvaluation(
                allowed,
                expectPromptShieldEnabled: true,
                expectPurviewEnabled: true)
            .CorrelationId
            .Should().Be(correlationId.ToString("D"));
        VerificationEvidenceValidator.ValidateBlockedEvaluation(blocked, expectPurviewEnabled: true).CorrelationId
            .Should().Be(correlationId.ToString("D"));

        var untrustedDecision = () => VerificationEvidenceValidator.ValidateBlockedEvaluation(
            blocked with { PurviewProcessing = "provider-controlled-text" },
            expectPurviewEnabled: true);
        var malformedCorrelation = () => VerificationEvidenceValidator.ValidateAllowedEvaluation(
            allowed with { HeaderCorrelationId = "provider-controlled-text" },
            expectPromptShieldEnabled: true,
            expectPurviewEnabled: true);
        untrustedDecision.Should().Throw<InvalidOperationException>();
        malformedCorrelation.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void MinimalProfileVerificationEvidence_ShouldRequireBothProtectionsDisabled()
    {
        var allowed = new PromptEvaluation(
            Guid.NewGuid(),
            true,
            "PROMPT_ALLOWED",
            "Disabled",
            "PurviewDisabled",
            "77777777-7777-4777-8777-777777777777",
            "88888888-8888-4888-8888-888888888888");

        VerificationEvidenceValidator.ValidateAllowedEvaluation(
                allowed,
                expectPromptShieldEnabled: false,
                expectPurviewEnabled: false)
            .Should().BeEquivalentTo(allowed);

        var unexpectedPromptShield = () => VerificationEvidenceValidator.ValidateAllowedEvaluation(
            allowed with { PromptShieldProcessing = "Allowed" },
            expectPromptShieldEnabled: false,
            expectPurviewEnabled: false);
        var unexpectedPurview = () => VerificationEvidenceValidator.ValidateAllowedEvaluation(
            allowed with { PurviewProcessing = "Allowed" },
            expectPromptShieldEnabled: false,
            expectPurviewEnabled: false);
        unexpectedPromptShield.Should().Throw<InvalidOperationException>();
        unexpectedPurview.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void FullVerificationOptions_ShouldBindExactProtectionExpectations()
    {
        var arguments = VerificationArguments("Full");
        arguments[Array.IndexOf(arguments, "--expect-prompt-shield-enabled") + 1] = "true";

        var options = Options.Parse(arguments);

        options.ExpectPromptShieldEnabled.Should().BeTrue();
        options.ExpectPurviewEnabled.Should().BeFalse();
    }

    [Theory]
    [InlineData("True")]
    [InlineData("FALSE")]
    [InlineData("1")]
    public void VerificationOptions_ShouldRejectNonCanonicalProtectionExpectation(string value)
    {
        var arguments = VerificationArguments("Full");
        arguments[Array.IndexOf(arguments, "--expect-prompt-shield-enabled") + 1] = value;

        var act = () => Options.Parse(arguments);

        act.Should().Throw<ArgumentException>()
            .WithMessage("*canonical lowercase true or false*");
    }

    [Fact]
    public void VerificationOptions_ShouldRequireBothProtectionExpectations()
    {
        var arguments = VerificationArguments("Full").ToList();
        var optionIndex = arguments.IndexOf("--expect-purview-enabled");
        arguments.RemoveRange(optionIndex, 2);

        var act = () => Options.Parse(arguments.ToArray());

        act.Should().Throw<ArgumentException>()
            .WithMessage("*--expect-purview-enabled is required*");
    }

    [Fact]
    public void RevokeOnlyVerificationOptions_ShouldRequireAndBindExactRecoveryCredentialId()
    {
        var recoveryCredentialId = Guid.Parse("44444444-4444-4444-8444-444444444444");

        var options = Options.Parse(VerificationArguments(
            "RevokeOnly",
            "--recovery-credential-id",
            recoveryCredentialId.ToString("D")));

        options.OperationMode.Should().Be(VerificationOperationMode.RevokeOnly);
        options.RecoveryCredentialId.Should().Be(recoveryCredentialId);
    }

    [Fact]
    public void RevokeOnlyVerificationOptions_ShouldRejectMissingRecoveryCredentialId()
    {
        var act = () => Options.Parse(VerificationArguments("RevokeOnly"));

        act.Should().Throw<ArgumentException>()
            .WithMessage("*--recovery-credential-id is required*");
    }

    [Fact]
    public void FullVerificationOptions_ShouldRejectRecoveryCredentialId()
    {
        var act = () => Options.Parse(VerificationArguments(
            "Full",
            "--recovery-credential-id",
            "44444444-4444-4444-8444-444444444444"));

        act.Should().Throw<ArgumentException>()
            .WithMessage("*accepted only for RevokeOnly*");
    }

    private static string[] VerificationArguments(string operationMode, params string[] additional)
    {
        var values = new List<string>
        {
            "--api-base-url", "https://gateway.example/",
            "--api-application-client-id", ApiClientId.ToString("D"),
            "--api-scope-base-uri", "api://a365-gateway-safe-dev",
            "--tenant-id", TenantId.ToString("D"),
            "--authentication-mode", "InteractiveBrowserUser",
            "--authentication-client-id", "55555555-5555-4555-8555-555555555555",
            "--operation-mode", operationMode,
            "--agent-registration-id", "66666666-6666-4666-8666-666666666666",
            "--external-agent-id", "agent-safe",
            "--tenant-user-object-id", UserObjectId.ToString("D"),
            "--expect-prompt-shield-enabled", "false",
            "--expect-purview-enabled", "false"
        };
        values.AddRange(additional);
        return values.ToArray();
    }

    private static string CreateUnsignedTestJwt(object claims)
    {
        static string Encode(byte[] value) => Convert.ToBase64String(value)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

        var header = Encode(Encoding.UTF8.GetBytes("{\"alg\":\"none\"}"));
        var payload = Encode(JsonSerializer.SerializeToUtf8Bytes(claims));
        return $"{header}.{payload}.test-signature";
    }
}
