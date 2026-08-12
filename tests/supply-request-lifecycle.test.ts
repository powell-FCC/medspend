import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import {
  allowedNextSupplyRequestStatuses,
  canTransitionSupplyRequest,
  type SupplyRequestStatus,
} from '../src/supply-requests/lifecycle.ts';
import { supplyRequestInputSchema } from '../src/supply-requests/validation.ts';

test('the complete forward supply request lifecycle is valid', () => {
  const lifecycle: SupplyRequestStatus[] = [
    'submitted', 'under_review', 'approved', 'ordered', 'received', 'completed',
  ];
  for (let index = 0; index < lifecycle.length - 1; index += 1) {
    assert.equal(canTransitionSupplyRequest(lifecycle[index], lifecycle[index + 1]), true);
  }
});

test('invalid backward, skipped, and terminal transitions are rejected', () => {
  for (const [from, to] of [
    ['submitted', 'completed'], ['ordered', 'submitted'], ['completed', 'approved'],
    ['denied', 'under_review'], ['received', 'denied'], ['submitted', 'submitted'],
  ] as [SupplyRequestStatus, SupplyRequestStatus][]) {
    assert.equal(canTransitionSupplyRequest(from, to), false, `${from} -> ${to}`);
  }
  assert.deepEqual(allowedNextSupplyRequestStatuses('completed'), []);
  assert.deepEqual(allowedNextSupplyRequestStatuses('denied'), []);
});

test('denial is allowed only before an ordered request has been received', () => {
  for (const status of ['submitted', 'under_review', 'approved', 'ordered'] as SupplyRequestStatus[]) {
    assert.equal(canTransitionSupplyRequest(status, 'denied'), true);
  }
  assert.equal(canTransitionSupplyRequest('received', 'denied'), false);
});

test('request quantity is optional or a positive integer', () => {
  const base = {
    organizationId: '00000000-0000-4000-8000-000000000001',
    requestType: 'reorder' as const,
    freeTextItem: 'Exam gloves',
  };
  assert.equal(supplyRequestInputSchema.parse({ ...base, quantity: null }).quantity, null);
  assert.equal(supplyRequestInputSchema.parse({ ...base, quantity: 3 }).quantity, 3);
  for (const quantity of [0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.throws(() => supplyRequestInputSchema.parse({ ...base, quantity }));
  }
});

test('database transition is atomic, organization-scoped, and preserves timestamps', async () => {
  const sql = await readFile(new URL('../supabase/migrations/20260814120000_phase4a1_supply_request_lifecycle.sql', import.meta.url), 'utf8');
  assert.match(sql, /CREATE OR REPLACE FUNCTION public\.transition_supply_request/);
  assert.match(sql, /has_org_role\([\s\S]*ARRAY\['owner','admin'\]/);
  assert.match(sql, /WHERE id = _request_id AND organization_id = _organization_id[\s\S]*FOR UPDATE/);
  assert.match(sql, /WHEN _status = 'ordered' THEN coalesce\(ordered_at, now\(\)\)[\s\S]*ELSE ordered_at/);
  assert.match(sql, /WHEN _status = 'received' THEN coalesce\(received_at, now\(\)\)[\s\S]*ELSE received_at/);
  assert.match(sql, /Invalid supply request transition/);
  assert.match(sql, /INSERT INTO public\.supply_request_updates/);
});

test('submission validates related records inside the active organization', async () => {
  const server = await readFile(new URL('../src/lib/supply-requests.functions.ts', import.meta.url), 'utf8');
  for (const table of ['products', 'teams', 'locations']) {
    assert.match(server, new RegExp(`requireRelatedRecord\\(context, "${table}"`));
  }
  assert.match(server, /eq\("organization_id", organizationId\)\.eq\("active", true\)/);
  assert.match(server, /table === "products"[\s\S]*staff_requestable/);
});

test('staff request summaries expose safe latest-update metadata without internal notes', async () => {
  const server = await readFile(new URL('../src/lib/supply-requests.functions.ts', import.meta.url), 'utf8');
  const myRequests = server.slice(server.indexOf('export const listMyRequestsFn'), server.indexOf('export const listOrgRequestsFn'));
  assert.match(myRequests, /latestStaffVisibleNote/);
  assert.match(myRequests, /latestStatusChange/);
  assert.match(myRequests, /latestUpdateAt/);
  assert.doesNotMatch(myRequests, /internal_note/);
});

test('request update history hides internal notes from staff and verifies ownership', async () => {
  const server = await readFile(new URL('../src/lib/supply-requests.functions.ts', import.meta.url), 'utf8');
  const updates = server.slice(server.indexOf('export const listRequestUpdatesFn'), server.indexOf('export const searchProductsFn'));
  assert.match(updates, /request\.requested_by !== context\.userId/);
  assert.match(updates, /if \(!isAdmin\) query = query\.not\("staff_visible_note", "is", null\)/);
  assert.match(updates, /internalNote: isAdmin \? row\.internal_note : undefined/);
});

test('the admin update workflow delegates to the protected transition RPC', async () => {
  const server = await readFile(new URL('../src/lib/supply-requests.functions.ts', import.meta.url), 'utf8');
  assert.match(server, /rpc\("transition_supply_request"/);
  assert.match(server, /_organization_id: data\.organizationId/);
  assert.doesNotMatch(server, /ordered_at\?: string \| null/);
});
