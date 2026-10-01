// Runtime configuration. In the container, the entrypoint writes /config.js which
// sets window.__A365_CONFIG__ from environment variables, so one image serves any
// deployment. In local dev (no config.js), the app falls back to mock mode.

export interface RuntimeConfig {
  clientId: string;
  tenantId: string;
  apiScope: string;
  useMock: boolean;
}

declare global {
  interface Window {
    __A365_CONFIG__?: Partial<RuntimeConfig>;
  }
}

const injected = typeof window !== "undefined" ? window.__A365_CONFIG__ : undefined;

export const config: RuntimeConfig = {
  clientId: injected?.clientId ?? "",
  tenantId: injected?.tenantId ?? "",
  apiScope: injected?.apiScope ?? "",
  // Mock when explicitly requested, or when no client id is configured (local dev).
  useMock:
    injected?.useMock ??
    (import.meta.env.VITE_USE_MOCK === "0" ? false : !injected?.clientId),
};

export const authEnabled = !config.useMock && config.clientId.length > 0;
