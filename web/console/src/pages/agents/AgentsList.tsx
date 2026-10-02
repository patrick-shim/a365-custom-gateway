import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { Link, useNavigate } from "react-router-dom";
import {
  Table, TableHeader, TableRow, TableHeaderCell, TableBody, TableCell,
  Spinner, Button, Text, Body1,
} from "@fluentui/react-components";
import { api } from "../../api/client";
import { blueprintName, formatTime, shieldLabel } from "../../api/display";
import { PageHeader } from "../../components/PageHeader";
import { StatusPill } from "../../components/StatusPill";
import { ErrorState } from "../../components/ErrorState";

export function AgentsList() {
  const navigate = useNavigate();
  const agents = useInfiniteQuery({
    queryKey: ["agents"],
    queryFn: ({ pageParam }) => api.listAgents(pageParam),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: last => last.nextCursor ?? undefined,
  });
  const blueprints = useQuery({ queryKey: ["blueprints"], queryFn: api.listBlueprints });
  const items = agents.data?.pages.flatMap(page => page.items) ?? [];
  return (
    <>
      <PageHeader title="Agents" subtitle="Each registration has its own identity and Gateway key."
        actions={<Button appearance="primary" onClick={() => navigate("/register")}>Register agent</Button>} />
      {agents.isPending ? <Spinner label="Loading agents" /> : agents.isError ? (
        <ErrorState error={agents.error} onRetry={() => void agents.refetch()} />
      ) : items.length === 0 ? <Body1>No agents registered yet.</Body1> : (
        <>
          {blueprints.isError && <ErrorState title="Blueprint names could not be loaded" error={blueprints.error} onRetry={() => void blueprints.refetch()} />}
          <div style={{ overflowX: "auto" }}>
            <Table aria-label="Agents">
              <TableHeader><TableRow>
                <TableHeaderCell>Agent</TableHeaderCell><TableHeaderCell>Blueprint</TableHeaderCell>
                <TableHeaderCell>Status</TableHeaderCell><TableHeaderCell>Prompt Shields</TableHeaderCell>
                <TableHeaderCell>Last activity</TableHeaderCell>
              </TableRow></TableHeader>
              <TableBody>{items.map(agent => (
                <TableRow key={agent.agentId}>
                  <TableCell>
                    <Link to={`/agents/${agent.agentId}`}>{agent.name}</Link>
                    <Text block size={200}>{agent.externalAgentId}</Text>
                  </TableCell>
                  <TableCell style={{ overflowWrap: "anywhere" }}>{blueprintName(agent, blueprints.data)}</TableCell>
                  <TableCell>
                    <StatusPill value={agent.status} />
                    {agent.status === "AwaitingAdminApproval" && <Text block size={200} style={{ marginTop: 8 }}>
                      <Link to={`/agents/${agent.agentId}`} aria-label={`Review registration for ${agent.name}`}>Review registration</Link>
                    </Text>}
                  </TableCell>
                  <TableCell><StatusPill value={shieldLabel(agent)} /></TableCell>
                  <TableCell>{formatTime(agent.lastActivityAtUtc)}</TableCell>
                </TableRow>
              ))}</TableBody>
            </Table>
          </div>
          {agents.hasNextPage && <Button style={{ marginTop: 16 }} disabled={agents.isFetchingNextPage}
            onClick={() => void agents.fetchNextPage()}>{agents.isFetchingNextPage ? "Loading..." : "Load more agents"}</Button>}
        </>
      )}
    </>
  );
}
