import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Button, Body1, Title2 } from "@fluentui/react-components";
import { MsalProvider } from "@azure/msal-react";
import { App } from "./App";
import { validateConfig } from "./runtime-config";
import { msalInstance } from "./auth/msal";
import { SignInGate } from "./components/SignInGate";
import { ApiError, SignInRequiredError } from "./api/errors";
import "./base.css";
import { ConsoleThemeProvider } from "./components/ConsoleThemeProvider";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: false,
      staleTime: 15_000,
      retry: (failures, error) => failures < 1 && !(error instanceof SignInRequiredError) &&
        !(error instanceof ApiError && error.status >= 400 && error.status < 500),
    },
    mutations: { retry: false, gcTime: 0 },
  },
});

function Shell() {
  return (
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </QueryClientProvider>
  );
}

async function bootstrap() {
  const root = createRoot(document.getElementById("root")!);
  let configurationValid = false;
  try {
    validateConfig();
    configurationValid = true;
    await msalInstance.initialize();
    const response = await msalInstance.handleRedirectPromise();
    if (response?.account) msalInstance.setActiveAccount(response.account);
    root.render(
      <StrictMode>
        <ConsoleThemeProvider>
          <MsalProvider instance={msalInstance}>
            <SignInGate><Shell /></SignInGate>
          </MsalProvider>
        </ConsoleThemeProvider>
      </StrictMode>,
    );
  } catch (error) {
    console.error("Console startup failed", { name: error instanceof Error ? error.name : "Unknown" });
    root.render(
      <ConsoleThemeProvider>
        <main role="alert" style={{ padding: 32, minHeight: "100vh" }}>
          <Title2 as="h1">Console could not start</Title2>
          <Body1 block>{configurationValid
            ? "Sign-in could not finish. Reload to try again."
            : "Console sign-in is not configured. Ask the deployer to check the client ID, tenant ID, and API scope."}</Body1>
          <Button style={{ marginTop: 16 }} onClick={() => window.location.reload()}>Reload Console</Button>
        </main>
      </ConsoleThemeProvider>,
    );
  }
}

void bootstrap();
