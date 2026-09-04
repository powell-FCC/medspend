import { createFileRoute, useNavigate, useParams } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useServerFn } from "@tanstack/react-start";
import { supabase } from "@/integrations/supabase/client";
import { acceptInvitationFn } from "@/lib/orgs.functions";
import { useQueryClient } from "@tanstack/react-query";

export const Route = createFileRoute("/join/$token")({
  head: () => ({
    meta: [{ title: "Join organization — SportSpend" }, { name: "robots", content: "noindex" }],
  }),
  component: JoinPage,
});

function JoinPage() {
  const { token } = useParams({ from: "/join/$token" });
  const navigate = useNavigate();
  const accept = useServerFn(acceptInvitationFn);
  const qc = useQueryClient();
  const [status, setStatus] = useState<"checking" | "need-auth" | "accepting" | "error">(
    "checking",
  );
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const { data } = await supabase.auth.getSession();
      if (!data.session) {
        setStatus("need-auth");
        return;
      }
      setStatus("accepting");
      try {
        const res = await accept({ data: { token } });
        await qc.invalidateQueries({ queryKey: ["me", "memberships"] });
        if (typeof window !== "undefined") {
          window.localStorage.setItem("medspend.activeOrgId", res.organizationId);
        }
        navigate({ to: res.route, replace: true });
      } catch (e) {
        setStatus("error");
        setMsg(e instanceof Error ? e.message : "Failed to accept invitation");
      }
    })();
  }, [token, accept, navigate, qc]);

  return (
    <div className="min-h-screen flex items-center justify-center bg-background px-4">
      <div className="max-w-sm w-full rounded-xl border bg-card p-6 text-center">
        <div className="font-semibold">Join organization</div>
        {status === "checking" && <p className="mt-3 text-sm text-muted-foreground">Checking…</p>}
        {status === "accepting" && (
          <p className="mt-3 text-sm text-muted-foreground">Accepting invitation…</p>
        )}
        {status === "need-auth" && (
          <div className="mt-4">
            <p className="text-sm text-muted-foreground">Sign in to accept your invitation.</p>
            <a
              className="mt-4 inline-block rounded-md bg-primary text-primary-foreground px-4 py-2 text-sm"
              href={`/auth?redirect=${encodeURIComponent(`/join/${token}`)}`}
            >
              Sign in
            </a>
          </div>
        )}
        {status === "error" && (
          <div className="mt-4">
            <p className="text-sm text-destructive">{msg}</p>
            <a className="mt-4 inline-block text-xs text-muted-foreground underline" href="/">
              Go home
            </a>
          </div>
        )}
      </div>
    </div>
  );
}
