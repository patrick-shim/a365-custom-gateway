import { Caption1, Spinner } from "@fluentui/react-components";

export function RefreshIndicator({ active, label = "Refreshing" }: { active: boolean; label?: string }) {
  if (!active) return null;
  return <div className="background-refresh" role="status" aria-live="polite">
    <Spinner size="tiny" />
    <Caption1>{label}</Caption1>
  </div>;
}
