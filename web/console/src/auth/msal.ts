import {
  PublicClientApplication,
  type Configuration,
  type AccountInfo,
} from "@azure/msal-browser";
import { config } from "../runtime-config";

const msalConfig: Configuration = {
  auth: {
    clientId: config.clientId || "00000000-0000-0000-0000-000000000000",
    authority: `https://login.microsoftonline.com/${config.tenantId || "common"}`,
    redirectUri: window.location.origin,
    postLogoutRedirectUri: window.location.origin,
  },
  cache: {
    cacheLocation: "sessionStorage",
    storeAuthStateInCookie: false,
  },
};

export const msalInstance = new PublicClientApplication(msalConfig);

/** Scopes requested for the Gateway API access token. */
export const apiScopes = config.apiScope ? [config.apiScope] : [];

/** Acquire an access token for the Gateway API, silently when possible. */
export async function getApiToken(): Promise<string | null> {
  if (apiScopes.length === 0) return null;
  const account: AccountInfo | undefined = msalInstance.getAllAccounts()[0];
  if (!account) return null;
  try {
    const result = await msalInstance.acquireTokenSilent({ scopes: apiScopes, account });
    return result.accessToken;
  } catch {
    await msalInstance.acquireTokenRedirect({ scopes: apiScopes, account });
    return null;
  }
}
