import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import {
  Card,
  Input,
  Field,
  Dropdown,
  Option,
  Button,
  Text,
  Body1,
  Caption1,
  makeStyles,
  tokens,
  MessageBar,
  MessageBarBody,
} from "@fluentui/react-components";
import { api } from "../../api/client";
import { PageHeader } from "../../components/PageHeader";
import { CopyableCommand } from "../../components/CopyableCommand";

const useStyles = makeStyles({
  card: { padding: tokens.spacingVerticalL, display: "flex", flexDirection: "column", gap: tokens.spacingVerticalM, maxWidth: "560px" },
  steps: { display: "flex", gap: tokens.spacingHorizontalM, marginBottom: tokens.spacingVerticalL },
  step: { color: tokens.colorNeutralForeground3 },
  stepOn: { color: tokens.colorBrandForeground1, fontWeight: tokens.fontWeightSemibold },
  row: { display: "flex", gap: tokens.spacingHorizontalS },
});

export function RegisterAgent() {
  const styles = useStyles();
  const navigate = useNavigate();
  const blueprints = useQuery({ queryKey: ["blueprints"], queryFn: api.listBlueprints });
  const [step, setStep] = useState(1);
  const [name, setName] = useState("");
  const [blueprintId, setBlueprintId] = useState<string>("");

  const labels = ["Name", "Blueprint", "Key"];

  return (
    <>
      <PageHeader title="Register agent" subtitle="Three steps. Pick a blueprint, get a key." />

      <div className={styles.steps}>
        {labels.map((l, i) => (
          <Text key={l} className={i + 1 === step ? styles.stepOn : styles.step}>
            {i + 1}. {l}
          </Text>
        ))}
      </div>

      {step === 1 && (
        <Card className={styles.card}>
          <Field label="Agent name">
            <Input value={name} onChange={(_, d) => setName(d.value)} placeholder="Support Copilot" />
          </Field>
          <Button appearance="primary" disabled={!name.trim()} onClick={() => setStep(2)} style={{ alignSelf: "flex-start" }}>
            Next
          </Button>
        </Card>
      )}

      {step === 2 && (
        <Card className={styles.card}>
          <Field label="Blueprint" hint="The agent gets its own Agent ID under this blueprint.">
            <Dropdown
              placeholder="Choose a blueprint"
              onOptionSelect={(_, d) => setBlueprintId(d.optionValue ?? "")}
              value={blueprints.data?.find((b) => b.id === blueprintId)?.displayName ?? ""}
            >
              {blueprints.data?.map((b) => (
                <Option key={b.id} value={b.id}>{b.displayName}</Option>
              ))}
            </Dropdown>
          </Field>
          <div className={styles.row}>
            <Button onClick={() => setStep(1)}>Back</Button>
            <Button appearance="primary" disabled={!blueprintId} onClick={() => setStep(3)}>Create</Button>
          </div>
        </Card>
      )}

      {step === 3 && (
        <Card className={styles.card}>
          <Text weight="semibold" size={400}>Agent created</Text>
          <Body1>Copy the key now. It's shown once.</Body1>
          <CopyableCommand label="One-time Gateway key" rows={1} command="gwk_live_7Q2f…shown-once…b9" />
          <Caption1>Prompt Shields is on by default. Change it on the agent page any time.</Caption1>
          <div className={styles.row}>
            <Button appearance="primary" onClick={() => navigate("/agents")}>Done</Button>
          </div>
          <MessageBar intent="info">
            <MessageBarBody>Hand the key and external ID to the requesting team. Lost key → rotate, never re-register.</MessageBarBody>
          </MessageBar>
        </Card>
      )}
    </>
  );
}
