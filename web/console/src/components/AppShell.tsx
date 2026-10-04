import { Switch } from "@fluentui/react-components";
import { useConsoleTheme } from "./ConsoleThemeProvider";
import { ReactNode, useState } from "react";
import { NavLink, useLocation } from "react-router-dom";
import { Home24Regular, Bot24Regular, Settings24Regular, ShieldTask24Regular, PlugConnected24Regular, Flow24Regular, ShieldCheckmark24Regular, Navigation24Regular, Dismiss24Regular } from "@fluentui/react-icons";

const groups = [
  { label: "Workspace", items: [{ to: "/", label: "Home", icon: <Home24Regular />, end: true }] },
  { label: "Agents", items: [{ to: "/agents", label: "Agents", icon: <Bot24Regular /> }, { to: "/register", label: "Register agent", icon: <Flow24Regular /> }] },
  { label: "Data protection", items: [{ to: "/data-protection/policies", label: "Policies", icon: <ShieldTask24Regular /> }] },
  { label: "Settings", items: [{ to: "/settings", label: "Gateway settings", icon: <Settings24Regular />, end: true }, { to: "/settings/purview", label: "Purview connection", icon: <PlugConnected24Regular /> }] },
];

export function AppShell({ children }: { children: ReactNode }) {
  const location = useLocation();
  const { dark, setDark } = useConsoleTheme();
  const [menuOpen, setMenuOpen] = useState(false);
  const section = location.pathname.startsWith("/data-protection") ? "Data protection"
    : location.pathname.startsWith("/settings") ? "Settings"
    : location.pathname.startsWith("/agents") || location.pathname === "/register" ? "Agents" : "Overview";
  return (
    <div className="gateway-shell">
      <a className="skip-link" href="#main-content">Skip to content</a>
      <nav className="gateway-sidebar" aria-label="Primary">
        <div className="gateway-brand">
          <span className="gateway-mark" aria-hidden="true"><Flow24Regular /></span>
          <div><strong>A365 Gateway</strong><span>CONTROL CENTER</span></div>
        </div>
        <button className="mobile-nav-toggle" aria-label={menuOpen ? "Close navigation" : "Open navigation"} aria-expanded={menuOpen} aria-controls="gateway-navigation" onClick={() => setMenuOpen(!menuOpen)}>{menuOpen ? <Dismiss24Regular /> : <Navigation24Regular />}</button>
        <div id="gateway-navigation" className={`gateway-navigation${menuOpen ? " is-open" : ""}`}>
          {groups.map(group => <div className="nav-group" key={group.label}>
            <span className="nav-label">{group.label}</span>
            {group.items.map(item => <NavLink key={item.to} to={item.to} end={'end' in item ? item.end : false}
              onClick={() => setMenuOpen(false)} className={({ isActive }) => `nav-link${isActive ? ' is-active' : ''}`}>
              {item.icon}<span>{item.label}</span><span className="nav-indicator" aria-hidden="true" />
            </NavLink>)}
          </div>)}
        </div>
        <a className="nav-link" href="/docs" target="_blank" rel="noopener noreferrer"><Flow24Regular aria-hidden="true" /><span>API reference ↗</span></a>
        <div className="sidebar-note"><ShieldCheckmark24Regular aria-hidden="true" /><div><strong>Your agents. Connected.</strong><span>Identity, protection & visibility.</span></div></div>
      </nav>
      <div className="gateway-workspace">
        <header className="gateway-topbar">
          <div className="workspace-crumb">Workspace <span aria-hidden="true">/</span> <strong>{section}</strong></div>
          <div className="topbar-controls"><Switch label="Dark theme" checked={dark} onChange={(_, data) => setDark(data.checked)} /><span className="identity-label"><ShieldCheckmark24Regular aria-hidden="true" /> Microsoft Entra ID</span></div>
        </header>
        <main id="main-content" tabIndex={-1} className="gateway-content">
          <div className="route-surface" key={location.pathname}>{children}</div>
        </main>
        <footer className="workspace-footer"><span>A365 Gateway</span><span>One place to manage your agents.</span></footer>
      </div>
    </div>
  );
}
