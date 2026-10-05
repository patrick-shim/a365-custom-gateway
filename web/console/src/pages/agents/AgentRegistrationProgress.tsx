import { useEffect, useId, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import {
  Body1, Button, Caption1, Card, MessageBar, MessageBarBody, ProgressBar, Spinner, Text,
  makeStyles, mergeClasses, shorthands, tokens,
} from "@fluentui/react-components";
import { Checkmark24Regular, Clock24Regular, ErrorCircle24Regular, Person24Regular } from "@fluentui/react-icons";
import { api } from "../../api/client";
import { ApiError } from "../../api/errors";
import type { AgentDetail } from "../../api/types";
import { ErrorState } from "../../components/ErrorState";
import { isSupportedSetup, setupStageName, setupStages } from "./provisioning";

const useStyles = makeStyles({
  card: {
    padding: tokens.spacingVerticalXXL, gap: tokens.spacingVerticalL, marginBottom: tokens.spacingVerticalXL,
    borderTop: `4px solid ${tokens.colorBrandStroke1}`, overflowWrap: "anywhere",
    "@media (max-width: 760px)": { padding: tokens.spacingVerticalL },
  },
  heading: { margin: 0 },
  summary: { display: "flex", alignItems: "flex-start", gap: tokens.spacingHorizontalL },
  indicator: {
    display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0,
    width: "48px", height: "48px", borderRadius: tokens.borderRadiusMedium,
    color: tokens.colorBrandForeground1, backgroundColor: tokens.colorBrandBackground2,
  },
  summaryText: { display: "grid", gap: tokens.spacingVerticalS, minWidth: 0 },
  progressText: { display: "flex", flexWrap: "wrap", justifyContent: "space-between", gap: tokens.spacingHorizontalS, marginBottom: tokens.spacingVerticalS },
  progress: { height: "8px" },
  stages: {
    display: "grid", gridTemplateColumns: "repeat(7, minmax(0, 1fr))", gap: tokens.spacingHorizontalS,
    listStyleType: "none", padding: 0, margin: 0,
    "@media (max-width: 900px)": { gridTemplateColumns: "1fr" },
  },
  stage: {
    display: "flex", flexDirection: "column", alignItems: "flex-start", gap: tokens.spacingVerticalS,
    borderTop: `2px solid ${tokens.colorNeutralStroke2}`, paddingTop: tokens.spacingVerticalM,
    "@media (max-width: 900px)": {
      flexDirection: "row", alignItems: "center", borderTopWidth: 0, paddingTop: 0,
      gap: tokens.spacingHorizontalM, paddingBottom: tokens.spacingVerticalS,
    },
  },
  stageMarker: {
    display: "flex", justifyContent: "center", alignItems: "center", flexShrink: 0,
    width: "32px", height: "32px", borderRadius: tokens.borderRadiusCircular,
    backgroundColor: tokens.colorNeutralBackground3, color: tokens.colorNeutralForeground2,
    fontWeight: tokens.fontWeightSemibold, border: `1px solid ${tokens.colorNeutralStroke2}`,
  },
  currentMarker: { backgroundColor: tokens.colorBrandBackground, color: tokens.colorNeutralForegroundOnBrand, ...shorthands.borderColor(tokens.colorBrandStroke1) },
  doneMarker: { backgroundColor: tokens.colorPaletteGreenBackground1, color: tokens.colorPaletteGreenForeground1, ...shorthands.borderColor(tokens.colorPaletteGreenBorder1) },
  errorMarker: { backgroundColor: tokens.colorPaletteRedBackground1, color: tokens.colorPaletteRedForeground1, ...shorthands.borderColor(tokens.colorPaletteRedBorder1) },
  stageText: { display: "grid", gap: tokens.spacingVerticalXXS },
  muted: { color: tokens.colorNeutralForeground2 },
  actions: { display: "flex", flexWrap: "wrap", gap: tokens.spacingHorizontalS, alignItems: "center" },
  confirmation: {
    padding: tokens.spacingVerticalL, backgroundColor: tokens.colorBrandBackground2,
    border: `1px solid ${tokens.colorBrandStroke2}`, borderRadius: tokens.borderRadiusMedium,
    display: "grid", gap: tokens.spacingVerticalM,
  },
});

function useReducedMotion() {
  const [reduced, setReduced] = useState(() => window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  useEffect(() => {
    const preference = window.matchMedia("(prefers-reduced-motion: reduce)");
    const changed = () => setReduced(preference.matches);
    changed();
    preference.addEventListener("change", changed);
    return () => preference.removeEventListener("change", changed);
  }, []);
  return reduced;
}

export function AgentRegistrationProgress({ agent }: { agent: AgentDetail }) {
  const styles = useStyles();
  const titleId = useId();
  const summaryId = useId();
  const confirmationId = useId();
  const reducedMotion = useReducedMotion();
  const qc = useQueryClient();
  const agentId = agent.agentId;
  const settingUp = ["Draft", "Provisioning", "AwaitingAdminApproval"].includes(agent.status);
  const reportedOperationId = agent.provisioning?.operationId;
  const history = useQuery({
    queryKey: ["provisioning-history", agentId],
    queryFn: () => api.findLatestProvisioningOperation(agentId),
    enabled: !reportedOperationId,
    refetchInterval: query => query.state.error || agent.status === "Active" ? false : 5000,
  });
  const operationId = reportedOperationId ?? history.data ?? undefined;
  const operation = useQuery({
    queryKey: ["registration-operation", operationId, agentId],
    queryFn: () => {
      if (!operationId) throw new ApiError("No provisioning operation was reported.", 200, "OPERATION_ID_UNAVAILABLE");
      return api.getRegistrationOperation(operationId, agentId);
    },
    enabled: !!operationId,
    refetchInterval: query => query.state.error || ["Completed", "Failed", "RequiresManualIntervention", "Cancelled"].includes(query.state.data?.status ?? "") ? false :
      agent.status === "Active" || query.state.data?.pollingRecommended ? 3000 :
        query.state.data?.status === "AwaitingAdministratorAction" ? 10000 : false,
  });
  const [confirming, setConfirming] = useState<string>();
  const confirmButton = useRef<HTMLButtonElement>(null);
  const finishButton = useRef<HTMLButtonElement>(null);
  const [posting, setPosting] = useState(false);
  const postingRef = useRef(false);
  const [retrying, setRetrying] = useState(false);
  const retryingRef = useRef(false);
  const [retryError, setRetryError] = useState<unknown>();
  const [attempt, setAttempt] = useState<{ operationId: string; submitted: boolean; uncertain: boolean; error?: unknown }>();
  const current = operation.isSuccess ? operation.data : undefined;
  const active = agent.status === "Active";
  const syncingCompletion = active && !!current && ["Pending", "Running", "AwaitingAdministratorAction"].includes(current.status) && !operation.error;
  useEffect(() => {
    if (active && operationId) void qc.invalidateQueries({ queryKey: ["registration-operation", operationId, agentId] });
  }, [active, operationId, agentId, qc]);
  const currentAttempt = attempt?.operationId === operationId ? attempt : undefined;
  const error = active ? undefined : currentAttempt?.error;
  const readError = operationId ? operation.error : history.error;
  const supported = !!current && isSupportedSetup(current);
  // AwaitingAdministratorAction persists ErrorCode/Summary as the pause reason
  // (e.g. AGENT365_REGISTRY_ACTION_REQUIRED). That is a wait state, not a failure.
  const failed = ["Failed", "RequiresManualIntervention"].includes(agent.status) ||
    !!current && ["Failed", "RequiresManualIntervention"].includes(current.status);
  const canRetry = failed && agent.retryProvisioning?.supported === true;
  const waiting = settingUp && (current
    ? current.status === "AwaitingAdministratorAction" || !!current.requiredAction
    : agent.status === "AwaitingAdminApproval");
  const registryAction = current?.requiredAction === "CompleteAgent365Registration";
  const gateClosed = registryAction && (current?.agent365RegistrationCompletionAvailable === false ||
    error instanceof ApiError && error.code === "PROVISIONING_DISABLED");
  const available = settingUp && !failed && supported && registryAction && current.status === "AwaitingAdministratorAction" &&
    !gateClosed && current.agent365RegistrationCompletionAvailable;
  const uncertain = currentAttempt?.uncertain === true;
  const submitted = currentAttempt?.submitted === true;
  const blocked = !!readError || error !== undefined || failed || !!current && !supported;
  const working = settingUp && !blocked && (posting || !waiting &&
    (current ? supported && current.pollingRecommended && ["Pending", "Running"].includes(current.status)
      : ["Draft", "Provisioning"].includes(agent.status)));
  const stage = setupStages.find(item => item.step === (current?.currentStep ?? agent.provisioning?.currentStep));
  const percent = current?.percentComplete ?? agent.provisioning?.percentComplete;
  const heading = active ? "Agent is Active" : blocked ? "Setup needs attention" :
    !settingUp ? `Agent status: ${agent.status}` :
    posting ? "Submitting your registration confirmation" :
      submitted && waiting ? "Confirmation accepted; checking status" :
        waiting ? registryAction || !current ? "Registration required" : "Setup is paused" :
          current?.status === "Completed" ? "Waiting for the agent's Active status" :
            current?.status === "Pending" || !current && agent.status === "Draft" ? "Queued for setup" :
              stage?.step === "VerifyAgent365Connection" ? "Verifying the Agent 365 connection" :
                working ? stage?.label ?? "Setting up the agent" : "Checking setup status";

  useEffect(() => {
    if (current) {
      void qc.invalidateQueries({ queryKey: ["agent", agentId] });
      void qc.invalidateQueries({ queryKey: ["agents"] });
      void qc.invalidateQueries({ queryKey: ["agent-summary"] });
    }
  }, [current?.status, current?.currentStep, current?.percentComplete, agentId, qc]);
  useEffect(() => {
    if (!available) setConfirming(undefined);
  }, [available, operationId]);
  useEffect(() => {
    if (confirming === operationId) confirmButton.current?.focus();
  }, [confirming, operationId]);

  async function checkOperation() {
    const result = operationId ? await operation.refetch() : await history.refetch();
    if (result.isSuccess && operationId && !submitted) setAttempt(undefined);
    await qc.invalidateQueries({ queryKey: ["agent", agentId] });
  }

  async function complete() {
    if (!operationId || !available || postingRef.current || uncertain || submitted || operation.isFetching) return;
    postingRef.current = true;
    setPosting(true);
    setConfirming(undefined);
    setAttempt(undefined);
    try {
      await api.completeAgent365Registration(operationId, agentId);
      setAttempt({ operationId, submitted: true, uncertain: false });
    } catch (failure) {
      setAttempt({ operationId, submitted: false, uncertain: failure instanceof ApiError && failure.outcomeUnknown, error: failure });
    } finally {
      await operation.refetch();
      await qc.invalidateQueries({ queryKey: ["agent", agentId] });
      postingRef.current = false;
      setPosting(false);
    }
  }

  async function retryProvisioning() {
    if (!canRetry || retryingRef.current || postingRef.current) return;
    retryingRef.current = true;
    setRetrying(true);
    setRetryError(undefined);
    setAttempt(undefined);
    try {
      await api.retryProvisioning(agentId);
      await Promise.all([
        qc.invalidateQueries({ queryKey: ["agent", agentId] }),
        qc.invalidateQueries({ queryKey: ["agents"] }),
        qc.invalidateQueries({ queryKey: ["agent-summary"] }),
        qc.invalidateQueries({ queryKey: ["provisioning-history", agentId] }),
      ]);
    } catch (failure) {
      setRetryError(failure);
    } finally {
      retryingRef.current = false;
      setRetrying(false);
    }
  }

  return <Card className={styles.card} role="region" aria-labelledby={titleId}
    data-state={active ? "active" : blocked ? "error" : working ? "busy" : waiting ? "waiting" : "idle"}
    data-motion={working && !reducedMotion ? "animated" : "static"}>
    <Text as="h2" id={titleId} size={500} weight="semibold" className={styles.heading}>Agent setup</Text>
    <div className={styles.summary}>
      <div className={styles.indicator} aria-hidden="true">
        {working && !reducedMotion ? <Spinner size="medium" /> : active ? <Checkmark24Regular /> :
          blocked ? <ErrorCircle24Regular /> : waiting ? <Person24Regular /> : <Clock24Regular />}
      </div>
      <div className={styles.summaryText} role="status" aria-live="polite" aria-atomic="true" id={summaryId}>
        <Text size={500} weight="semibold">{heading}</Text>
        {working && !posting && <Body1>{current?.status === "Pending" || agent.status === "Draft"
          ? "Waiting for the provisioning worker. Progress changes only when the Gateway reports it."
          : stage?.description ?? "The Gateway is preparing this agent. Progress is read from the server."}</Body1>}
        {active && <Body1>The agent record confirms it is Active. No registration confirmation is needed.</Body1>}
        {syncingCompletion && <Body1>{!reducedMotion && <Spinner size="tiny" />} Refreshing the final setup result automatically…</Body1>}
        {!active && !settingUp && !blocked && <Body1>The setup history does not change this agent's current state. No registration action is available.</Body1>}
        {settingUp && !blocked && current?.status === "Completed" && <Body1>
          The operation completed, but the agent is not Active yet. Checking the agent record; setup is not confirmed.
        </Body1>}
        {settingUp && !failed && submitted && <Body1>
          Registry completion was accepted. Waiting for worker verification and an Active agent readback.
        </Body1>}
        {waiting && !posting && !submitted && <Body1>
          {registryAction || !current
            ? "Setup is paused for a registration confirmation, not background processing."
            : "The worker is waiting for an action, not processing in the background."}
        </Body1>}
      </div>
    </div>
    {!reportedOperationId && <Caption1>
      {operationId ? "Operation found in this agent's provisioning history." :
        "The agent detail did not include an operation ID. Checking this agent's provisioning history; no operation is guessed."}
    </Caption1>}
    {!operationId && history.isSuccess && <MessageBar intent="warning"><MessageBarBody>
      No provisioning job was reported for this agent. Refresh setup status; if it remains unavailable, review API compatibility on Platform with the agent reference below.
    </MessageBarBody></MessageBar>}
    {readError && <ErrorState title="Setup progress could not be verified" error={readError} onRetry={() => void checkOperation()} />}
    {readError instanceof ApiError && readError.status === 403 && <Body1>
      Reading provisioning history and operations requires the Gateway API role <code>Gateway.Administrator</code> or <code>Gateway.Operator</code>.
    </Body1>}
    {current && !supported && <MessageBar intent="warning"><MessageBarBody>
      This operation's workflow or stages are not supported by this Console. No registration action is enabled.
      Review API and worker compatibility on Platform; the exact operation is listed below.
    </MessageBarBody></MessageBar>}
    {!active && registryAction && supported && <Body1>
      The agent identity is already created. A signed-in Gateway Administrator confirms adding this existing agent to Microsoft 365's Registry.
      This creates no new identity or Gateway key. It is not Purview approval, and there is no outside approval inbox.
    </Body1>}
    {!active && supported && gateClosed && <MessageBar intent="warning"><MessageBarBody>
      The Registry completion gate is closed on this Gateway. The deployment settings <code>Agent365:DelegatedRegistry:Enabled</code> and{" "}
      <code>Agent365:DelegatedRegistry:AllowContinuousDevelopmentAccess</code> must permit this action. The Console cannot change them.
    </MessageBarBody></MessageBar>}
    {!active && waiting && current && !registryAction && <MessageBar intent="warning"><MessageBarBody>
      {current.requiredAction
        ? <>The API requires <code>{current.requiredAction}</code>, an action this Console cannot perform.</>
        : "The API has not advertised a supported registration action for this paused operation."}{" "}
      No confirmation is available. Refresh setup status and review API compatibility on Platform using the operation reference.
    </MessageBarBody></MessageBar>}
    {failed && <MessageBar intent="error" role="alert"><MessageBarBody>
      <Text weight="semibold">Agent setup needs attention. </Text>
      {current?.error?.message ?? agent.provisioning?.lastError ?? "The Gateway reported a failure without a diagnostic message. Use the support reference below to investigate."}
      <Caption1 block>Stage: {setupStageName(current?.currentStep ?? agent.provisioning?.currentStep)}</Caption1>
      {canRetry && <Caption1 block>{agent.retryProvisioning?.reason}</Caption1>}
      {!canRetry && agent.retryProvisioning?.reason && <Caption1 block>{agent.retryProvisioning.reason}</Caption1>}
    </MessageBarBody></MessageBar>}
    {canRetry && <Button appearance="primary" size="large" disabled={retrying || posting}
      style={{ alignSelf: "flex-start" }} onClick={() => void retryProvisioning()}>
      {retrying ? "Retrying provisioning..." : "Retry provisioning"}
    </Button>}
    {retryError !== undefined && <ErrorState title="Provisioning retry was not accepted" error={retryError} />}
    {error !== undefined && <ErrorState title="Registration confirmation was not accepted" error={error} />}
    {error instanceof ApiError && error.status === 403 && <Body1>
      This signed-in session was refused. Confirmation requires the Gateway API role <code>Gateway.Administrator</code> and delegated{" "}
      <code>access_as_user</code>. <code>Gateway.Operator</code> can read progress but cannot finish registration.
      Review the role assignment on Platform before signing in with the appropriate account.
    </Body1>}
    {uncertain && !active && <Body1>
      The response was lost or invalid. Check setup status before considering another confirmation; no request will be repeated automatically.
    </Body1>}
    {available && confirming !== operationId && <Button appearance="primary" size="large"
      disabled={posting || uncertain || submitted || operation.isFetching} style={{ alignSelf: "flex-start" }}
      ref={finishButton} onClick={() => setConfirming(operationId)}>Finish Agent 365 registration</Button>}
    {available && confirming === operationId && <div role="group" aria-labelledby={confirmationId} className={styles.confirmation}>
      <Text id={confirmationId} size={400} weight="semibold">Confirm Microsoft 365 Registry registration</Text>
      <Body1>Add this existing agent to Microsoft 365's Registry using your signed-in Gateway Administrator account?
        The API checks your role and delegated authorization. The Gateway reconciles any existing attempt before queuing verification; it does not recreate the identity or key.</Body1>
      <div className={styles.actions}>
        <Button appearance="primary" disabled={posting || uncertain || submitted || operation.isFetching}
          ref={confirmButton} onClick={() => void complete()}>Confirm registration</Button>
        <Button disabled={posting} onClick={() => {
          setConfirming(undefined);
          requestAnimationFrame(() => finishButton.current?.focus());
        }}>Cancel</Button>
      </div>
    </div>}
    {percent !== undefined && <div>
      <div className={styles.progressText}>
        <Text weight="semibold">{percent}% reported by the Gateway</Text>
        <Caption1>{current ? "Latest operation readback" : "Latest agent readback; operation details are not confirmed"}</Caption1>
      </div>
      <ProgressBar className={styles.progress} value={percent} max={100} thickness="large"
        color={active ? "success" : blocked ? "error" : waiting ? "warning" : "brand"}
        aria-label="Agent setup progress" aria-valuetext={`${percent}% reported by the Gateway. ${heading}.`}
        bar={{ style: { transitionProperty: working && !reducedMotion ? "width" : "none" } }} />
    </div>}
    {supported && current && <ol className={styles.stages} aria-label="Setup stages">
      {setupStages.map((item, index) => {
        const status = current.steps?.[index].status;
        const done = status === "Completed";
        const failedStep = status === "Failed";
        const isCurrent = !active && current.status !== "Completed" && current.currentStep === item.step;
        const state = failedStep ? "failed" : done ? "done" : status === "Skipped" ? "skipped" : isCurrent ? "current" : "future";
        const label = done ? "Done" : failedStep ? "Failed" : status === "Skipped" ? "Skipped" :
          isCurrent ? waiting && !submitted ? "Confirmation needed" : working ? "Current stage" : "Paused" : "Not started";
        return <li key={item.step} className={styles.stage} aria-current={isCurrent ? "step" : undefined} data-state={state}>
          <span aria-hidden="true" className={mergeClasses(styles.stageMarker,
            failedStep ? styles.errorMarker : done ? styles.doneMarker : isCurrent ? styles.currentMarker : undefined)}>
            {done ? <Checkmark24Regular /> : failedStep ? <ErrorCircle24Regular /> : index + 1}
          </span>
          <div className={styles.stageText}>
            <Text weight={isCurrent ? "semibold" : "regular"}>{item.label}</Text>
            <Caption1 className={styles.muted}>{label}</Caption1>
          </div>
        </li>;
      })}
    </ol>}
    <div className={styles.actions}>
      <Button disabled={posting || operation.isFetching || history.isFetching} onClick={() => void checkOperation()}>Refresh setup status</Button>
      {!active && <Link to="/platform#registration-access">Review registration access and compatibility</Link>}
    </div>
    <details>
      <summary>Operation details</summary>
      <Caption1 block>Agent reference: {agentId}</Caption1>
      {operationId && <Caption1 block>Operation reference: {operationId}</Caption1>}
      {current && <>
        <Caption1 block>Type: {current.type}; status: {current.status}</Caption1>
        {current.currentStep && <Caption1 block>Server step: {current.currentStep}</Caption1>}
        {current.error?.code && <Caption1 block>Code: {current.error.code}</Caption1>}
        {current.requiredAction && <Caption1 block>Required action: {current.requiredAction}</Caption1>}
        {!supported && current.steps?.map((step, index) => <Caption1 block key={`${index}-${step.step}`}>{step.step}: {step.status}</Caption1>)}
      </>}
    </details>
  </Card>;
}
