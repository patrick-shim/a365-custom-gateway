import { beforeEach, describe, expect, it, vi } from "vitest";
import { InteractionRequiredAuthError } from "@azure/msal-browser";

const { account, client } = vi.hoisted(() => {
  const account = { homeAccountId: "test-home", localAccountId: "test-local",
    environment: "login.microsoftonline.com", tenantId: "test-tenant", username: "test-user" };
  return {
    account,
    client: {
      getActiveAccount: vi.fn(() => account),
      getAllAccounts: vi.fn(() => [account]),
      acquireTokenSilent: vi.fn(),
      acquireTokenPopup: vi.fn(),
    },
  };
});
vi.mock("@azure/msal-browser", async importOriginal => ({
  ...await importOriginal<typeof import("@azure/msal-browser")>(),
  PublicClientApplication: vi.fn(function () { return client; }),
}));
vi.mock("../runtime-config", () => ({
  config: { clientId: "test-client", tenantId: "test-tenant", apiScope: "api://test/access_as_user" },
}));

beforeEach(() => {
  vi.resetModules();
  vi.clearAllMocks();
  client.acquireTokenSilent.mockResolvedValue({ accessToken: "test-only-token" });
  client.acquireTokenPopup.mockResolvedValue({ accessToken: "test-only-token" });
});

describe("Gateway API authorization interaction", () => {
  it("uses the configured API scopes and the same claims on the next silent acquisition", async () => {
    const { satisfyApiClaimsChallenge, getApiToken } = await import("./msal");
    const claims = '{"access_token":{"acrs":{"value":"test"}}}';
    await satisfyApiClaimsChallenge(claims);
    expect(client.acquireTokenPopup).toHaveBeenCalledWith({
      scopes: ["api://test/access_as_user"], account, claims,
    });
    expect(await getApiToken()).toBe("test-only-token");
    expect(client.acquireTokenSilent).toHaveBeenCalledWith({
      scopes: ["api://test/access_as_user"], account, claims,
    });
  });

  it("does not remember a challenge after a cancelled interaction", async () => {
    const { satisfyApiClaimsChallenge, getApiToken } = await import("./msal");
    client.acquireTokenPopup.mockRejectedValue(new Error("Cancelled"));
    await expect(satisfyApiClaimsChallenge('{"access_token":{}}')).rejects.toThrow("Cancelled");
    await getApiToken();
    expect(client.acquireTokenSilent).toHaveBeenCalledWith({
      scopes: ["api://test/access_as_user"], account, claims: undefined,
    });
  });

  it("turns an interactive requirement into a visible sign-in error rather than starting a redirect", async () => {
    const { getApiToken } = await import("./msal");
    client.acquireTokenSilent.mockRejectedValue(new InteractionRequiredAuthError("interaction_required"));
    await expect(getApiToken()).rejects.toMatchObject({ name: "SignInRequiredError" });
    expect(client.acquireTokenPopup).not.toHaveBeenCalled();
  });
});
