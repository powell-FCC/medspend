import { createFileRoute, Link, useNavigate, useSearch } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import { z } from "zod";
import { ArrowLeft, LockKeyhole } from "lucide-react";
import { SportSpendLogo } from "@/components/brand/SportSpendLogo";
import { supabase } from "@/integrations/supabase/client";
import { lovable } from "@/integrations/lovable/index";
import {
  SIGNUP_CONFIRMATION_MESSAGE,
  authErrorMessage,
  confirmationRedirectUrl,
  safeAuthRedirect,
  validateCredentials,
} from "@/lib/auth-ux";

const searchSchema = z.object({ redirect: z.string().optional() });

export const Route = createFileRoute("/auth")({
  validateSearch: (s) => searchSchema.parse(s),
  head: () => ({
    meta: [
      { title: "Sign in — SportSpend" },
      { name: "description", content: "Sign in to your SportSpend organization." },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: AuthPage,
});

function AuthPage() {
  const navigate = useNavigate();
  const { redirect } = useSearch({ from: "/auth" });
  const [mode, setMode] = useState<"signin" | "signup">("signin");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [fullName, setFullName] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const submittingRef = useRef(false);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      if (data.session) navigate({ to: safeAuthRedirect(redirect) ?? "/dashboard", replace: true });
    });
  }, [navigate, redirect]);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (submittingRef.current) return;
    setErr(null);
    setSuccess(null);
    const validationError = validateCredentials(email, password);
    if (validationError) {
      setErr(validationError);
      return;
    }
    if (mode === "signup" && !fullName.trim()) {
      setErr("Enter your full name.");
      return;
    }
    submittingRef.current = true;
    setLoading(true);
    try {
      if (mode === "signup") {
        const { data: signupData, error } = await supabase.auth.signUp({
          email,
          password,
          options: {
            emailRedirectTo: confirmationRedirectUrl(window.location.origin, redirect),
            data: { full_name: fullName },
          },
        });
        if (error) throw error;
        if (signupData.user?.identities?.length === 0) {
          setErr("This email is already registered. Sign in instead.");
          return;
        }
        if (!signupData.session) {
          setSuccess(SIGNUP_CONFIRMATION_MESSAGE);
          return;
        }
      } else {
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
      }
      const { data } = await supabase.auth.getSession();
      if (data.session) navigate({ to: safeAuthRedirect(redirect) ?? "/dashboard", replace: true });
    } catch (e: unknown) {
      setErr(authErrorMessage(e));
    } finally {
      submittingRef.current = false;
      setLoading(false);
    }
  }

  async function google() {
    setErr(null);
    const result = await lovable.auth.signInWithOAuth("google", {
      redirect_uri: window.location.origin,
    });
    if (result.error) setErr(String(result.error.message ?? "Google sign-in failed"));
    if (result.redirected) return;
    const { data } = await supabase.auth.getSession();
    if (data.session) navigate({ to: safeAuthRedirect(redirect) ?? "/dashboard", replace: true });
  }

  return (
    <div className="sportspend-auth">
      <aside className="sp-auth-story" aria-label="SportSpend">
        <div className="sp-auth-story-inner">
          <Link to="/" className="sp-auth-logo-link" aria-label="Back to SportSpend home">
            <SportSpendLogo className="sp-auth-story-logo" />
          </Link>
          <div className="sp-auth-story-copy">
            <p className="sp-eyebrow">
              <span />
              Built for athletic operations
            </p>
            <h1>Keep every request, approval, and purchase moving.</h1>
            <p>One clear workspace for staff and sports operations leaders.</p>
          </div>
        </div>
      </aside>

      <main className="sp-auth-main">
        <div className="sp-auth-panel">
          <Link to="/" className="sp-auth-back">
            <ArrowLeft aria-hidden="true" />
            Back to home
          </Link>
          <SportSpendLogo className="sp-auth-mobile-logo" />
          <div className="sp-auth-heading">
            <span>
              <LockKeyhole aria-hidden="true" />
            </span>
            <div>
              <p>{mode === "signin" ? "Welcome back" : "Get started"}</p>
              <h1>{mode === "signin" ? "Sign in to SportSpend" : "Create your account"}</h1>
            </div>
          </div>
          <p className="sp-auth-intro">
            {mode === "signin"
              ? "Access your organization’s supply workspace."
              : "Create your login, then set up or join your organization."}
          </p>
          <button onClick={google} className="sp-auth-google">
            Continue with Google
          </button>
          <div className="sp-auth-divider">
            <div /> <span>or continue with email</span> <div />
          </div>
          <form onSubmit={submit} className="sp-auth-form" noValidate>
            {mode === "signup" && (
              <label>
                <span>Full name</span>
                <input
                  autoComplete="name"
                  placeholder="Your full name"
                  value={fullName}
                  onChange={(e) => setFullName(e.target.value)}
                  required
                />
              </label>
            )}
            <label>
              <span>Email</span>
              <input
                autoComplete="email"
                type="email"
                placeholder="you@organization.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                required
              />
            </label>
            <label>
              <span>Password</span>
              <input
                autoComplete={mode === "signin" ? "current-password" : "new-password"}
                type="password"
                placeholder="At least 6 characters"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                minLength={6}
                required
              />
            </label>
            {success && (
              <div role="status" className="sp-auth-success">
                {success}
              </div>
            )}
            {err && (
              <div role="alert" className="sp-auth-error">
                {err}
              </div>
            )}
            <button type="submit" disabled={loading} className="sp-auth-submit">
              {loading
                ? mode === "signin"
                  ? "Signing in…"
                  : "Creating account…"
                : mode === "signin"
                  ? "Sign in"
                  : "Create account"}
            </button>
          </form>
          <button
            className="sp-auth-mode"
            disabled={loading}
            onClick={() => {
              setMode(mode === "signin" ? "signup" : "signin");
              setErr(null);
              setSuccess(null);
            }}
          >
            {mode === "signin" ? "Need an account? Sign up" : "Have an account? Sign in"}
          </button>
        </div>
      </main>
    </div>
  );
}
