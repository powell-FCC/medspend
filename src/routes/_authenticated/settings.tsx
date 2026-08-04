import { createFileRoute } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useState } from "react";
import { useActiveOrg } from "@/hooks/use-active-org";
import { createInvitationFn, listOrgInvitesFn, listOrgMembersFn, revokeInvitationFn } from "@/lib/orgs.functions";
import {
  createOrgStructureFn,
  listOrgStructureFn,
  updateOrgStructureFn,
} from "@/lib/org-structure.functions";

export const Route = createFileRoute("/_authenticated/settings")({
  head: () => ({ meta: [{ title: "Settings — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: Page,
});

function Page() {
  const { active } = useActiveOrg();
  const listInvites = useServerFn(listOrgInvitesFn);
  const listMembers = useServerFn(listOrgMembersFn);
  const create = useServerFn(createInvitationFn);
  const revoke = useServerFn(revokeInvitationFn);
  const qc = useQueryClient();

  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [role, setRole] = useState<"staff" | "admin">("staff");
  const [lastLink, setLastLink] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const invitesQ = useQuery({
    queryKey: ["org", active?.organizationId, "invites"],
    queryFn: () => listInvites({ data: { organizationId: active!.organizationId } }),
    enabled: !!active,
  });
  const membersQ = useQuery({
    queryKey: ["org", active?.organizationId, "members"],
    queryFn: () => listMembers({ data: { organizationId: active!.organizationId } }),
    enabled: !!active,
  });

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    try {
      const res = await create({
        data: { organizationId: active!.organizationId, email, name, role },
      });
      const link = `${window.location.origin}/join/${res.token}`;
      setLastLink(link);
      setEmail("");
      setName("");
      await qc.invalidateQueries({ queryKey: ["org", active?.organizationId, "invites"] });
    } catch (e) {
      setErr(e instanceof Error ? e.message : "Failed to create invitation");
    }
  }

  if (!active) return null;

  return (
    <div className="max-w-4xl mx-auto px-6 py-8 space-y-8">
      <div>
        <h1 className="text-2xl font-semibold">Settings</h1>
        <div className="text-sm text-muted-foreground">{active.organizationName}</div>
      </div>

      <section className="rounded-xl border bg-card p-5">
        <h2 className="font-medium">Invite staff</h2>
        <form onSubmit={submit} className="mt-3 grid gap-2 md:grid-cols-4">
          <input
            className="rounded-md border bg-background px-3 py-2 text-sm"
            placeholder="Email"
            type="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
          <input
            className="rounded-md border bg-background px-3 py-2 text-sm"
            placeholder="Name (optional)"
            value={name}
            onChange={(e) => setName(e.target.value)}
          />
          <select
            className="rounded-md border bg-background px-3 py-2 text-sm"
            value={role}
            onChange={(e) => setRole(e.target.value as "staff" | "admin")}
          >
            <option value="staff">Staff</option>
            <option value="admin">Admin</option>
          </select>
          <button className="rounded-md bg-primary text-primary-foreground px-3 py-2 text-sm">Create invite</button>
        </form>
        {err && <div className="mt-2 text-xs text-destructive">{err}</div>}
        {lastLink && (
          <div className="mt-3 rounded-md border border-dashed bg-muted p-3 text-xs break-all">
            <div className="font-medium mb-1">Share this one-time invitation link:</div>
            <a href={lastLink} className="underline">
              {lastLink}
            </a>
          </div>
        )}
      </section>

      <section className="rounded-xl border bg-card p-5">
        <h2 className="font-medium">Pending invitations</h2>
        <ul className="mt-3 divide-y">
          {(invitesQ.data ?? [])
            .filter((i) => !i.accepted_at && !i.revoked_at)
            .map((i) => (
              <li key={i.id} className="py-2 flex items-center justify-between text-sm">
                <div>
                  <div>{i.invited_email}</div>
                  <div className="text-xs text-muted-foreground">
                    {i.invited_role} · expires {new Date(i.expires_at).toLocaleDateString()}
                  </div>
                </div>
                <button
                  className="text-xs underline text-destructive"
                  onClick={async () => {
                    await revoke({ data: { id: i.id } });
                    await qc.invalidateQueries({ queryKey: ["org", active.organizationId, "invites"] });
                  }}
                >
                  Revoke
                </button>
              </li>
            ))}
          {(invitesQ.data ?? []).filter((i) => !i.accepted_at && !i.revoked_at).length === 0 && (
            <li className="py-2 text-sm text-muted-foreground">No pending invitations.</li>
          )}
        </ul>
      </section>

      <section className="rounded-xl border bg-card p-5">
        <h2 className="font-medium">Members</h2>
        <ul className="mt-3 divide-y">
          {(membersQ.data ?? []).map((m) => (
            <li key={m.id} className="py-2 flex items-center justify-between text-sm">
              <div>
                <div>{m.fullName ?? m.email ?? m.userId}</div>
                <div className="text-xs text-muted-foreground">{m.email}</div>
              </div>
              <div className="text-xs uppercase tracking-wider text-primary">{m.role}</div>
            </li>
          ))}
        </ul>
      </section>

      <StructureSection kind="teams" title="Teams" organizationId={active.organizationId} />
      <StructureSection kind="locations" title="Locations" organizationId={active.organizationId} />
    </div>
  );
}

function StructureSection({
  kind,
  title,
  organizationId,
}: {
  kind: "teams" | "locations";
  title: string;
  organizationId: string;
}) {
  const list = useServerFn(listOrgStructureFn);
  const create = useServerFn(createOrgStructureFn);
  const update = useServerFn(updateOrgStructureFn);
  const qc = useQueryClient();
  const [name, setName] = useState("");
  const [error, setError] = useState<string | null>(null);

  const key = ["org", organizationId, "structure"];
  const q = useQuery({
    queryKey: key,
    queryFn: () => list({ data: { organizationId, includeArchived: true } }),
  });
  const rows = (q.data?.[kind] ?? []) as { id: string; name: string; active: boolean }[];

  async function refresh() {
    await qc.invalidateQueries({ queryKey: key });
  }

  return (
    <section className="rounded-xl border bg-card p-5" data-section={kind}>
      <h2 className="font-medium">{title}</h2>
      <form
        className="mt-3 flex gap-2"
        onSubmit={async (e) => {
          e.preventDefault();
          setError(null);
          try {
            await create({ data: { organizationId, kind, name } });
            setName("");
            await refresh();
          } catch (err) {
            setError(err instanceof Error ? err.message : "Failed");
          }
        }}
      >
        <input
          className="flex-1 rounded-md border bg-background px-3 py-2 text-sm"
          placeholder={kind === "teams" ? "Team name" : "Location name"}
          required
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
        <button className="rounded-md bg-primary text-primary-foreground px-3 py-2 text-sm">
          Add {kind === "teams" ? "team" : "location"}
        </button>
      </form>
      {error && <div className="mt-2 text-xs text-destructive">{error}</div>}
      <ul className="mt-3 divide-y">
        {rows.map((r) => (
          <li key={r.id} className="py-2 flex items-center justify-between text-sm">
            <span className={r.active ? "" : "text-muted-foreground line-through"}>{r.name}</span>
            <span className="flex items-center gap-3 text-xs">
              <button
                className="underline"
                onClick={async () => {
                  const next = window.prompt("Rename", r.name);
                  if (!next?.trim()) return;
                  await update({ data: { organizationId, kind, id: r.id, name: next } });
                  await refresh();
                }}
              >
                Rename
              </button>
              <button
                className="underline text-destructive"
                onClick={async () => {
                  await update({ data: { organizationId, kind, id: r.id, active: !r.active } });
                  await refresh();
                }}
              >
                {r.active ? "Archive" : "Restore"}
              </button>
            </span>
          </li>
        ))}
        {rows.length === 0 && (
          <li className="py-2 text-sm text-muted-foreground">None yet.</li>
        )}
      </ul>
    </section>
  );
}