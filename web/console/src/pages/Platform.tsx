import { useQuery } from "@tanstack/react-query";
import {
  Card,
  Spinner,
  Text,
  Body1,
  Caption1,
  Switch,
  makeStyles,
  tokens,
} from "@fluentui/react-components";
import { api } from "../api/client";
import { PageHeader } from "../components/PageHeader";
import { StatusPill } from "../components/StatusPill";

const useStyles = makeStyles({
  card: { padding: tokens.spacingVerticalL, marginBottom: tokens.spacingVerticalL, display: "flex", flexDirection: "column", gap: tokens.spacingVerticalM },
  grid: { display: "grid", gridTemplateColumns: "1fr 1fr", gap: tokens.spacingHorizontalL },
  row: { display: "flex", justifyContent: "space-between", alignItems: "center" },
});

export function Platform() {
  const styles = useStyles();
  const health = useQuery({ queryKey: ["health"], queryFn: api.getHealth });
  if (health.isLoading) return <Spinner label="Loading…" />;
  const h = health.data!;

  return (
    <>
      <PageHeader title="Platform" subtitle="Deployment health, capabilities, and defaults." />

      <Card className={styles.card}>
        <Text weight="semibold">Health</Text>
        <div className={styles.grid}>
          <HealthRow label="Gateway API" value={h.api} />
          <HealthRow label="Worker" value={h.worker} />
          <HealthRow label="Prompt Shields" value={h.promptShields} />
          <HealthRow label="Purview" value={h.purview} />
        </div>
        <Caption1>Region {h.region} · admission {h.admissionMode}</Caption1>
      </Card>

      <Card className={styles.card}>
        <Text weight="semibold">Defaults</Text>
        <div className={styles.row}>
          <div>
            <Body1>Prompt Shields for new agents</Body1>
            <Caption1 block>Operators can change it per agent later.</Caption1>
          </div>
          <Switch defaultChecked label="On" labelPosition="above" />
        </div>
      </Card>

      <Card className={styles.card}>
        <Text weight="semibold">Access</Text>
        <Caption1>Roles: Administrator, Operator, Auditor, Support reader. Credential actions are admin-only.</Caption1>
      </Card>
    </>
  );

  function HealthRow({ label, value }: { label: string; value: string }) {
    return (
      <div className={styles.row}>
        <Body1>{label}</Body1>
        <StatusPill value={value} />
      </div>
    );
  }
}
