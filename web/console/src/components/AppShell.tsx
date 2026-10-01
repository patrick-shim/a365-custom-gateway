import { ReactNode } from "react";
import { NavLink, useLocation } from "react-router-dom";
import { makeStyles, tokens, Text, Caption1, Badge } from "@fluentui/react-components";
import {
  Home24Regular,
  Bot24Regular,
  Settings24Regular,
  ShieldTask24Regular,
  PlugConnected24Regular,
  Database24Regular,
  Flow24Regular,
} from "@fluentui/react-icons";
import { usingMock } from "../api/client";

const useStyles = makeStyles({
  app: {
    display: "grid",
    gridTemplateColumns: "260px 1fr",
    minHeight: "100vh",
    backgroundColor: tokens.colorNeutralBackground2,
  },
  sidebar: {
    backgroundColor: tokens.colorNeutralBackground1,
    borderRight: `1px solid ${tokens.colorNeutralStroke2}`,
    display: "flex",
    flexDirection: "column",
    padding: `${tokens.spacingVerticalL} ${tokens.spacingHorizontalM}`,
    gap: tokens.spacingVerticalM,
  },
  brand: {
    display: "flex",
    alignItems: "center",
    gap: tokens.spacingHorizontalS,
    padding: `0 ${tokens.spacingHorizontalS}`,
  },
  brandMark: {
    width: "32px",
    height: "32px",
    borderRadius: tokens.borderRadiusMedium,
    background: `linear-gradient(135deg, ${tokens.colorBrandBackground}, ${tokens.colorPaletteBerryBackground3})`,
  },
  group: { display: "flex", flexDirection: "column", gap: "2px" },
  groupLabel: {
    textTransform: "uppercase",
    letterSpacing: "0.04em",
    color: tokens.colorNeutralForeground3,
    padding: `${tokens.spacingVerticalS} ${tokens.spacingHorizontalS} ${tokens.spacingVerticalXS}`,
  },
  link: {
    display: "flex",
    alignItems: "center",
    gap: tokens.spacingHorizontalS,
    padding: `${tokens.spacingVerticalSNudge} ${tokens.spacingHorizontalS}`,
    borderRadius: tokens.borderRadiusMedium,
    color: tokens.colorNeutralForeground1,
    textDecoration: "none",
    fontSize: tokens.fontSizeBase300,
  },
  linkActive: {
    backgroundColor: tokens.colorNeutralBackground1Selected,
    fontWeight: tokens.fontWeightSemibold,
  },
  main: { display: "flex", flexDirection: "column", minWidth: 0 },
  topbar: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: `${tokens.spacingVerticalM} ${tokens.spacingHorizontalXXL}`,
    borderBottom: `1px solid ${tokens.colorNeutralStroke2}`,
    backgroundColor: tokens.colorNeutralBackground1,
  },
  content: {
    padding: tokens.spacingVerticalXXL,
    maxWidth: "1100px",
    width: "100%",
  },
  spacer: { flex: 1 },
  footer: { marginTop: "auto", padding: tokens.spacingHorizontalS },
});

interface NavItem {
  to: string;
  label: string;
  icon: ReactNode;
  end?: boolean;
}

const homeItems: NavItem[] = [
  { to: "/", label: "Home", icon: <Home24Regular />, end: true },
];

const agentItems: NavItem[] = [
  { to: "/agents", label: "Agents", icon: <Bot24Regular /> },
  { to: "/register", label: "Register agent", icon: <Flow24Regular /> },
];

const dataProtectionItems: NavItem[] = [
  { to: "/data-protection/connection", label: "Connection", icon: <PlugConnected24Regular /> },
  { to: "/data-protection/classifiers", label: "Classifiers", icon: <Database24Regular /> },
  { to: "/data-protection/policies", label: "Policies", icon: <ShieldTask24Regular /> },
];

const platformItems: NavItem[] = [
  { to: "/platform", label: "Platform", icon: <Settings24Regular /> },
];

export function AppShell({ children }: { children: ReactNode }) {
  const styles = useStyles();
  const location = useLocation();
  const section = location.pathname.startsWith("/data-protection")
    ? "Data Protection"
    : "Gateway Console";

  return (
    <div className={styles.app}>
      <nav className={styles.sidebar} aria-label="Primary">
        <div className={styles.brand}>
          <div className={styles.brandMark} aria-hidden />
          <div>
            <Text weight="semibold">A365 Gateway</Text>
            <Caption1 block>Control center</Caption1>
          </div>
        </div>

        <NavGroup label="" items={homeItems} />
        <NavGroup label="Agents" items={agentItems} />
        <NavGroup label="Data protection" items={dataProtectionItems} />
        <NavGroup label="Platform" items={platformItems} />

        <div className={styles.footer}>
          {usingMock && <Badge appearance="tint" color="informative">Demo data</Badge>}
        </div>
      </nav>

      <div className={styles.main}>
        <header className={styles.topbar}>
          <Text weight="semibold">{section}</Text>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <Badge appearance="outline" color="success">Identity protected · Microsoft Entra ID</Badge>
          </div>
        </header>
        <div className={styles.content}>{children}</div>
      </div>
    </div>
  );

  function NavGroup({ label, items }: { label: string; items: NavItem[] }) {
    return (
      <div className={styles.group}>
        {label && <Caption1 className={styles.groupLabel}>{label}</Caption1>}
        {items.map((item) => (
          <NavLink
            key={item.to}
            to={item.to}
            end={item.end}
            className={({ isActive }) =>
              isActive ? `${styles.link} ${styles.linkActive}` : styles.link
            }
          >
            {item.icon}
            {item.label}
          </NavLink>
        ))}
      </div>
    );
  }
}
