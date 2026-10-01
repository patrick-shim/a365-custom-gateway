import { useQuery } from "@tanstack/react-query";
import { Table, TableHeader, TableRow, TableHeaderCell, TableBody, TableCell, Spinner, Button, Body1, Caption1 } from "@fluentui/react-components";
import { api } from "../../api/client";
import { PageHeader } from "../../components/PageHeader";
import { StatusPill } from "../../components/StatusPill";
import { ErrorState } from "../../components/ErrorState";

const modeLabel: Record<string, string> = {
  Enforce: "Blocking", SimulationWithTips: "Simulating (with tips)",
  SimulationWithoutTips: "Simulating", AuditOnly: "Simulating", Disabled: "Off",
};

export function Policies() {
  const profiles = useQuery({ queryKey: ["dlp"], queryFn: api.listDlpProfiles });
  return (
    <>
      <PageHeader title="Policies" subtitle="Saved DLP policies are shared by all agents on their blueprint."
        actions={<Button disabled={profiles.isFetching} onClick={() => void profiles.refetch()}>Reload policies</Button>} />
      {profiles.isPending ? <Spinner label="Loading policies" /> : profiles.isError ? (
        <ErrorState error={profiles.error} onRetry={() => void profiles.refetch()} />
      ) : profiles.data.length === 0 ? <Body1>No DLP policies configured.</Body1> : (
        <div style={{ overflowX: "auto" }}>
          <Table aria-label="DLP policies">
            <TableHeader><TableRow>
              <TableHeaderCell>Policy</TableHeaderCell><TableHeaderCell>Blueprint application</TableHeaderCell>
              <TableHeaderCell>Mode</TableHeaderCell><TableHeaderCell>Classifiers</TableHeaderCell><TableHeaderCell>State</TableHeaderCell>
            </TableRow></TableHeader>
            <TableBody>{profiles.data.map(profile => {
              const mode = profile.policyMode ?? profile.mode;
              return <TableRow key={profile.id}>
                <TableCell>{profile.displayName}</TableCell><TableCell><code>{profile.blueprintApplicationId}</code></TableCell>
                <TableCell>{modeLabel[mode] ?? mode}</TableCell>
                <TableCell>{profile.sensitiveInformationTypes?.map(item => item.exactName).join(", ") || profile.sensitiveInformationTypeName}</TableCell>
                <TableCell><StatusPill value={profile.status} />
                  {!profile.readiness.isReady && <Caption1 block>Effective enforcement not verified.</Caption1>}
                  {profile.readiness.blockers.length > 0 && <details><summary>Readiness details</summary>
                    {profile.readiness.blockers.map(blocker => <Caption1 block key={blocker}>{blocker}</Caption1>)}
                  </details>}
                </TableCell>
              </TableRow>;
            })}</TableBody>
          </Table>
        </div>
      )}
      <Caption1 block style={{ marginTop: 16 }}>This page is read-only. Policy editing and behavior tests are not yet available in this Console.</Caption1>
    </>
  );
}
