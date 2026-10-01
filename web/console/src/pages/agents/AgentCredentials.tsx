import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Body1, Button, Caption1, Card, Spinner, Text } from "@fluentui/react-components";
import { api } from "../../api/client";
import { ApiError } from "../../api/errors";
import { formatTime } from "../../api/display";
import type { GatewayCredential } from "../../api/types";
import { CopyableCommand } from "../../components/CopyableCommand";
import { ErrorState } from "../../components/ErrorState";

export function AgentCredentials({ agentId, externalAgentId }: { agentId: string; externalAgentId: string }) {
  const credentials = useQuery({ queryKey: ["credentials", agentId], queryFn: () => api.listCredentials(agentId) });
  const [confirm, setConfirm] = useState<string>();
  const [key, setKey] = useState<GatewayCredential>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>();
  const [uncertain, setUncertain] = useState(false);
  async function act() {
    if (!confirm || busy) return;
    setBusy(true);
    setError(undefined);
    try {
      if (confirm === "issue") {
        const result = await api.issueCredential(agentId);
        setKey(result.gatewayCredential);
      } else {
        await api.revokeCredential(agentId, confirm);
      }
      setConfirm(undefined);
      await credentials.refetch();
    } catch (failure) {
      setError(failure);
      if (confirm === "issue" && failure instanceof ApiError && failure.outcomeUnknown) setUncertain(true);
      setConfirm(undefined);
      void credentials.refetch();
    } finally {
      setBusy(false);
    }
  }
  return (
    <Card style={{ gap: 16, padding: 24 }}>
      <CopyableCommand label="External ID" rows={1} command={externalAgentId} />
      <Caption1>Keys are shown once. Creating a replacement does not revoke the old key.</Caption1>
      {key && (
        <>
          <Body1>Save the replacement before leaving this tab, then update your agent and revoke its old key.</Body1>
          <CopyableCommand label="One-time Gateway key" command={key.apiKey} />
          <Button onClick={() => setKey(undefined)}>I saved the key</Button>
        </>
      )}
      {error !== undefined && <ErrorState title="Credential action was not confirmed" error={error} />}
      {uncertain && <Body1>An issuance may have completed without returning its key. Review the key list and revoke the unreceived key before creating another replacement.</Body1>}
      {credentials.isPending ? <Spinner label="Loading keys" /> : credentials.isError ? (
        <ErrorState error={credentials.error} onRetry={() => void credentials.refetch()} />
      ) : (
        <>
          <Text weight="semibold">Issued keys</Text>
          {credentials.data.items.length === 0 && <Body1>No keys issued.</Body1>}
          {credentials.data.items.map(item => (
            <div key={item.keyId} style={{ borderBottom: "1px solid", paddingBottom: 12 }}>
              <Body1 block><code>{item.keyId}</code></Body1>
              <Caption1 block>Created: {formatTime(item.createdAtUtc)}; expires: {formatTime(item.expiresAtUtc)}</Caption1>
              {item.revokedAtUtc ? <Caption1 block>Revoked: {formatTime(item.revokedAtUtc)}</Caption1> :
                <Button disabled={busy || !!key} onClick={() => setConfirm(item.keyId)}>Revoke key</Button>}
            </div>
          ))}
          {!confirm && <Button disabled={busy || !!key} onClick={() => { setUncertain(false); setConfirm("issue"); }} style={{ alignSelf: "flex-start" }}>Create replacement key</Button>}
        </>
      )}
      {confirm && (
        <div role="group" aria-label="Confirm credential change">
          <Body1 block>{confirm === "issue" ? "Create a new Gateway key? Existing keys stay active." : "Revoke this key? Agents using it will immediately lose Gateway access."}</Body1>
          <Button appearance="primary" disabled={busy} onClick={() => void act()}>{busy ? "Working..." : "Confirm"}</Button>
          <Button disabled={busy} onClick={() => setConfirm(undefined)}>Cancel</Button>
        </div>
      )}
    </Card>
  );
}
