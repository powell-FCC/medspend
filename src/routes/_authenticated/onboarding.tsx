import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useServerFn } from "@tanstack/react-start";
import { useQueryClient } from "@tanstack/react-query";
import { createOrganizationFn } from "@/lib/orgs.functions";

export const Route = createFileRoute("/_authenticated/onboarding")({
  head: () => ({ meta: [{ title: "Get started — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: Onboarding,
});

function Onboarding() {
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const create = useServerFn(createOrganizationFn);
  const qc = useQueryClient();
  const navigate = useNavigate();

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr(null);
    try {
      const res = await create({ data: { name } });
      window.localStorage.setItem("medspend.activeOrgId", res.organizationId);
      await qc.invalidateQueries({ queryKey: ["me", "memberships"] });
      navigate({ to: "/dashboard", replace: true });
    } catch (e) {
      setErr(e instanceof Error ? e.message : "Failed to create organization");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-background px-4">
      <div className="w-full max-w-md rounded-xl border bg-card p-6">
        <h1 className="text-lg font-semibold">Get started with MedSpend</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Create an organization to manage supply requests and purchasing for your team.
        </p>
        <p className="mt-3 text-xs text-muted-foreground">
          Waiting on an invitation? Ask your admin for the invite link and open it here.
        </p>
        <form onSubmit={submit} className="mt-6 space-y-3">
          <label className="block text-sm">
            <span className="text-muted-foreground">Organization name</span>
            <input
              className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
              placeholder="e.g. FC Cincinnati"
              value={name}
              onChange={(e) => setName(e.target.value)}
              required
            />
          </label>
          {err && <div className="text-xs text-destructive">{err}</div>}
          <button
            type="submit"
            disabled={busy || !name.trim()}
            className="w-full rounded-md bg-primary text-primary-foreground px-3 py-2 text-sm font-medium disabled:opacity-60"
          >
            {busy ? "Creating…" : "Create organization"}
          </button>
        </form>
      </div>
    </div>
  );
}