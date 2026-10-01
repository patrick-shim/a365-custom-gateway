import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { FluentProvider, webLightTheme } from "@fluentui/react-components";
import { MsalProvider } from "@azure/msal-react";
import { App } from "./App";
import { applyDemoOverrides } from "./api/mock";
import { authEnabled } from "./runtime-config";
import { msalInstance } from "./auth/msal";
import { SignInGate } from "./components/SignInGate";

applyDemoOverrides(window.location.search);

const queryClient = new QueryClient({
  defaultOptions: { queries: { refetchOnWindowFocus: false, retry: 1 } },
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

  if (!authEnabled) {
    root.render(
      <StrictMode>
        <FluentProvider theme={webLightTheme}>
          <Shell />
        </FluentProvider>
      </StrictMode>,
    );
    return;
  }

  await msalInstance.initialize();
  await msalInstance.handleRedirectPromise();

  root.render(
    <StrictMode>
      <FluentProvider theme={webLightTheme}>
        <MsalProvider instance={msalInstance}>
          <SignInGate>
            <Shell />
          </SignInGate>
        </MsalProvider>
      </FluentProvider>
    </StrictMode>,
  );
}

void bootstrap();
