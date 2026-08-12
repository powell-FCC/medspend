import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { resolveMemberDisplayName } from '../src/identity/member-identity.ts';

test('member identity follows safe display priority and never emits a raw UUID', () => {
  const userId = 'a3f39473-bfea-414a-98a6-804efa0b8619';
  assert.equal(resolveMemberDisplayName({ userId, profileFullName: 'John Smith', metadataDisplayName: 'Metadata Name', email: 'john@example.com' }), 'John Smith');
  assert.equal(resolveMemberDisplayName({ userId, profileFirstName: 'John', profileLastName: 'Smith', email: 'john@example.com' }), 'John Smith');
  assert.equal(resolveMemberDisplayName({ userId, metadataDisplayName: 'John Metadata', email: 'john@example.com' }), 'John Metadata');
  assert.equal(resolveMemberDisplayName({ userId, email: 'john@example.com' }), 'john@example.com');
  assert.equal(resolveMemberDisplayName({ userId }), 'Member a3f39473');
  assert.notEqual(resolveMemberDisplayName({ userId }), userId);
});

test('identity RPC is admin-only, organization-scoped, auth-aware, and returns safe fields only', async () => {
  const migration = await readFile(new URL('../supabase/migrations/20260815120000_phase4a3_1_staff_identity_context.sql', import.meta.url), 'utf8');
  assert.match(migration, /list_organization_member_identities/);
  assert.match(migration, /public\.is_org_admin\(_organization_id, auth\.uid\(\)\)/);
  assert.match(migration, /membership\.organization_id = _organization_id/);
  assert.match(migration, /profile\.full_name[\s\S]*first_name[\s\S]*display_name[\s\S]*profile\.email[\s\S]*auth_user\.email/);
  assert.doesNotMatch(migration, /RETURNS TABLE\([^)]*(raw_user_meta_data|phone|encrypted_password)/);
});

test('invite acceptance synchronizes a usable profile and organization defaults are validated', async () => {
  const migration = await readFile(new URL('../supabase/migrations/20260815120000_phase4a3_1_staff_identity_context.sql', import.meta.url), 'utf8');
  assert.match(migration, /INSERT INTO public\.profiles[\s\S]*ON CONFLICT \(id\) DO UPDATE/);
  assert.match(migration, /Selected team is unavailable for this organization/);
  assert.match(migration, /Selected location is unavailable for this organization/);
  assert.match(migration, /organization_memberships_validate_context/);
  assert.match(migration, /organization_invites_validate_context/);
});

test('settings sends optional team and location defaults through the invitation flow', async () => {
  const settings = await readFile(new URL('../src/routes/_authenticated/settings.tsx', import.meta.url), 'utf8');
  assert.match(settings, /aria-label="Default team"/);
  assert.match(settings, /aria-label="Default location"/);
  assert.match(settings, /defaultTeamId: defaultTeamId \|\| null/);
  assert.match(settings, /defaultLocationId: defaultLocationId \|\| null/);
});

test('request submission derives membership defaults, requires missing context, and validates organization ownership', async () => {
  const source = await readFile(new URL('../src/lib/supply-requests.functions.ts', import.meta.url), 'utf8');
  const submit = source.slice(source.indexOf('export const submitSupplyRequestFn'), source.indexOf('export const listMyRequestsFn'));
  assert.match(submit, /rpc\("submit_supply_request"/);
  assert.match(submit, /_team_id: data\.teamId \?\? null/);
  assert.match(submit, /_location_id: data\.locationId \?\? null/);
  const migration = await readFile(new URL('../supabase/migrations/20260812140000_phase4a4_multi_item_supply_requests.sql', import.meta.url), 'utf8');
  assert.match(migration, /coalesce\(_team_id, _membership\.default_team_id\)/);
  assert.match(migration, /coalesce\(_location_id, _membership\.default_location_id\)/);
  assert.match(migration, /organization_id = _organization_id AND active = true/);
  assert.match(migration, /_organization_id, _uid, _request_type/);
});

test('admin request attribution uses safe identities and includes team and location while staff ownership stays enforced', async () => {
  const source = await readFile(new URL('../src/lib/supply-requests.functions.ts', import.meta.url), 'utf8');
  const admin = source.slice(source.indexOf('export const getAdminSupplyRequestDashboardFn'), source.indexOf('export const updateRequestStatusFn'));
  assert.match(admin, /list_organization_member_identities/);
  assert.match(admin, /requesterEmail/);
  assert.match(admin, /teams\(name\),locations\(name\)/);
  assert.match(admin, /team\?\.name \?\? requesterIdentity\?\.default_team_name/);
  assert.match(admin, /location\?\.name \?\? requesterIdentity\?\.default_location_name/);
  assert.doesNotMatch(admin, /Unknown requester/);
  const staffDetail = source.slice(source.indexOf('export const getStaffRequestDetailFn'), source.indexOf('export const listOrgRequestsFn'));
  assert.match(staffDetail, /eq\("requested_by", context\.userId\)/);
  assert.doesNotMatch(staffDetail, /internal_note/);
});
