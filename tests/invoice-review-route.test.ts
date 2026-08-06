import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { invoiceReviewParams } from '../src/invoice/review-route.ts';

test('an uploaded vendor invoice with zero extracted items can open manual review', async () => {
  const vendorInvoiceId = '3c87b477-4189-4392-bd6a-b6d0eaccf213';
  const uploadedInvoice = { vendorInvoiceId, status: 'uploaded', itemsProcessed: 0 } as const;

  assert.deepEqual(invoiceReviewParams(uploadedInvoice.vendorInvoiceId), { invoiceId: vendorInvoiceId });
  assert.equal(`/invoices/${invoiceReviewParams(uploadedInvoice.vendorInvoiceId).invoiceId}`, `/invoices/${vendorInvoiceId}`);

  const [invoiceLayout, invoiceIndex, invoiceList] = await Promise.all([
    readFile(new URL('../src/routes/_authenticated/invoices.tsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/routes/_authenticated/invoices.index.tsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/components/invoice-history/InvoiceListPage.tsx', import.meta.url), 'utf8'),
  ]);
  assert.match(invoiceLayout, /component: Outlet/);
  assert.match(invoiceIndex, /component: InvoiceListPage/);
  assert.match(invoiceList, /invoiceReviewParams\(invoice\.vendorInvoiceId\)/);

  const reviewServer = await readFile(new URL('../src/lib/invoice-processing.functions.ts', import.meta.url), 'utf8');
  assert.match(reviewServer, /processing_status: completed \? 'completed' : 'review_required'/);
  assert.match(reviewServer, /onConflict: 'source_file_id'/);
  assert.doesNotMatch(reviewServer, /itemsProcessed/);
});
