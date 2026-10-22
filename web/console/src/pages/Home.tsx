import { Bot24Regular, Pulse24Regular, ShieldTask24Regular } from "@fluentui/react-icons";
import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { Card, Spinner, Text, Caption1, Body1 } from "@fluentui/react-components";
import { api } from "../api/client";
import { PageHeader } from "../components/PageHeader";
import { ErrorState } from "../components/ErrorState";
import { StatusPill } from "../components/StatusPill";
import { RefreshIndicator } from "../components/RefreshIndicator";
import { purviewConnectionQueryKey } from "../api/queryKeys";

export function Home() {
  const health = useQuery({ queryKey: ["health"], queryFn: api.getHealth });
  const agents = useQuery({ queryKey: ["agent-summary"], queryFn: () => api.listAgents() });
  const purview = useQuery({ queryKey: purviewConnectionQueryKey, queryFn: api.getPurviewConnection, retry: false, refetchInterval: 60_000 });
  return (
    <>
      <PageHeader title="Home" subtitle="Manage agents, check protection, and review your Gateway." />
      <section className="overview-hero"><div className="overview-eyebrow"><ShieldTask24Regular aria-hidden="true" /> Agent operations</div><h2>A clear view. Confident control.</h2><p>Bring your agents, identities, and protection together. Keep every connection in view and every next step within reach.</p></section>
      <div className="overview-grid">
        <Card>
          <div className="overview-icon"><Bot24Regular aria-hidden="true" /></div><Text weight="semibold">Agents</Text>
          {agents.isPending ? <Spinner size="small" label="Loading agents" /> : agents.isError ? (
            <ErrorState error={agents.error} onRetry={() => agents.refetch()} />
          ) : (
            <>
              <RefreshIndicator active={agents.isFetching} label="Refreshing agent count" />
              <Text className="overview-number" size={700}>{agents.data.totalCount ?? agents.data.items.length}</Text>
              {agents.data.totalCount === null && agents.data.nextCursor && <Caption1>More registrations are available on the Agents page.</Caption1>}
              <Link to="/agents">View agents</Link>
              <Link to="/register">Register agent</Link>
            </>
          )}
        </Card>
        <Card>
          <div className="overview-icon"><Pulse24Regular aria-hidden="true" /></div><Text weight="semibold">Gateway API</Text>
          {health.isPending ? <Spinner size="small" label="Checking API" /> : health.isError ? (
            <ErrorState error={health.error} onRetry={() => health.refetch()} />
          ) : <><StatusPill value={health.data} /><RefreshIndicator active={health.isFetching} label="Rechecking API" /></>}
          <Link to="/settings">View gateway settings</Link>
        </Card>
        <Card>
          <div className="overview-icon"><ShieldTask24Regular aria-hidden="true" /></div><Text weight="semibold">Data protection</Text>
          <Body1>Review protection for individual agents. Policy rules and classifiers are managed in Purview.</Body1>
          {purview.isPending ? <Spinner size="small" label="Loading connection" /> : !purview.data ? (
            <ErrorState error={purview.error} onRetry={() => purview.refetch()} />
          ) : (
            <>
              {purview.isError && <ErrorState title="The latest Purview connection check failed" error={purview.error} onRetry={() => purview.refetch()} />}
              <RefreshIndicator active={purview.isFetching} label="Checking Purview connection" />
              <StatusPill value={purview.data.state} />
              <Caption1>{purview.data.catalogRetrievedAtUtc
                ? `Saved catalog: ${new Date(purview.data.catalogRetrievedAtUtc).toLocaleString()}`
                : "No verified policy catalog"}</Caption1>
              <Body1>Assignment and gateway enforcement are verified separately for each agent.</Body1>
            </>
          )}
          <Link to="/data-protection/policies">View policies and agents</Link>
          <Link to="/settings/purview">Connection diagnostics</Link>
        </Card>
      </div>
    </>
  );
}
