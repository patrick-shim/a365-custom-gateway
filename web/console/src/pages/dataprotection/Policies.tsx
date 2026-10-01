import { useQuery } from "@tanstack/react-query";
import {
  Table,
  TableHeader,
  TableRow,
  TableHeaderCell,
  TableBody,
  TableCell,
  Spinner,
  Button,
  Caption1,
} from "@fluentui/react-components";
import { api } from "../../api/client";
import { PageHeader } from "../../components/PageHeader";
import { StatusPill } from "../../components/StatusPill";

const modeLabel: Record<string, string> = {
  Enforce: "Blocking",
  SimulationWithTips: "Simulating (with tips)",
  SimulationWithoutTips: "Simulating",
  Disabled: "Off",
};

export function Policies() {
  const profiles = useQuery({ queryKey: ["dlp"], queryFn: api.listDlpProfiles });

  return (
    <>
      <PageHeader
        title="Policies"
        subtitle="One DLP policy per blueprint. Shared by every agent on that blueprint."
        actions={<Button appearance="primary">New policy</Button>}
      />

      {profiles.isLoading ? (
        <Spinner label="Loading…" />
      ) : (
        <Table aria-label="DLP policies">
          <TableHeader>
            <TableRow>
              <TableHeaderCell>Blueprint</TableHeaderCell>
              <TableHeaderCell>Mode</TableHeaderCell>
              <TableHeaderCell>Classifiers</TableHeaderCell>
              <TableHeaderCell>State</TableHeaderCell>
            </TableRow>
          </TableHeader>
          <TableBody>
            {profiles.data!.map((p) => (
              <TableRow key={p.id}>
                <TableCell>{p.blueprintDisplayName}</TableCell>
                <TableCell>{modeLabel[p.mode] ?? p.mode}</TableCell>
                <TableCell>{p.selectedSitCount} selected</TableCell>
                <TableCell><StatusPill value={p.readiness} /></TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
      <Caption1 block style={{ marginTop: 12 }}>
        Simulating tests a policy without blocking. Switch to Blocking when you're ready.
      </Caption1>
    </>
  );
}
