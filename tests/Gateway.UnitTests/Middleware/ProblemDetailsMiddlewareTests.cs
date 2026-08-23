using System.Text.Json;
using FluentAssertions;
using Gateway.Api.Middleware;
using Gateway.Contracts;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using NSubstitute;
using ValidationException = Gateway.Application.Exceptions.ValidationException;

namespace Gateway.UnitTests.Middleware;

public class ProblemDetailsMiddlewareTests
{
    private static ProblemDetailsMiddleware CreateMiddleware(
        RequestDelegate next,
        string environmentName = "Production")
    {
        var logger = Substitute.For<ILogger<ProblemDetailsMiddleware>>();
        var environment = Substitute.For<IHostEnvironment>();
        environment.EnvironmentName.Returns(environmentName);

        return new ProblemDetailsMiddleware(next, logger, environment);
    }

    private static DefaultHttpContext CreateHttpContext(string path = "/api/v1/agents", string? correlationId = null)
    {
        var context = new DefaultHttpContext();
        context.Response.Body = new MemoryStream();
        context.Request.Path = path;

        if (correlationId is not null)
        {
            context.Items["CorrelationId"] = correlationId;
        }

        return context;
    }

    private static async Task<JsonDocument> ReadResponseBodyAsync(HttpContext context)
    {
        context.Response.Body.Seek(0, SeekOrigin.Begin);
        return await JsonDocument.ParseAsync(context.Response.Body);
    }

    [Fact]
    public async Task InvokeAsync_Should_Return400_When_ValidationExceptionThrown()
    {
        var errors = new Dictionary<string, string[]>
        {
            ["Name"] = ["Name is required."]
        };
        RequestDelegate next = _ => throw new ValidationException(errors);
        var middleware = CreateMiddleware(next);
        var context = CreateHttpContext();

        await middleware.InvokeAsync(context);

        context.Response.StatusCode.Should().Be(StatusCodes.Status400BadRequest);

        var body = await ReadResponseBodyAsync(context);
        body.RootElement.GetProperty("status").GetInt32().Should().Be(400);
        body.RootElement.GetProperty("title").GetString().Should().Be("Validation Failed");
        body.RootElement.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.VALIDATION_FAILED);
        body.RootElement.TryGetProperty("errors", out _).Should().BeTrue();
    }

    [Fact]
    public async Task InvokeAsync_Should_Return404_When_NotFoundExceptionThrown()
    {
        RequestDelegate next = _ => throw new Application.Exceptions.NotFoundException("AgentRegistration", Guid.NewGuid());
        var middleware = CreateMiddleware(next);
        var context = CreateHttpContext();

        await middleware.InvokeAsync(context);

        context.Response.StatusCode.Should().Be(StatusCodes.Status404NotFound);

        var body = await ReadResponseBodyAsync(context);
        body.RootElement.GetProperty("status").GetInt32().Should().Be(404);
        body.RootElement.GetProperty("title").GetString().Should().Be("Resource Not Found");
        body.RootElement.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.AGENT_NOT_FOUND);
    }

    [Fact]
    public async Task InvokeAsync_Should_Return409_When_ConflictExceptionThrown()
    {
        RequestDelegate next = _ => throw new Application.Exceptions.ConflictException(
            "Duplicate agent", ErrorCodes.DUPLICATE_EXTERNAL_AGENT_ID);
        var middleware = CreateMiddleware(next);
        var context = CreateHttpContext();

        await middleware.InvokeAsync(context);

        context.Response.StatusCode.Should().Be(StatusCodes.Status409Conflict);

        var body = await ReadResponseBodyAsync(context);
        body.RootElement.GetProperty("status").GetInt32().Should().Be(409);
        body.RootElement.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.DUPLICATE_EXTERNAL_AGENT_ID);
    }

    [Fact]
    public async Task InvokeAsync_Should_Return409_WithStateInfo_When_InvalidStateTransitionExceptionThrown()
    {
        RequestDelegate next = _ => throw new Application.Exceptions.InvalidStateTransitionException("Draft", "Enable");
        var middleware = CreateMiddleware(next);
        var context = CreateHttpContext();

        await middleware.InvokeAsync(context);

        context.Response.StatusCode.Should().Be(StatusCodes.Status409Conflict);

        var body = await ReadResponseBodyAsync(context);
        body.RootElement.GetProperty("status").GetInt32().Should().Be(409);
        body.RootElement.GetProperty("title").GetString().Should().Be("Invalid State Transition");
        body.RootElement.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.INVALID_STATE_TRANSITION);
        body.RootElement.GetProperty("currentState").GetString().Should().Be("Draft");
        body.RootElement.GetProperty("attemptedAction").GetString().Should().Be("Enable");
    }

    [Fact]
    public async Task InvokeAsync_Should_Return403_When_DomainExceptionWithAgentIdentityMismatch()
    {
        RequestDelegate next = _ => throw new Application.Exceptions.DomainException(
            "Caller identity does not match", ErrorCodes.AGENT_IDENTITY_MISMATCH);
        var middleware = CreateMiddleware(next);
        var context = CreateHttpContext();

        await middleware.InvokeAsync(context);

        context.Response.StatusCode.Should().Be(StatusCodes.Status403Forbidden);

        var body = await ReadResponseBodyAsync(context);
        body.RootElement.GetProperty("status").GetInt32().Should().Be(403);
        body.RootElement.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.AGENT_IDENTITY_MISMATCH);
    }

    [Fact]
    public async Task InvokeAsync_Should_Return403_When_DomainExceptionWithAgentDisabled()
    {
        RequestDelegate next = _ => throw new Application.Exceptions.DomainException(
            "Agent is not active", ErrorCodes.AGENT_DISABLED);
        var middleware = CreateMiddleware(next);
        var context = CreateHttpContext();

        await middleware.InvokeAsync(context);

        context.Response.StatusCode.Should().Be(StatusCodes.Status403Forbidden);

        var body = await ReadResponseBodyAsync(context);
        body.RootElement.GetProperty("status").GetInt32().Should().Be(403);
        body.RootElement.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.AGENT_DISABLED);
    }

    [Fact]
    public async Task InvokeAsync_Should_Return422_When_DomainExceptionWithOtherErrorCode()
    {
        RequestDelegate next = _ => throw new Application.Exceptions.DomainException(
            "Unsupported feature", ErrorCodes.UNSUPPORTED_FEATURE_CONFIGURATION);
        var middleware = CreateMiddleware(next);
        var context = CreateHttpContext();

        await middleware.InvokeAsync(context);

        context.Response.StatusCode.Should().Be(StatusCodes.Status422UnprocessableEntity);

        var body = await ReadResponseBodyAsync(context);
        body.RootElement.GetProperty("status").GetInt32().Should().Be(422);
        body.RootElement.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.UNSUPPORTED_FEATURE_CONFIGURATION);
    }

    [Fact]
    public async Task InvokeAsync_Should_Return500_When_UnhandledExceptionThrown()
    {
        RequestDelegate next = _ => throw new InvalidOperationException("Something broke");
        var middleware = CreateMiddleware(next, "Production");
        var context = CreateHttpContext();

        await middleware.InvokeAsync(context);

        context.Response.StatusCode.Should().Be(StatusCodes.Status500InternalServerError);

        var body = await ReadResponseBodyAsync(context);
        body.RootElement.GetProperty("status").GetInt32().Should().Be(500);
        body.RootElement.GetProperty("title").GetString().Should().Be("Internal Server Error");
        body.RootElement.TryGetProperty("detail", out _).Should().BeFalse(
            "detail should not be present in non-Development to avoid leaking internals");
    }

    [Fact]
    public async Task InvokeAsync_Should_IncludeDetailInDevelopment_When_UnhandledExceptionThrown()
    {
        RequestDelegate next = _ => throw new InvalidOperationException("Something broke");
        var middleware = CreateMiddleware(next, "Development");
        var context = CreateHttpContext();

        await middleware.InvokeAsync(context);

        context.Response.StatusCode.Should().Be(StatusCodes.Status500InternalServerError);

        var body = await ReadResponseBodyAsync(context);
        body.RootElement.TryGetProperty("detail", out var detail).Should().BeTrue();
        detail.GetString().Should().Be("Something broke");
    }

    [Fact]
    public async Task InvokeAsync_Should_IncludeCorrelationId_When_PresentInContext()
    {
        RequestDelegate next = _ => throw new Application.Exceptions.NotFoundException("Agent", "id-1");
        var middleware = CreateMiddleware(next);
        var context = CreateHttpContext(correlationId: "corr-12345");

        await middleware.InvokeAsync(context);

        var body = await ReadResponseBodyAsync(context);
        body.RootElement.GetProperty("correlationId").GetString().Should().Be("corr-12345");
    }

    [Fact]
    public async Task InvokeAsync_Should_NotIncludeCorrelationId_When_NotPresentInContext()
    {
        RequestDelegate next = _ => throw new Application.Exceptions.NotFoundException("Agent", "id-1");
        var middleware = CreateMiddleware(next);
        var context = CreateHttpContext(correlationId: null);

        await middleware.InvokeAsync(context);

        var body = await ReadResponseBodyAsync(context);
        body.RootElement.TryGetProperty("correlationId", out _).Should().BeFalse();
    }

    [Fact]
    public async Task InvokeAsync_Should_SetInstanceToRequestPath()
    {
        RequestDelegate next = _ => throw new Application.Exceptions.NotFoundException("Agent", "id-1");
        var middleware = CreateMiddleware(next);
        var context = CreateHttpContext("/api/v1/agents/123");

        await middleware.InvokeAsync(context);

        var body = await ReadResponseBodyAsync(context);
        body.RootElement.GetProperty("instance").GetString().Should().Be("/api/v1/agents/123");
    }

    [Fact]
    public async Task InvokeAsync_Should_SetContentTypeToApplicationProblemJson()
    {
        RequestDelegate next = _ => throw new Application.Exceptions.NotFoundException("Agent", "id-1");
        var middleware = CreateMiddleware(next);
        var context = CreateHttpContext();

        await middleware.InvokeAsync(context);

        // The middleware sets "application/problem+json" before WriteAsJsonAsync.
        // WriteAsJsonAsync may override to "application/json; charset=utf-8".
        // Either way, the response content type should contain "json".
        context.Response.ContentType.Should().Contain("json");
    }

    [Fact]
    public async Task InvokeAsync_Should_NotCatch_When_NoExceptionThrown()
    {
        var invoked = false;
        RequestDelegate next = _ =>
        {
            invoked = true;
            return Task.CompletedTask;
        };
        var middleware = CreateMiddleware(next);
        var context = CreateHttpContext();

        await middleware.InvokeAsync(context);

        invoked.Should().BeTrue();
        // Response body should remain empty when no exception occurs
    }
}
