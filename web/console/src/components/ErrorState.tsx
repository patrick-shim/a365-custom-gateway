import { useEffect, useState } from "react";
import { Button, MessageBar, MessageBarBody, MessageBarTitle, Caption1, Spinner } from "@fluentui/react-components";
import { ApiError, errorMessage, SignInRequiredError } from "../api/errors";
import { apiScopes, msalInstance, satisfyApiClaimsChallenge } from "../auth/msal";

export function ErrorState({ error, onRetry, title = "Could not load this information" }: {
  error: unknown;
  onRetry?: () => void | Promise<unknown>;
  title?: string;
}) {
  const [signInFailed, setSignInFailed] = useState(false);
  const [signingIn, setSigningIn] = useState(false);
  const [authorizationUpdated, setAuthorizationUpdated] = useState(false);
  const challenge = error instanceof ApiError ? error.authorizationChallenge : undefined;
  const needsSignIn = error instanceof SignInRequiredError || (error instanceof ApiError && error.status === 401);
  const intent = needsSignIn || error instanceof ApiError && [403, 409, 412, 429].includes(error.status) ? "warning" : "error";
  const guidance = recoveryGuidance(error);
  useEffect(() => {
    setAuthorizationUpdated(false);
    setSignInFailed(false);
  }, [error]);
  async function signIn() {
    setSignInFailed(false);
    setSigningIn(true);
    try {
      if (challenge?.kind === "claims") {
        await satisfyApiClaimsChallenge(challenge.claims);
        setAuthorizationUpdated(true);
      } else {
        await msalInstance.loginRedirect({ scopes: apiScopes });
      }
    } catch {
      setSignInFailed(true);
    } finally {
      setSigningIn(false);
    }
  }
  async function retry() {
    if (!onRetry || signingIn) return;
    setSigningIn(true);
    try { await onRetry(); }
    finally { setSigningIn(false); }
  }
  return (
    <MessageBar intent={intent} role="alert" style={{ marginBottom: 16 }}>
      <MessageBarBody>
        <MessageBarTitle>{title}</MessageBarTitle>
        {errorMessage(error)}
        {guidance && <Caption1 block className="error-guidance">{guidance}</Caption1>}
        {error instanceof ApiError && (error.code || error.correlationId) && (
          <details style={{ marginTop: 8 }}>
            <summary>Details</summary>
            {error.code && <Caption1 block>Code: {error.code}</Caption1>}
            {error.correlationId && <Caption1 block>Reference: {error.correlationId}</Caption1>}
          </details>
        )}
        {challenge?.kind === "consent" && <Caption1 block>
          A tenant administrator must consent to the Gateway API's delegated Graph permissions.
          Signing in to the Console does not grant those permissions.
          {" "}Run gateway up from the installation folder to repair and verify bootstrap consent, then retry registration.
          {challenge.scopes.length > 0 && ` Required: ${challenge.scopes.join(", ")}.`}
        </Caption1>}
        {challenge?.kind === "unavailable" && <Caption1 block>
          The authorization challenge could not be read. Ask your Gateway administrator to check API consent and the response headers.
        </Caption1>}
        {authorizationUpdated ? <Caption1 block role="status">
          Authorization updated. Check the current operation before confirming again; no action was repeated.
        </Caption1> : needsSignIn && challenge?.kind !== "unavailable" && challenge?.kind !== "consent" ? (
          <Button style={{ marginTop: 8 }} disabled={signingIn} icon={signingIn ? <Spinner size="tiny" /> : undefined}
            onClick={() => void signIn()}>
            {signingIn ? "Starting sign-in…" : challenge?.kind === "claims" ? "Continue sign-in" : "Sign in again"}
          </Button>
        ) : onRetry ? (
          <Button style={{ marginTop: 8 }} disabled={signingIn} icon={signingIn ? <Spinner size="tiny" /> : undefined}
            onClick={() => void retry()}>{signingIn ? "Trying again…" : "Try again"}</Button>
        ) : null}
        {signInFailed && <Caption1 block>Sign-in could not start. Reload the page and try again.</Caption1>}
      </MessageBarBody>
    </MessageBar>
  );
}

function recoveryGuidance(error: unknown): string | null {
  if (error instanceof SignInRequiredError) return "Your work on this page is unchanged. Sign in again, then retry the read.";
  if (!(error instanceof ApiError)) return "Retry the last read. If the problem continues, keep the page open and contact your Gateway administrator.";
  if (error.outcomeUnknown) return "The result is unconfirmed. Refresh current state before submitting the change again.";
  if (error.status === 0 || [502, 503, 504].includes(error.status))
    return "The Console is available, but the Gateway API is not ready. Wait a moment, then retry. If it continues, run gateway verify.";
  if (error.status === 403) return "Ask a Gateway administrator to confirm your assigned role. Signing in again does not add permission.";
  if (error.status === 409 || error.status === 412) return "The saved state changed. Refresh it, review the latest values, and submit a new request.";
  if (error.status === 429) return "The Gateway is limiting requests. Wait briefly before trying again.";
  return null;
}
