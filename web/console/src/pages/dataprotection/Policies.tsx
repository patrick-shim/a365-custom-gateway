import { useState } from "react";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { Table, TableHeader, TableRow, TableHeaderCell, TableBody, TableCell, Spinner, Button, Body1, Caption1, Card, Text, Badge, Input } from "@fluentui/react-components";
import { api } from "../../api/client";
import { PageHeader } from "../../components/PageHeader";
import { StatusPill } from "../../components/StatusPill";
import { ErrorState } from "../../components/ErrorState";
import { evaluationLabel } from "../../api/display";

export function Policies() {
  const catalog = useQuery({ queryKey: ["purview-policy-catalog"], queryFn: api.listPurviewPolicies, retry: false, refetchInterval: 60_000 });
  const [search, setSearch] = useState("");
  const [draft, setDraft] = useState("");
  const agents = useInfiniteQuery({
    queryKey: ["agents", "data-protection", search],
    queryFn: ({ pageParam }) => api.listAgents(pageParam, search || undefined),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: last => last.nextCursor ?? undefined,
  });
  const items = agents.data?.pages.flatMap(page => page.items) ?? [];
  return <>
    <PageHeader title="Policies" subtitle="Review data protection for individual agents. Policy definitions stay in Microsoft Purview." />
    <div style={{ display: "grid", gap: 20 }}>
      <Card style={{ padding: 24, gap: 12 }}>
        <Text as="h2" size={500} weight="semibold">Existing policies from Purview</Text>
        <Body1>Your policy administrator owns the rules, sensitive information types, and actions. The gateway's role is to select existing policies for agents and verify enforcement.</Body1>
        <Caption1>Policies are read from Purview. A compatible policy still needs an agent assignment, synchronization, and verified blocking.</Caption1>
        {catalog.isPending ? <Spinner label="Loading policies from Purview" /> : catalog.isError ?
          <ErrorState error={catalog.error} onRetry={() => void catalog.refetch()} /> : <>
          <Caption1>Last read from Purview: {new Date(catalog.data.retrievedAtUtc).toLocaleString()}</Caption1>
          {catalog.data.items.length === 0 ? <Body1>Purview returned no policies for this tenant.</Body1> :
            <div style={{ overflowX: "auto" }}><Table aria-label="Policies from Purview">
              <TableHeader><TableRow><TableHeaderCell>Policy</TableHeaderCell><TableHeaderCell>Agent blocking support</TableHeaderCell></TableRow></TableHeader>
              <TableBody>{catalog.data.items.map(policy => <TableRow key={policy.id}>
                <TableCell>{policy.displayName}</TableCell>
                <TableCell><Badge appearance="tint" color={policy.compatibility.canAssign ? "informative" : "subtle"}>{policy.compatibility.canAssign ? "Compatible" : "Not compatible"}</Badge>
                  {policy.compatibility.reason && <Caption1 block>{policy.compatibility.reason}</Caption1>}</TableCell>
              </TableRow>)}</TableBody>
            </Table></div>}
        </>}
        <Body1>Choose an agent below to select a compatible policy, review its individual identity, and apply the assignment. Assignment and verified gateway enforcement are shown separately.</Body1>
        <a href="https://purview.microsoft.com/datalossprevention/policies" target="_blank" rel="noopener noreferrer">Open policies in Purview ↗</a>
      </Card>
      <Card style={{ padding: 24, gap: 16 }}>
        <Text as="h2" size={500} weight="semibold">Agent data protection</Text>
        <Caption1>Evaluation settings are shown separately from verified policy enforcement.</Caption1>
        <form onSubmit={event => { event.preventDefault(); setSearch(draft.trim()); }} style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <Input aria-label="Search agents" placeholder="Find an agent" value={draft} onChange={(_, data) => setDraft(data.value)} style={{ minWidth: 0 }} />
          <Button type="submit">Search</Button>
          <Button disabled={agents.isFetching} onClick={() => void agents.refetch()}>Refresh agents</Button>
        </form>
        {agents.isPending ? <Spinner label="Loading agents" /> : agents.isError ? <ErrorState error={agents.error} onRetry={() => void agents.refetch()} /> : items.length === 0 ? (
          <Body1>{search ? "No agents match your search." : "No agents registered yet."}</Body1>
        ) : <div style={{ overflowX: "auto" }}>
          <Table aria-label="Agent data protection">
            <TableHeader><TableRow><TableHeaderCell>Agent</TableHeaderCell><TableHeaderCell>Registration</TableHeaderCell><TableHeaderCell>Gateway evaluation</TableHeaderCell></TableRow></TableHeader>
            <TableBody>{items.map(agent => <TableRow key={agent.agentId}>
              <TableCell><Link to={`/agents/${agent.agentId}?tab=data-protection`}>{agent.name}</Link><Caption1 block>{agent.externalAgentId}</Caption1></TableCell>
              <TableCell><StatusPill value={agent.status} /></TableCell>
              <TableCell>{evaluationLabel(agent.features?.purviewEnabled)}</TableCell>
            </TableRow>)}</TableBody>
          </Table>
        </div>}
        {agents.hasNextPage && <Button style={{ alignSelf: "flex-start" }} disabled={agents.isFetchingNextPage} onClick={() => void agents.fetchNextPage()}>{agents.isFetchingNextPage ? "Loading..." : "Load more agents"}</Button>}
      </Card>
    </div>
  </>;
}
