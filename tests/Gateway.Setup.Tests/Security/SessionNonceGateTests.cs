using FluentAssertions;
using Gateway.Setup.Security;

namespace Gateway.Setup.Tests.Security;

public sealed class SessionNonceGateTests
{
    [Fact]
    public void GeneratedNonce_IsHighEntropyUrlSafeAndSingleUse()
    {
        var issue = SessionNonceGate.Create();

        issue.Nonce.Should().MatchRegex("^[A-Za-z0-9_-]{43}$");
        issue.Gate.TryConsume("wrong-value").Should().BeFalse();
        issue.Gate.TryConsume(issue.Nonce).Should().BeTrue();
        issue.Gate.TryConsume(issue.Nonce).Should().BeFalse();
    }

    [Fact]
    public void SessionPolicy_EstablishesOnlyFromExactInitialGet()
    {
        const string nonce = "known-session-nonce";
        var gate = SessionNonceGate.FromKnownNonce(nonce);

        SetupSessionPolicy.Evaluate(false, "POST", "/setup", nonce, gate)
            .Should().Be(SessionDecision.Deny);
        SetupSessionPolicy.Evaluate(false, "GET", "/setup/welcome", nonce, gate)
            .Should().Be(SessionDecision.Deny);
        SetupSessionPolicy.Evaluate(false, "GET", "/setup", nonce, gate)
            .Should().Be(SessionDecision.Establish);
        SetupSessionPolicy.Evaluate(false, "GET", "/setup", nonce, gate)
            .Should().Be(SessionDecision.Deny);
        SetupSessionPolicy.Evaluate(true, "POST", "/_blazor", null, gate)
            .Should().Be(SessionDecision.Allow);
    }
}
