import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useSearchParams } from "react-router-dom";
import { Spinner, Card, Text, Body1, Caption1, Button, MessageBar, MessageBarBody } from "@fluentui/react-components";
import { api } from "../../api/client";
import { ApiError } from "../../api/errors";
import { formatTime, utcTime } from "../../api/display";
import { connectionIsUsable, type ConnectionReview } from "../../api/types";
import { config } from "../../runtime-config";
import { PageHeader } from "../../components/PageHeader";
import { StatusPill } from "../../components/StatusPill";
import { ErrorState } from "../../components/ErrorState";

const runningStatuses = ["Pending", "Submitted", "Running", "PendingPropagation"];

export function Connection() {
  const qc = useQueryClient();
  const [params, setParams] = useSearchParams();
  const operationId = params.get("operation");
  const connection = useQuery({
    queryKey: ["purview"], queryFn: api.getPurviewConnection,
    refetchInterval: query => !query.state.error && query.state.data?.status === "PendingVerification" ? 3000 : false,
  });
  const operation = useQuery({
    queryKey: ["protection-operation", operationId],
    queryFn: async () => {
      const result = await api.getProtectionOperation(operationId!);
      if (result.targetType !== "PurviewTenantConnection" ||
        !["ConnectPurviewTenant", "VerifyPurviewTenantConnection"].includes(result.type)) {
        throw new ApiError("This operation is not a Purview connection check.", 200, "OPERATION_MISMATCH");
      }
      return result;
    },
    enabled: !!operationId,
    refetchInterval: query => query.state.error ? false :
      (!query.state.data || runningStatuses.includes(query.state.data.status)) ? 3000 : false,
  });
  const [review, setReview] = useState<ConnectionReview>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>();
  const current = connection.data;
  const running = !!operationId && (operation.isPending || !!operation.data && runningStatuses.includes(operation.data.status));
  const unresolved = !!operationId && operation.isError;
  const usable = connection.isSuccess && !running && connectionIsUsable(current ?? null);

  useEffect(() => {
    if (operation.data && !runningStatuses.includes(operation.data.status)) {
      void qc.invalidateQueries({ queryKey: ["purview"] });
      void qc.invalidateQueries({ queryKey: ["sits"] });
    }
  }, [operation.data?.status, qc]);

  async function prepare() {
    setBusy(true);
    setError(undefined);
    try {
      setReview(await api.reviewPurviewConnection(current?.rowVersion ?? "*"));
    } catch (failure) {
      setError(failure);
    } finally {
      setBusy(false);
    }
  }

  async function confirm() {
    if (!review || busy) return;
    setBusy(true);
    setError(undefined);
    setReview(undefined);
    try {
      if (utcTime(review.expiresAtUtc) <= Date.now() || review.expectedRowVersion !== (current?.rowVersion ?? "*")) {
        throw new ApiError("The review expired or the connection changed. Review a fresh check.", 412, "REVIEW_EXPIRED");
      }
      const accepted = await api.confirmPurviewConnection(review);
      setParams({ operation: accepted.operationId });
      void qc.invalidateQueries({ queryKey: ["protection-operation", accepted.operationId] });
      await qc.invalidateQueries({ queryKey: ["purview"] });
    } catch (failure) {
      setError(failure);
      if (failure instanceof ApiError && failure.outcomeUnknown) {
        setParams({ operation: review.reviewTokenId });
        void qc.invalidateQueries({ queryKey: ["protection-operation", review.reviewTokenId] });
      }
      void connection.refetch();
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <PageHeader title="Connection" subtitle="Purview access and verification status."
        actions={<Button disabled={connection.isPending || connection.isError || busy || running || unresolved || !!review || current?.status === "PendingVerification"}
          onClick={() => void prepare()}>{busy ? "Working..." : "Verify connection"}</Button>} />
      {connection.isPending ? <Spinner label="Loading connection" /> : connection.isError ? (
        <ErrorState error={connection.error} onRetry={() => void connection.refetch()} />
      ) : (
        <Card style={{ padding: 24, gap: 12, marginBottom: 16 }}>
          <StatusPill value={current?.status === "Connected" && !usable
            ? running ? "PendingVerification" : "VerificationExpired" : current?.status ?? "NotConnected"} />
          <Body1>{usable
            ? "Gateway access is verified. DLP policy readiness is checked separately."
            : running || current?.status === "PendingVerification"
              ? "Gateway verification is in progress. Access is not verified yet."
            : current?.status === "VerificationFailed"
              ? "The last check could not verify Purview access. Review a fresh Gateway check to try again."
              : current?.status === "AwaitingAdministrator"
                ? "An earlier companion handoff is pending. You can review a fresh Gateway check without completing that handoff."
              : "Purview access is not currently verified. Agent registration can continue without it."}</Body1>
          <Caption1>Last verified: {formatTime(current?.lastVerifiedAtUtc)}</Caption1>
          {current?.status === "Connected" && !running && !usable && <Body1>Verification is expired or incomplete. Review a fresh check to verify access.</Body1>}
          <details>
            <summary>Connection details</summary>
            <Caption1 block>Tenant: {current?.tenantId ?? config.tenantId}</Caption1>
            {current?.authorityApplicationId && <Caption1 block>Verified automation application: {current.authorityApplicationId}</Caption1>}
            {current?.lastFailureCode && <Caption1 block>Last failure: {current.lastFailureCode}</Caption1>}
          </details>
          <Button style={{ alignSelf: "flex-start" }} disabled={connection.isFetching} onClick={() => void connection.refetch()}>Reload status</Button>
        </Card>
      )}
      {error !== undefined && <ErrorState title="The verification request was not confirmed" error={error} />}
      {error instanceof ApiError && error.outcomeUnknown && <Body1>
        Check the reviewed operation below before starting another check. The request will not be repeated automatically.
      </Body1>}
      {review && <Card style={{ gap: 12, padding: 24, marginBottom: 16 }}>
        <Text weight="semibold">Confirm Gateway verification</Text>
        <Body1>{review.review.readinessDisclaimer}</Body1>
        <Caption1>No downloaded scripts or pasted evidence. Existing application and certificate permissions are unchanged.</Caption1>
        {current && connectionIsUsable(current) && <Body1>Starting a fresh check pauses verified Purview access until verification finishes.</Body1>}
        <Caption1>Tenant: {review.review.tenantId}</Caption1>
        <div style={{ display: "flex", gap: 8 }}>
          <Button appearance="primary" disabled={busy} onClick={() => void confirm()}>Confirm verification</Button>
          <Button disabled={busy} onClick={() => setReview(undefined)}>Cancel</Button>
        </div>
      </Card>}
      {operationId && <Card style={{ gap: 12, padding: 24, marginBottom: 16 }}>
        <Text weight="semibold">Latest operation</Text>
        {operation.isPending ? <Spinner label="Loading operation" /> : operation.isError ? (
          <ErrorState error={operation.error} onRetry={() => void operation.refetch()} />
        ) : (
          <>
            <StatusPill value={operation.data.status} />
            {running && <Body1 role="status">Checking access. This can take a few minutes; you can leave and return to this link.</Body1>}
            {["Failed", "RequiresManualIntervention"].includes(operation.data.status) && <MessageBar intent="error" role="alert"><MessageBarBody>
              Purview verification failed. Registration is unaffected. The details below identify the failed step and support reference.
            </MessageBarBody></MessageBar>}
            {(operation.data.status === "AwaitingAdministrator" || operation.data.requiredAction === "CompletePurviewTenantConnection") ? (
              <MessageBar intent="warning"><MessageBarBody>This is an earlier companion operation, not a fresh Gateway verification. Use Verify connection to review the server-owned check.</MessageBarBody></MessageBar>
            ) : operation.data.requiresManualIntervention && (
              <MessageBar intent="warning"><MessageBarBody>The Gateway requires administrator attention. Review the operation details below.</MessageBarBody></MessageBar>
            )}
            {operation.data.status === "Completed" && connection.isSuccess && !connectionIsUsable(current ?? null) && <Body1>
              This operation completed, but current connection readback is not verified. Completion alone does not establish usable access.
            </Body1>}
            <details><summary>Check details</summary>
              <Caption1 block>Operation: {operation.data.id}</Caption1>
              <Caption1 block>Reference: {operation.data.correlationId}</Caption1>
              {operation.data.failureCode && <Caption1 block>Failure: {operation.data.failureCode}</Caption1>}
              {operation.data.requiredAction && <Caption1 block>Required action: {operation.data.requiredAction}</Caption1>}
              {operation.data.steps.map((step, i) => <Caption1 block key={i}>{step.step}: {step.status}{step.failureCode && ` (${step.failureCode})`}</Caption1>)}
              {operation.data.blockers.map(blocker => <Caption1 block key={blocker}>{blocker}</Caption1>)}
            </details>
            <Button disabled={operation.isFetching} style={{ alignSelf: "flex-start" }} onClick={() => void operation.refetch()}>Check operation</Button>
          </>
        )}
      </Card>}
      <Link to="/data-protection/classifiers">View classifiers</Link>
    </>
  );
}
