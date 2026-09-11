import { createFileRoute } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useState } from "react";
import { useActiveOrg } from "@/hooks/use-active-org";
import { createInvitationFn, listOrgInvitesFn, listOrgMembersFn, revokeInvitationFn } from "@/lib/orgs.functions";
import { listOrgStructureFn } from "@/lib/org-structure.functions";
import { ConfirmOrganizationAction, MembersSection, StructureSection } from "@/components/settings/OrganizationManagement";

export const Route = createFileRoute("/_authenticated/settings")({
  head: () => ({ meta: [{ title: "Settings — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: Page,
});

function Page() {
  const { active } = useActiveOrg();
  if (!active || (active.role !== "owner" && active.role !== "admin")) return null;
  return <SettingsContent key={active.organizationId} />;
}

function SettingsContent() {
  const { active } = useActiveOrg();
  const listInvites = useServerFn(listOrgInvitesFn);
  const listMembers = useServerFn(listOrgMembersFn);
  const create = useServerFn(createInvitationFn);
  const revoke = useServerFn(revokeInvitationFn);
  const listStructure = useServerFn(listOrgStructureFn);
  const qc = useQueryClient();

  const [revoking, setRevoking] = useState<{ id: string; email: string } | null>(null);
  const [inviting, setInviting] = useState(false);
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [role, setRole] = useState<"staff" | "admin">("staff");
  const [defaultTeamId, setDefaultTeamId] = useState("");
  const [defaultLocationId, setDefaultLocationId] = useState("");
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
  const structureQ = useQuery({
    queryKey: ["org", active?.organizationId, "structure", "active"],
    queryFn: () => listStructure({ data: { organizationId: active!.organizationId, includeArchived: false } }),
    enabled: !!active,
  });

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    setInviting(true);
    try {
      const res = await create({
        data: {
          organizationId: active!.organizationId,
          email,
          name,
          role,
          defaultTeamId: defaultTeamId || null,
          defaultLocationId: defaultLocationId || null,
        },
      });
      const link = `${window.location.origin}/join/${res.token}`;
      setLastLink(link);
      setEmail("");
      setName("");
      setDefaultTeamId("");
      setDefaultLocationId("");
      await qc.invalidateQueries({ queryKey: ["org", active?.organizationId, "invites"] });
    } catch (e) {
      setErr(e instanceof Error ? e.message : "Failed to create invitation");
    } finally {
      setInviting(false);
    }
  }

  if (!active) return null;

  return (
    <div className="max-w-5xl mx-auto px-6 py-8 space-y-8">
      <div>
        <h1 className="text-2xl font-semibold">Settings</h1>
        <div className="text-sm text-muted-foreground">{active.organizationName}</div>
      </div>

      <section className="rounded-xl border bg-card p-5">
        <h2 className="font-medium">Invite staff</h2>
        <form onSubmit={submit} className="mt-3 grid gap-2 md:grid-cols-2">
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
          <select aria-label="Default team" className="rounded-md border bg-background px-3 py-2 text-sm" value={defaultTeamId} onChange={(event) => setDefaultTeamId(event.target.value)}>
            <option value="">No default team</option>
            {structureQ.data?.teams.map((team) => <option key={team.id} value={team.id}>{team.name}</option>)}
          </select>
          <select aria-label="Default location" className="rounded-md border bg-background px-3 py-2 text-sm" value={defaultLocationId} onChange={(event) => setDefaultLocationId(event.target.value)}>
            <option value="">No default location</option>
            {structureQ.data?.locations.map((location) => <option key={location.id} value={location.id}>{location.name}</option>)}
          </select>
          <button disabled={inviting || !structureQ.isSuccess} className="rounded-md bg-primary text-primary-foreground px-3 py-2 text-sm disabled:opacity-50">{inviting ? "Creating…" : "Create invite"}</button>
        </form>
        {(err || structureQ.error) && <div role="alert" className="mt-2 text-xs text-destructive">{err ?? structureQ.error?.message}</div>}
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
        {invitesQ.error && <p role="alert" className="mt-2 text-sm text-destructive">{invitesQ.error.message}</p>}
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
                  onClick={() => setRevoking({ id: i.id, email: i.invited_email })}
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

      <MembersSection organizationId={active.organizationId} actor={active} members={membersQ.data ?? []} loading={membersQ.isLoading} error={membersQ.error} />
      {revoking && <ConfirmOrganizationAction
        title={`Revoke invitation for ${revoking.email}?`}
        description="This invitation link will no longer grant access to the organization."
        action="Revoke invitation"
        onClose={() => setRevoking(null)}
        onConfirm={async () => {
          await revoke({ data: { id: revoking.id } });
          setLastLink(null);
          await qc.invalidateQueries({ queryKey: ["org", active.organizationId, "invites"] });
        }}
      />}

      <StructureSection kind="teams" title="Teams" organizationId={active.organizationId} />
      <StructureSection kind="locations" title="Locations" organizationId={active.organizationId} />
    </div>
  );
}
