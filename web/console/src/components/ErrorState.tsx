import { useState } from "react";
import { Button, MessageBar, MessageBarBody, MessageBarTitle, Caption1 } from "@fluentui/react-components";
import { ApiError, errorMessage, SignInRequiredError } from "../api/errors";
import { apiScopes, msalInstance } from "../auth/msal";

export function ErrorState({ error, onRetry, title = "Could not load this information" }: {
  error: unknown;
  onRetry?: () => void;
  title?: string;
}) {
  const [signInFailed, setSignInFailed] = useState(false);
  const needsSignIn = error instanceof SignInRequiredError || (error instanceof ApiError && error.status === 401);
  async function signIn() {
    setSignInFailed(false);
    try {
      await msalInstance.loginRedirect({ scopes: apiScopes });
    } catch {
      setSignInFailed(true);
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
        {needsSignIn ? (
          <Button style={{ marginTop: 8 }} onClick={() => void signIn()}>Sign in again</Button>
        ) : onRetry ? (
          <Button style={{ marginTop: 8 }} onClick={onRetry}>Try again</Button>
        ) : null}
        {signInFailed && <Caption1 block>Sign-in could not start. Reload the page and try again.</Caption1>}
      </MessageBarBody>
    </MessageBar>
  );
}
