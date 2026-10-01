import { useQuery } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import {
  Table,
  TableHeader,
  TableRow,
  TableHeaderCell,
  TableBody,
  TableCell,
  TableCellLayout,
  Spinner,
  Button,
  makeStyles,
  tokens,
  Text,
} from "@fluentui/react-components";
import { Bot24Regular } from "@fluentui/react-icons";
import { api } from "../../api/client";
import { PageHeader } from "../../components/PageHeader";
import { StatusPill } from "../../components/StatusPill";

const useStyles = makeStyles({
  clickable: { cursor: "pointer" },
  sub: { color: tokens.colorNeutralForeground3 },
});

export function AgentsList() {
  const styles = useStyles();
  const navigate = useNavigate();
  const agents = useQuery({ queryKey: ["agents"], queryFn: api.listAgents });

  return (
    <>
      <PageHeader
        title="Agents"
        subtitle="External agents connected to Agent 365 through this Gateway. Each agent has its own child Agent ID and its own Prompt Shields choice."
        actions={<Button appearance="primary" onClick={() => navigate("/register")}>Register agent</Button>}
      />

      {agents.isLoading ? (
        <Spinner label="Loading agents…" />
      ) : (
        <Table aria-label="Agents" size="medium">
          <TableHeader>
            <TableRow>
              <TableHeaderCell>Agent</TableHeaderCell>
              <TableHeaderCell>Blueprint</TableHeaderCell>
              <TableHeaderCell>Status</TableHeaderCell>
              <TableHeaderCell>Prompt Shields</TableHeaderCell>
              <TableHeaderCell>Activity (24h)</TableHeaderCell>
            </TableRow>
          </TableHeader>
          <TableBody>
            {agents.data!.map((agent) => (
              <TableRow
                key={agent.id}
                className={styles.clickable}
                onClick={() => navigate(`/agents/${agent.id}`)}
              >
                <TableCell>
                  <TableCellLayout media={<Bot24Regular />}>
                    <Text weight="semibold">{agent.displayName}</Text>
                    <br />
                    <Text className={styles.sub} size={200}>{agent.externalAgentId}</Text>
                  </TableCellLayout>
                </TableCell>
                <TableCell>{agent.blueprint.displayName}</TableCell>
                <TableCell><StatusPill value={agent.lifecycle} /></TableCell>
                <TableCell><StatusPill value={agent.promptShield} /></TableCell>
                <TableCell>{agent.activity24h.toLocaleString()}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </>
  );
}
