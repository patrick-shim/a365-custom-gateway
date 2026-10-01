import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate } from "react-router-dom";
import {
  Card, Input, Field, Dropdown, Option, Button, Text, Body1, Caption1,
  Spinner, Select, RadioGroup, Radio, Checkbox, MessageBar, MessageBarBody,
} from "@fluentui/react-components";
import { api } from "../../api/client";
import { ApiError, SignInRequiredError } from "../../api/errors";
import type { Agent, Registration, RegisterAgentRequest } from "../../api/types";
import { getAccount } from "../../auth/msal";
import { PageHeader } from "../../components/PageHeader";
import { CopyableCommand } from "../../components/CopyableCommand";
import { ErrorState } from "../../components/ErrorState";

export function RegisterAgent() {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const [step, setStep] = useState(1);
  const blueprints = useQuery({ queryKey: ["blueprints"], queryFn: api.listBlueprints, enabled: step === 2 });
  const [name, setName] = useState("");
  const [externalId, setExternalId] = useState(() => `agent-${crypto.randomUUID()}`);
  const [environment, setEnvironment] = useState<RegisterAgentRequest["environment"]>("Development");
  const [blueprintId, setBlueprintId] = useState("");
  const [newBlueprint, setNewBlueprint] = useState(false);
  const [blueprintDisplayName, setBlueprintDisplayName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>();
  const [result, setResult] = useState<Registration>();
  const [saved, setSaved] = useState(false);
  const [uncertain, setUncertain] = useState(false);
  const [existing, setExisting] = useState<Agent>();
  const [readbackMessage, setReadbackMessage] = useState("");
  const compatible = blueprints.data?.filter(b => b.isAgent365Compatible) ?? [];
  const validName = name.trim().length > 0 && name.trim().length <= 256;
  const validExternalId = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/.test(externalId);
  const validBlueprint = newBlueprint ? blueprintDisplayName.trim().length > 0 :
    compatible.some(b => b.blueprintObjectId === blueprintId);
  const cardStyle = { padding: 24, gap: 16, maxWidth: 620 };

  async function create() {
    if (!validName || !validExternalId || !validBlueprint || busy || uncertain) return;
    setBusy(true);
    setError(undefined);
    try {
      const oid = getAccount()?.idTokenClaims?.oid;
      if (typeof oid !== "string" || !oid) throw new SignInRequiredError();
      const registered = await api.registerAgent({
        name: name.trim(), externalAgentId: externalId, ownerObjectId: oid, environment,
        blueprint: newBlueprint
          ? { mode: "CreateNew", displayName: blueprintDisplayName.trim() }
          : { mode: "UseExisting", blueprintObjectId: blueprintId },
      });
      setResult(registered);
      setStep(3);
      void qc.invalidateQueries({ queryKey: ["agents"] });
      void qc.invalidateQueries({ queryKey: ["agent-summary"] });
    } catch (failure) {
      setError(failure);
      setUncertain(failure instanceof ApiError && (failure.outcomeUnknown || failure.status === 409));
    } finally {
      setBusy(false);
    }
  }

  async function findRegistration() {
    setBusy(true);
    setReadbackMessage("");
    try {
      let cursor: string | undefined;
      const visited = new Set<string>();
      do {
        const page = await api.listAgents(cursor, externalId);
        const match = page.items.find(a => a.externalAgentId === externalId);
        if (match) {
          setExisting(match);
          return;
        }
        cursor = page.nextCursor ?? undefined;
        if (cursor && visited.has(cursor)) throw new ApiError("The Gateway returned a repeated page cursor.", 200, "INVALID_API_RESPONSE");
        if (cursor) visited.add(cursor);
      } while (cursor);
      setReadbackMessage("No registration found yet. Check again before attempting another registration.");
    } catch (failure) {
      setError(failure);
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <PageHeader title="Register agent" subtitle="Name the agent, choose a blueprint, and save its Gateway key." />
      <Body1 block style={{ marginBottom: 16 }}>Step {step} of 3: {["Name", "Blueprint", "Key"][step - 1]}</Body1>
      {step === 1 && (
        <Card style={cardStyle}>
          <Field label="Agent name" required><Input value={name} maxLength={256} onChange={(_, data) => setName(data.value)} placeholder="Support Copilot" /></Field>
          <Field label="External ID" required hint="Your team uses this ID in API calls."
            validationMessage={!validExternalId ? "Use letters, numbers, dots, hyphens, or underscores; start with a letter or number." : undefined}>
            <Input value={externalId} maxLength={128} onChange={(_, data) => setExternalId(data.value)} />
          </Field>
          <Field label="Environment">
            <Select value={environment} onChange={(_, data) => {
              if (data.value === "Development" || data.value === "Test" || data.value === "Production") setEnvironment(data.value);
            }}>
              <option>Development</option><option>Test</option><option>Production</option>
            </Select>
          </Field>
          <Button appearance="primary" disabled={!validName || !validExternalId} onClick={() => setStep(2)} style={{ alignSelf: "flex-start" }}>Next</Button>
        </Card>
      )}
      {step === 2 && (
        <Card style={cardStyle}>
          <RadioGroup value={newBlueprint ? "new" : "existing"} layout="horizontal"
            onChange={(_, data) => setNewBlueprint(data.value === "new")} disabled={busy || uncertain}>
            <Radio value="existing" label="Use existing blueprint" /><Radio value="new" label="Create new blueprint" />
          </RadioGroup>
          {newBlueprint ? (
            <Field label="Blueprint name" hint="Reusable by other agents later." required>
              <Input value={blueprintDisplayName} maxLength={256} disabled={busy || uncertain} onChange={(_, data) => setBlueprintDisplayName(data.value)} />
            </Field>
          ) : blueprints.isPending ? <Spinner label="Loading blueprints" /> : blueprints.isError ? (
            <ErrorState error={blueprints.error} onRetry={() => void blueprints.refetch()} />
          ) : compatible.length === 0 ? <Body1>No compatible blueprints found. Create a new blueprint to continue.</Body1> : (
            <Field label="Blueprint" hint="This agent receives its own child identity." required>
              <Dropdown placeholder="Choose a blueprint" disabled={busy || uncertain}
                selectedOptions={blueprintId ? [blueprintId] : []}
                value={compatible.find(b => b.blueprintObjectId === blueprintId)?.displayName ?? ""}
                onOptionSelect={(_, data) => setBlueprintId(data.optionValue ?? "")}>
                {compatible.map(b => <Option key={b.blueprintObjectId} value={b.blueprintObjectId} text={b.displayName}>{b.displayName}</Option>)}
              </Dropdown>
            </Field>
          )}
          {error !== undefined && <ErrorState title="Registration was not confirmed" error={error} />}
          {uncertain && !existing && (
            <>
              <Body1>Do not register again until the existing request is checked.</Body1>
              <Button disabled={busy} onClick={() => void findRegistration()}>Check registration</Button>
              {readbackMessage && <Body1 role="status">{readbackMessage}</Body1>}
            </>
          )}
          {existing && <MessageBar intent="info"><MessageBarBody>
            Registration found. The original key cannot be retrieved. <Link to={`/agents/${existing.agentId}`}>Open agent to create a replacement key</Link>.
          </MessageBarBody></MessageBar>}
          <div style={{ display: "flex", gap: 8 }}>
            <Button disabled={busy || uncertain} onClick={() => setStep(1)}>Back</Button>
            <Button appearance="primary" disabled={busy || uncertain || !validBlueprint} onClick={() => void create()}>
              {busy ? "Working..." : "Create agent"}
            </Button>
          </div>
          <Caption1>Purview is configured separately. Prompt Shields follows the Gateway default until you choose a per-agent setting.</Caption1>
        </Card>
      )}
      {step === 3 && result && (
        <Card style={cardStyle}>
          <Text weight="semibold" size={400}>Registration accepted</Text>
          <Body1>Identity provisioning may still be running. The agent page shows its current status.</Body1>
          <CopyableCommand label="External ID" rows={1} command={result.externalAgentId} />
          {result.gatewayCredential ? (
            <>
              <Body1>Save this key now. Leaving this page hides it permanently.</Body1>
              <CopyableCommand label="One-time Gateway key" rows={2} command={result.gatewayCredential.apiKey} />
              <Checkbox label="I saved the key" checked={saved} onChange={(_, data) => setSaved(data.checked === true)} />
            </>
          ) : <Body1>No key was returned. Open the agent page to create a replacement; do not register again.</Body1>}
          <Button appearance="primary" disabled={!!result.gatewayCredential && !saved}
            onClick={() => navigate(`/agents/${result.agentId}`)} style={{ alignSelf: "flex-start" }}>Open agent</Button>
        </Card>
      )}
    </>
  );
}
