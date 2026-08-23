namespace Gateway.EndToEndTests;

/// <summary>
/// Collection definition that ensures all E2E tests sharing the GatewayWebApplicationFactory
/// run sequentially. This is necessary because TestAuthHandler uses static state that would
/// be corrupted by parallel test execution.
/// </summary>
[CollectionDefinition(Name)]
public class EndToEndTestCollection : ICollectionFixture<Fixtures.GatewayWebApplicationFactory>
{
    public const string Name = "EndToEnd";
}
