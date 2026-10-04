import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { Card, Spinner, Text, Body1, Caption1, Switch } from "@fluentui/react-components";
import { api } from "../api/client";
import { PageHeader } from "../components/PageHeader";
import { StatusPill } from "../components/StatusPill";
import { ErrorState } from "../components/ErrorState";

export function Platform() {
  const qc = useQueryClient();
  const health = useQuery({ queryKey: ["health"], queryFn: api.getHealth });
  const config = useQuery({ queryKey: ["system-config"], queryFn: api.getSystemConfig });
  const defaults = useMutation({
    mutationFn: ({ enabled, version }: { enabled: boolean; version: string }) => api.setPromptShieldDefault(enabled, version),
    onSuccess: async updated => {
      qc.setQueryData(["system-config"], updated);
      await Promise.all([
        qc.invalidateQueries({ queryKey: ["agent"] }),
        qc.invalidateQueries({ queryKey: ["agents"] }),
      ]);
    },
    onError: () => { void config.refetch(); },
  });
  return (
    <>
      <PageHeader title="Gateway settings" subtitle="Service health and registration defaults." />
      <Card style={{ marginBottom: 16 }}>
        <Text weight="semibold">Purview access</Text>
        <Body1>Tenant access is a deployment setup responsibility. Use connection diagnostics to check administrative access; manage policy choices from Data protection.</Body1>
        <Link to="/settings/purview">Open connection diagnostics</Link>
      </Card>
      <Card style={{ marginBottom: 16 }}>
        <Text weight="semibold">Gateway API</Text>
        {health.isPending ? <Spinner size="small" label="Checking API" /> : health.isError ? (
          <ErrorState error={health.error} onRetry={() => void health.refetch()} />
        ) : <StatusPill value={health.data} />}
        <Caption1>This check does not report worker health or delivery to Agent 365.</Caption1>
      </Card>
      <Card style={{ marginBottom: 16 }}>
        <Text weight="semibold">Registration defaults</Text>
        {config.isPending ? <Spinner size="small" label="Loading defaults" /> : config.isError ? (
          <ErrorState error={config.error} onRetry={() => void config.refetch()} />
        ) : (
          <>
            <Body1>Registration environment: {config.data.registrationDefaults.environment}</Body1>
            {config.data.registrationDefaults.reason && <Caption1>{config.data.registrationDefaults.reason}</Caption1>}
            <Switch checked={config.data.defaultPromptShieldEnabled}
              disabled={defaults.isPending || config.isFetching || !config.data.rowVersion || !config.data.promptShieldAvailable}
              label="Prompt Shields default" onChange={(_, data) => {
                if (config.data.rowVersion) defaults.mutate({ enabled: data.checked, version: config.data.rowVersion });
              }} />
            <Caption1>Applies to new agents and agents using the default. Explicit per-agent choices stay unchanged.</Caption1>
            {!config.data.promptShieldAvailable && <Body1>Prompt Shields is not available in this deployment.</Body1>}
            {defaults.isPending && <Body1 role="status">Saving default...</Body1>}
            {defaults.isError && <ErrorState title="Could not save the default" error={defaults.error} />}
            <Caption1>Provisioning: {config.data.provisioningMode}; execution {config.data.provisioningExecutionEnabled ? "enabled" : "disabled"}.</Caption1>
          </>
        )}
      </Card>
      <Card id="registration-access" style={{ gap: 12 }}>
        <Text as="h2" size={400} weight="semibold">Agent 365 registration access</Text>
        <Body1>Finishing registration adds an existing agent identity to Microsoft 365's Registry. It is not a Purview approval or an outside approval inbox.</Body1>
        <Body1>The API requires a signed-in user with its <code>Gateway.Administrator</code> app role and delegated <code>access_as_user</code> scope.
          <code> Gateway.Operator</code> can read provisioning progress but cannot confirm registration.</Body1>
        <Caption1>To verify an assignment, open Microsoft Entra admin center, Enterprise applications, the Gateway API application, then Users and groups.
          Check the API application, not just the Console SPA. Sign in again after an authorized assignment change. This Console does not grant roles.</Caption1>
        <Body1>The Registry action also requires both deployment settings <code>Agent365:DelegatedRegistry:Enabled</code> and{" "}
          <code>Agent365:DelegatedRegistry:AllowContinuousDevelopmentAccess</code>. The operation response reports whether that gate is open;
          the provisioning-execution setting above is a separate gate. These settings are not editable here and do not authorize production use of a development-only provider.</Body1>
        <Caption1>If an operation, its stages, or registration defaults are missing or incompatible, the deployment owner must verify matching API, worker and Console contracts.
          Keep the agent and operation references from the setup card; do not re-register the agent. No progress or default environment is inferred.</Caption1>
        <Caption1>Only a reported consent challenge calls for reviewing the Gateway API's delegated Graph consent. Signing in to the Console alone does not grant API consent.</Caption1>
      </Card>
    </>
  );
}
