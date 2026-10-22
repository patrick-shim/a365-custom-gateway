import { expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { FluentProvider, webLightTheme } from "@fluentui/react-components";
import { ApiError } from "../api/errors";
import { ErrorState } from "./ErrorState";

vi.mock("../auth/msal", () => ({
  apiScopes: ["api://test/access_as_user"],
  msalInstance: { loginRedirect: vi.fn() },
  satisfyApiClaimsChallenge: vi.fn(),
}));

it("explains temporary gateway availability and shows an active retry", async () => {
  let finish!: () => void;
  const retry = vi.fn(() => new Promise<void>(resolve => { finish = resolve; }));
  render(<FluentProvider theme={webLightTheme}>
    <ErrorState error={new ApiError("The Gateway returned HTTP 502.", 502)} onRetry={retry} />
  </FluentProvider>);

  expect(screen.getByRole("alert")).toHaveTextContent("Gateway API is not ready");
  await userEvent.setup().click(screen.getByRole("button", { name: "Try again" }));
  expect(screen.getByRole("button", { name: "Trying again…" })).toBeDisabled();
  finish();
  await waitFor(() => expect(screen.getByRole("button", { name: "Try again" })).toBeEnabled());
  expect(retry).toHaveBeenCalledOnce();
});

it("explains stale state without suggesting another blind mutation", () => {
  render(<FluentProvider theme={webLightTheme}>
    <ErrorState error={new ApiError("The response was lost.", 503, "REQUEST_UNCONFIRMED", undefined, true)} />
  </FluentProvider>);
  expect(screen.getByRole("alert")).toHaveTextContent("Refresh current state before submitting the change again");
  expect(screen.queryByRole("button", { name: "Try again" })).not.toBeInTheDocument();
});
