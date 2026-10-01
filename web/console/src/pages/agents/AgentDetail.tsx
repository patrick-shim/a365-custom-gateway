import { useState } from "react";
import { useParams, useNavigate } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Spinner,
  Card,
  Switch,
  Text,
  Body1,
  Caption1,
  TabList,
  Tab,
  makeStyles,
  tokens,
  Button,
  MessageBar,
  MessageBarBody,
} from "@fluentui/react-components";
import { ArrowLeft24Regular } from "@fluentui/react-icons";
import { api } from "../../api/client";
import { PageHeader } from "../../components/PageHeader";
import { StatusPill } from "../../components/StatusPill";
import { CopyableCommand } from "../../components/CopyableCommand";

const useStyles = makeStyles({
  back: { marginBottom: tokens.spacingVerticalS },
  card: {
    padding: tokens.spacingVerticalL,
    display: "flex",
    flexDirection: "column",
    gap: tokens.spacingVerticalM,
    marginBottom: tokens.spacingVerticalL,
  },
  shieldRow: { display: "flex", justifyContent: "space-between", alignItems: "center", gap: tokens.spacingHorizontalL },
  facts: { display: "grid", gridTemplateColumns: "150px 1fr", rowGap: tokens.spacingVerticalS, columnGap: tokens.spacingHorizontalL },
  dt: { color: tokens.colorNeutralForeground3 },
  tabs: { marginBottom: tokens.spacingVerticalM },
});

type TabKey = "protection" | "identity" | "api" | "activity";

export function AgentDetail() {
  const styles = useStyles();
  const { id = "" } = useParams();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const [tab, setTab] = useState<TabKey>("protection");

  const agentQuery = useQuery({ queryKey: ["agent", id], queryFn: () => api.getAgent(id) });
  const shield = useMutation({
    mutationFn: (enabled: boolean) => api.setPromptShield(id, enabled),
    onSuccess: (updated) => {
      qc.setQueryData(["agent", id], updated);
      void qc.invalidateQueries({ queryKey: ["agents"] });
    },
  });

  if (agentQuery.isLoading) return <Spinner label="Loading…" />;
  const agent = agentQuery.data;
  if (!agent) return <Body1>Agent not found.</Body1>;
  const shieldOn = agent.promptShield === "On" || agent.promptShield === "DefaultOn";

  return (
    <>
      <Button className={styles.back} appearance="subtle" icon={<ArrowLeft24Regular />} onClick={() => navigate("/agents")}>
        Agents
      </Button>
      <PageHeader title={agent.displayName} subtitle={agent.externalAgentId} actions={<StatusPill value={agent.lifecycle} />} />

      <TabList className={styles.tabs} selectedValue={tab} onTabSelect={(_, d) => setTab(d.value as TabKey)}>
        <Tab value="protection">Prompt Shields</Tab>
        <Tab value="identity">Identity</Tab>
        <Tab value="api">API key</Tab>
        <Tab value="activity">Activity</Tab>
      </TabList>

      {tab === "protection" && (
        <Card className={styles.card}>
          <div className={styles.shieldRow}>
            <div>
              <Text weight="semibold">Prompt Shields</Text>
              <Caption1 block>Screens every prompt before your model runs.</Caption1>
            </div>
            <Switch
              checked={shieldOn}
              disabled={shield.isPending}
              onChange={(_, d) => shield.mutate(d.checked)}
              label={shieldOn ? "On" : "Off"}
              labelPosition="above"
            />
          </div>
          <Caption1>Data loss (DLP) is set on the <strong>{agent.blueprint.displayName}</strong>, not here.</Caption1>
        </Card>
      )}

      {tab === "identity" && (
        <Card className={styles.card}>
          <div className={styles.facts}>
            <Caption1 className={styles.dt}>Blueprint</Caption1>
            <Body1>{agent.blueprint.displayName}</Body1>
            <Caption1 className={styles.dt}>Agent ID</Caption1>
            <Body1>{agent.childAgentId ? <code>{agent.childAgentId}</code> : "Pending"}</Body1>
            <Caption1 className={styles.dt}>Status</Caption1>
            <StatusPill value={agent.lifecycle} />
          </div>
          {agent.lifecycle === "AwaitingRegistryHandoff" && (
            <MessageBar intent="warning">
              <MessageBarBody>An admin must finish the Agent 365 Registry step.</MessageBarBody>
            </MessageBar>
          )}
        </Card>
      )}

      {tab === "api" && (
        <Card className={styles.card}>
          <div className={styles.facts}>
            <Caption1 className={styles.dt}>External ID</Caption1>
            <Body1><code>{agent.externalAgentId}</code></Body1>
          </div>
          <CopyableCommand
            label="Evaluate a prompt (before your model)"
            rows={3}
            command={`curl -X POST "$GATEWAY_API/api/v1/prompts:evaluate" \\\n  -H "Authorization: Bearer $GATEWAY_KEY" \\\n  -d '{"externalAgentId":"${agent.externalAgentId}","prompt":"..."}'`}
          />
          <Caption1>The key is shown once at registration. Lost key → rotate, don't re-register.</Caption1>
          <Button appearance="secondary" style={{ alignSelf: "flex-start" }}>Rotate key</Button>
        </Card>
      )}

      {tab === "activity" && (
        <Card className={styles.card}>
          <div className={styles.facts}>
            <Caption1 className={styles.dt}>Last 24h</Caption1>
            <Body1>{agent.activity24h.toLocaleString()} interactions</Body1>
            <Caption1 className={styles.dt}>Last seen</Caption1>
            <Body1>{agent.lastActivityAtUtc ? new Date(agent.lastActivityAtUtc).toLocaleString() : "—"}</Body1>
            <Caption1 className={styles.dt}>Sent to</Caption1>
            <Body1>{agent.observabilityExport === "Agent365+AzureMonitor" ? "Agent 365 + Azure Monitor" : "Agent 365"}</Body1>
          </div>
        </Card>
      )}
    </>
  );
}
