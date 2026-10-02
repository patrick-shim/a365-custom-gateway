import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Body1, Button, Caption1, Card, MessageBar, MessageBarBody, Spinner, Text } from "@fluentui/react-components";
import { api } from "../../api/client";
import { ApiError } from "../../api/errors";
import { ErrorState } from "../../components/ErrorState";
import { StatusPill } from "../../components/StatusPill";

export function AgentRegistrationProgress({ agentId, operationId, agentStatus }: {
  agentId: string;
  operationId: string;
  agentStatus: string;
}) {
  const qc = useQueryClient();
  const operation = useQuery({
    queryKey: ["registration-operation", operationId, agentId],
    queryFn: () => api.getRegistrationOperation(operationId, agentId),
    refetchInterval: query => query.state.error ? false : query.state.data?.pollingRecommended ? 3000 : false,
  });
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>();
  const [uncertain, setUncertain] = useState(false);
  const [submitted, setSubmitted] = useState(false);
  const current = operation.isSuccess ? operation.data : undefined;
  const available = current?.requiredAction === "CompleteAgent365Registration" &&
    current.agent365RegistrationCompletionAvailable;
  const failed = !!current && ["Failed", "RequiresManualIntervention"].includes(current.status);
  const registration = !!current && ["ProvisionAgent", "RetryProvisioning"].includes(current.type);

  useEffect(() => {
    if (current) {
      void qc.invalidateQueries({ queryKey: ["agent", agentId] });
      void qc.invalidateQueries({ queryKey: ["agents"] });
    }
  }, [current?.status, current?.currentStep, agentId, qc]);

  async function checkOperation() {
    const result = await operation.refetch();
    if (result.isSuccess) setUncertain(false);
    await qc.invalidateQueries({ queryKey: ["agent", agentId] });
  }

  async function complete() {
    if (!available || busy || uncertain || submitted) return;
    setBusy(true);
    setError(undefined);
    setConfirming(false);
    try {
      await api.completeAgent365Registration(operationId, agentId);
      setSubmitted(true);
    } catch (failure) {
      setError(failure);
      setUncertain(failure instanceof ApiError && failure.outcomeUnknown);
    } finally {
      await operation.refetch();
      await qc.invalidateQueries({ queryKey: ["agent", agentId] });
      setBusy(false);
    }
  }

  return <Card style={{ padding: 24, gap: 12, marginBottom: 16 }}>
    <Text weight="semibold">{registration || available ? "Agent 365 registration" : "Agent operation"}</Text>
    {operation.isPending ? <Spinner label="Loading registration operation" /> : operation.isError ? (
      <ErrorState error={operation.error} onRetry={() => void checkOperation()} />
    ) : current && <>
      <StatusPill value={current.status} />
      {current.pollingRecommended && <Body1 role="status">
        Checking operation: {current.currentStep ?? "Waiting for the worker"} ({current.percentComplete}%).
      </Body1>}
      {current.requiredAction === "CompleteAgent365Registration" && <Body1>
        {available
          ? "A signed-in Gateway administrator can complete the Registry step here."
          : "The Registry completion gate is closed on this Gateway. Ask your Gateway administrator to check the deployment gate."}
      </Body1>}
      {!failed && (submitted || registration && current.status === "Completed") && agentStatus !== "Active" && <Body1 role="status">
        {current.status === "Completed"
          ? "The operation completed; the agent is not currently Active. Its status above is authoritative."
          : "Registry completion was accepted. Waiting for worker verification and an Active agent readback."}
      </Body1>}
      {(current.error || failed) && (
        <MessageBar intent="error" role="alert"><MessageBarBody>
          {current.error?.message ?? "This operation needs administrator attention. Check the details below."}
        </MessageBarBody></MessageBar>
      )}
      {available && !confirming && <Button appearance="primary" disabled={busy || uncertain || submitted || operation.isFetching}
        style={{ alignSelf: "flex-start" }} onClick={() => setConfirming(true)}>Complete registration</Button>}
      {confirming && <div>
        <Body1 block>Complete this agent's Registry step using your administrator identity? The Gateway will check any existing attempt and queue verification; it will not recreate the agent.</Body1>
        <div style={{ display: "flex", gap: 8, marginTop: 12 }}>
          <Button appearance="primary" disabled={!available || busy || uncertain} onClick={() => void complete()}>Confirm registration</Button>
          <Button disabled={busy} onClick={() => setConfirming(false)}>Cancel</Button>
        </div>
      </div>}
      <details>
        <summary>Operation details</summary>
        <Caption1 block>Reference: {operationId}</Caption1>
        <Caption1 block>Type: {current.type}</Caption1>
        {current.error?.code && <Caption1 block>Code: {current.error.code}</Caption1>}
        {current.requiredAction && <Caption1 block>Required action: {current.requiredAction}</Caption1>}
        {current.steps?.map(step => <Caption1 block key={step.step}>{step.step}: {step.status}</Caption1>)}
      </details>
    </>}
    {busy && <Body1 role="status">Completing the Registry step...</Body1>}
    {error !== undefined && <ErrorState title="Registry completion was not confirmed" error={error} />}
    {uncertain && <Body1>The response was lost or invalid. Check the operation before considering another confirmation; no request will be repeated automatically.</Body1>}
    <Button disabled={busy || operation.isFetching} style={{ alignSelf: "flex-start" }} onClick={() => void checkOperation()}>Check operation</Button>
  </Card>;
}
