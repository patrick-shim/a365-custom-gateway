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
  MessageBar,
  MessageBarBody,
} from "@fluentui/react-components";
import { ArrowClockwise24Regular } from "@fluentui/react-icons";
import { api } from "../../api/client";
import { PageHeader } from "../../components/PageHeader";

export function Classifiers() {
  const sits = useQuery({ queryKey: ["sits"], queryFn: api.listSensitiveInformationTypes });
  const purview = useQuery({ queryKey: ["purview"], queryFn: api.getPurviewConnection });

  const connected = purview.data?.status === "Connected";

  return (
    <>
      <PageHeader
        title="Classifiers"
        subtitle="The sensitive info types your policies can look for."
        actions={<Button icon={<ArrowClockwise24Regular />} disabled={!connected}>Refresh</Button>}
      />

      {!connected && (
        <MessageBar intent="warning" style={{ marginBottom: 16 }}>
          <MessageBarBody>Connect Purview first to load classifiers.</MessageBarBody>
        </MessageBar>
      )}

      {sits.isLoading ? (
        <Spinner label="Loading…" />
      ) : (
        <Table aria-label="Classifiers">
          <TableHeader>
            <TableRow>
              <TableHeaderCell>Name</TableHeaderCell>
              <TableHeaderCell>Publisher</TableHeaderCell>
            </TableRow>
          </TableHeader>
          <TableBody>
            {sits.data!.map((s) => (
              <TableRow key={s.id}>
                <TableCell>{s.name}</TableCell>
                <TableCell>{s.publisher}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </>
  );
}
