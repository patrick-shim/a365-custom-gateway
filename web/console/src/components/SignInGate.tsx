import { useState } from "react";
import { makeStyles, tokens, Title2, Body1, Button, Spinner } from "@fluentui/react-components";
import { useMsal, useIsAuthenticated } from "@azure/msal-react";
import { InteractionStatus } from "@azure/msal-browser";
import { apiScopes } from "../auth/msal";

const useStyles = makeStyles({
  root: {
    minHeight: "100vh",
    display: "grid",
    placeItems: "center",
    backgroundColor: tokens.colorNeutralBackground2,
  },
  card: {
    display: "flex",
    flexDirection: "column",
    gap: tokens.spacingVerticalL,
    alignItems: "center",
    padding: tokens.spacingVerticalXXL,
    backgroundColor: tokens.colorNeutralBackground1,
    borderRadius: tokens.borderRadiusXLarge,
    boxShadow: tokens.shadow16,
    maxWidth: "380px",
    textAlign: "center",
  },
  mark: {
    width: "48px",
    height: "48px",
    borderRadius: tokens.borderRadiusMedium,
    background: `linear-gradient(135deg, ${tokens.colorBrandBackground}, ${tokens.colorPaletteBerryBackground3})`,
  },
});

export function SignInGate({ children }: { children: React.ReactNode }) {
  const styles = useStyles();
  const { instance, inProgress } = useMsal();
  const isAuthenticated = useIsAuthenticated();
  const [failed, setFailed] = useState(false);
  async function signIn() {
    setFailed(false);
    try {
      await instance.loginRedirect({ scopes: apiScopes });
    } catch {
      setFailed(true);
    }
  }

  if (isAuthenticated) return <>{children}</>;

  if (inProgress !== InteractionStatus.None) {
    return (
      <div className={styles.root}>
        <Spinner label="Signing in…" />
      </div>
    );
  }

  return (
    <div className={styles.root}>
      <div className={styles.card}>
        <div className={styles.mark} aria-hidden />
        <Title2>A365 Gateway Console</Title2>
        <Body1>Sign in with your Microsoft Entra account to continue.</Body1>
        <Button
          appearance="primary"
          onClick={() => void signIn()}
        >
          Sign in
        </Button>
        {failed && <Body1 role="alert">Sign-in could not start. Reload and try again.</Body1>}
      </div>
    </div>
  );
}
