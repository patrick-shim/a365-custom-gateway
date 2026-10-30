import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Badge, Body1, Button, Caption1, Card, Field, MessageBar, MessageBarBody,
  MessageBarTitle, Select, Spinner, Text,
} from "@fluentui/react-components";
import { api } from "../../api/client";
import { ApiError } from "../../api/errors";
import type { AgentDetail, PurviewConnection } from "../../api/types";
import { evaluationLabel } from "../../api/display";
import { ErrorState } from "../../components/ErrorState";
import { RefreshIndicator } from "../../components/RefreshIndicator";
import { StatusPill } from "../../components/StatusPill";
import { purviewConnectionQueryKey, purviewPolicyCatalogQueryKey } from "../../api/queryKeys";

export function AgentDataProtection({ agent }: { agent: AgentDetail }) {
  const identity = agent.agent365?.agentId;
  const cache = useQueryClient();
  const catalog = useQuery({ queryKey: purviewPolicyCatalogQueryKey, queryFn: api.listPurviewPolicies, refetchInterval: 60000 });
  const connection = useQuery({
    queryKey: purviewConnectionQueryKey,
    queryFn: api.getPurviewConnection,
    retry: false,
    refetchInterval: query => ["Connecting", "Refreshing"].includes(query.state.data?.state ?? "") ? 5000 : 60000,
  });
  const assignments = useQuery({ queryKey: ["agent-policies", agent.agentId], queryFn: () => api.listAgentPolicies(agent.agentId), refetchInterval: 5000 });
  const [selected, setSelected] = useState("");
  const [review, setReview] = useState<Awaited<ReturnType<typeof api.reviewAgentPolicy>> | null>(null);
  const [action, setAction] = useState<"review" | "confirm" | null>(null);
  const [error, setError] = useState<unknown>();
  const [errorPhase, setErrorPhase] = useState<"review" | "confirm">("review");
  const busy = action !== null;
  const policy = catalog.data?.items.find(x => x.id === selected);
  const pending = assignments.data?.items.some(x => x.status === "Pending");
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    setNow(Date.now());
    const timer = window.setInterval(() => setNow(Date.now()), pending ? 1000 : 30000);
    return () => window.clearInterval(timer);
  }, [pending]);
  const requestedConnectionCatalog = useRef<string | null>(null);
  useEffect(() => {
    const accepted = connection.data?.catalogRetrievedAtUtc;
    const loaded = catalog.data?.retrievedAtUtc;
    if (!accepted || !loaded) return;
    if (Date.parse(loaded) >= Date.parse(accepted)) {
      requestedConnectionCatalog.current = null;
      return;
    }
    if (requestedConnectionCatalog.current === accepted) return;
    requestedConnectionCatalog.current = accepted;
    void cache.invalidateQueries({ queryKey: purviewPolicyCatalogQueryKey });
  }, [cache, catalog.data?.retrievedAtUtc, connection.data?.catalogRetrievedAtUtc]);
  const previousLoadedCatalog = useRef<string | undefined>(undefined);
  useEffect(() => {
    const current = catalog.data?.retrievedAtUtc;
    if (!current) return;
    const previous = previousLoadedCatalog.current;
    previousLoadedCatalog.current = current;
    if (previous === undefined || previous === current) return;
    setSelected("");
    setReview(null);
    if (error instanceof ApiError && error.code === "PURVIEW_INVENTORY_STALE") {
      setError(undefined);
    }
  }, [catalog.data?.retrievedAtUtc, error]);
  const reviewReadiness = getAssignmentReviewReadiness(
    connection.data,
    catalog.data?.retrievedAtUtc,
    now,
  );
  async function prepare() {
    if (!policy || !reviewReadiness.ready) return;
    setAction("review"); setError(undefined); setErrorPhase("review");
    try { setReview(await api.reviewAgentPolicy(agent.agentId, policy.id, policy.revision)); }
    catch (e) { setError(e); }
    finally { setAction(null); }
  }
  async function confirm() {
    if (!review || !reviewReadiness.ready) return;
    setAction("confirm"); setError(undefined); setErrorPhase("confirm");
    try {
      await api.confirmAgentPolicy(agent.agentId, review.operationId);
      setReview(null); setSelected("");
      await cache.invalidateQueries({ queryKey: ["agent-policies", agent.agentId] });
      await cache.invalidateQueries({ queryKey: ["agent", agent.agentId] });
    } catch (e) { setError(e); }
    finally { setAction(null); }
  }
  const state = assignments.isError ? undefined : assignments.data;
  const needsAttention = state?.items.some(item => item.status === "NeedsAttention") ?? false;
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
      {catalog.data && <Caption1>Last synced {new Date(catalog.data.retrievedAtUtc).toLocaleString()}. Saved policies stay available until the next successful manual sync.</Caption1>}
      {catalog.isPending && <Spinner size="small" label="Loading saved policies" />}
      {catalog.isError && <ErrorState title="The current Purview catalog is unavailable" error={catalog.error} onRetry={() => catalog.refetch()} />}
      {connection.isError && <ErrorState title="Purview connection status is unavailable" error={connection.error}
        onRetry={() => connection.refetch()} />}
      <RefreshIndicator active={catalog.isFetching && !catalog.isPending} label="Reloading saved catalog" />
      {connection.isPending && <Spinner size="tiny" label="Checking Purview connection" />}
      {!connection.isPending && !reviewReadiness.ready && <MessageBar intent={reviewReadiness.intent}
        role={reviewReadiness.intent === "warning" ? "alert" : "status"}>
        <MessageBarBody>
          <MessageBarTitle>{reviewReadiness.title}</MessageBarTitle>
          {reviewReadiness.detail}
        </MessageBarBody>
      </MessageBar>}
      <Field label="Choose an existing policy">
        <Select value={selected} disabled={busy || pending || !!review || !identity || !catalog.data || catalog.isError || !reviewReadiness.ready} onChange={(_, data) => setSelected(data.value)}>
          <option value="">Select a policy</option>
          {catalog.data?.items.filter(x => x.compatibility.canAssign).map(x => <option key={x.id} value={x.id}>{x.displayName}</option>)}
        </Select>
      </Field>
      <Button appearance="primary" disabled={!policy || busy || pending || !!review || catalog.isError || !reviewReadiness.ready}
        icon={action === "review" ? <Spinner size="tiny" /> : undefined} onClick={() => void prepare()}>
        {action === "review" ? "Preparing review…" : "Review assignment"}
      </Button>
      <Button disabled={busy || catalog.isFetching || connection.isFetching || !!review}
        icon={catalog.isFetching || connection.isFetching ? <Spinner size="tiny" /> : undefined}
        onClick={() => void Promise.all([connection.refetch(), catalog.refetch()])}>
        {catalog.isFetching || connection.isFetching ? "Reloading…" : "Reload saved catalog"}
      </Button>
      {review && <Card style={{ padding: 16, gap: 12 }}>
        <Text weight="semibold">Review: {review.policyName}</Text>
        <Body1>Agent identity: {review.agentIdentityId}</Body1>
        <Body1>{review.effect}</Body1>
        <Caption1>Review expires {new Date(review.expiresAtUtc).toLocaleTimeString()}.</Caption1>
        <div style={{ display: "flex", gap: 8 }}><Button appearance="primary" disabled={busy || !reviewReadiness.ready || Date.parse(review.expiresAtUtc) <= Date.now()}
          icon={action === "confirm" ? <Spinner size="tiny" /> : undefined} onClick={() => void confirm()}>
          {action === "confirm" ? "Submitting assignment…" : "Apply to this agent"}
        </Button><Button disabled={busy} onClick={() => setReview(null)}>Cancel</Button></div>
      </Card>}
      {error !== undefined && <ErrorState title={errorPhase === "confirm" ? "Assignment was not confirmed" : "Assignment review could not be prepared"} error={error} />}
      {assignments.isPending && <Spinner size="small" label="Checking assignment status" />}
      {assignments.isError && <ErrorState title="Assignment status is unavailable. No protection state has been assumed."
        error={assignments.error} onRetry={() => assignments.refetch()} />}
      <RefreshIndicator active={assignments.isFetching && !assignments.isPending} label="Checking assignment status" />
      {(pending || assignments.isError) && <Button disabled={assignments.isFetching} icon={assignments.isFetching ? <Spinner size="tiny" /> : undefined}
        onClick={() => void assignments.refetch()}>{assignments.isFetching ? "Checking…" : "Check assignment status"}</Button>}
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
        </> : overdue ? <Badge appearance="tint" color="danger" style={{ alignSelf: "flex-start" }}>Assignment taking longer than expected</Badge>
          : stale ? <Badge appearance="tint" color="warning" style={{ alignSelf: "flex-start" }}>Status update delayed</Badge>
            : <StatusPill value={x.status === "Assigned" ? "Assigned" : x.status === "NeedsAttention" ? "NeedsAttention" : "Unconfirmed"} />}
        {overdue && <Body1 role="alert">The confirmation window has elapsed. The outcome is not confirmed; check assignment status before reviewing again.</Body1>}
        {stale && !overdue && <Body1 role="alert">A recent status check is unavailable. Background progress is not confirmed.</Body1>}
        {x.status === "NeedsAttention" && <Body1 role="alert">This assignment no longer matches the current verified catalog. Refresh the catalog, review the exact policy revision and agent scope, then apply it again if it is still appropriate.</Body1>}
        {x.status === "Assigned" && x.assignedAtUtc && <Caption1>Purview assignment confirmed {new Date(x.assignedAtUtc).toLocaleString()}. Policy sync and gateway enforcement are checked separately below.</Caption1>}
        {x.failureCode === "ASSIGNMENT_RESULT_INVALID" ? <Caption1 role="alert">
          ASSIGNMENT_RESULT_INVALID. Inspect the Purview connector and this operation&apos;s status, then repair or redeploy the bootstrap-owned Purview Catalog Host assignment transport before refreshing the catalog or reviewing another assignment. Do not retry or resubmit this assignment until that transport is repaired.
        </Caption1> : x.failureCode && <Caption1>{x.failureCode}. Refresh the policy catalog and review again to reconcile its current scope.</Caption1>}
      </Card>; })}
      {state?.items.length === 0 && <Body1>No policies selected in this Console. Policies scoped elsewhere in Purview may still apply.</Body1>}
      <Link to="/data-protection/policies">View all policies and agents</Link>
      <Link to="/settings/purview">Open Manual sync</Link>
      <a href="https://purview.microsoft.com/datalossprevention/policies" target="_blank" rel="noopener noreferrer">Open policies in Purview ↗</a>
    </Card>
    <Card style={{ padding: 24, gap: 12 }}>
      <Text as="h2" size={400} weight="semibold">Enforcement status</Text>
      <StatusPill value={observed ? "Verified" : needsAttention ? "NeedsAttention" : state?.bindingCurrent ? "PendingVerification" : state?.items.length ? "Unconfirmed" : "NotConfigured"} />
      <Body1>{observed ? "Gateway allow and block verified" : needsAttention ? "One or more saved assignments need review before enforcement can be verified" : state?.bindingCurrent ? "Assigned · awaiting sync and gateway verification" : state?.items.length ? "Enforcement readiness not confirmed · protected requests fail closed" : `Gateway content evaluation: ${evaluationLabel(agent.features?.purviewEnabled)}`}</Body1>
      {state?.allowObservedAtUtc && <Caption1>Last gateway allow: {new Date(state.allowObservedAtUtc).toLocaleString()}</Caption1>}
      {state?.blockObservedAtUtc && <Caption1>Last gateway DLP block: {new Date(state.blockObservedAtUtc).toLocaleString()}</Caption1>}
      <Caption1>These observations come from the gateway API under this agent’s current configuration. Purview evaluates all applicable policies; a block alone does not identify which policy caused it.</Caption1>
    </Card>
  </div>;
}

type AssignmentReviewReadiness = {
  ready: boolean;
  intent: "info" | "warning";
  title: string;
  detail: string;
};

function getAssignmentReviewReadiness(
  connection: PurviewConnection | undefined,
  catalogRetrievedAtUtc: string | undefined,
  now: number,
): AssignmentReviewReadiness {
  if (!catalogRetrievedAtUtc) return {
    ready: false,
    intent: "warning",
    title: "No verified policy catalog is ready",
    detail: "Run Manual sync to retrieve the first saved policy list.",
  };
  const acceptedAt = connection?.catalogRetrievedAtUtc ? Date.parse(connection.catalogRetrievedAtUtc) : null;
  const retrievedAt = Date.parse(catalogRetrievedAtUtc);
  if (!Number.isFinite(retrievedAt) || retrievedAt > now + 60_000) return {
    ready: false,
    intent: "warning",
    title: "The verified policy catalog could not be confirmed",
    detail: "Reload the saved catalog before reviewing a new assignment.",
  };
  if (acceptedAt !== null && acceptedAt > retrievedAt) return {
    ready: false,
    intent: "info",
    title: "Loading the latest verified policy catalog",
    detail: "A newer Purview snapshot was accepted. Review will be available after this page loads that exact revision.",
  };
  return { ready: true, intent: "info", title: "Policy assignment is ready", detail: "" };
}
