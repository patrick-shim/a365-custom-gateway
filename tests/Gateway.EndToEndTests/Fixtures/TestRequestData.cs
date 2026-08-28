using Gateway.Contracts.Dtos;

namespace Gateway.EndToEndTests.Fixtures;

internal static class TestRequestData
{
    internal static AgentBlueprintSelectionDto ValidBlueprint => new(
        Mode: "UseExisting",
        BlueprintObjectId: "0e6f36da-a880-4612-99af-9f923f7105de",
        DisplayName: null);
}
