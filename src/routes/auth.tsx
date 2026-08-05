import { createFileRoute, useNavigate, useSearch } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import { z } from "zod";
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
      { title: "Sign in — MedSpend" },
      { name: "description", content: "Sign in to your MedSpend organization." },
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
    const result = await lovable.auth.signInWithOAuth("google", { redirect_uri: window.location.origin });
    if (result.error) setErr(String(result.error.message ?? "Google sign-in failed"));
    if (result.redirected) return;
    const { data } = await supabase.auth.getSession();
    if (data.session) navigate({ to: safeAuthRedirect(redirect) ?? "/dashboard", replace: true });
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-background px-4">
      <div className="w-full max-w-sm">
        <div className="text-center mb-6">
          <div className="font-semibold tracking-tight text-lg">MedSpend</div>
          <p className="text-sm text-muted-foreground mt-1">
            {mode === "signin" ? "Sign in to your account" : "Create your account"}
          </p>
        </div>
        <div className="rounded-xl border bg-card p-6 shadow-sm">
          <button
            onClick={google}
            className="w-full rounded-md border px-3 py-2 text-sm font-medium hover:bg-muted"
          >
            Continue with Google
          </button>
          <div className="my-4 flex items-center gap-2 text-xs text-muted-foreground">
            <div className="flex-1 h-px bg-border" /> or <div className="flex-1 h-px bg-border" />
          </div>
          <form onSubmit={submit} className="space-y-3" noValidate>
            {mode === "signup" && (
              <input
                className="w-full rounded-md border bg-background px-3 py-2 text-sm"
                placeholder="Full name"
                value={fullName}
                onChange={(e) => setFullName(e.target.value)}
                required
              />
            )}
            <input
              className="w-full rounded-md border bg-background px-3 py-2 text-sm"
              type="email"
              placeholder="Email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
            />
            <input
              className="w-full rounded-md border bg-background px-3 py-2 text-sm"
              type="password"
              placeholder="Password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              minLength={6}
              required
            />
            {success && <div role="status" className="rounded-md border border-primary/30 bg-primary/5 p-3 text-sm text-foreground">{success}</div>}
            {err && <div role="alert" className="text-xs text-destructive">{err}</div>}
            <button
              type="submit"
              disabled={loading}
              className="w-full rounded-md bg-primary text-primary-foreground px-3 py-2 text-sm font-medium disabled:opacity-60"
            >
              {loading ? (mode === "signin" ? "Signing in…" : "Creating account…") : mode === "signin" ? "Sign in" : "Create account"}
            </button>
          </form>
          <button
            className="mt-4 w-full text-xs text-muted-foreground hover:text-foreground"
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
      </div>
    </div>
  );
}
