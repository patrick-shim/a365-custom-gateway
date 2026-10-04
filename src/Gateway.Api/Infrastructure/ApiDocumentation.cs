using Gateway.Api.Authorization;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc.Controllers;
using Microsoft.AspNetCore.OpenApi;
using Microsoft.OpenApi;

namespace Gateway.Api.Infrastructure;

public static class ApiDocumentation
{
    private static readonly Dictionary<string, (string Summary, string Description)> Operations = new()
    {
        ["Activities.SubmitActivity"] = ("Submit an agent activity", "Queues sanitized activity telemetry. HTTP 202 means accepted, not delivered to Agent 365. Use a stable ActivityId and a UUID v4 Idempotency-Key for retries."),
        ["Activities.SubmitBatchActivities"] = ("Submit an activity batch", "Queues a bounded batch of activities for the authenticated agent. Use a UUID v4 Idempotency-Key. Inspect the response for per-item acceptance."),
        ["Interactions.SubmitInteraction"] = ("Submit a completed AI interaction", "Submit only after a successful prompt evaluation and model call. Supply the matching, unexpired evaluationReceiptId as promptEvaluationReceiptId. Agent, prompt, interaction, user and timestamp must match the evaluation. HTTP 202 is intake acceptance, not downstream delivery."),
        ["PromptEvaluations.Evaluate"] = ("Evaluate a prompt before calling a model", "Checks the agent's enabled Prompt Shields and Purview protections. Only allowed=true with a valid evaluationReceiptId authorizes the external model call. A blocked prompt returns 403; unavailable protection fails closed with 503. Never call the model on a failed or unknown result."),
        ["AgentRuntime.GetReadiness"] = ("Check agent credential access", "Returns 204 when this agent credential passes authentication and admission. This is not proof of Purview enforcement or telemetry delivery."),
        ["AgentIdentityBlueprints.ListAgentIdentityBlueprints"] = ("List available identity blueprints", "Lists blueprints eligible for registration. Each registration receives an individual agent identity; policies are assigned to that identity, not the shared blueprint."),
        ["Agents.RegisterAgent"] = ("Register an external agent", "Creates a registration and queues provisioning. Save the returned one-time credential securely. A 202 response is not Active. If the response is lost, reconcile using the exact externalAgentId instead of blindly creating another registration."),
        ["Agents.ListAgents"] = ("Search and paginate agents", "Follow nextCursor until absent. Search and pagination are server-side; do not interpret one page as the complete inventory."),
        ["Agents.GetAgent"] = ("Read an agent", "Returns registration state, protection configuration, provisioning references and rowVersion. Active registration does not itself establish protection readiness."),
        ["Agents.ListAgentIngressCredentials"] = ("List agent credential metadata", "Returns metadata only. Existing secret values cannot be retrieved."),
        ["Agents.IssueAgentIngressCredential"] = ("Issue an agent credential", "Returns a new secret once with no-store caching. Save it securely and do not automatically retry an uncertain issuance."),
        ["Agents.RevokeAgentIngressCredential"] = ("Revoke an agent credential", "Revokes only the selected credential. The server enforces the last-usable-credential guard."),
        ["Agents.UpdateFeatures"] = ("Update agent features", "Protection changes require Idempotency-Key and If-Match headers matching idempotencyKey and expectedRowVersion in the reviewed body. Reload and review after a version conflict. This does not change the agent lifecycle."),
        ["Agents.EnableAgent"] = ("Enable an agent", "Changes gateway admission state for the selected registration."),
        ["Agents.DisableAgent"] = ("Disable an agent", "Disables gateway admission for the selected registration."),
        ["Agents.DeleteAgent"] = ("Delete a gateway registration", "Deletes the gateway registration according to lifecycle rules. Linked Microsoft identities and Registry resources are not automatically deleted."),
        ["Agents.RetryProvisioning"] = ("Retry eligible provisioning", "Retries only server-approved failed provisioning. Read the returned operation before deciding on another action."),
        ["Agents.GetAuditEvents"] = ("Read administrative audit events", "Returns the selected agent's administrative history, subject to caller authorization."),
        ["Agents.GetProvisioningHistory"] = ("Read provisioning history", "Returns operation history used to find authoritative setup status and outstanding actions."),
        ["Operations.GetOperationStatus"] = ("Read provisioning operation status", "Poll this operation for authoritative stages, failure details and requested administrator actions. Do not infer completion from elapsed time."),
        ["Operations.CompleteAgent365Registration"] = ("Confirm Agent 365 Registry registration", "Requires a signed-in Gateway.Administrator with access_as_user and the API's delegated Graph Registry consent. Adds the existing agent to the Registry; it does not create another identity. Confirmation queues verification and is not an Active readback."),
        ["PurviewPolicyCatalog.List"] = ("Read existing Purview policies", "Returns a fresh tenant-bound catalog and compatibility reasons. Failure returns 503 instead of a fabricated empty catalog. Policy definitions and classifiers are managed in Purview."),
        ["AgentPolicyAssignments.List"] = ("Read individual-agent policy assignments", "Reports assignment states, binding freshness and observed allow/block timestamps. Assigned, synchronized and verified enforcement are distinct. A block does not identify which applicable policy caused it."),
        ["AgentPolicyAssignments.Review"] = ("Review an individual-agent assignment", "Binds a compatible policy revision, administrator and exact agent identity to a short-lived review. No policy write occurs until confirmation. Use policyId and revision from the current catalog."),
        ["AgentPolicyAssignments.Confirm"] = ("Confirm a reviewed policy assignment", "Queues the reviewed assignment for this individual identity. Preserves unrelated targets, exclusions, rules and mode. Returns 202 for new work or 200 for an already confirmed operation. Poll assignments for confirmation; requests fail closed while required protection is unavailable."),
        ["System.GetSystemConfig"] = ("Read gateway settings", "Returns supported runtime defaults and their current rowVersion. Initial tenant connection setup belongs to bootstrap."),
        ["System.UpdateSystemConfig"] = ("Update gateway defaults", "Protection default changes require Idempotency-Key and If-Match headers matching the reviewed request body. Explicit per-agent protection choices remain unchanged."),
        ["Health.GetHealth"] = ("Check process liveness", "Public liveness check. Does not establish worker health, policy enforcement or downstream delivery."),
        ["Health.GetReadiness"] = ("Check database readiness", "Public database connectivity check. Returns 503 when unavailable; does not establish Microsoft service readiness.")
    };

    public static void Configure(OpenApiOptions options)
    {
        options.AddDocumentTransformer((document, context, ct) =>
        {
            document.Info.Title = "A365 Gateway API";
            document.Info.Version = "v1";
            document.Info.Description = "Connect independently hosted agents to Microsoft Entra, Agent 365, Purview and Prompt Shields. Administration uses an Entra access token; agent ingress uses a gateway-issued secret. Both use Authorization: Bearer, but are not interchangeable. Evaluate → call your model only on allow → submit the interaction. HTTP 202 means queued, never confirmed delivery. All timestamps are UTC. Interactive requests act on the live deployment.";
            document.Components ??= new();
            document.Components.SecuritySchemes = new Dictionary<string, IOpenApiSecurityScheme>
            {
                ["EntraBearer"] = new OpenApiSecurityScheme { Type = SecuritySchemeType.Http, Scheme = "bearer", BearerFormat = "JWT", Description = "Entra access token for the Gateway API audience with the endpoint's required gateway role. Do not paste a gateway agent key here." },
                ["AgentKey"] = new OpenApiSecurityScheme { Type = SecuritySchemeType.Http, Scheme = "bearer", Description = "One-time gateway-issued agent key (a365gw_v1_...). Scoped to its registered agent. Do not use an Entra token for agent ingress." }
            };
            return Task.CompletedTask;
        });
        options.AddOperationTransformer((operation, context, ct) =>
        {
            if (context.Description.ActionDescriptor is not ControllerActionDescriptor action) return Task.CompletedTask;
            var id = $"{action.ControllerName}.{action.ActionName}";
            operation.OperationId = id;
            if (Operations.TryGetValue(id, out var text)) { operation.Summary = text.Summary; operation.Description = text.Description; }
            var policies = action.EndpointMetadata.OfType<IAuthorizeData>().Select(x => x.Policy).Where(x => x is not null).ToArray();
            if (policies.Length > 0 && !action.EndpointMetadata.OfType<IAllowAnonymous>().Any())
            {
                var scheme = policies.Contains(AuthorizationPolicies.ExternalAgentOnly) ? "AgentKey" : "EntraBearer";
                operation.Security = [new OpenApiSecurityRequirement { [new OpenApiSecuritySchemeReference(scheme, context.Document)] = [] }];
                operation.Description += "\n\nAuthorization policy: " + string.Join(", ", policies) + ".";
                operation.Responses ??= new();
                operation.Responses.TryAdd("401", new OpenApiResponse { Description = "Missing, invalid or expired credential. Use the authentication scheme documented for this operation." });
                operation.Responses.TryAdd("403", new OpenApiResponse { Description = "Authenticated caller is not permitted, or protection blocked the request. Inspect the response errorCode and correlationId." });
                operation.Responses.TryAdd("429", new OpenApiResponse { Description = "Gateway rate limit exceeded. Respect Retry-After when supplied." });
            }
            foreach (var parameter in (operation.Parameters ?? []).OfType<OpenApiParameter>())
            {
                if (parameter.Name == "Idempotency-Key") { parameter.Required = true; parameter.Description = "Canonical UUID v4. Reuse only for a retry of this exact request; use a new value for a new action."; }
            }
            if (id is "Agents.UpdateFeatures" or "System.UpdateSystemConfig")
            {
                operation.Parameters ??= [];
                operation.Parameters.Add(new OpenApiParameter { Name = "Idempotency-Key", In = ParameterLocation.Header, Description = "Required for protection changes; must match body idempotencyKey (UUID v4).", Schema = new OpenApiSchema { Type = JsonSchemaType.String } });
                operation.Parameters.Add(new OpenApiParameter { Name = "If-Match", In = ParameterLocation.Header, Description = "Required for protection changes; one exact row version matching body expectedRowVersion. Read the latest resource before reviewing a new change.", Schema = new OpenApiSchema { Type = JsonSchemaType.String } });
            }
            return Task.CompletedTask;
        });
    }
}

