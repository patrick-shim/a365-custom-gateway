import { useEffect, useState } from "react";
import { Button, MessageBar, MessageBarBody, MessageBarTitle, Caption1 } from "@fluentui/react-components";
import { ApiError, errorMessage, SignInRequiredError } from "../api/errors";
import { apiScopes, msalInstance, satisfyApiClaimsChallenge } from "../auth/msal";

export function ErrorState({ error, onRetry, title = "Could not load this information" }: {
  error: unknown;
  onRetry?: () => void;
  title?: string;
}) {
  const [signInFailed, setSignInFailed] = useState(false);
  const [signingIn, setSigningIn] = useState(false);
  const [authorizationUpdated, setAuthorizationUpdated] = useState(false);
  const challenge = error instanceof ApiError ? error.authorizationChallenge : undefined;
  const needsSignIn = error instanceof SignInRequiredError || (error instanceof ApiError && error.status === 401);
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
  return (
    <MessageBar intent="error" role="alert" style={{ marginBottom: 16 }}>
      <MessageBarBody>
        <MessageBarTitle>{title}</MessageBarTitle>
        {errorMessage(error)}
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
          <Button style={{ marginTop: 8 }} disabled={signingIn} onClick={() => void signIn()}>
            {challenge?.kind === "claims" ? "Continue sign-in" : "Sign in again"}
          </Button>
        ) : onRetry ? (
          <Button style={{ marginTop: 8 }} onClick={onRetry}>Try again</Button>
        ) : null}
        {signInFailed && <Caption1 block>Sign-in could not start. Reload the page and try again.</Caption1>}
      </MessageBarBody>
    </MessageBar>
  );
}
