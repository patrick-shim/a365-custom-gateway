import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { Table, TableHeader, TableRow, TableHeaderCell, TableBody, TableCell, Spinner, Button, Body1, Caption1 } from "@fluentui/react-components";
import { api } from "../../api/client";
import { connectionIsUsable } from "../../api/types";
import { formatTime } from "../../api/display";
import { PageHeader } from "../../components/PageHeader";
import { ErrorState } from "../../components/ErrorState";

export function Classifiers() {
  const purview = useQuery({ queryKey: ["purview"], queryFn: api.getPurviewConnection });
  const connected = purview.isSuccess && connectionIsUsable(purview.data);
  const inventory = useQuery({ queryKey: ["sits"], queryFn: api.listSensitiveInformationTypes, enabled: connected });
  return (
    <>
      <PageHeader title="Classifiers" subtitle="Sensitive information types available to your DLP policies."
        actions={<Button disabled={!connected || inventory.isFetching} onClick={() => void inventory.refetch()}>Reload list</Button>} />
      {purview.isPending ? <Spinner label="Loading connection" /> : purview.isError ? (
        <ErrorState error={purview.error} onRetry={() => void purview.refetch()} />
      ) : !connected ? (
        <Body1>Purview access must be verified before classifiers can be loaded. <Link to="/data-protection/connection">Check connection</Link>.</Body1>
      ) : inventory.isPending ? <Spinner label="Loading classifiers" /> : inventory.isError ? (
        <><ErrorState error={inventory.error} onRetry={() => void inventory.refetch()} /><Link to="/data-protection/connection">Refresh inventory through a connection check</Link></>
      ) : (
        <>
          <Caption1 block>Retrieved: {formatTime(inventory.data.retrievedAtUtc)}; expires: {formatTime(inventory.data.expiresAtUtc)}</Caption1>
          {inventory.data.isExpired && <Body1 role="alert">This inventory has expired. <Link to="/data-protection/connection">Refresh connection</Link>.</Body1>}
          {inventory.data.items.length === 0 ? <Body1>No classifiers were returned by Purview.</Body1> : (
            <Table aria-label="Classifiers">
              <TableHeader><TableRow><TableHeaderCell>Name</TableHeaderCell><TableHeaderCell>Publisher</TableHeaderCell></TableRow></TableHeader>
              <TableBody>{inventory.data.items.map(item => (
                <TableRow key={item.id}><TableCell>{item.exactName}</TableCell><TableCell>{item.publisher}</TableCell></TableRow>
              ))}</TableBody>
            </Table>
          )}
        </>
      )}
    </>
  );
}
