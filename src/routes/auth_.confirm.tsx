import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import type { EmailOtpType } from "@supabase/supabase-js";
import { z } from "zod";
import { supabase } from "@/integrations/supabase/client";
import { safeAuthRedirect } from "@/lib/auth-ux";

const searchSchema = z.object({
  code: z.string().optional(),
  token_hash: z.string().optional(),
  type: z.string().optional(),
  error: z.string().optional(),
  error_description: z.string().optional(),
  redirect: z.string().optional(),
});

export const Route = createFileRoute("/auth_/confirm")({
  validateSearch: (search) => searchSchema.parse(search),
  head: () => ({
    meta: [
      { title: "Confirm email — MedSpend" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: ConfirmEmailPage,
});

function ConfirmEmailPage() {
  const search = Route.useSearch();
  const [status, setStatus] = useState<"checking" | "confirmed" | "invalid">("checking");
  const redirect = safeAuthRedirect(search.redirect);
  const signInHref = redirect ? `/auth?redirect=${encodeURIComponent(redirect)}` : "/auth";

  useEffect(() => {
    let active = true;
    (async () => {
      try {
        if (search.error || search.error_description) throw new Error("callback error");

        let callbackError: Error | null = null;
        if (search.code) {
          const { error } = await supabase.auth.exchangeCodeForSession(search.code);
          callbackError = error;
        } else if (search.token_hash && search.type) {
          const allowedTypes = new Set(["signup", "email", "invite", "email_change"]);
          if (!allowedTypes.has(search.type)) throw new Error("unsupported confirmation type");
          const { error } = await supabase.auth.verifyOtp({
            token_hash: search.token_hash,
            type: search.type as EmailOtpType,
          });
          callbackError = error;
        }

        const { data } = await supabase.auth.getSession();
        if (callbackError && !data.session) throw callbackError;
        if (!data.session) throw new Error("missing confirmation session");

        await supabase.auth.signOut({ scope: "local" });
        if (active) setStatus("confirmed");
      } catch {
        if (active) setStatus("invalid");
      }
    })();
    return () => { active = false; };
  }, [search.code, search.error, search.error_description, search.token_hash, search.type]);

  return (
    <div className="min-h-screen flex items-center justify-center bg-background px-4">
      <div className="w-full max-w-sm rounded-xl border bg-card p-6 text-center shadow-sm">
        <div className="font-semibold tracking-tight text-lg">MedSpend</div>
        {status === "checking" && <p className="mt-4 text-sm text-muted-foreground">Confirming your email…</p>}
        {status === "confirmed" && (
          <>
            <h1 className="mt-4 text-xl font-semibold">Email confirmed</h1>
            <p className="mt-2 text-sm text-muted-foreground">Your address is confirmed. You can now sign in to MedSpend.</p>
            <a href={signInHref} className="mt-5 inline-flex rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground">Continue to sign in</a>
          </>
        )}
        {status === "invalid" && (
          <>
            <h1 className="mt-4 text-xl font-semibold">Confirmation link unavailable</h1>
            <p className="mt-2 text-sm text-muted-foreground">This confirmation link is invalid or has expired. Request a new confirmation email and try again.</p>
            <a href={signInHref} className="mt-5 inline-flex rounded-md border px-4 py-2 text-sm font-medium">Return to sign in</a>
          </>
        )}
      </div>
    </div>
  );
}
