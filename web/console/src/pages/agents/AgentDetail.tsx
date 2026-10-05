import { useParams, useSearchParams, Link } from "react-router-dom";
import { useState } from "react";
import { AgentTestPanel } from "./AgentTestPanel";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Spinner, Card, Switch, Text, Body1, Caption1, TabList, Tab, Button } from "@fluentui/react-components";
import { api } from "../../api/client";
import { blueprintName, formatTime, shieldLabel } from "../../api/display";
import { PageHeader } from "../../components/PageHeader";
import { StatusPill } from "../../components/StatusPill";
import { ErrorState } from "../../components/ErrorState";
import { AgentCredentials } from "./AgentCredentials";
import { AgentRegistrationProgress } from "./AgentRegistrationProgress";
import { AgentDataProtection } from "./AgentDataProtection";

export function AgentDetail() {
  const [testing, setTesting] = useState(false);
  const { id = "" } = useParams();
  const qc = useQueryClient();
  const [params, setParams] = useSearchParams();
  const requestedTab = params.get("tab") ?? "protection";
  const tab = ["protection", "data-protection", "identity", "api", "activity"].includes(requestedTab) ? requestedTab : "protection";
  const agent = useQuery({
    queryKey: ["agent", id], queryFn: () => api.getAgent(id),
    refetchInterval: query => query.state.error ? false :
      query.state.data && ["Draft", "Provisioning", "AwaitingAdminApproval"].includes(query.state.data.status) ? 5000 : false,
  });
  const blueprints = useQuery({ queryKey: ["blueprints"], queryFn: api.listBlueprints });
  const shield = useMutation({
    mutationFn: ({ enabled, version }: { enabled: boolean; version: string }) => api.setPromptShield(id, enabled, version),
    onSuccess: async () => {
      await Promise.all([
        qc.invalidateQueries({ queryKey: ["agent", id] }),
        qc.invalidateQueries({ queryKey: ["agents"] }),
        qc.invalidateQueries({ queryKey: ["agent-summary"] }),
      ]);
    },
    onError: () => { void agent.refetch(); },
  });
  const a = agent.data;
  const canChangeProtection = a?.status === "Active" || a?.status === "Disabled";
  return (
    <>
      <Link to="/agents">Back to agents</Link>
      <PageHeader title={a?.name ?? "Agent"} subtitle={a?.externalAgentId}
        actions={a && <><StatusPill value={a.status} /><Button disabled={agent.isFetching} onClick={() => void agent.refetch()}>Refresh status</Button></>} />
      {agent.isPending ? <Spinner label="Loading agent" /> : agent.isError ? (
        <ErrorState error={agent.error} onRetry={() => void agent.refetch()} />
      ) : a && (
        <>
          {a.status === "Disabled" && <Card style={{ marginBottom: 16 }}><Text weight="semibold">Disabled on this gateway</Text><Body1>New prompt, activity and AI interaction submissions are blocked. The Agent 365 registration is unchanged.</Body1><Link to="/settings/agents">Manage gateway access</Link></Card>}
          {a.status !== "Disabled" && (a.provisioning || ["Draft", "Provisioning", "AwaitingAdminApproval", "Failed", "RequiresManualIntervention"].includes(a.status)) &&
            <AgentRegistrationProgress key={id} agent={a} />}
          <div style={{ display: "flex", alignItems: "center", flexWrap: "wrap", gap: 12, marginBottom: 16 }}>
            <TabList selectedValue={tab} onTabSelect={(_, data) => {
              if (typeof data.value === "string") setParams(previous => { const next = new URLSearchParams(previous); next.set("tab", data.value as string); return next; });
            }} style={{ flexWrap: "wrap" }}>
              <Tab value="protection">Prompt Shields</Tab><Tab value="data-protection">Data protection</Tab><Tab value="identity">Identity</Tab>
              <Tab value="api">API key</Tab><Tab value="activity">Activity</Tab>
            </TabList>
            <Button disabled={a.status !== "Active"} onClick={() => setTesting(true)}>Test Agent</Button>
          </div>
          {tab === "protection" && <Card style={{ gap: 16, padding: 24 }}>
            <Text weight="semibold">Prompt Shields</Text>
            <Caption1>Screens prompts sent to the Gateway before your external model runs.</Caption1>
            {a.features ? (
              <>
                <Switch checked={a.features.promptShieldEnabled ?? a.features.promptShieldEffectivelyEnabled}
                  disabled={shield.isPending || agent.isFetching || !canChangeProtection}
                  label="Prompt Shields" onChange={(_, data) => shield.mutate({ enabled: data.checked, version: a.rowVersion })} />
                <Body1>Effective state: <StatusPill value={shieldLabel(a)} /></Body1>
                {a.features.promptShieldEnabled == null && <Caption1>Using the Gateway default.</Caption1>}
                {a.features.promptShieldCapabilityStatus && <Caption1>Capability: {a.features.promptShieldCapabilityStatus}</Caption1>}
                {!canChangeProtection && <Caption1>Protection settings become available after the agent is provisioned.</Caption1>}
              </>
            ) : <Body1>The Gateway did not report this agent's protection settings.</Body1>}
            {shield.isPending && <Spinner size="tiny" label="Saving and checking the setting..." />}
            {shield.isError && <ErrorState title="The protection change was not confirmed" error={shield.error} />}
            <Caption1>This setting does not enable or disable the agent.</Caption1>
          </Card>}
          {tab === "data-protection" && <AgentDataProtection key={id} agent={a} />}
          {tab === "identity" && <Card style={{ gap: 12, padding: 24 }}>
            {blueprints.isError && <ErrorState title="Blueprint names could not be loaded" error={blueprints.error} onRetry={() => void blueprints.refetch()} />}
            <Text weight="semibold">{blueprintName(a, blueprints.data)}</Text>
            <Caption1>Blueprint application ID</Caption1><Body1><code>{a.agent365?.blueprintId ?? "Not assigned"}</code></Body1>
            <Caption1>Blueprint object ID</Caption1><Body1><code>{a.agent365?.blueprintObjectId ?? "Not assigned"}</code></Body1>
            <Caption1>Child agent ID</Caption1><Body1><code>{a.agent365?.agentId ?? "Not assigned"}</code></Body1>
            <Caption1>Agent identity object ID</Caption1><Body1><code>{a.agent365?.agentIdentityObjectId ?? "Not assigned"}</code></Body1>
            <Body1>Environment: {a.environment}</Body1>
          </Card>}
          {tab === "api" && <AgentCredentials key={id} agentId={id} externalAgentId={a.externalAgentId} />}
          {tab === "activity" && <Card style={{ gap: 12, padding: 24 }}>
            <Caption1>Last activity recorded by the Gateway</Caption1><Body1>{formatTime(a.lastActivityAtUtc)}</Body1>
            <Caption1>Configured export destinations</Caption1><Body1>{a.features?.observabilityMode ?? "Not reported"}</Body1>
            <Caption1>Registration accepted</Caption1><Body1>{formatTime(a.createdAtUtc)}</Body1>
            <Caption1>Activity acceptance is not proof of downstream delivery.</Caption1>
          </Card>}
        </>
      )}
      {testing && a && <AgentTestPanel key={id} agent={a} onClose={() => setTesting(false)} />}
    </>
  );
}
