import { Component, type ErrorInfo, type ReactNode } from "react";
import { Button, Body1 } from "@fluentui/react-components";
import { PageHeader } from "./PageHeader";

export class RouteErrorBoundary extends Component<
  { children: ReactNode; onReset: () => void },
  { failed: boolean }
> {
  state = { failed: false };

  static getDerivedStateFromError() {
    return { failed: true };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("Console page could not render", { name: error.name, componentStack: info.componentStack });
  }

  render() {
    if (!this.state.failed) return this.props.children;
    return (
      <section role="alert">
        <PageHeader title="This page could not be displayed" />
        <Body1 block>Your navigation is still available. Try this page again or choose another page.</Body1>
        <Button style={{ marginTop: 16 }} onClick={() => {
          this.props.onReset();
          this.setState({ failed: false });
        }}>Reload page data</Button>
      </section>
    );
  }
}
