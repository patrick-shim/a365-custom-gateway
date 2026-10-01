using System.Diagnostics.CodeAnalysis;
using System.Net;
using FluentAssertions;
using Gateway.Setup.Security;
using Microsoft.AspNetCore.Http;

namespace Gateway.Setup.Tests.Security;

public sealed class SetupBoundaryMiddlewareTests
{
    private const string FixtureNonce = "offline-fixture-nonce";

    [Fact]
    public async Task NonceEstablishesOneInMemorySessionWithoutCallingAnEndpointAndCannotBeReplayed()
    {
        var session = new FixtureSession();
        var gate = SessionNonceGate.FromKnownNonce(FixtureNonce);
        var calls = 0;
        var middleware = new SetupBoundaryMiddleware(context =>
        {
            calls++;
            context.Response.StatusCode = StatusCodes.Status200OK;
            return Task.CompletedTask;
        });
        var initial = Request(session, "GET", "/setup", FixtureNonce);

        await middleware.InvokeAsync(initial, gate, new SetupActivityTracker());

        initial.Response.StatusCode.Should().Be(StatusCodes.Status302Found);
        initial.Response.Headers.Location.ToString().Should().Be("/setup/welcome");
        session.GetString(SetupSessionPolicy.SessionKey).Should().Be("1");
        session.CommitCount.Should().Be(1);
        calls.Should().Be(0);
        var replay = Request(new FixtureSession(), "GET", "/setup", FixtureNonce);
        await middleware.InvokeAsync(replay, gate, new SetupActivityTracker());
        replay.Response.StatusCode.Should().Be(StatusCodes.Status404NotFound);
        calls.Should().Be(0);

        var authorized = Request(session, "GET", "/setup/welcome");
        await middleware.InvokeAsync(authorized, gate, new SetupActivityTracker());
        authorized.Response.StatusCode.Should().Be(StatusCodes.Status200OK);
        authorized.Response.Headers.CacheControl.ToString().Should().Contain("no-store");
        authorized.Response.Headers["Referrer-Policy"].ToString().Should().Be("no-referrer");
        authorized.Response.Headers.XFrameOptions.ToString().Should().Be("DENY");
        calls.Should().Be(1);
    }

    [Theory]
    [InlineData("localhost:43123", "127.0.0.1")]
    [InlineData("127.0.0.1:43123", "192.0.2.10")]
    public async Task WrongHostOrConnectionCannotConsumeANonceOrReachAnEndpoint(string host, string remote)
    {
        var session = new FixtureSession();
        var gate = SessionNonceGate.FromKnownNonce(FixtureNonce);
        var context = Request(session, "GET", "/setup", FixtureNonce);
        context.Request.Host = HostString.FromUriComponent(host);
        context.Connection.RemoteIpAddress = IPAddress.Parse(remote);
        var middleware = new SetupBoundaryMiddleware(_ =>
            throw new InvalidOperationException("An unauthorized fixture reached the endpoint."));

        await middleware.InvokeAsync(context, gate, new SetupActivityTracker());

        context.Response.StatusCode.Should().Be(StatusCodes.Status404NotFound);
        session.Keys.Should().BeEmpty();
        session.CommitCount.Should().Be(0);
        gate.TryConsume(FixtureNonce).Should().BeTrue();
    }

    [Theory]
    [InlineData("GET", 200)]
    [InlineData("HEAD", 200)]
    [InlineData("POST", 404)]
    public async Task StaticAssetAccessNeverAuthorizesASession(string method, int expectedStatus)
    {
        var session = new FixtureSession();
        var gate = SessionNonceGate.FromKnownNonce(FixtureNonce);
        var context = Request(session, method, "/app.fixture.css");
        var calls = 0;
        var middleware = new SetupBoundaryMiddleware(_ =>
        {
            calls++;
            return Task.CompletedTask;
        });

        await middleware.InvokeAsync(context, gate, new SetupActivityTracker());

        context.Response.StatusCode.Should().Be(expectedStatus);
        calls.Should().Be(expectedStatus == 200 ? 1 : 0);
        session.Keys.Should().BeEmpty();
        session.CommitCount.Should().Be(0);
        gate.TryConsume(FixtureNonce).Should().BeTrue();
    }

    [Fact]
    public async Task AnUnauthenticatedPageRequestNeverRunsItsEndpoint()
    {
        var gate = SessionNonceGate.FromKnownNonce(FixtureNonce);
        var context = Request(new FixtureSession(), "GET", "/setup/account");
        var middleware = new SetupBoundaryMiddleware(_ =>
            throw new InvalidOperationException("An unauthorized fixture attempted account discovery."));

        await middleware.InvokeAsync(context, gate, new SetupActivityTracker());

        context.Response.StatusCode.Should().Be(StatusCodes.Status404NotFound);
        gate.TryConsume(FixtureNonce).Should().BeTrue();
    }

    private static DefaultHttpContext Request(
        FixtureSession session, string method, string path, string? nonce = null)
    {
        var context = new DefaultHttpContext { Session = session };
        context.Connection.RemoteIpAddress = IPAddress.Loopback;
        context.Connection.LocalIpAddress = IPAddress.Loopback;
        context.Request.Host = new HostString("127.0.0.1", 43123);
        context.Request.Method = method;
        context.Request.Path = path;
        if (nonce is not null)
        {
            context.Request.QueryString = QueryString.Create("nonce", nonce);
        }

        return context;
    }

    private sealed class FixtureSession : ISession
    {
        private readonly Dictionary<string, byte[]> values = new(StringComparer.Ordinal);
        public string Id => "offline-fixture-session";
        public bool IsAvailable => true;
        public IEnumerable<string> Keys => values.Keys;
        public int CommitCount { get; private set; }
        public void Clear() => values.Clear();
        public void Remove(string key) => values.Remove(key);
        public bool TryGetValue(string key, [NotNullWhen(true)] out byte[]? value) => values.TryGetValue(key, out value);

        public void Set(string key, byte[] value)
        {
            Assert.Equal(SetupSessionPolicy.SessionKey, key);
            Assert.Single(value);
            values[key] = value.ToArray();
        }

        public Task LoadAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }

        public Task CommitAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            CommitCount++;
            return Task.CompletedTask;
        }
    }
}
