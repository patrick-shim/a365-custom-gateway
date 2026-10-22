import { useEffect, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import {
  Body1, Button, Caption1, Card, MessageBar, MessageBarBody, MessageBarTitle,
  ProgressBar, Spinner, Text,
} from "@fluentui/react-components";
import { api } from "../../api/client";
import {
  purviewConnectionQueryKey, purviewConnectorOperationQueryKey, purviewPolicyCatalogQueryKey,
} from "../../api/queryKeys";
import type { PurviewConnection, PurviewConnectorOperation } from "../../api/types";
import { PageHeader } from "../../components/PageHeader";
import { ErrorState } from "../../components/ErrorState";
import { RefreshIndicator } from "../../components/RefreshIndicator";
import { StatusPill } from "../../components/StatusPill";

const terminalOperationStates = new Set(["Succeeded", "Failed", "NeedsAttention", "TimedOut", "Cancelled"]);
const liveOperationStates = new Set(["Pending", "Running"]);

type ConnectionAction = "connect" | "refresh";

export function Connection() {
  const queryClient = useQueryClient();
  const [confirmationOpen, setConfirmationOpen] = useState(false);
  const [activeOperationId, setActiveOperationId] = useState<string | null>(null);
  const [activeAction, setActiveAction] = useState<ConnectionAction | null>(null);
  const [operationAcceptedAt, setOperationAcceptedAt] = useState<number | null>(null);
  const [now, setNow] = useState(Date.now);
  const handledTerminal = useRef<string | null>(null);
  const submissionInFlight = useRef(false);

  const connection = useQuery({
    queryKey: purviewConnectionQueryKey,
    queryFn: api.getPurviewConnection,
    retry: false,
    refetchInterval: 60_000,
  });
  const state = connection.data?.state;

  useEffect(() => {
    const durableOperationId = connection.data?.currentOperationId;
    const durableState = connection.data?.state;
    if (!durableOperationId || !durableState || !["Connecting", "Refreshing"].includes(durableState) ||
        durableOperationId === activeOperationId) return;
    setActiveOperationId(durableOperationId);
    setActiveAction(durableState === "Connecting" ? "connect" : "refresh");
    setOperationAcceptedAt(null);
    handledTerminal.current = null;
  }, [activeOperationId, connection.data?.currentOperationId, connection.data?.state]);

  const operation = useQuery({
    queryKey: purviewConnectorOperationQueryKey(activeOperationId ?? "none"),
    queryFn: () => api.getPurviewConnectorOperation(activeOperationId!),
    enabled: !!activeOperationId,
    retry: false,
    refetchInterval: query => {
      const value = query.state.data;
      return !query.state.error && value && liveOperationStates.has(value.status) && value.pollingRecommended
        ? 3_000
        : false;
    },
  });

  const mutation = useMutation({
    mutationFn: ({ action, rowVersion }: { action: ConnectionAction; rowVersion: string }) =>
      action === "connect" ? api.startPurviewConnection(rowVersion) : api.refreshPurviewPolicies(rowVersion),
    onSuccess: (result, variables) => {
      setConfirmationOpen(false);
      setOperationAcceptedAt(Date.now());
      handledTerminal.current = null;
      setActiveAction(variables.action);
      setActiveOperationId(result.operationId);
      void queryClient.invalidateQueries({ queryKey: purviewConnectionQueryKey });
    },
    onSettled: () => { submissionInFlight.current = false; },
  });

  useEffect(() => {
    const value = operation.data;
    if (!value || !activeOperationId) return;
    if (!terminalOperationStates.has(value.status) || handledTerminal.current === value.operationId) return;
    handledTerminal.current = value.operationId;
    void Promise.all([
      queryClient.invalidateQueries({ queryKey: purviewConnectionQueryKey }),
      queryClient.invalidateQueries({ queryKey: purviewPolicyCatalogQueryKey }),
    ]);
  }, [activeOperationId, operation.data, queryClient]);

  useEffect(() => {
    const value = operation.data;
    if (!value || !liveOperationStates.has(value.status) || operation.isError) return;
    setNow(Date.now());
    const timer = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, [activeOperationId, operation.data?.status, operation.isError]);

  function start(action: ConnectionAction) {
    const current = connection.data;
    if (!current || mutation.isPending || submissionInFlight.current) return;
    submissionInFlight.current = true;
    mutation.reset();
    mutation.mutate({ action, rowVersion: current.rowVersion });
  }

  const pending = mutation.isPending || state === "Connecting" || state === "Refreshing" ||
    (!!operation.data && liveOperationStates.has(operation.data.status));
  const primary = actionFor(state);
  const operationElapsed = operation.data
    ? Math.max(0, Math.floor((now - Date.parse(operation.data.startedAtUtc)) / 1000))
    : operationAcceptedAt ? Math.max(0, Math.floor((now - operationAcceptedAt) / 1000)) : null;
  const repair = connection.data ? repairGuidance(connection.data) : null;

  return <>
    <PageHeader title="Purview connection"
      subtitle="Connect to Microsoft Purview and retrieve the existing DLP policy catalog on demand."
      actions={<Button disabled={connection.isFetching || mutation.isPending}
        icon={connection.isFetching ? <Spinner size="tiny" /> : undefined}
        onClick={() => void connection.refetch()}>
        {connection.isFetching ? "Checking status…" : "Check status"}
      </Button>} />
    {connection.isPending ? <Spinner label="Checking Purview connection" /> : !connection.data ?
      <ErrorState title="Purview connection status is unavailable" error={connection.error} onRetry={() => connection.refetch()} /> : <>
      {connection.isError && <ErrorState title="The latest connection check failed" error={connection.error} onRetry={() => connection.refetch()} />}
      <Card className="purview-connection-card" aria-label="Purview connection status">
        <div className="purview-connection-heading">
          <div>
            <Text as="h2" size={500} weight="semibold">Microsoft Purview policy catalog</Text>
            <Body1>{stateDescription(connection.data)}</Body1>
          </div>
          <StatusPill value={connection.data.state} />
        </div>

        <div className="purview-connection-actions">
          {primary.kind === "connect" && !confirmationOpen ?
            <Button appearance="primary" disabled={pending} onClick={() => setConfirmationOpen(true)}>{primary.label}</Button> :
            primary.kind === "refresh" ? <Button appearance="primary" disabled={pending}
              icon={pending ? <Spinner size="tiny" /> : undefined} onClick={() => start("refresh")}>
              {pending ? "Policy refresh in progress…" : primary.label}
            </Button> : <Button appearance="primary" disabled icon={<Spinner size="tiny" />}>{primary.label}</Button>}
          <Caption1>Manual refresh mode · no scheduled catalog refresh</Caption1>
        </div>

        {confirmationOpen && <Card className="purview-confirmation" aria-label="Confirm Purview connection">
          <Text weight="semibold">{state === "Disconnected" ? "Reconnect to Purview?" : "Connect to Purview?"}</Text>
          <Body1>This uses the identity, certificate, permissions, and connector installed by bootstrap. It verifies access and retrieves the policy catalog; it does not create or change policies.</Body1>
          <div className="purview-connection-actions">
            <Button appearance="primary" disabled={mutation.isPending} icon={mutation.isPending ? <Spinner size="tiny" /> : undefined}
              onClick={() => start("connect")}>{mutation.isPending ? "Starting connection…" : "Confirm connection"}</Button>
            <Button disabled={mutation.isPending} onClick={() => setConfirmationOpen(false)}>Cancel</Button>
          </div>
        </Card>}

        {mutation.isError && <ErrorState title={primary.kind === "refresh" ? "Policy refresh was not started" : "Purview connection was not started"}
          error={mutation.error} onRetry={() => connection.refetch()} />}

        {(activeOperationId || connection.data.currentOperationId) && <OperationProgress
          operationId={activeOperationId ?? connection.data.currentOperationId!}
          operation={operation.data}
          action={activeAction}
          connectionState={mutation.data?.operationId === (activeOperationId ?? connection.data.currentOperationId)
            ? mutation.data.connectionState
            : connection.data.state}
          accepted={!operation.data && !operation.isError}
          elapsed={operationElapsed}
          error={operation.error}
          checking={operation.isFetching}
          onCheck={() => void operation.refetch()} />}

        {connection.data.state === "Degraded" && <MessageBar intent="warning" role="alert">
          <MessageBarBody><MessageBarTitle>The latest policy refresh did not complete</MessageBarTitle>
            The previous verified catalog remains available below. This management failure alone does not mean configured agents lost runtime protection.
            {connection.data.lastFailureCode && <Caption1 block>Code: {connection.data.lastFailureCode}</Caption1>}
            {connection.data.correlationId && <Caption1 block>Reference: {connection.data.correlationId}</Caption1>}
          </MessageBarBody>
        </MessageBar>}
        {connection.data.state === "Disconnected" && repair && <MessageBar intent="warning" role="alert">
          <MessageBarBody><MessageBarTitle>Purview management needs attention</MessageBarTitle>{repair}</MessageBarBody>
        </MessageBar>}

        <ConnectionFacts value={connection.data} />
        <Body1>Catalog discovery is separate from policy assignment and runtime enforcement. Applying a policy still requires review for one exact agent identity, and allow/block evidence is verified separately.</Body1>
      </Card>
    </>}
    <div className="purview-footer-links">
      <Link to="/data-protection/policies">View saved policies and agents</Link>
      <a href="https://purview.microsoft.com/datalossprevention/policies" target="_blank" rel="noopener noreferrer">Open policies in Purview ↗</a>
    </div>
  </>;
}

function OperationProgress({ operationId, operation, action, connectionState, accepted, elapsed, error, checking, onCheck }: {
  operationId: string;
  operation?: PurviewConnectorOperation;
  action: ConnectionAction | null;
  connectionState: PurviewConnection["state"];
  accepted: boolean;
  elapsed: number | null;
  error: unknown;
  checking: boolean;
  onCheck: () => void;
}) {
  const live = !!operation && liveOperationStates.has(operation.status) && operation.pollingRecommended && !error;
  const pollingPaused = !!operation && liveOperationStates.has(operation.status) && !operation.pollingRecommended && !error;
  const connecting = operation?.type === "Connect" || (!operation && (action === "connect" || connectionState === "Connecting"));
  return <Card className="purview-operation-card" aria-label="Purview operation progress">
    <div className="purview-connection-heading">
      <Text weight="semibold">{connecting ? "Connecting to Purview" : "Refreshing the policy catalog"}</Text>
      <StatusPill value={operation?.status ?? "Pending"} />
    </div>
    {accepted && <Body1 role="status">Request accepted. Waiting for authoritative operation status; no completion has been assumed.</Body1>}
    {operation && <>
      <ProgressBar aria-label="Purview connector operation progress" value={operation.percentComplete / 100} />
      <div className="purview-operation-summary">
        <Body1>{operation.currentStep ? humanize(operation.currentStep) : operation.status}</Body1>
        <Caption1>{operation.percentComplete}%{elapsed !== null ? ` · elapsed ${formatDuration(elapsed)}` : ""}</Caption1>
      </div>
      {live && <Caption1>Microsoft Purview catalog retrieval can take several minutes. The Console will keep checking until the Gateway reports a final status.</Caption1>}
      {operation.steps && operation.steps.length > 0 && <ol className="purview-operation-steps">
        {operation.steps.map(step => <li key={step.step}><StatusPill value={step.status} /><span>{humanize(step.step)}</span></li>)}
      </ol>}
      {operation.error && <MessageBar intent="error" role="alert"><MessageBarBody>
        <MessageBarTitle>The connector operation stopped</MessageBarTitle>{operation.error.message ?? "The operation did not complete."}
        {operation.error.code && <Caption1 block>Code: {operation.error.code}</Caption1>}
      </MessageBarBody></MessageBar>}
    </>}
    {pollingPaused && <MessageBar intent="warning" role="alert"><MessageBarBody>
      <MessageBarTitle>Automatic status checks paused</MessageBarTitle>The Gateway did not recommend further polling for this live operation. Check the same operation before starting another.
    </MessageBarBody></MessageBar>}
    {error !== null && error !== undefined && <ErrorState title="Operation status is unavailable" error={error} />}
    {(pollingPaused || error) && <Button disabled={checking} icon={checking ? <Spinner size="tiny" /> : undefined} onClick={onCheck}>
      {checking ? "Checking…" : "Check operation status"}
    </Button>}
    {live && <RefreshIndicator active label="Checking operation status" />}
    <Caption1>Operation: {operationId}</Caption1>
  </Card>;
}

function ConnectionFacts({ value }: { value: PurviewConnection }) {
  const catalogAvailable = value.catalogVerificationStatus === "Verified" && !!value.catalogRetrievedAtUtc;
  return <dl className="purview-facts">
    <Fact label="Tenant" value={value.tenantId} />
    <Fact label="Connector" value={value.connectorProfile === "LocalWindows" ? "Local Windows" : "Not configured"} />
    <Fact label="Connector instance" value={value.connectorInstanceId ?? "Not reported"} />
    <Fact label="Last heartbeat" value={formatTimestamp(value.lastHeartbeatAtUtc)} />
    <Fact label="Last refresh attempt" value={formatTimestamp(value.lastAttemptedRefreshAtUtc)} />
    <Fact label="Last successful refresh" value={formatTimestamp(value.lastSuccessfulRefreshAtUtc)} />
    <Fact label="Catalog snapshot" value={catalogAvailable
      ? `${formatTimestamp(value.catalogRetrievedAtUtc)} (${formatAge(value.catalogRetrievedAtUtc!)})`
      : "No verified catalog"} />
    <Fact label="Catalog verification" value={value.catalogVerificationStatus} />
    <Fact label="Policies" value={catalogAvailable
      ? `${value.policyCount} total · ${value.compatiblePolicyCount} compatible · ${value.incompatiblePolicyCount} incompatible`
      : "Unavailable"} />
  </dl>;
}

function Fact({ label, value }: { label: string; value: string }) {
  return <div><dt>{label}</dt><dd>{value}</dd></div>;
}

function actionFor(state: PurviewConnection["state"] | undefined): { kind: "connect" | "refresh" | "progress"; label: string } {
  switch (state) {
    case "NotConfigured": return { kind: "connect", label: "Connect to Purview" };
    case "Connecting": return { kind: "progress", label: "Connecting…" };
    case "Connected": return { kind: "refresh", label: "Policy Refresh" };
    case "Refreshing": return { kind: "progress", label: "Policy refresh in progress…" };
    case "Degraded": return { kind: "refresh", label: "Retry Policy Refresh" };
    case "Disconnected": return { kind: "connect", label: "Reconnect" };
    default: return { kind: "progress", label: "Loading…" };
  }
}

function stateDescription(value: PurviewConnection): string {
  switch (value.state) {
    case "NotConfigured": return "Bootstrap-owned Purview settings have not been verified. Connect once to retrieve the first catalog.";
    case "Connecting": return "The Gateway is verifying the installed connector, identity, permissions, tenant, and first catalog.";
    case "Connected": return "The connector is ready. Retrieve policy additions or changes only when you choose Policy Refresh.";
    case "Refreshing": return "A manual policy refresh is running. The previous verified snapshot remains available while it completes.";
    case "Degraded": return "The last management operation failed, but the previous verified catalog remains visible.";
    case "Disconnected": return "The Gateway cannot currently run Purview management operations. Review the repair guidance before reconnecting.";
  }
}

function repairGuidance(value: PurviewConnection): string | null {
  switch (value.lastFailureCode) {
    case "PURVIEW_CONNECTOR_SETUP_REQUIRED":
      return "Run gateway up from the installation folder to reconcile the bootstrap-owned connector configuration, then reconnect.";
    case "PURVIEW_CONNECTOR_UNAVAILABLE":
      return "Check the local Purview connector task and sign-in state, then use Check status before reconnecting.";
    case "PURVIEW_CONNECTOR_RESULT_INVALID":
      return "The connector result did not pass tenant or trust validation. Run gateway diagnose and investigate before reconnecting.";
    case "PURVIEW_CONNECTOR_TIMED_OUT":
      return "The bounded operation expired. Check connector health and current state before retrying.";
    default:
      return value.lastFailureCode
        ? "Run gateway diagnose from the installation folder and use the reference below when investigating."
        : "Check the connector host, bootstrap-owned credentials, permissions, and tenant configuration, then check status again.";
  }
}

function formatTimestamp(value: string | null): string {
  return value ? new Date(value).toLocaleString() : "Not recorded";
}

function formatAge(value: string): string {
  const seconds = Math.max(0, Math.floor((Date.now() - Date.parse(value)) / 1000));
  if (seconds < 60) return "less than a minute old";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m old`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h old`;
  return `${Math.floor(seconds / 86_400)}d old`;
}

function formatDuration(seconds: number): string {
  return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
}

function humanize(value: string): string {
  return value.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, character => character.toUpperCase());
}
