import { useQuery } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import {
  Card,
  Spinner,
  Text,
  Body1,
  Caption1,
  Link,
  makeStyles,
  tokens,
} from "@fluentui/react-components";
import { Warning24Filled, CheckmarkCircle24Filled } from "@fluentui/react-icons";
import { api } from "../api/client";
import { PageHeader } from "../components/PageHeader";

const useStyles = makeStyles({
  stats: { display: "flex", gap: tokens.spacingHorizontalL, marginBottom: tokens.spacingVerticalXL },
  stat: { padding: tokens.spacingVerticalM, minWidth: "140px" },
  num: { fontSize: tokens.fontSizeHero700, fontWeight: tokens.fontWeightSemibold },
  attn: { display: "flex", flexDirection: "column", gap: tokens.spacingVerticalS },
  item: {
    display: "flex",
    alignItems: "center",
    gap: tokens.spacingHorizontalM,
    padding: tokens.spacingVerticalM,
  },
  ok: { display: "flex", alignItems: "center", gap: tokens.spacingHorizontalS, color: tokens.colorPaletteGreenForeground1 },
});

interface Attention {
  text: string;
  to: string;
  linkLabel: string;
}

export function Home() {
  const styles = useStyles();
  const navigate = useNavigate();
  const health = useQuery({ queryKey: ["health"], queryFn: api.getHealth });
  const agents = useQuery({ queryKey: ["agents"], queryFn: api.listAgents });
  const purview = useQuery({ queryKey: ["purview"], queryFn: api.getPurviewConnection });

  if (health.isLoading || agents.isLoading || purview.isLoading) return <Spinner label="Loading…" />;

  const items: Attention[] = [];
  if (purview.data?.status === "AwaitingProviderReference")
    items.push({ text: "Purview needs one-time setup.", to: "/data-protection/connection", linkLabel: "Finish setup" });
  const handoff = agents.data?.filter((a) => a.lifecycle === "AwaitingRegistryHandoff") ?? [];
  if (handoff.length)
    items.push({ text: `${handoff.length} agent${handoff.length > 1 ? "s" : ""} waiting for Registry handoff.`, to: "/agents", linkLabel: "View agents" });
  if (health.data!.api !== "Healthy")
    items.push({ text: "Gateway API is not healthy.", to: "/platform", linkLabel: "Check platform" });

  const active = agents.data?.filter((a) => a.lifecycle === "Active").length ?? 0;

  return (
    <>
      <PageHeader title="Home" subtitle="What needs your attention, and where to go." />

      <div className={styles.stats}>
        <Card className={styles.stat}><Caption1>Agents</Caption1><div className={styles.num}>{agents.data!.length}</div><Caption1>{active} active</Caption1></Card>
        <Card className={styles.stat}><Caption1>Prompt Shields on</Caption1><div className={styles.num}>{agents.data!.filter((a) => a.promptShield === "On" || a.promptShield === "DefaultOn").length}</div></Card>
        <Card className={styles.stat}><Caption1>Region</Caption1><div className={styles.num} style={{ fontSize: 20 }}>{health.data!.region}</div><Caption1>{health.data!.api}</Caption1></Card>
      </div>

      <Text weight="semibold" size={400}>Needs attention</Text>
      <div className={styles.attn} style={{ marginTop: tokens.spacingVerticalS }}>
        {items.length === 0 ? (
          <Card className={styles.item}>
            <span className={styles.ok}><CheckmarkCircle24Filled /> All clear. Nothing needs you right now.</span>
          </Card>
        ) : (
          items.map((i, idx) => (
            <Card key={idx} className={styles.item}>
              <Warning24Filled style={{ color: tokens.colorStatusWarningForeground1 }} />
              <Body1 style={{ flex: 1 }}>{i.text}</Body1>
              <Link onClick={() => navigate(i.to)}>{i.linkLabel}</Link>
            </Card>
          ))
        )}
      </div>
    </>
  );
}
