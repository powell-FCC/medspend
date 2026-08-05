export const SIGNUP_CONFIRMATION_MESSAGE =
  "Account created. Check your email to confirm your address before signing in.";

export function safeAuthRedirect(redirect: string | undefined): string | undefined {
  return redirect?.startsWith("/") && !redirect.startsWith("//") ? redirect : undefined;
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

  if (code.includes("user_already_exists") || message.includes("already registered") || message.includes("already exists")) {
    return "This email is already registered. Sign in instead.";
  }
  if (code.includes("email_address_invalid") || message.includes("invalid email") || message.includes("valid email")) {
    return "Enter a valid email address.";
  }
  if (code.includes("weak_password") || message.includes("password") && (message.includes("weak") || message.includes("characters"))) {
    return "Password is too weak. Use at least 6 characters.";
  }
  if (code.includes("email_not_confirmed") || message.includes("email not confirmed")) {
    return "Email not confirmed. Check your inbox and confirm your address before signing in.";
  }
  if (error instanceof TypeError || message.includes("fetch") || message.includes("network") || message.includes("failed to fetch")) {
    return "Network error. Check your connection and try again.";
  }
  return "Something went wrong. Please try again.";
}

export function validateCredentials(email: string, password: string): string | null {
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) return "Enter a valid email address.";
  if (password.length < 6) return "Password is too weak. Use at least 6 characters.";
  return null;
}
