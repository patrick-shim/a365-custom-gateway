import { useState } from "react";
import { useInfiniteQuery, useQueryClient } from "@tanstack/react-query";
import { Button, Card, Checkbox, Dialog, DialogSurface, DialogBody, DialogTitle, DialogContent, DialogActions, Spinner, Text, Input } from "@fluentui/react-components";
import { api } from "../api/client";
import { PageHeader } from "../components/PageHeader";
import { ErrorState } from "../components/ErrorState";
import { StatusPill } from "../components/StatusPill";

type Reviewed = Awaited<ReturnType<typeof api.getAgent>>;
type ListedAgent = Awaited<ReturnType<typeof api.listAgents>>["items"][number];
export function AgentDeletion() {
  const qc = useQueryClient();
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [review, setReview] = useState<Reviewed[]>([]);
  const [busy, setBusy] = useState(false);
  const [busyLabel, setBusyLabel] = useState("");
  const [error, setError] = useState<unknown>();
  const [confirmation, setConfirmation] = useState("");
  const [results, setResults] = useState<Record<string, string>>({});
  const [accessReview, setAccessReview] = useState<{ enabled: boolean; agents: ListedAgent[] }>();
  const agents = useInfiniteQuery({ queryKey: ["agents", "deletion"], queryFn: ({ pageParam }) => api.listAgents(pageParam),
    initialPageParam: undefined as string | undefined, getNextPageParam: last => last.nextCursor ?? undefined });
  const items = agents.data?.pages.flatMap(page => page.items) ?? [];
  const eligible = items.filter(a => a.agent365?.instanceId && ["Active", "Disabled", "Deleting"].includes(a.status));
  const accessCandidates = (enabled: boolean) => items.filter(a => selected.has(a.agentId) && a.status === (enabled ? "Disabled" : "Active"));
  async function changeAccess() {
    if (!accessReview) return;
    const batch = accessReview;
    setAccessReview(undefined); setBusy(true); setResults({});
    try {
      for (const [index, agent] of batch.agents.entries()) {
        setBusyLabel(`${batch.enabled ? "Enabling" : "Disabling"} agent ${index + 1} of ${batch.agents.length}`);
        setResults(r => ({ ...r, [agent.agentId]: batch.enabled ? "Enabling gateway access…" : "Disabling gateway access…" }));
        try {
          await api.setAgentEnabled(agent.agentId, batch.enabled);
          setResults(r => ({ ...r, [agent.agentId]: batch.enabled ? "Active — gateway access restored" : "Disabled — new gateway submissions blocked. Agent 365 unchanged." }));
          setSelected(s => { const next = new Set(s); next.delete(agent.agentId); return next; });
        } catch (e) {
          setResults(r => ({ ...r, [agent.agentId]: e instanceof Error ? e.message : "Change unconfirmed. Refresh before retrying." }));
        }
      }
      await Promise.all([qc.invalidateQueries({ queryKey: ["agents"] }), qc.invalidateQueries({ queryKey: ["agent"] }), qc.invalidateQueries({ queryKey: ["agent-summary"] })]);
    } finally { setBusy(false); setBusyLabel(""); }
  }
  async function prepare() {
    setBusy(true); setBusyLabel("Reviewing selected agents"); setError(undefined); setResults({});
    try {
      const snapshot = await Promise.all([...selected].map(id => api.getAgent(id)));
      setConfirmation(""); setReview(snapshot);
    } catch (e) { setError(e); }
    finally { setBusy(false); setBusyLabel(""); }
  }
  async function remove() {
    const batch = [...review];
    setReview([]); setBusy(true); setError(undefined);
    try {
      for (const [index, agent] of batch.entries()) {
        setBusyLabel(`Deleting agent ${index + 1} of ${batch.length}`);
        setResults(r => ({ ...r, [agent.agentId]: "Deleting and verifying with Microsoft…" }));
        try {
          await api.deleteRegisteredAgent(agent.agentId, agent.rowVersion);
          setResults(r => ({ ...r, [agent.agentId]: "Deleted from gateway and Agent 365" }));
          setSelected(s => { const next = new Set(s); next.delete(agent.agentId); return next; });
        } catch (e) {
          setResults(r => ({ ...r, [agent.agentId]: e instanceof Error ? e.message : "Deletion unconfirmed. Refresh and retry." }));
        }
      }
      await qc.invalidateQueries({ queryKey: ["agents"] });
      await qc.invalidateQueries({ queryKey: ["agent"] });
    } finally { setBusy(false); setBusyLabel(""); }
  }
  return <>
    <PageHeader title="Manage Agents" subtitle="Manage gateway access or permanently deregister selected agents." />
    <Card style={{ marginBottom: 20 }}>
      <Text weight="semibold">Gateway access</Text>
      <Text>Disable blocks new prompt, activity and AI interaction submissions to this gateway. Agent 365 registration, Entra identity and protection settings remain unchanged. Enable restores gateway access. Previously accepted work may finish processing.</Text>
      <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>
        <Button className="warning-action" disabled={busy || !accessCandidates(false).length} onClick={() => setAccessReview({ enabled: false, agents: accessCandidates(false) })}>Disable selected ({accessCandidates(false).length})</Button>
        <Button appearance="primary" disabled={busy || !accessCandidates(true).length} onClick={() => setAccessReview({ enabled: true, agents: accessCandidates(true) })}>Enable selected ({accessCandidates(true).length})</Button>
      </div>
    </Card>
    <Card style={{ marginBottom: 20 }}>
      <Text>Gateway administrators only. Agent 365 removal is verified before the gateway registration is removed. Failed or unconfirmed deletions remain visible for retry.</Text>
      <Text>Shared blueprints, Entra identities, Purview policies and historical audit records are retained. This action has no undo in the gateway.</Text>
      <div style={{ display: "flex", gap: 12, alignItems: "center", flexWrap: "wrap" }}>
        <Button className="destructive-action" disabled={busy || !selected.size} onClick={() => void prepare()}>Review deletion ({selected.size})</Button>
        <Button disabled={busy || agents.isFetching} icon={agents.isFetching ? <Spinner size="tiny" /> : undefined}
          onClick={() => void agents.refetch()}>{agents.isFetching ? "Refreshing…" : "Refresh"}</Button>
        {busy && <Spinner size="small" label={busyLabel || "Processing selected agents"} />}
      </div>
      {error != null && <ErrorState error={error} />}
    </Card>
    {agents.isPending ? <Spinner label="Loading agents" /> : agents.isError ? <ErrorState error={agents.error} onRetry={() => agents.refetch()} /> : <Card>
      <Checkbox label="Select all eligible agents on loaded pages" disabled={busy || !eligible.length}
        checked={eligible.length > 0 && eligible.every(a => selected.has(a.agentId))}
        onChange={(_, d) => setSelected(d.checked ? new Set(eligible.map(a => a.agentId)) : new Set())} />
      {!items.length && <Text>No registered agents.</Text>}
      {items.map(agent => <div key={agent.agentId} style={{ borderTop: "1px solid var(--colorNeutralStroke2)", padding: "12px 0" }}>
        <Checkbox label={`${agent.name} — ${agent.externalAgentId}`} checked={selected.has(agent.agentId)} disabled={busy || !eligible.some(a => a.agentId === agent.agentId)}
          onChange={(_, d) => setSelected(s => { const next = new Set(s); if (d.checked) next.add(agent.agentId); else next.delete(agent.agentId); return next; })} />
        <StatusPill value={agent.status} />
        {agent.status === "Disabled" && <Text block size={200}>Gateway access blocked · Agent 365 registration unchanged</Text>}
        <Text block size={200}>Registry: {agent.agent365?.instanceId ?? "Not registered"}</Text>
      </div>)}
      {agents.hasNextPage && <Button disabled={busy || agents.isFetchingNextPage} icon={agents.isFetchingNextPage ? <Spinner size="tiny" /> : undefined}
        onClick={() => void agents.fetchNextPage()}>{agents.isFetchingNextPage ? "Loading more agents…" : "Load more agents"}</Button>}
    </Card>}
    <div aria-live="polite" style={{ marginTop: 20 }}>{Object.entries(results).map(([id, message]) =>
      <Card className="action-result" data-tone={resultTone(message)} key={id} style={{ marginBottom: 8 }}>
        <Text weight="semibold">{items.find(a => a.agentId === id)?.name ?? id}</Text><Text>{message}</Text>
      </Card>)}</div>
    <Dialog open={!!accessReview} onOpenChange={(_, d) => { if (!d.open) setAccessReview(undefined); }}>
      <DialogSurface><DialogBody><DialogTitle>{accessReview?.enabled ? "Enable" : "Disable"} gateway access?</DialogTitle>
        <DialogContent><p>{accessReview?.enabled ? "Restore gateway submissions for these agents." : "Block new gateway submissions for these agents. You can enable them again later."} This does not change their Agent 365 registration.</p>
          <ul>{accessReview?.agents.map(a => <li key={a.agentId}>{a.name} · {a.externalAgentId}</li>)}</ul>
        </DialogContent>
        <DialogActions><Button onClick={() => setAccessReview(undefined)}>Cancel</Button><Button appearance="primary" onClick={() => void changeAccess()}>{accessReview?.enabled ? "Enable gateway access" : "Disable gateway access"}</Button></DialogActions>
      </DialogBody></DialogSurface>
    </Dialog>
    <Dialog open={review.length > 0} onOpenChange={(_, d) => { if (!d.open) setReview([]); }}>
      <DialogSurface><DialogBody><DialogTitle>Delete {review.length} registered agent{review.length === 1 ? "" : "s"} permanently?</DialogTitle>
        <DialogContent>
          <p>This stops gateway access and permanently removes each selected Agent 365 Registry entry. There is no undo. Shared resources and historical audit records are retained.</p>
          <ul>{review.map(a => <li key={a.agentId}>{a.name} · {a.externalAgentId}<br /><small>{a.agent365?.instanceId}</small></li>)}</ul>
          <label htmlFor="delete-confirm">Type DELETE to confirm</label>
          <Input id="delete-confirm" value={confirmation} onChange={(_, d) => setConfirmation(d.value)} />
        </DialogContent>
        <DialogActions><Button onClick={() => setReview([])}>Cancel</Button><Button className="destructive-action" disabled={confirmation !== "DELETE"} onClick={() => void remove()}>Delete permanently</Button></DialogActions>
      </DialogBody></DialogSurface>
    </Dialog>
  </>;
}

function resultTone(message: string): "success" | "warning" | "danger" {
  if (/^(Active|Disabled|Deleted)/.test(message)) return "success";
  if (/unconfirmed|failed|denied|error/i.test(message)) return "danger";
  return "warning";
}
