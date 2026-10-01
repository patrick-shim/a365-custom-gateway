import { afterEach, describe, expect, it, vi } from "vitest";

afterEach(() => {
  delete window.__A365_CONFIG__;
  vi.unstubAllEnvs();
  vi.resetModules();
});

describe("runtime configuration", () => {
  it("fails visibly rather than silently using demo data when settings are missing", async () => {
    vi.stubEnv("VITE_CLIENT_ID", "");
    vi.stubEnv("VITE_TENANT_ID", "");
    vi.stubEnv("VITE_API_SCOPE", "");
    const { validateConfig } = await import("./runtime-config");
    expect(validateConfig).toThrow("Console sign-in is not configured");
  });

  it("rejects the old production mock-mode switch", async () => {
    window.__A365_CONFIG__ = { clientId: "test", tenantId: "test", apiScope: "api://test/access_as_user", useMock: true };
    const { validateConfig } = await import("./runtime-config");
    expect(validateConfig).toThrow("Console sign-in is not configured");
  });

  it("uses explicitly configured public Entra settings", async () => {
    window.__A365_CONFIG__ = { clientId: "test", tenantId: "test", apiScope: "api://test/access_as_user", useMock: false };
    const { validateConfig, config } = await import("./runtime-config");
    expect(validateConfig).not.toThrow();
    expect(config.clientId).toBe("test");
    expect(config).not.toHaveProperty("useMock");
  });
});
