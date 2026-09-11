import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { updateOrgMemberFn } from "@/lib/orgs.functions";
import {
  createOrgStructureFn,
  listOrgStructureFn,
  updateOrgStructureFn,
} from "@/lib/org-structure.functions";
import {
  memberRestrictions,
  structureNameSchema,
  type OrganizationMember,
  type StructureRecord,
} from "@/organization/management";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";

const inputClass = "w-full rounded-md border bg-background px-3 py-2 text-sm";
const errorMessage = (error: unknown) =>
  error instanceof Error ? error.message : "Unable to save changes. Try again.";

function useRefreshOrganization(organizationId: string) {
  const qc = useQueryClient();
  return () =>
    Promise.all([
      qc.invalidateQueries({ queryKey: ["org", organizationId] }),
      qc.invalidateQueries({ queryKey: ["me", "memberships"] }),
    ]);
}

export function ConfirmOrganizationAction({
  title,
  description,
  action,
  onConfirm,
  onClose,
}: {
  title: string;
  description: string;
  action: string;
  onConfirm: () => Promise<unknown>;
  onClose: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <AlertDialog
      open
      onOpenChange={(open) => {
        if (!open && !busy) onClose();
      }}
    >
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          <AlertDialogDescription>{description}</AlertDialogDescription>
        </AlertDialogHeader>
        {error && (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        )}
        <AlertDialogFooter>
          <AlertDialogCancel asChild>
            <Button variant="outline" disabled={busy}>
              Cancel
            </Button>
          </AlertDialogCancel>
          <Button
            variant="destructive"
            disabled={busy}
            onClick={async () => {
              setBusy(true);
              setError(null);
              try {
                await onConfirm();
                onClose();
              } catch (err) {
                setError(errorMessage(err));
              } finally {
                setBusy(false);
              }
            }}
          >
            {busy ? "Saving…" : action}
          </Button>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

export function MembersSection({
  organizationId,
  actor,
  members,
  loading,
  error,
}: {
  organizationId: string;
  actor: { id: string; role: "owner" | "admin" | "staff" };
  members: OrganizationMember[];
  loading: boolean;
  error: Error | null;
}) {
  const update = useServerFn(updateOrgMemberFn);
  const refresh = useRefreshOrganization(organizationId);
  const [showInactive, setShowInactive] = useState(false);
  const [editing, setEditing] = useState<OrganizationMember | null>(null);
  const [changingStatus, setChangingStatus] = useState<OrganizationMember | null>(null);
  const activeOwnerCount = members.filter(
    (member) => member.active && member.role === "owner",
  ).length;
  const rows = members
    .filter((member) => showInactive || member.active)
    .sort((a, b) => Number(b.active) - Number(a.active) || a.fullName.localeCompare(b.fullName));
  return (
    <section className="rounded-xl border bg-card p-5" data-section="members">
      <div className="flex items-center justify-between gap-4">
        <h2 className="font-medium">Members</h2>
        <label className="flex items-center gap-2 text-sm text-muted-foreground">
          <input
            type="checkbox"
            checked={showInactive}
            onChange={(e) => setShowInactive(e.target.checked)}
          />
          Show inactive
        </label>
      </div>
      <p className="mt-1 text-sm text-muted-foreground">
        Manage roles and defaults. Deactivation removes organization access and keeps historical
        attribution.
      </p>
      {loading && <p className="mt-3 text-sm text-muted-foreground">Loading members…</p>}
      {error && (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {error.message}
        </p>
      )}
      <ul className="mt-3 divide-y">
        {rows.map((member) => {
          const restrictions = memberRestrictions(actor, member, activeOwnerCount);
          return (
            <li key={member.id} className="flex items-center justify-between gap-4 py-3 text-sm">
              <div className="min-w-0">
                <div className="font-medium">
                  {member.fullName}
                  {member.id === actor.id && (
                    <span className="ml-2 text-xs text-muted-foreground">You</span>
                  )}
                </div>
                <div className="text-xs text-muted-foreground">{member.email}</div>
                {restrictions.reason && (
                  <div className="mt-1 text-xs text-muted-foreground">{restrictions.reason}</div>
                )}
              </div>
              <div className="flex shrink-0 items-center gap-2">
                <span className="text-xs capitalize text-muted-foreground">{member.role}</span>
                <StatusBadge active={member.active} />
                <Button
                  size="sm"
                  variant="outline"
                  disabled={!restrictions.canEdit}
                  onClick={() => setEditing(member)}
                >
                  Edit
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  disabled={!restrictions.canChangeActive}
                  onClick={() => setChangingStatus(member)}
                >
                  {member.active ? "Deactivate" : "Reactivate"}
                </Button>
              </div>
            </li>
          );
        })}
        {!loading && !error && rows.length === 0 && (
          <li className="py-3 text-sm text-muted-foreground">No members to show.</li>
        )}
      </ul>
      {editing && (
        <MemberEditor
          member={editing}
          organizationId={organizationId}
          actor={actor}
          activeOwnerCount={activeOwnerCount}
          onClose={() => setEditing(null)}
          onSaved={refresh}
        />
      )}
      {changingStatus && (
        <ConfirmOrganizationAction
          title={`${changingStatus.active ? "Deactivate" : "Reactivate"} ${changingStatus.fullName}?`}
          description={
            changingStatus.active
              ? "They will lose access to this organization, and their pending invitations will be revoked. Their account, requests, and historical attribution will be preserved."
              : `They will regain access to this organization with the ${changingStatus.role} role.`
          }
          action={changingStatus.active ? "Deactivate member" : "Reactivate member"}
          onClose={() => setChangingStatus(null)}
          onConfirm={async () => {
            await update({
              data: {
                organizationId,
                id: changingStatus.id,
                changes: { active: !changingStatus.active },
              },
            });
            await refresh();
          }}
        />
      )}
    </section>
  );
}

function MemberEditor({
  member,
  organizationId,
  actor,
  activeOwnerCount,
  onClose,
  onSaved,
}: {
  member: OrganizationMember;
  organizationId: string;
  actor: { id: string; role: "owner" | "admin" | "staff" };
  activeOwnerCount: number;
  onClose: () => void;
  onSaved: () => Promise<unknown>;
}) {
  const update = useServerFn(updateOrgMemberFn);
  const list = useServerFn(listOrgStructureFn);
  const structure = useQuery({
    queryKey: ["org", organizationId, "structure", "all"],
    queryFn: () => list({ data: { organizationId, includeArchived: true } }),
  });
  const [role, setRole] = useState(member.role);
  const [teamId, setTeamId] = useState(member.defaultTeamId ?? "");
  const [locationId, setLocationId] = useState(member.defaultLocationId ?? "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const restrictions = memberRestrictions(actor, member, activeOwnerCount);
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !busy) onClose();
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Edit {member.fullName}</DialogTitle>
          <DialogDescription>
            Update this member’s role and defaults for this organization. Name and email are managed
            through their account.
          </DialogDescription>
        </DialogHeader>
        <form
          className="space-y-4"
          onSubmit={async (event) => {
            event.preventDefault();
            setBusy(true);
            setError(null);
            const changes = {
              ...(role !== member.role ? { role } : {}),
              ...((teamId || null) !== member.defaultTeamId
                ? { default_team_id: teamId || null }
                : {}),
              ...((locationId || null) !== member.defaultLocationId
                ? { default_location_id: locationId || null }
                : {}),
            };
            try {
              if (Object.keys(changes).length)
                await update({ data: { organizationId, id: member.id, changes } });
              await onSaved();
              onClose();
            } catch (err) {
              setError(errorMessage(err));
            } finally {
              setBusy(false);
            }
          }}
        >
          <label className="block space-y-1 text-sm">
            <span>Role</span>
            <select
              aria-label="Member role"
              className={inputClass}
              value={role}
              disabled={busy || !restrictions.canChangeRole}
              onChange={(e) => setRole(e.target.value as typeof role)}
            >
              <option value="staff">Staff</option>
              <option value="admin">Admin</option>
              {(actor.role === "owner" || member.role === "owner") && (
                <option value="owner">Owner</option>
              )}
            </select>
          </label>
          {restrictions.reason && (
            <p className="text-xs text-muted-foreground">{restrictions.reason}</p>
          )}
          {role !== member.role && (
            <p className="rounded-md bg-muted p-3 text-sm">
              Saving changes will change this member’s access from {member.role} to {role}.
            </p>
          )}
          <DefaultSelect
            label="Member default team"
            value={teamId}
            onChange={setTeamId}
            rows={structure.data?.teams ?? []}
            currentId={member.defaultTeamId}
            disabled={busy || !structure.isSuccess}
          />
          <DefaultSelect
            label="Member default location"
            value={locationId}
            onChange={setLocationId}
            rows={structure.data?.locations ?? []}
            currentId={member.defaultLocationId}
            disabled={busy || !structure.isSuccess}
          />
          {(error || structure.error) && (
            <p role="alert" className="text-sm text-destructive">
              {error ?? structure.error?.message}
            </p>
          )}
          <DialogFooter>
            <Button type="button" variant="outline" disabled={busy} onClick={onClose}>
              Cancel
            </Button>
            <Button disabled={busy || !structure.isSuccess}>
              {busy ? "Saving…" : "Save changes"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function DefaultSelect({
  label,
  value,
  onChange,
  rows,
  currentId,
  disabled,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  rows: StructureRecord[];
  currentId: string | null;
  disabled: boolean;
}) {
  return (
    <label className="block space-y-1 text-sm">
      <span>{label.replace("Member default", "Default")}</span>
      <select
        aria-label={label}
        className={inputClass}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        disabled={disabled}
      >
        <option value="">No default</option>
        {rows
          .filter((row) => row.active || row.id === currentId)
          .map((row) => (
            <option key={row.id} value={row.id} disabled={!row.active}>
              {row.name}
              {!row.active ? " (archived)" : ""}
            </option>
          ))}
      </select>
    </label>
  );
}

function StatusBadge({ active, archived = false }: { active: boolean; archived?: boolean }) {
  return (
    <span
      className={`rounded-full border px-2 py-0.5 text-xs ${active ? "border-primary/20 bg-primary/5 text-primary" : "bg-muted text-muted-foreground"}`}
    >
      {active ? "Active" : archived ? "Archived" : "Inactive"}
    </span>
  );
}

export function StructureSection({
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
  const refresh = useRefreshOrganization(organizationId);
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showArchived, setShowArchived] = useState(false);
  const [editing, setEditing] = useState<StructureRecord | null>(null);
  const [editName, setEditName] = useState("");
  const [changingStatus, setChangingStatus] = useState<StructureRecord | null>(null);
  const q = useQuery({
    queryKey: ["org", organizationId, "structure", "all"],
    queryFn: () => list({ data: { organizationId, includeArchived: true } }),
  });
  const rows = (q.data?.[kind] ?? []).filter((row) => showArchived || row.active);
  const singular = kind === "teams" ? "team" : "location";

  return (
    <section className="rounded-xl border bg-card p-5" data-section={kind}>
      <div className="flex items-center justify-between gap-4">
        <h2 className="font-medium">{title}</h2>
        <label className="flex items-center gap-2 text-sm text-muted-foreground">
          <input
            type="checkbox"
            checked={showArchived}
            onChange={(e) => setShowArchived(e.target.checked)}
          />
          Show archived
        </label>
      </div>
      <form
        className="mt-3 flex gap-2"
        onSubmit={async (event) => {
          event.preventDefault();
          setError(null);
          setBusy(true);
          try {
            await create({ data: { organizationId, kind, name: structureNameSchema.parse(name) } });
            setName("");
            await refresh();
          } catch (err) {
            setError(errorMessage(err));
          } finally {
            setBusy(false);
          }
        }}
      >
        <input
          className={inputClass}
          aria-label={`New ${singular} name`}
          placeholder={`${singular === "team" ? "Team" : "Location"} name`}
          required
          maxLength={120}
          value={name}
          onChange={(e) => setName(e.target.value)}
          disabled={busy}
        />
        <Button disabled={busy || !name.trim()}>Add {singular}</Button>
      </form>
      {(error || q.error) && (
        <p role="alert" className="mt-2 text-sm text-destructive">
          {error ?? q.error?.message}
        </p>
      )}
      {q.isLoading && (
        <p className="mt-3 text-sm text-muted-foreground">Loading {title.toLowerCase()}…</p>
      )}
      <ul className="mt-3 divide-y">
        {rows.map((row) => (
          <li key={row.id} className="flex items-center justify-between gap-4 py-3 text-sm">
            <span className={row.active ? "font-medium" : "text-muted-foreground"}>{row.name}</span>
            <div className="flex items-center gap-2">
              <StatusBadge active={row.active} archived />
              <Button
                size="sm"
                variant="outline"
                disabled={busy}
                onClick={() => {
                  setEditing(row);
                  setEditName(row.name);
                  setError(null);
                }}
              >
                Edit
              </Button>
              <Button
                size="sm"
                variant="ghost"
                disabled={busy}
                onClick={() => setChangingStatus(row)}
              >
                {row.active ? "Archive" : "Reactivate"}
              </Button>
            </div>
          </li>
        ))}
        {!q.isLoading && !q.error && rows.length === 0 && (
          <li className="py-3 text-sm text-muted-foreground">
            No {showArchived ? "" : "active "}
            {title.toLowerCase()}.
          </li>
        )}
      </ul>
      {editing && (
        <Dialog
          open
          onOpenChange={(open) => {
            if (!open && !busy) {
              setEditing(null);
              setError(null);
            }
          }}
        >
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Edit {singular}</DialogTitle>
              <DialogDescription>
                Update the name of {editing.name}. Historical records will display the updated name.
              </DialogDescription>
            </DialogHeader>
            <form
              className="space-y-4"
              onSubmit={async (event) => {
                event.preventDefault();
                setError(null);
                setBusy(true);
                try {
                  await update({
                    data: {
                      organizationId,
                      kind,
                      id: editing.id,
                      name: structureNameSchema.parse(editName),
                    },
                  });
                  await refresh();
                  setEditing(null);
                } catch (err) {
                  setError(errorMessage(err));
                } finally {
                  setBusy(false);
                }
              }}
            >
              <label className="block space-y-1 text-sm">
                <span>Name</span>
                <input
                  className={inputClass}
                  required
                  maxLength={120}
                  value={editName}
                  onChange={(e) => setEditName(e.target.value)}
                  disabled={busy}
                />
              </label>
              {error && (
                <p role="alert" className="text-sm text-destructive">
                  {error}
                </p>
              )}
              <DialogFooter>
                <Button
                  type="button"
                  variant="outline"
                  disabled={busy}
                  onClick={() => {
                    setEditing(null);
                    setError(null);
                  }}
                >
                  Cancel
                </Button>
                <Button disabled={busy || !editName.trim()}>
                  {busy ? "Saving…" : "Save changes"}
                </Button>
              </DialogFooter>
            </form>
          </DialogContent>
        </Dialog>
      )}
      {changingStatus && (
        <ConfirmOrganizationAction
          title={`${changingStatus.active ? "Archive" : "Reactivate"} ${changingStatus.name}?`}
          description={
            changingStatus.active
              ? `This ${singular} will be removed from active selections and member/invitation defaults. Historical requests and invoice associations will be preserved.`
              : `This ${singular} will be available for new selections. Previous member defaults will not be restored automatically.`
          }
          action={changingStatus.active ? `Archive ${singular}` : `Reactivate ${singular}`}
          onClose={() => setChangingStatus(null)}
          onConfirm={async () => {
            await update({
              data: { organizationId, kind, id: changingStatus.id, active: !changingStatus.active },
            });
            await refresh();
          }}
        />
      )}
    </section>
  );
}
