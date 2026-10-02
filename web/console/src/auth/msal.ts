import {
  PublicClientApplication,
  InteractionRequiredAuthError,
  type Configuration,
  type AccountInfo,
} from "@azure/msal-browser";
import { config } from "../runtime-config";
import { SignInRequiredError } from "../api/errors";

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
let apiClaims: string | undefined;

/** Acquire an access token for the Gateway API, silently when possible. */
export function getAccount(): AccountInfo | undefined {
  return msalInstance.getActiveAccount() ?? msalInstance.getAllAccounts()[0];
}

export async function getApiToken(): Promise<string> {
  const account = getAccount();
  if (apiScopes.length === 0 || !account) throw new SignInRequiredError();
  try {
    const result = await msalInstance.acquireTokenSilent({ scopes: apiScopes, account, claims: apiClaims });
    return result.accessToken;
  } catch (error) {
    if (error instanceof InteractionRequiredAuthError) throw new SignInRequiredError();
    throw error;
  }
}

export async function satisfyApiClaimsChallenge(claims: string): Promise<void> {
  const account = getAccount();
  if (apiScopes.length === 0 || !account) throw new SignInRequiredError();
  await msalInstance.acquireTokenPopup({ scopes: apiScopes, account, claims });
  apiClaims = claims;
}
