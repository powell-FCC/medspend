import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { documentTypeLabel, getInvoiceDeletionEligibility, reconstructInventoryLedger } from '../src/invoice/deletion.ts';

const root = new URL('../', import.meta.url);
const migration = await readFile(new URL('supabase/migrations/20260817120000_phase3a6_safe_invoice_deletion.sql', root), 'utf8');
const server = await readFile(new URL('src/lib/invoice-history.functions.ts', root), 'utf8');
const page = await readFile(new URL('src/components/invoice-history/InvoiceListPage.tsx', root), 'utf8');

const invoice = (id: string, amount: number) => ({ id, adjustmentAmount: amount, belongsToDeletedInvoice: true });
const other = (id: string, amount: number) => ({ id, adjustmentAmount: amount, belongsToDeletedInvoice: false });

test('posted and completed documents are eligible while active processing remains blocked', () => {
  assert.equal(getInvoiceDeletionEligibility({ status: 'completed', processingStatus: 'completed', postedAt: '2026-08-12T00:00:00Z' }).eligible, true);
  for (const status of ['uploaded', 'failed', 'review_required'] as const) assert.equal(getInvoiceDeletionEligibility({ status, processingStatus: status, postedAt: null }).eligible, true);
  assert.equal(getInvoiceDeletionEligibility({ status: 'processing', processingStatus: 'processing', postedAt: null }).eligible, false);
});

test('newest, oldest, and middle receipt deletion preserves the other invoice contributions', () => {
  const all = [other('a', 10), other('b', 20), other('c', 5)];
  for (const deleted of ['a', 'b', 'c']) {
    const entries = all.map((entry) => ({ ...entry, belongsToDeletedInvoice: entry.id === deleted }));
    const result = reconstructInventoryLedger(45, entries);
    const removed = all.find((entry) => entry.id === deleted)!.adjustmentAmount;
    assert.equal(result.quantity, 45 - removed);
    assert.equal(result.ledger.at(-1)?.newQuantity, 45 - removed);
  }
});

test('subsequent negative, positive, damaged, and expired adjustments remain and receive coherent balances', () => {
  const result = reconstructInventoryLedger(29, [invoice('receipt', 10), other('usage', -8), other('addition', 5), other('damaged', -2), other('expired', -1)]);
  assert.equal(result.quantity, 19);
  assert.deepEqual(result.ledger.map((entry) => [entry.id, entry.previousQuantity, entry.newQuantity]), [
    ['usage', 25, 17], ['addition', 17, 22], ['damaged', 22, 20], ['expired', 20, 19],
  ]);
});

test('multiple invoice lines for one inventory item are aggregated exactly once', () => {
  const result = reconstructInventoryLedger(37, [invoice('line-1', 6), invoice('line-2', 4), other('later', 7)]);
  assert.equal(result.removedQuantity, 10);
  assert.equal(result.quantity, 27);
  assert.deepEqual(result.ledger.map((entry) => entry.id), ['later']);
});

test('negative current, starting, or intermediate reconstruction blocks without a result', () => {
  assert.throws(() => reconstructInventoryLedger(2, [invoice('receipt', 10), other('usage', -8)]), /current inventory negative/);
  assert.throws(() => reconstructInventoryLedger(5, [invoice('receipt', 2), other('addition', 5)]), /begin below zero/);
  assert.throws(() => reconstructInventoryLedger(5, [invoice('receipt', 2), other('usage', -4), other('addition', 6)]), /become negative/);
});

test('RPC is owner-only, organization-scoped, atomic, and client input cannot control impact', () => {
  assert.match(migration, /auth\.uid\(\) IS NULL OR NOT public\.has_org_role/);
  assert.match(migration, /WHERE id = _source_file_id AND organization_id = _organization_id\s+FOR UPDATE/);
  assert.match(migration, /split_part\(_source\.storage_path, '\/', 1\) <> _organization_id::text/);
  assert.match(migration, /inventory\.organization_id = _organization_id/g);
  assert.match(migration, /_reconstructed_quantity < 0/);
  assert.match(migration, /inventory provenance is incomplete/);
  assert.match(migration, /adjustment\.adjustment_amount = item\.quantity/);
  assert.match(migration, /ORDER BY adjustment\.created_at, adjustment\.id/);
  assert.match(migration, /previous_quantity = _running_quantity/);
  assert.match(migration, /new_quantity = _running_quantity \+ _adjustment\.adjustment_amount/);
  assert.match(server, /deleteInput = z\.object\(\{ organizationId: z\.string\(\)\.uuid\(\), invoiceId: z\.string\(\)\.uuid\(\) \}\)\.strict\(\)/);
  assert.doesNotMatch(server, /deleteInput[\s\S]{0,180}(storagePath|inventory|adjustment|price)/);
});

test('posted purge removes invoice provenance and rebuilds remaining purchase metadata', () => {
  assert.match(migration, /DELETE FROM public\.inventory_adjustments/);
  assert.match(migration, /DELETE FROM public\.inventory_price_history/);
  assert.match(migration, /ORDER BY history\.purchase_date DESC, history\.created_at DESC, history\.id DESC/);
  assert.match(migration, /last_purchase_price = _latest_price/);
  assert.match(migration, /last_purchase_date = _latest_date/);
  assert.match(migration, /DELETE FROM public\.invoices/);
  assert.match(migration, /DELETE FROM public\.vendor_invoices/);
});

test('shared canonical records and unrelated workflows are never deleted or changed', () => {
  for (const table of ['products', 'vendors', 'vendor_products', 'inventory_items']) assert.doesNotMatch(migration, new RegExp(`DELETE FROM public\\.${table}`));
  assert.doesNotMatch(migration, /supply_requests|supply_request_items/);
  assert.doesNotMatch(migration, /CREATE OR REPLACE FUNCTION public\.post_reviewed_invoice/);
  assert.doesNotMatch(migration, /UPDATE public\.(products|vendors|vendor_products)/);
});

test('server derives storage identity after DB success and reports isolated storage failure', () => {
  assert.match(server, /rpc\('delete_invoice_permanently'/);
  assert.match(server, /remove\(\[result\.storagePath\]\)/);
  assert.match(server, /Document deleted, but its uploaded file could not be removed/);
});

test('owner UI gives posted invoices stronger, document-aware permanent confirmation', () => {
  assert.equal(documentTypeLabel('ORDER_CONFIRMATION'), 'order confirmation');
  assert.match(page, /Permanently delete/);
  assert.match(page, /selected\?\.posted/);
  assert.match(page, /inventory receipts, purchasing history, price history, and spend totals/);
  assert.match(page, /After deletion, MedSpend will behave as though this document was never uploaded/);
  assert.match(page, /formatCurrency\(selected\.total\)/);
  assert.match(page, /AlertDialogCancel/);
  assert.match(page, /deletion\.error/);
  assert.match(page, /setQueryData<InvoiceHistoryRow\[\]>/);
  for (const key of ['purchase-history', 'vendor-history', 'inventory-intelligence', 'inventory']) assert.match(page, new RegExp(`'${key}'`));
});

test('migration only installs capability and does not proactively mutate historical data', () => {
  const beforeFunction = migration.split('AS $$')[0];
  assert.doesNotMatch(beforeFunction, /DELETE FROM|UPDATE public\.|TRUNCATE/);
  assert.doesNotMatch(migration, /DROP TABLE|ALTER TABLE/);
});
