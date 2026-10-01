import type { Agent, Blueprint } from "./types";

export function utcTime(value: string): number {
  return Date.parse(/(?:Z|[+-]\d{2}:\d{2})$/i.test(value) ? value : `${value}Z`);
}

export function formatTime(value: string | null | undefined): string {
  if (!value) return "Not recorded";
  const time = utcTime(value);
  return Number.isFinite(time) ? new Date(time).toLocaleString() : "Unknown";
}

export function blueprintName(agent: Agent, blueprints: Blueprint[] | undefined): string {
  const identity = agent.agent365;
  if (!identity?.blueprintId && !identity?.blueprintObjectId) return "Not assigned";
  return blueprints?.find(b =>
    b.blueprintObjectId === identity.blueprintObjectId || b.blueprintClientId === identity.blueprintId,
  )?.displayName ?? identity.blueprintId ?? identity.blueprintObjectId ?? "Name unavailable";
}

export function shieldLabel(agent: Agent): string {
  if (!agent.features) return "Unknown";
  if (agent.features.promptShieldEffectivelyEnabled) return "On";
  return agent.features.promptShieldEnabled === true ? "Unavailable" : "Off";
}
