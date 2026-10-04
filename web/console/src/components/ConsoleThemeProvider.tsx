import { createContext, ReactNode, useContext, useEffect, useState } from "react";
import { FluentProvider } from "@fluentui/react-components";
import { gatewayDarkTheme, gatewayTheme } from "../theme";

const storageKey = "a365-gateway-theme";
type Mode = "light" | "dark";
function readMode(): Mode {
  try { return localStorage.getItem(storageKey) === "light" ? "light" : "dark"; }
  catch { return "dark"; }
}
const ThemeContext = createContext({ dark: true, setDark: (_dark: boolean) => {} });
export const useConsoleTheme = () => useContext(ThemeContext);

export function ConsoleThemeProvider({ children }: { children: ReactNode }) {
  const [mode, setMode] = useState<Mode>(readMode);
  const setDark = (dark: boolean) => {
    const next = dark ? "dark" : "light";
    setMode(next);
    try { localStorage.setItem(storageKey, next); } catch { /* Theme still works when browser storage is unavailable. */ }
  };
  useEffect(() => {
    document.documentElement.dataset.theme = mode;
    document.documentElement.style.colorScheme = mode;
  }, [mode]);
  useEffect(() => {
    const sync = (event: StorageEvent) => {
      if (event.key === storageKey || event.key === null) setMode(readMode());
    };
    window.addEventListener("storage", sync);
    return () => window.removeEventListener("storage", sync);
  }, []);
  return <ThemeContext.Provider value={{ dark: mode === "dark", setDark }}>
    <FluentProvider theme={mode === "dark" ? gatewayDarkTheme : gatewayTheme}>{children}</FluentProvider>
  </ThemeContext.Provider>;
}
