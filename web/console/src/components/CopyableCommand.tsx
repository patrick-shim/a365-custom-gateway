import { useState } from "react";
import {
  Button,
  Caption1,
  Field,
  Textarea,
  makeStyles,
  tokens,
} from "@fluentui/react-components";
import { Copy24Regular, Checkmark24Regular } from "@fluentui/react-icons";

const useStyles = makeStyles({
  root: {
    display: "flex",
    flexDirection: "column",
    gap: tokens.spacingVerticalXS,
  },
  row: {
    display: "flex",
    alignItems: "flex-start",
    gap: tokens.spacingHorizontalS,
  },
  mono: {
    flex: 1,
    fontFamily: tokens.fontFamilyMonospace,
  },
});

export function CopyableCommand({
  label,
  command,
  rows = 2,
}: {
  label: string;
  command: string;
  rows?: number;
}) {
  const styles = useStyles();
  const [copied, setCopied] = useState(false);
  const [failed, setFailed] = useState(false);

  async function copy() {
    try {
      setFailed(false);
      await navigator.clipboard.writeText(command);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      setCopied(false);
      setFailed(true);
    }
  }

  return (
    <Field label={label} className={styles.root}>
      <div className={styles.row}>
        <Textarea
          className={styles.mono}
          value={command}
          readOnly
          rows={rows}
          resize="vertical"
          aria-label={label}
        />
        <Button
          appearance="secondary"
          icon={copied ? <Checkmark24Regular /> : <Copy24Regular />}
          onClick={copy}
        >
          {copied ? "Copied" : "Copy"}
        </Button>
      </div>
      <Caption1 role={failed ? "alert" : undefined}>
        {failed ? "Clipboard access was blocked. Select the text and copy it manually." : "You can also select the text and copy it manually."}
      </Caption1>
    </Field>
  );
}
