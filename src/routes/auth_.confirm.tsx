import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import type { EmailOtpType } from "@supabase/supabase-js";
import { z } from "zod";
import { supabase } from "@/integrations/supabase/client";
import { safeAuthRedirect } from "@/lib/auth-ux";
import { SportSpendLogo } from "@/components/brand/SportSpendLogo";

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
    meta: [{ title: "Confirm email — SportSpend" }, { name: "robots", content: "noindex" }],
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
    return () => {
      active = false;
    };
  }, [search.code, search.error, search.error_description, search.token_hash, search.type]);

  return (
    <div className="sportspend-auth sp-confirm-page">
      <div className="sp-confirm-panel">
        <a href="/" aria-label="SportSpend home">
          <SportSpendLogo className="sp-confirm-logo" />
        </a>
        {status === "checking" && (
          <p className="mt-4 text-sm text-muted-foreground">Confirming your email…</p>
        )}
        {status === "confirmed" && (
          <>
            <h1 className="mt-4 text-xl font-semibold">Email confirmed</h1>
            <p className="mt-2 text-sm text-muted-foreground">
              Your address is confirmed. You can now sign in to SportSpend.
            </p>
            <a href={signInHref} className="sp-confirm-primary">
              Continue to sign in
            </a>
          </>
        )}
        {status === "invalid" && (
          <>
            <h1 className="mt-4 text-xl font-semibold">Confirmation link unavailable</h1>
            <p className="mt-2 text-sm text-muted-foreground">
              This confirmation link is invalid or has expired. Request a new confirmation email and
              try again.
            </p>
            <a href={signInHref} className="sp-confirm-secondary">
              Return to sign in
            </a>
          </>
        )}
      </div>
    </div>
  );
}
