import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { multiItemSupplyRequestInputSchema } from '../src/supply-requests/validation.ts';

const productId = '11111111-1111-4111-8111-111111111111';
const base = { organizationId: '22222222-2222-4222-8222-222222222222', requestType: 'reorder' as const };

test('one, multiple catalog, mixed, and multiple custom request lines validate', () => {
  for (const items of [
    [{ productId, quantity: 1 }],
    [{ productId, quantity: 2 }, { productId: '33333333-3333-4333-8333-333333333333', quantity: 3 }],
    [{ productId, quantity: 2 }, { freeTextItem: 'Custom wrap', quantity: 4 }],
    [{ freeTextItem: 'Custom wrap', quantity: 4 }, { freeTextItem: 'Travel kit', quantity: 1 }],
  ]) assert.equal(multiItemSupplyRequestInputSchema.safeParse({ ...base, items }).success, true);
});

test('empty requests and invalid quantities or ambiguous identities are rejected per line', () => {
  for (const items of [
    [],
    [{ productId, quantity: 0 }],
    [{ productId, quantity: -1 }],
    [{ productId, quantity: 1.5 }],
    [{ productId, freeTextItem: 'Both', quantity: 1 }],
    [{ quantity: 1 }],
  ]) assert.equal(multiItemSupplyRequestInputSchema.safeParse({ ...base, items }).success, false);
});

test('migration is additive, backfills historical parents, secures lines, and submits atomically', async () => {
  const sql = await readFile(new URL('../supabase/migrations/20260812140000_phase4a4_multi_item_supply_requests.sql', import.meta.url), 'utf8');
  assert.match(sql, /CREATE TABLE public\.supply_request_items/);
  assert.match(sql, /FOREIGN KEY \(supply_request_id, organization_id\)/);
  assert.match(sql, /FOREIGN KEY \(product_id, organization_id\)/);
  assert.match(sql, /INSERT INTO public\.supply_request_items[\s\S]*FROM public\.supply_requests request/);
  assert.match(sql, /CREATE OR REPLACE FUNCTION public\.submit_supply_request/);
  assert.match(sql, /jsonb_array_length\(_items\) = 0/);
  assert.match(sql, /Each requested quantity must be a positive whole number/);
  assert.match(sql, /A selected product is unavailable for this organization/);
  assert.match(sql, /request\.requested_by = auth\.uid\(\)[\s\S]*public\.is_org_admin/);
  assert.doesNotMatch(sql, /DROP (TABLE|COLUMN)|ALTER TABLE public\.supply_requests DROP/);
});

test('staff and admin view models load child lines while preserving legacy fallback and parent queues', async () => {
  const server = await readFile(new URL('../src/lib/supply-requests.functions.ts', import.meta.url), 'utf8');
  assert.match(server, /from\("supply_request_items"\)/);
  assert.match(server, /id: `legacy:\$\{request\.id\}`/);
  assert.match(server, /itemCount: items\.length/);
  const adminModel = await readFile(new URL('../src/supply-requests/admin-dashboard.ts', import.meta.url), 'utf8');
  assert.match(adminModel, /for \(const request of requests\)/);
  assert.doesNotMatch(adminModel, /for \(const item of request\.items\)/);
});

test('staff cart and both detail surfaces render complete item lists', async () => {
  const staffForm = await readFile(new URL('../src/routes/_authenticated/staff/request.tsx', import.meta.url), 'utf8');
  assert.match(staffForm, /Add to Request/);
  assert.match(staffForm, /Your Request/);
  assert.match(staffForm, /Remove \$\{item\.name\}/);
  const staffDetail = await readFile(new URL('../src/routes/_authenticated/staff/requests.$id.tsx', import.meta.url), 'utf8');
  const adminDetail = await readFile(new URL('../src/components/admin/supply-requests/AdminRequestDetail.tsx', import.meta.url), 'utf8');
  assert.match(staffDetail, /request\.data\.items\.map/);
  assert.match(adminDetail, /request\.items\.map/);
});

test('inventory demand uses child lines and distinct parent request identifiers', async () => {
  const source = await readFile(new URL('../src/lib/inventory-intelligence.functions.ts', import.meta.url), 'utf8');
  assert.match(source, /from\('supply_request_items'\)/);
  assert.match(source, /supply_request_id,product_id,quantity/);
  assert.match(source, /requestId: row\.supply_request_id/);
});
