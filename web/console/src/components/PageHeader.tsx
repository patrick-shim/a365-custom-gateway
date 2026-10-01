import { ReactNode } from "react";
import { makeStyles, tokens, Title2, Body1 } from "@fluentui/react-components";

const useStyles = makeStyles({
  root: { marginBottom: tokens.spacingVerticalXL },
  sub: { color: tokens.colorNeutralForeground2, marginTop: tokens.spacingVerticalXS },
  actions: { marginTop: tokens.spacingVerticalM, display: "flex", gap: tokens.spacingHorizontalS },
});

export function PageHeader({
  title,
  subtitle,
  actions,
}: {
  title: string;
  subtitle?: string;
  actions?: ReactNode;
}) {
  const styles = useStyles();
  return (
    <div className={styles.root}>
      <Title2 as="h1" style={{ margin: 0 }}>{title}</Title2>
      {subtitle && <Body1 className={styles.sub} block>{subtitle}</Body1>}
      {actions && <div className={styles.actions}>{actions}</div>}
    </div>
  );
}
