export type AuthorizationChallenge =
  | { kind: "claims"; claims: string }
  | { kind: "consent"; scopes: string[] }
  | { kind: "unavailable" };

export class ApiError extends Error {
  constructor(
    message: string,
    public readonly status: number,
    public readonly code?: string,
    public readonly correlationId?: string,
    public readonly outcomeUnknown = false,
    public readonly authorizationChallenge?: AuthorizationChallenge,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export function readAuthorizationChallenge(header: string | null): AuthorizationChallenge {
  if (!header || header.length > 32_768 || !/^Bearer\s/i.test(header)) return { kind: "unavailable" };
  const fields = new Map<string, string>();
  for (const match of header.replace(/^Bearer\s+/i, "").matchAll(/(?:^|,\s*)([a-z_]+)="((?:[^"\\]|\\.)*)"/gi)) {
    const key = match[1].toLowerCase();
    if (fields.has(key)) return { kind: "unavailable" };
    fields.set(key, match[2].replace(/\\(["\\])/g, "$1"));
  }
  if (fields.get("error") === "insufficient_claims") {
    try {
      const bytes = Uint8Array.from(atob(fields.get("claims") ?? ""), char => char.charCodeAt(0));
      const claims = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
      const value: unknown = JSON.parse(claims);
      if (value && typeof value === "object" && !Array.isArray(value) && "access_token" in value &&
        value.access_token && typeof value.access_token === "object" && !Array.isArray(value.access_token)) {
        return { kind: "claims", claims };
      }
    } catch {
      // An invalid challenge must be visible, not used for another token request.
    }
  } else if (fields.get("error") === "insufficient_scope") {
    const scopes = (fields.get("scope") ?? "").split(" ").filter(Boolean);
    if (scopes.length <= 20 && scopes.every(scope =>
      scope.length <= 256 && /^(?:https:\/\/graph\.microsoft\.com\/)?[A-Za-z][A-Za-z0-9._-]+$/.test(scope))) {
      return { kind: "consent", scopes };
    }
  }
  return { kind: "unavailable" };
}

export class SignInRequiredError extends Error {
  constructor() {
    super("Your session needs attention. Sign in again to continue.");
    this.name = "SignInRequiredError";
  }
}

export function errorMessage(error: unknown): string {
  if (error instanceof ApiError || error instanceof SignInRequiredError) return error.message;
  return "Something went wrong. Try again; if it continues, contact your Gateway administrator.";
}
