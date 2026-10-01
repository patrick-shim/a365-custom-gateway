using System.Buffers.Binary;
using System.Globalization;
using Gateway.Application.Agents.Queries;
using Gateway.Application.Agents.Validators;
using Gateway.Application.Behaviors;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.TestSupport;

namespace Gateway.UnitTests;

public sealed class AgentListingTests
{
    [Theory]
    [InlineData("en-US")]
    [InlineData("fr-FR")]
    [InlineData("ar-SA")]
    public void Opaque_cursor_preserves_exact_timestamp_ticks_and_id_independently_of_culture(string culture)
    {
        var previous = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(culture);
            var createdAt = new DateTime(638950001234567891, DateTimeKind.Unspecified);
            var id = Guid.Parse("ff001122-3344-4566-8899-aabbccddeeff");
            var cursor = ListAgentsCursor.Encode(createdAt, id);

            Assert.Matches("^[A-Za-z0-9_-]{34}$", cursor);
            Assert.True(ListAgentsCursor.TryDecode(cursor, out var decodedDate, out var decodedId));
            Assert.Equal(createdAt.Ticks, decodedDate.Ticks);
            Assert.Equal(DateTimeKind.Utc, decodedDate.Kind);
            Assert.Equal(id, decodedId);
            Assert.Equal(cursor, ListAgentsCursor.Encode(decodedDate, decodedId));
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }

    public static IEnumerable<object[]> MalformedCursors()
    {
        yield return ["not-base64"];
        yield return [Guid.NewGuid().ToString("D")];
        yield return [" "];
        yield return [new string('A', 100_000)];
        yield return [Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("2030-01-02|not-a-guid"))];
        yield return [CursorPayload(2, TestData.Now.Ticks, Guid.NewGuid())];
        yield return [CursorPayload(1, -1, Guid.NewGuid())];
        yield return [CursorPayload(1, DateTime.MaxValue.Ticks + 1, Guid.NewGuid())];
        yield return [CursorPayload(1, TestData.Now.Ticks, Guid.Empty)];
        var canonical = CursorPayload(1, TestData.Now.Ticks, new Guid("00000000-0000-4000-8000-000000000000"));
        yield return [canonical[..^1] + "B"];
    }

    [Theory]
    [MemberData(nameof(MalformedCursors))]
    public async Task Malformed_cursors_are_safe_validation_failures_before_the_handler(string cursor)
    {
        var validator = new ListAgentsValidator();
        var query = new ListAgentsQuery(null, null, null, 100, cursor);
        Assert.False(ListAgentsCursor.TryDecode(cursor, out _, out _));
        var result = validator.Validate(query);
        Assert.Equal(ListAgentsCursor.InvalidMessage, Assert.Single(result.Errors).ErrorMessage);

        var behavior = new ValidationBehavior<ListAgentsQuery, AgentListResponse>([validator]);
        var reachedHandler = false;
        var error = await Assert.ThrowsAsync<Gateway.Application.Exceptions.ValidationException>(() => behavior.Handle(
            query, () =>
            {
                reachedHandler = true;
                return Task.FromResult(new AgentListResponse([], null, 0));
            }, default));
        Assert.False(reachedHandler);
        Assert.Equal([ListAgentsCursor.InvalidMessage], error.Errors["Cursor"]);
    }

    [Theory]
    [InlineData("active", "production", 1, true)]
    [InlineData(" ACTIVE ", " Test ", 200, true)]
    [InlineData(null, null, 100, true)]
    [InlineData("", "", 100, true)]
    [InlineData("NotAStatus", null, 100, false)]
    [InlineData("3", null, 100, false)]
    [InlineData(null, "NotAnEnvironment", 100, false)]
    [InlineData(null, "1", 100, false)]
    [InlineData(null, null, 0, false)]
    [InlineData(null, null, 201, false)]
    public void Filter_validation_does_not_silently_broaden_invalid_queries(
        string? status, string? environment, int limit, bool valid)
    {
        Assert.Equal(valid, new ListAgentsValidator().Validate(new ListAgentsQuery(status, environment, null, limit)).IsValid);
    }

    [Fact]
    public void Valid_cursor_and_bounded_literal_search_pass_validation()
    {
        var query = new ListAgentsQuery(null, null, "%_[literal]", 100, ListAgentsCursor.Encode(TestData.Now, Guid.NewGuid()));
        Assert.True(new ListAgentsValidator().Validate(query).IsValid);
        Assert.False(new ListAgentsValidator().Validate(query with { Search = new string('x', 257) }).IsValid);
    }

    [Theory]
    [InlineData(0, false)]
    [InlineData(2, false)]
    [InlineData(3, true)]
    public async Task Handler_uses_one_lookahead_row_and_never_issues_a_phantom_final_cursor(int returned, bool hasMore)
    {
        var rows = Enumerable.Range(0, returned).Select(_ => TestData.Agent()).ToList();
        var repository = new FiniteAgentRepository(rows, total: 137);
        var activity = new ListingActivityReads();
        var incomingCursor = ListAgentsCursor.Encode(TestData.Now.AddSeconds(-1), Guid.NewGuid());

        var result = await new ListAgentsHandler(repository, activity, activity).Handle(
            new(" Active ", " Production ", " invoice-eu ", 2, incomingCursor), default);

        Assert.Equal(new AgentListFilter("Active", "Production", "invoice-eu", 3, incomingCursor), Assert.Single(repository.Calls));
        Assert.Equal(Math.Min(2, returned), result.Items.Count);
        Assert.Equal(137, result.TotalCount);
        Assert.Equal(hasMore, result.NextCursor is not null);
        Assert.Equal(returned == 0 ? 0 : 2, activity.Calls.Count);
        Assert.All(activity.Calls, ids => Assert.Equal(rows.Take(2).Select(agent => agent.Id), ids));
        if (hasMore)
        {
            Assert.True(ListAgentsCursor.TryDecode(result.NextCursor, out var date, out var id));
            Assert.Equal(rows[1].CreatedAtUtc, date);
            Assert.Equal(rows[1].Id, id);
            Assert.NotEqual(rows[2].Id, id);
        }
    }

    private static string CursorPayload(byte version, long ticks, Guid id)
    {
        var bytes = new byte[25];
        bytes[0] = version;
        BinaryPrimitives.WriteInt64BigEndian(bytes.AsSpan(1, 8), ticks);
        id.TryWriteBytes(bytes.AsSpan(9));
        return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    private sealed class FiniteAgentRepository(List<AgentRegistration> rows, int total) : IAgentRepository
    {
        public List<AgentListFilter> Calls { get; } = [];

        public Task<(List<AgentRegistration> Items, int TotalCount)> ListAsync(AgentListFilter filter, CancellationToken ct)
        {
            Assert.Empty(Calls);
            Calls.Add(filter);
            return Task.FromResult((rows.ToList(), total));
        }

        public Task<AgentRegistration?> GetByIdAsync(Guid id, CancellationToken ct) => throw Unexpected();
        public Task AddAsync(AgentRegistration agent, CancellationToken ct) => throw Unexpected();
        public Task<bool> ExistsAsync(string externalAgentId, CancellationToken ct) => throw Unexpected();
    }

    private sealed class ListingActivityReads : IAiInteractionRepository, IActivityReceiptRepository
    {
        public List<Guid[]> Calls { get; } = [];
        public Task<IReadOnlyDictionary<Guid, DateTime>> GetLatestReceivedAtUtcAsync(
            IReadOnlyCollection<Guid> agentRegistrationIds, CancellationToken ct)
        {
            Assert.True(Calls.Count < 2);
            Calls.Add(agentRegistrationIds.ToArray());
            return Task.FromResult<IReadOnlyDictionary<Guid, DateTime>>(new Dictionary<Guid, DateTime>());
        }

        Task<AiInteractionRecord?> IAiInteractionRepository.GetByIdAsync(Guid id, CancellationToken ct) => throw Unexpected();
        Task<ActivityReceipt?> IActivityReceiptRepository.GetByIdAsync(Guid id, CancellationToken ct) => throw Unexpected();
        public Task AddAsync(AiInteractionRecord record, CancellationToken ct) => throw Unexpected();
        public Task AddAsync(ActivityReceipt receipt, CancellationToken ct) => throw Unexpected();
        public Task<bool> ExistsByExternalIdAsync(Guid agentRegistrationId, string externalActivityId, CancellationToken ct) => throw Unexpected();
    }

    private static InvalidOperationException Unexpected() => new("Unscripted listing fixture call; no provider fallback exists.");
}
