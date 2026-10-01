import { Badge } from "@fluentui/react-components";

type Tone = "success" | "warning" | "danger" | "informative" | "subtle";

const toneByValue: Record<string, Tone> = {
  Healthy: "success",
  Active: "success",
  Connected: "success",
  Installed: "success",
  On: "success",
  Ready: "success",
  Degraded: "warning",
  Pending: "warning",
  DefaultOn: "warning",
  DefaultOff: "subtle",
  AwaitingProviderReference: "warning",
  AwaitingRegistryHandoff: "warning",
  PendingVerification: "warning",
  Simulation: "warning",
  SimulationWithTips: "warning",
  SimulationWithoutTips: "warning",
  Unhealthy: "danger",
  Failed: "danger",
  VerificationFailed: "danger",
  Unavailable: "warning",
  Cancelled: "subtle",
  Completed: "success",
  Running: "informative",
  Submitted: "informative",
  SimulationReady: "informative",
  PendingPropagation: "warning",
  RequiresManualIntervention: "warning",
  Expired: "danger",
  Off: "subtle",
  Disabled: "subtle",
  NotConnected: "subtle",
  NotInstalled: "subtle",
  Draft: "informative",
  Provisioning: "informative",
};

const colorByTone: Record<Tone, "success" | "warning" | "danger" | "informative" | "subtle"> = {
  success: "success",
  warning: "warning",
  danger: "danger",
  informative: "informative",
  subtle: "subtle",
};

export function StatusPill({ value: supplied }: { value: string | null | undefined }) {
  const value = typeof supplied === "string" && supplied.trim() ? supplied : "Unknown";
  const tone = toneByValue[value] ?? "informative";
  return (
    <Badge appearance="filled" color={colorByTone[tone]}>
      {humanize(value)}
    </Badge>
  );
}

function humanize(value: string): string {
  return value
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/^./, (c) => c.toUpperCase());
}
