import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { Body1, Button, Caption1, Card, Spinner, Text } from "@fluentui/react-components";
import { api } from "../../api/client";
import { PageHeader } from "../../components/PageHeader";
import { ErrorState } from "../../components/ErrorState";

export function Connection() {
  const catalog = useQuery({ queryKey: ["purview-policy-catalog"], queryFn: api.listPurviewPolicies,
    retry: false, refetchInterval: 60_000 });
  return <>
    <PageHeader title="Purview connection" subtitle="Connection setup is managed by bootstrap."
      actions={<Button disabled={catalog.isFetching} onClick={() => void catalog.refetch()}>Refresh status</Button>} />
    <Card style={{ padding: 24, gap: 12, marginBottom: 20 }}>
      <Text as="h2" size={500} weight="semibold">Policy catalog access</Text>
      {catalog.isFetching ? <Spinner label="Checking policy catalog" /> : catalog.isError ?
        <ErrorState error={catalog.error} onRetry={() => void catalog.refetch()} /> : catalog.data && <>
          <Body1>A current, signed policy catalog is available.</Body1>
          <Caption1>Last read from Purview: {new Date(catalog.data.retrievedAtUtc).toLocaleString()}</Caption1>
          <Caption1>Policies returned: {catalog.data.items.length}</Caption1>
        </>}
      <Body1>Bootstrap configures the management identity, certificate, and permissions. Use bootstrap to repair setup if catalog access is unavailable.</Body1>
      <Body1>Catalog access does not prove that assignments can be written or that sensitive content is blocked. Review each agent's assignment and gateway enforcement separately.</Body1>
    </Card>
    <Link to="/data-protection/policies">View policies and agents</Link>
  </>;
}
