import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { memberRestrictions, memberUpdateSchema, structureNameSchema, type OrganizationMember } from "../src/organization/management.ts";
import { requireOrganizationAdmin } from "../src/organization/access.ts";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const id = "11111111-1111-4111-8111-111111111111";
const member: OrganizationMember = { id, userId: id, role: "staff", active: true, defaultTeamId: null, defaultLocationId: null, fullName: "Jordan", email: "jordan@example.test" };
const sql = read("../supabase/migrations/20260910120000_internal_beta_organization_management.sql");

test("admin desktop and mobile navigation share Supply Requests with unchanged URLs", () => {
  const shell = read("../src/components/app/AdminAppShell.tsx");
  assert.match(shell, /to: "\/supply-requests", label: "Supply Requests"/);
  assert.doesNotMatch(shell, /label: "Staff"/);
  assert.equal((shell.match(/\{label\}/g) ?? []).length, 2);
  const route = read("../src/routes/_authenticated/supply-requests.tsx");
  assert.match(route, /Request Inbox/);
  assert.match(read("../src/components/staff/StaffBottomNav.tsx"), /\/staff\/request/);
});

test("only scoped member fields are accepted, with explicit nulls to clear defaults", () => {
  const base = { organizationId: id, id, changes: { role: "admin", default_team_id: null } };
  assert.equal(memberUpdateSchema.safeParse(base).success, true);
  for (const changes of [{}, { full_name: "Other" }, { email: "other@example.test" }, { user_id: id }, { organization_id: id }, { active: "false" }, { role: "superadmin" }, { default_team_id: "invalid" }]) {
    assert.equal(memberUpdateSchema.safeParse({ ...base, changes }).success, false);
  }
  assert.equal(memberUpdateSchema.parse({ ...base, changes: { active: false } }).changes.active, false);
  assert.equal(structureNameSchema.parse("  Track & Field  "), "Track & Field");
  for (const name of ["", "   ", "a".repeat(121)]) assert.equal(structureNameSchema.safeParse(name).success, false);
});

test("member controls protect self, the last owner, and owner management while allowing supported admin edits", () => {
  const owner = { id: "owner", role: "owner" as const };
  const admin = { id: "admin", role: "admin" as const };
  assert.equal(memberRestrictions(owner, member, 1).canChangeActive, true);
  assert.equal(memberRestrictions(admin, member, 1).canEdit, true);
  assert.equal(memberRestrictions({ id: "staff", role: "staff" }, member, 1).canEdit, false);
  const ownerMember = { ...member, role: "owner" as const };
  assert.equal(memberRestrictions(admin, ownerMember, 2).canEdit, false);
  assert.equal(memberRestrictions(owner, ownerMember, 1).canChangeActive, false);
  assert.equal(memberRestrictions(owner, ownerMember, 1).canChangeRole, false);
  assert.equal(memberRestrictions(owner, ownerMember, 2).canChangeActive, true);
  assert.equal(memberRestrictions({ id, role: "owner" }, ownerMember, 2).canChangeRole, false);
  assert.equal(memberRestrictions({ id, role: "owner" }, ownerMember, 2).canChangeActive, false);
  assert.equal(memberRestrictions({ id, role: "owner" }, ownerMember, 2).canEdit, true);
  assert.equal(memberRestrictions(owner, { ...ownerMember, active: false }, 1).canChangeActive, true);
});

test("server admin guard checks organization, identity, and active membership; staff, inactive users and nonmembers fail", async () => {
  const memberships = [
    { organization_id: "org-a", user_id: "owner", active: true, role: "owner" },
    { organization_id: "org-a", user_id: "admin", active: true, role: "admin" },
    { organization_id: "org-a", user_id: "staff", active: true, role: "staff" },
    { organization_id: "org-a", user_id: "inactive", active: false, role: "admin" },
  ];
  const db = { from(table: string) {
    assert.equal(table, "organization_memberships");
    const filters: Record<string, unknown> = {};
    return { select() { return this; }, eq(key: string, value: unknown) { filters[key] = value; return this; },
      async maybeSingle() { return { data: memberships.find((m) => Object.entries(filters).every(([k, v]) => m[k] === v)) ?? null, error: null }; } };
  } } as unknown as Parameters<typeof requireOrganizationAdmin>[0];
  assert.equal(await requireOrganizationAdmin(db, "owner", "org-a"), "owner");
  assert.equal(await requireOrganizationAdmin(db, "admin", "org-a"), "admin");
  for (const user of ["staff", "inactive", "nonmember"]) await assert.rejects(requireOrganizationAdmin(db, user, "org-a"), /Forbidden/);
  await assert.rejects(requireOrganizationAdmin(db, "owner", "org-b"), /Forbidden/);
  const server = read("../src/lib/orgs.functions.ts");
  const mutation = server.slice(server.indexOf("export const updateOrgMemberFn"));
  assert.match(mutation, /middleware\(\[requireSupabaseAuth\]\)/);
  assert.match(mutation, /requireOrganizationAdmin\(context.supabase, context.userId, data.organizationId\)/);
  assert.match(mutation, /rpc\("update_organization_member"/);
});

test("structure mutations retain organization guards and active-only selection has a separate cache", () => {
  const source = read("../src/lib/org-structure.functions.ts");
  const route = read("../src/routes/_authenticated/settings.tsx");
  const controls = read("../src/components/settings/OrganizationManagement.tsx");
  assert.match(source, /if \(!data.includeArchived\) q = q.eq\("active", true\)/);
  for (const name of ["createOrgStructureFn", "updateOrgStructureFn"]) {
    const mutation = source.slice(source.indexOf(`export const ${name}`));
    assert.match(mutation, /requireOrganizationAdmin\(context.supabase, context.userId, data.organizationId\)/);
  }
  assert.match(source, /if \(!row\) throw new Error\("Record not found in this organization"\)/);
  assert.match(route, /"structure", "active"/);
  assert.match(controls, /"structure", "all"/);
  assert.match(controls, /rows\s*\.filter\(\(row\) => row.active \|\| row.id === currentId\)/);
  assert.match(controls, /disabled=\{!row.active\}/);
  assert.match(read("../src/routes/_authenticated/staff/request.tsx"), /includeArchived: false/);
});

test("Settings controls confirm deactivation, archive and invite revocation and reset on organization change", () => {
  const controls = read("../src/components/settings/OrganizationManagement.tsx");
  const route = read("../src/routes/_authenticated/settings.tsx");
  assert.match(route, /active.role !== "owner" && active.role !== "admin"/);
  assert.match(route, /SettingsContent key=\{active.organizationId\}/);
  assert.match(controls, /AlertDialogContent/);
  for (const label of ["Deactivate member", "Reactivate member", "Show inactive", "Show archived", "Save changes"]) assert.ok(controls.includes(label));
  assert.match(route, /ConfirmOrganizationAction[\s\S]*action="Revoke invitation"/);
});

test("migration retains identities and historical foreign keys while narrowing mutation privileges", () => {
  const identities = sql.slice(sql.indexOf("CREATE OR REPLACE FUNCTION public.list_organization_member_identities"));
  assert.doesNotMatch(identities, /membership.active/);
  assert.match(identities, /membership.organization_id = _organization_id/);
  assert.match(identities, /public.is_org_admin\(_organization_id, auth.uid\(\)\)/);
  assert.match(sql, /REVOKE DELETE ON public.organization_memberships, public.teams, public.locations FROM authenticated/);
  assert.match(sql, /AS RESTRICTIVE FOR SELECT TO authenticated/);
  assert.match(sql, /WHERE id = _membership_id AND organization_id = _organization_id FOR UPDATE/);
  assert.match(sql, /UPDATE public.organizations SET updated_at = now\(\) WHERE id = _organization_id/);
  assert.match(sql, /UPDATE public.organizations SET updated_at = now\(\) WHERE id = OLD.organization_id/);
  assert.match(sql, /Only owners can manage owners/);
  assert.match(sql, /Keep at least one active owner/);
  assert.match(sql, /Ask an owner or admin to reactivate your membership/);
  assert.doesNotMatch(sql, /DELETE FROM|DROP TABLE|DROP POLICY|ALTER TABLE|UPDATE public\.(supply_requests|supply_request_updates|invoices|invoice_items|organization_budgets)/);
});
