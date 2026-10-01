export class ApiError extends Error {
  constructor(
    message: string,
    public readonly status: number,
    public readonly code?: string,
    public readonly correlationId?: string,
    public readonly outcomeUnknown = false,
  ) {
    super(message);
    this.name = "ApiError";
  }
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
