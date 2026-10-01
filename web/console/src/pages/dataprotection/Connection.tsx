import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Spinner,
  Card,
  Text,
  Body1,
  Caption1,
  Button,
  MessageBar,
  MessageBarBody,
  makeStyles,
  tokens,
} from "@fluentui/react-components";
import { ArrowClockwise24Regular } from "@fluentui/react-icons";
import { api } from "../../api/client";
import { PageHeader } from "../../components/PageHeader";
import { StatusPill } from "../../components/StatusPill";
import { CopyableCommand } from "../../components/CopyableCommand";

const useStyles = makeStyles({
  card: {
    marginBottom: tokens.spacingVerticalL,
    padding: tokens.spacingVerticalL,
    display: "flex",
    flexDirection: "column",
    gap: tokens.spacingVerticalM,
  },
  facts: {
    display: "grid",
    gridTemplateColumns: "180px 1fr",
    rowGap: tokens.spacingVerticalXS,
    columnGap: tokens.spacingHorizontalL,
  },
  dt: { color: tokens.colorNeutralForeground3 },
  step: { display: "flex", flexDirection: "column", gap: tokens.spacingVerticalXS },
});

export function Connection() {
  const styles = useStyles();
  const qc = useQueryClient();
  const connection = useQuery({ queryKey: ["purview"], queryFn: api.getPurviewConnection });
  const recheck = useMutation({
    mutationFn: () => api.recheckPurviewConnection(),
    onSuccess: (c) => qc.setQueryData(["purview"], c),
  });

  if (connection.isLoading) return <Spinner label="Loading…" />;
  const c = connection.data!;
  const needsSetup =
    c.status === "AwaitingProviderReference" ||
    c.lastFailureCode === "PURVIEW_CONNECTION_PROVIDER_UNVERIFIED";

  return (
    <>
      <PageHeader
        title="Connection"
        subtitle="Lets the Gateway read classifiers and apply DLP policies."
        actions={<StatusPill value={needsSetup ? "Needs setup" : c.status} />}
      />

      {c.status === "Connected" && (
        <MessageBar intent="success" className={styles.card}>
          <MessageBarBody>Connected. {c.sensitiveInformationTypeCount ?? 0} classifiers available.</MessageBarBody>
        </MessageBar>
      )}

      {needsSetup && (
        <Card className={styles.card}>
          <Text weight="semibold" size={400}>Finish Purview setup</Text>
          <Body1>Register the Gateway in Security &amp; Compliance. One time, one command.</Body1>

          <div className={styles.step}>
            <Caption1>1. Sign in (admin)</Caption1>
            <CopyableCommand
              label=""
              rows={1}
              command={`Connect-IPPSSession -UserPrincipalName ${c.administratorUpn ?? "<your-admin-upn>"}`}
            />
          </div>
          <div className={styles.step}>
            <Caption1>2. Register the Gateway</Caption1>
            <CopyableCommand
              label=""
              command={`New-ServicePrincipal -AppId ${c.automationApplicationId ?? "<app-id>"} -ObjectId ${c.automationServicePrincipalObjectId ?? "<object-id>"} -DisplayName "A365 Gateway Purview Automation"`}
            />
          </div>

          <Button
            appearance="primary"
            icon={<ArrowClockwise24Regular />}
            disabled={recheck.isPending}
            onClick={() => recheck.mutate()}
            style={{ alignSelf: "flex-start" }}
          >
            {recheck.isPending ? "Re-checking…" : "Re-check"}
          </Button>

          {recheck.isSuccess && recheck.data.status !== "Connected" && (
            <Caption1>Still not set up. If you just ran it, wait a minute and re-check.</Caption1>
          )}
        </Card>
      )}

      <Card className={styles.card}>
        <div className={styles.facts}>
          <Caption1 className={styles.dt}>Tenant</Caption1>
          <Body1><code>{c.tenantId}</code></Body1>
          <Caption1 className={styles.dt}>Automation app</Caption1>
          <Body1><code>{c.automationApplicationId ?? "—"}</code></Body1>
          {c.lastFailureCode && (
            <>
              <Caption1 className={styles.dt}>Details</Caption1>
              <Body1><code>{c.lastFailureCode}</code></Body1>
            </>
          )}
        </div>
      </Card>
    </>
  );
}
