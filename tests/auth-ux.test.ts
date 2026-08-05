import assert from "node:assert/strict";
import test from "node:test";
import {
  SIGNUP_CONFIRMATION_MESSAGE,
  authErrorMessage,
  confirmationRedirectUrl,
  safeAuthRedirect,
  validateCredentials,
} from "../src/lib/auth-ux.ts";

test("confirmation URL uses the current origin and preserves an internal invite redirect", () => {
  assert.equal(
    confirmationRedirectUrl("https://medspend.example", "/join/invite-token"),
    "https://medspend.example/auth/confirm?redirect=%2Fjoin%2Finvite-token",
  );
  assert.equal(confirmationRedirectUrl("http://localhost:8080"), "http://localhost:8080/auth/confirm");
});

test("unsafe redirects are discarded", () => {
  assert.equal(safeAuthRedirect("https://attacker.example"), undefined);
  assert.equal(safeAuthRedirect("//attacker.example"), undefined);
});

test("signup confirmation copy is exact", () => {
  assert.equal(SIGNUP_CONFIRMATION_MESSAGE, "Account created. Check your email to confirm your address before signing in.");
});

test("credential validation distinguishes invalid email and weak password", () => {
  assert.equal(validateCredentials("not-an-email", "long-enough"), "Enter a valid email address.");
  assert.equal(validateCredentials("person@example.com", "123"), "Password is too weak. Use at least 6 characters.");
});

test("safe auth errors are categorized", () => {
  assert.match(authErrorMessage({ code: "user_already_exists" }), /already registered/);
  assert.match(authErrorMessage({ code: "email_not_confirmed" }), /Email not confirmed/);
  assert.match(authErrorMessage(new TypeError("Failed to fetch")), /Network error/);
  assert.equal(authErrorMessage(new Error("database exploded")), "Something went wrong. Please try again.");
});
