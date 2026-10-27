export const SIGNUP_CONFIRMATION_MESSAGE =
  "Account created. Check your email to confirm your address before signing in.";

// Only same-site paths. Backslashes and control characters are refused too: browsers
// treat "/\host" like "//host".
export function safeAuthRedirect(redirect: string | undefined): string | undefined {
  if (!redirect?.startsWith("/") || redirect.startsWith("//") || redirect.includes("\\"))
    return undefined;
  for (let i = 0; i < redirect.length; i++) if (redirect.charCodeAt(i) < 0x20) return undefined;
  return redirect;
}

// OAuth providers return to the site root, so a QR deep link (/count/<token>) would be lost
// across a Google sign-in. The path waits in sessionStorage for a short while instead, and
// only a safe same-site path is ever stored or returned.
type RedirectStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;
const PENDING_AUTH_REDIRECT_KEY = "medspend.pendingAuthRedirect";
const PENDING_AUTH_REDIRECT_TTL_MS = 15 * 60 * 1000;

export function rememberPendingAuthRedirect(
  storage: RedirectStorage,
  redirect: string | undefined,
  now = Date.now(),
): void {
  const safe = safeAuthRedirect(redirect);
  if (safe) storage.setItem(PENDING_AUTH_REDIRECT_KEY, JSON.stringify({ path: safe, at: now }));
  else storage.removeItem(PENDING_AUTH_REDIRECT_KEY);
}

export function takePendingAuthRedirect(
  storage: RedirectStorage,
  now = Date.now(),
): string | undefined {
  const raw = storage.getItem(PENDING_AUTH_REDIRECT_KEY);
  if (!raw) return undefined;
  storage.removeItem(PENDING_AUTH_REDIRECT_KEY);
  try {
    const value = JSON.parse(raw) as { path?: unknown; at?: unknown };
    if (typeof value.path !== "string" || typeof value.at !== "number") return undefined;
    if (now - value.at > PENDING_AUTH_REDIRECT_TTL_MS || value.at > now) return undefined;
    return safeAuthRedirect(value.path);
  } catch {
    return undefined;
  }
}

export function confirmationRedirectUrl(origin: string, redirect?: string): string {
  const url = new URL("/auth/confirm", origin);
  const safeRedirect = safeAuthRedirect(redirect);
  if (safeRedirect) url.searchParams.set("redirect", safeRedirect);
  return url.toString();
}

export function authErrorMessage(error: unknown): string {
  const value = error as { message?: unknown; code?: unknown; status?: unknown } | null;
  const message = typeof value?.message === "string" ? value.message.toLowerCase() : "";
  const code = typeof value?.code === "string" ? value.code.toLowerCase() : "";

  if (
    code.includes("user_already_exists") ||
    message.includes("already registered") ||
    message.includes("already exists")
  ) {
    return "This email is already registered. Sign in instead.";
  }
  if (
    code.includes("email_address_invalid") ||
    message.includes("invalid email") ||
    message.includes("valid email")
  ) {
    return "Enter a valid email address.";
  }
  if (
    code.includes("weak_password") ||
    (message.includes("password") && (message.includes("weak") || message.includes("characters")))
  ) {
    return "Password is too weak. Use at least 6 characters.";
  }
  if (code.includes("email_not_confirmed") || message.includes("email not confirmed")) {
    return "Email not confirmed. Check your inbox and confirm your address before signing in.";
  }
  if (
    error instanceof TypeError ||
    message.includes("fetch") ||
    message.includes("network") ||
    message.includes("failed to fetch")
  ) {
    return "Network error. Check your connection and try again.";
  }
  return "Something went wrong. Please try again.";
}

export function validateCredentials(email: string, password: string): string | null {
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) return "Enter a valid email address.";
  if (password.length < 6) return "Password is too weak. Use at least 6 characters.";
  return null;
}
