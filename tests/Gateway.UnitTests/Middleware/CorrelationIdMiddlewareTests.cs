using FluentAssertions;
using Gateway.Api.Middleware;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using NSubstitute;

namespace Gateway.UnitTests.Middleware;

public sealed class CorrelationIdMiddlewareTests
{
    [Fact]
    public async Task InvokeAsync_PreservesOneSafeCallerCorrelationId()
    {
        var context = new DefaultHttpContext();
        context.Request.Headers["X-Correlation-Id"] = "client.trace_123";
        var middleware = CreateMiddleware(_ => Task.CompletedTask);

        await middleware.InvokeAsync(context);

        context.Items["CorrelationId"].Should().Be("client.trace_123");
        context.Response.Headers["X-Correlation-Id"].ToString().Should().Be("client.trace_123");
    }

    [Theory]
    [InlineData("")]
    [InlineData("contains spaces")]
    [InlineData("contains/slash")]
    public async Task InvokeAsync_ReplacesUnsafeCallerCorrelationId(string supplied)
    {
        var context = new DefaultHttpContext();
        context.Request.Headers["X-Correlation-Id"] = supplied;
        var middleware = CreateMiddleware(_ => Task.CompletedTask);

        await middleware.InvokeAsync(context);

        Guid.TryParse(context.Items["CorrelationId"] as string, out _).Should().BeTrue();
    }

    [Fact]
    public async Task InvokeAsync_ReplacesOversizedCallerCorrelationId()
    {
        var context = new DefaultHttpContext();
        context.Request.Headers["X-Correlation-Id"] = new string('a', 129);
        var middleware = CreateMiddleware(_ => Task.CompletedTask);

        await middleware.InvokeAsync(context);

        Guid.TryParse(context.Items["CorrelationId"] as string, out _).Should().BeTrue();
    }

    private static CorrelationIdMiddleware CreateMiddleware(RequestDelegate next) =>
        new(next, Substitute.For<ILogger<CorrelationIdMiddleware>>());
}
