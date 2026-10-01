import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { Card, Spinner, Text, Caption1, Body1 } from "@fluentui/react-components";
import { api } from "../api/client";
import { connectionIsUsable } from "../api/types";
import { PageHeader } from "../components/PageHeader";
import { ErrorState } from "../components/ErrorState";
import { StatusPill } from "../components/StatusPill";

export function Home() {
  const health = useQuery({ queryKey: ["health"], queryFn: api.getHealth });
  const agents = useQuery({ queryKey: ["agent-summary"], queryFn: () => api.listAgents() });
  const purview = useQuery({ queryKey: ["purview"], queryFn: api.getPurviewConnection });
  return (
    <>
      <PageHeader title="Home" subtitle="Manage agents, check protection, and review your Gateway." />
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))", gap: 16 }}>
        <Card>
          <Text weight="semibold">Agents</Text>
          {agents.isPending ? <Spinner size="small" label="Loading agents" /> : agents.isError ? (
            <ErrorState error={agents.error} onRetry={() => void agents.refetch()} />
          ) : (
            <>
              <Text size={700}>{agents.data.totalCount ?? agents.data.items.length}</Text>
              {agents.data.totalCount === null && agents.data.nextCursor && <Caption1>More registrations are available on the Agents page.</Caption1>}
              <Link to="/agents">View agents</Link>
              <Link to="/register">Register agent</Link>
            </>
          )}
        </Card>
        <Card>
          <Text weight="semibold">Gateway API</Text>
          {health.isPending ? <Spinner size="small" label="Checking API" /> : health.isError ? (
            <ErrorState error={health.error} onRetry={() => void health.refetch()} />
          ) : <StatusPill value={health.data} />}
          <Link to="/platform">View platform</Link>
        </Card>
        <Card>
          <Text weight="semibold">Purview connection</Text>
          {purview.isPending ? <Spinner size="small" label="Loading connection" /> : purview.isError ? (
            <ErrorState error={purview.error} onRetry={() => void purview.refetch()} />
          ) : (
            <>
              <StatusPill value={purview.data?.status ?? "NotConnected"} />
              <Body1>{connectionIsUsable(purview.data)
                ? "Connection verified. Policy readiness is checked separately."
                : "Data protection needs attention. Agent registration is separate."}</Body1>
            </>
          )}
          <Link to="/data-protection/connection">View connection</Link>
        </Card>
      </div>
    </>
  );
}
