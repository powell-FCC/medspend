import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const read = (path: string) => readFile(new URL(path, import.meta.url), 'utf8');

test('Phase 3A.2 persists raw text and metadata on the unique processing job', async () => {
  const [sql, server] = await Promise.all([
    read('../supabase/migrations/20260811120000_phase3a2_embedded_pdf_text.sql'),
    read('../src/lib/invoice-processing.functions.ts'),
  ]);
  for (const column of ['document_text_status', 'raw_extracted_text', 'document_page_count', 'document_processing_duration_ms', 'ocr_required']) {
    assert.match(sql, new RegExp(column));
  }
  assert.match(server, /raw_extracted_text: result\.status === 'success' \? result\.text : null/);
  assert.match(server, /ocr_provider: result\.provider/);
  assert.doesNotMatch(sql, /CREATE TABLE/i);
});

test('document extraction is idempotent, retry-safe, and organization scoped', async () => {
  const server = await read('../src/lib/invoice-processing.functions.ts');
  assert.match(server, /eq\('invoice_id', sourceFileId\)\.eq\('organization_id', organizationId\)/);
  assert.match(server, /eq\('status', 'uploaded'\)/);
  assert.match(server, /invoice_processing_jobs'\)\.update/);
  assert.doesNotMatch(server, /invoice_processing_jobs'\)\.insert/);
  assert.match(server, /assertOwner\(context\.supabase, context\.userId, data\.organizationId\)/);
});

test('embedded text never populates draft invoice fields and approval remains unchanged', async () => {
  const server = await read('../src/lib/invoice-processing.functions.ts');
  const embeddedFunction = server.slice(server.indexOf('async function attemptEmbeddedTextExtraction'), server.indexOf('export const getInvoiceReviewFn'));
  assert.doesNotMatch(embeddedFunction, /from\('invoices'\)|from\('invoice_items'\)/);
  assert.match(server, /rpc\('post_reviewed_invoice'/);
  assert.equal((server.match(/rpc\('post_reviewed_invoice'/g) ?? []).length, 1);
});

test('manual review exposes success, OCR-required, and failure states', async () => {
  const page = await read('../src/components/invoice-processing/InvoiceReviewPage.tsx');
  assert.match(page, /Document text extracted successfully/);
  assert.match(page, /OCR is required for this PDF/);
  assert.match(page, /Document text extraction failed/);
  assert.match(page, /Approve invoice/);
});

