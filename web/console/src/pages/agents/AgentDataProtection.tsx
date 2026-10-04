import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Badge, Body1, Button, Caption1, Card, Field, Select, Spinner, Text } from "@fluentui/react-components";
import { api } from "../../api/client";
import type { AgentDetail } from "../../api/types";
import { evaluationLabel } from "../../api/display";

export function AgentDataProtection({ agent }: { agent: AgentDetail }) {
  const identity = agent.agent365?.agentId;
  const cache = useQueryClient();
  const catalog = useQuery({ queryKey: ["purview-policies"], queryFn: api.listPurviewPolicies, refetchInterval: 60000 });
  const assignments = useQuery({ queryKey: ["agent-policies", agent.agentId], queryFn: () => api.listAgentPolicies(agent.agentId), refetchInterval: 5000 });
  const [selected, setSelected] = useState("");
  const [review, setReview] = useState<Awaited<ReturnType<typeof api.reviewAgentPolicy>> | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const policy = catalog.data?.items.find(x => x.id === selected);
  const pending = assignments.data?.items.some(x => x.status === "Pending");
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    if (!pending) return;
    setNow(Date.now());
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [pending]);
  async function prepare() {
    if (!policy) return;
    setBusy(true); setError(null);
    try { setReview(await api.reviewAgentPolicy(agent.agentId, policy.id, policy.revision)); }
    catch (e) { setError(e instanceof Error ? e.message : "Could not review the assignment."); }
    finally { setBusy(false); }
  }
  async function confirm() {
    if (!review) return;
    setBusy(true); setError(null);
    try {
      await api.confirmAgentPolicy(agent.agentId, review.operationId);
      setReview(null); setSelected("");
      await cache.invalidateQueries({ queryKey: ["agent-policies", agent.agentId] });
      await cache.invalidateQueries({ queryKey: ["agent", agent.agentId] });
    } catch (e) { setError(e instanceof Error ? e.message : "Assignment was not confirmed. Refresh its status before retrying."); }
    finally { setBusy(false); }
  }
  const state = assignments.isError ? undefined : assignments.data;
  const observed = state?.bindingCurrent && state.allowObservedAtUtc && state.blockObservedAtUtc;
  return <div style={{ display: "grid", gap: 16 }}>
    <Card style={{ padding: 24, gap: 12 }}>
      <Text as="h2" size={500} weight="semibold">Data protection for this agent</Text>
      <Body1>Select existing Purview DLP policies. Your policy administrator manages rules, classifiers, and blocking actions in Purview.</Body1>
      <Caption1>Individual agent identity</Caption1>
      <Body1 style={{ overflowWrap: "anywhere" }}>{identity ?? "Available after the agent identity is created."}</Body1>
      <Caption1>Assignments target this agent. Other agents that share its blueprint are not added.</Caption1>
    </Card>
    <Card style={{ padding: 24, gap: 12 }}>
      <Text as="h2" size={400} weight="semibold">Policies from Purview</Text>
      {catalog.isError && <Body1 role="alert">The current Purview catalog is unavailable. Refresh after checking Settings → Purview.</Body1>}
      <Field label="Choose an existing policy">
        <Select value={selected} disabled={busy || pending || !!review || !identity || !catalog.data || catalog.isError} onChange={(_, data) => setSelected(data.value)}>
          <option value="">Select a policy</option>
          {catalog.data?.items.filter(x => x.compatibility.canAssign).map(x => <option key={x.id} value={x.id}>{x.displayName}</option>)}
        </Select>
      </Field>
      <Button appearance="primary" disabled={!policy || busy || pending || !!review || catalog.isError} onClick={prepare}>Review assignment</Button>
      <Button disabled={busy || catalog.isFetching || !!review} onClick={() => void catalog.refetch()}>Refresh policies</Button>
      {review && <Card style={{ padding: 16, gap: 12 }}>
        <Text weight="semibold">Review: {review.policyName}</Text>
        <Body1>Agent identity: {review.agentIdentityId}</Body1>
        <Body1>{review.effect}</Body1>
        <Caption1>Review expires {new Date(review.expiresAtUtc).toLocaleTimeString()}.</Caption1>
        <div style={{ display: "flex", gap: 8 }}><Button appearance="primary" disabled={busy || Date.parse(review.expiresAtUtc) <= Date.now()} onClick={confirm}>Apply to this agent</Button><Button disabled={busy} onClick={() => setReview(null)}>Cancel</Button></div>
      </Card>}
      {error && <Body1 role="alert">{error}</Body1>}
      {assignments.isError && <Body1 role="alert">Assignment status is unavailable. No protection state has been assumed.</Body1>}
      {(pending || assignments.isError) && <Button disabled={assignments.isFetching} onClick={() => void assignments.refetch()}>Check assignment status</Button>}
      {state?.items.map(x => {
        const overdue = x.status === "Pending" && !!x.expiresAtUtc && Date.parse(x.expiresAtUtc) <= now;
        const stale = x.status === "Pending" && now - assignments.dataUpdatedAt > 20000;
        const elapsed = x.confirmedAtUtc ? Math.max(0, Math.floor((now - Date.parse(x.confirmedAtUtc)) / 1000)) : null;
        return <Card key={x.operationId} style={{ padding: 16, gap: 8 }}>
        <Text weight="semibold">{x.policyName}</Text>
        {x.status === "Pending" && !overdue && !stale ? <>
          <Spinner size="tiny" label="Applying assignment" style={{ justifyContent: "flex-start" }} />
          <Body1>Waiting for Purview assignment confirmation. This can take several minutes. You can leave this page; the request continues in the background.</Body1>
          {elapsed !== null && <Caption1>Elapsed: {Math.floor(elapsed / 60)}m {elapsed % 60}s</Caption1>}
          <Caption1>Checks automatically every 5 seconds while this page is active. Last checked {new Date(assignments.dataUpdatedAt).toLocaleTimeString()}.</Caption1>
        </> : <Badge appearance="tint" color={x.status === "Failed" || overdue ? "danger" : "informative"} style={{ alignSelf: "flex-start" }}>{overdue ? "Assignment taking longer than expected" : stale ? "Status update delayed" : x.status === "Assigned" ? "Assigned" : "Assignment not confirmed"}</Badge>}
        {overdue && <Body1 role="alert">The confirmation window has elapsed. The outcome is not confirmed; check assignment status before reviewing again.</Body1>}
        {stale && !overdue && <Body1 role="alert">A recent status check is unavailable. Background progress is not confirmed.</Body1>}
        {x.status === "Assigned" && x.assignedAtUtc && <Caption1>Purview assignment confirmed {new Date(x.assignedAtUtc).toLocaleString()}. Policy sync and gateway enforcement are checked separately below.</Caption1>}
        {x.failureCode && <Caption1>{x.failureCode}. Refresh the policy catalog and review again to reconcile its current scope.</Caption1>}
      </Card>; })}
      {state?.items.length === 0 && <Body1>No policies selected in this Console. Policies scoped elsewhere in Purview may still apply.</Body1>}
      <Link to="/data-protection/policies">View all policies and agents</Link>
      <a href="https://purview.microsoft.com/datalossprevention/policies" target="_blank" rel="noopener noreferrer">Open policies in Purview ↗</a>
    </Card>
    <Card style={{ padding: 24, gap: 12 }}>
      <Text as="h2" size={400} weight="semibold">Enforcement status</Text>
      <Body1>{observed ? "Gateway allow and block verified" : state?.bindingCurrent ? "Assigned · awaiting sync and gateway verification" : state?.items.length ? "Enforcement readiness not confirmed · protected requests fail closed" : `Gateway content evaluation: ${evaluationLabel(agent.features?.purviewEnabled)}`}</Body1>
      {state?.allowObservedAtUtc && <Caption1>Last gateway allow: {new Date(state.allowObservedAtUtc).toLocaleString()}</Caption1>}
      {state?.blockObservedAtUtc && <Caption1>Last gateway DLP block: {new Date(state.blockObservedAtUtc).toLocaleString()}</Caption1>}
      <Caption1>These observations come from the gateway API under this agent’s current configuration. Purview evaluates all applicable policies; a block alone does not identify which policy caused it.</Caption1>
    </Card>
  </div>;
}
