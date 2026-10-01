using System.Text.RegularExpressions;
using YamlDotNet.Core;
using YamlDotNet.Serialization;

namespace Gateway.SourceTests;

public sealed class OpenApiContractTests
{
    private static readonly HashSet<string> HttpMethods = new(StringComparer.Ordinal)
    {
        "get", "post", "put", "patch", "delete", "options", "head", "trace"
    };

    [Fact]
    public void DuplicateYamlKeysAreRejected()
    {
        Assert.Throws<YamlException>(() => Read("name: first\nname: second\n"));
        Assert.Throws<YamlException>(() => Read("paths:\n  /agents:\n    get: one\n    get: two\n"));
    }

    [Fact]
    public void AllLocalReferencesResolveAndOperationIdsAreUnique()
    {
        var root = ReadSpecification();
        Assert.Equal("3.0.3", root["openapi"]);
        var references = Descendants(root)
            .Where(value => value.ContainsKey("$ref"))
            .Select(value => Assert.IsType<string>(value["$ref"])).ToArray();
        Assert.NotEmpty(references);
        foreach (var reference in references)
        {
            Assert.StartsWith("#/", reference);
            object current = root;
            foreach (var segment in reference[2..].Split('/'))
            {
                var key = segment.Replace("~1", "/", StringComparison.Ordinal).Replace("~0", "~", StringComparison.Ordinal);
                var mapping = Assert.IsAssignableFrom<IDictionary<object, object>>(current);
                Assert.True(mapping.TryGetValue(key, out var next), $"Unresolved OpenAPI reference: {reference}");
                current = Assert.IsType<object>(next, exactMatch: false);
            }
        }

        var operations = Operations(root).ToArray();
        var identifiers = operations.Select(operation =>
            Assert.IsType<string>(operation.Operation["operationId"])).ToArray();
        Assert.NotEmpty(identifiers);
        Assert.Equal(identifiers.Length, identifiers.Distinct(StringComparer.Ordinal).Count());
    }

    [Fact]
    public void DocumentedOperationsMatchControllerRoutes()
    {
        var root = ReadSpecification();
        var documented = Operations(root).Select(value => $"{value.Method} {EndpointPath(root, value.Path, value.Operation)}")
            .Order(StringComparer.Ordinal).ToArray();
        var actual = new List<string>();
        foreach (var file in Directory.EnumerateFiles(SourceTree.Resolve("src", "Gateway.Api", "Controllers"), "*Controller.cs"))
        {
            var source = File.ReadAllText(file);
            var baseRoute = Regex.Match(source, """\[Route\("([^"]+)"\)\]""").Groups[1].Value;
            foreach (Match method in Regex.Matches(source, """\[Http(Get|Post|Put|Patch|Delete)(?:\("([^"]*)"\))?\]"""))
            {
                var template = method.Groups[2].Value;
                var route = template.StartsWith('/') || template.StartsWith("~/", StringComparison.Ordinal)
                    ? template.TrimStart('~', '/')
                    : $"{baseRoute.TrimEnd('/')}/{template}".Trim('/');
                route = Regex.Replace(route, @"\{([^}:]+):[^}]+\}", "{$1}");
                route = "/" + route;
                if (route == "/health/bootstrap-attestation")
                    continue;
                actual.Add($"{method.Groups[1].Value.ToLowerInvariant()} {route}");
            }
        }
        Assert.Equal(documented, actual.Order(StringComparer.Ordinal).ToArray());
    }

    [Fact]
    public void DelegatedScopeAndAlternativeRolesRemainSeparate()
    {
        const string scope = "api://{gatewayApiApplicationId}/access_as_user";
        var root = ReadSpecification();
        var components = Assert.IsAssignableFrom<IDictionary<object, object>>(root["components"]);
        var schemes = Assert.IsAssignableFrom<IDictionary<object, object>>(components["securitySchemes"]);
        var bearer = Assert.IsAssignableFrom<IDictionary<object, object>>(schemes["entraBearer"]);
        var flows = Assert.IsAssignableFrom<IDictionary<object, object>>(bearer["flows"]);
        var flow = Assert.IsAssignableFrom<IDictionary<object, object>>(flows["authorizationCode"]);
        var scopes = Assert.IsAssignableFrom<IDictionary<object, object>>(flow["scopes"]);
        Assert.Equal(scope, Assert.Single(scopes.Keys));

        var checkedOperations = 0;
        foreach (var (_, _, operation) in Operations(root))
        {
            if (!operation.TryGetValue("security", out var security))
                continue;
            foreach (var requirement in Assert.IsAssignableFrom<IEnumerable<object>>(security))
            {
                var mapping = Assert.IsAssignableFrom<IDictionary<object, object>>(requirement);
                if (!mapping.TryGetValue("entraBearer", out var values))
                    continue;
                Assert.Equal(scope, Assert.Single(Assert.IsAssignableFrom<IEnumerable<object>>(values)));
                var roles = Assert.IsAssignableFrom<IEnumerable<object>>(operation["x-gateway-roles-any-of"]).ToArray();
                Assert.NotEmpty(roles);
                Assert.All(roles, role => Assert.Contains(Assert.IsType<string>(role),
                    new[] { "Gateway.Administrator", "Gateway.Operator", "Gateway.Auditor", "Gateway.SupportReader" }));
                checkedOperations++;
            }
        }
        Assert.True(checkedOperations > 0, "No control-plane security requirements were inspected.");
    }

    private static IDictionary<object, object> ReadSpecification() =>
        Read(File.ReadAllText(SourceTree.Resolve("docs", "api", "openapi.yaml")));

    private static IDictionary<object, object> Read(string yaml) =>
        Assert.IsAssignableFrom<IDictionary<object, object>>(
            new DeserializerBuilder().WithDuplicateKeyChecking().Build().Deserialize<object>(yaml));

    private static string EndpointPath(IDictionary<object, object> root, string path, IDictionary<object, object> operation)
    {
        var paths = Assert.IsAssignableFrom<IDictionary<object, object>>(root["paths"]);
        var pathItem = Assert.IsAssignableFrom<IDictionary<object, object>>(paths[path]);
        var serverValue = operation.TryGetValue("servers", out var operationServers) ? operationServers
            : pathItem.TryGetValue("servers", out var pathServers) ? pathServers : root["servers"];
        var server = Assert.IsAssignableFrom<IDictionary<object, object>>(
            Assert.Single(Assert.IsAssignableFrom<IEnumerable<object>>(serverValue)));
        var url = Assert.IsType<string>(server["url"]);
        var match = Regex.Match(url, @"^https?://[^/]+(?<prefix>/.*)?$");
        Assert.True(match.Success, "OpenAPI server must have an explicit HTTP origin.");
        return match.Groups["prefix"].Value.TrimEnd('/') + path;
    }

    private static IEnumerable<IDictionary<object, object>> Descendants(object value)
    {
        if (value is IDictionary<object, object> mapping)
        {
            yield return mapping;
            foreach (var child in mapping.Values)
            foreach (var descendant in Descendants(child))
                yield return descendant;
        }
        else if (value is IEnumerable<object> sequence)
        {
            foreach (var child in sequence)
            foreach (var descendant in Descendants(child))
                yield return descendant;
        }
    }

    private static IEnumerable<(string Method, string Path, IDictionary<object, object> Operation)> Operations(
        IDictionary<object, object> root)
    {
        var paths = Assert.IsAssignableFrom<IDictionary<object, object>>(root["paths"]);
        foreach (var (path, value) in paths)
        {
            var verbs = Assert.IsAssignableFrom<IDictionary<object, object>>(value);
            foreach (var (method, operation) in verbs)
            {
                if (method is string verb && HttpMethods.Contains(verb))
                    yield return (verb, Assert.IsType<string>(path), Assert.IsAssignableFrom<IDictionary<object, object>>(operation));
            }
        }
    }
}
