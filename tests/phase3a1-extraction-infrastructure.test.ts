import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const read = (path: string) => readFile(new URL(path, import.meta.url), 'utf8');

test('Phase 3A.1 stores provider-neutral extraction state without network or RLS changes', async () => {
  const [sql, providers, mocks] = await Promise.all([
    read('../supabase/migrations/20260810120000_phase3a1_extraction_infrastructure.sql'),
    read('../src/extraction/providers.ts'), read('../src/extraction/mock-providers.ts'),
  ]);
  assert.match(providers, /interface OCRProvider/);
  assert.match(providers, /interface InvoiceExtractionProvider/);
  assert.match(sql, /extraction_result jsonb/);
  assert.doesNotMatch(sql, /(?:CREATE|ALTER|DROP) POLICY|ENABLE ROW LEVEL SECURITY/i);
  assert.doesNotMatch(mocks, /fetch\(|openai|anthropic|textract|documentai/i);
});

test('review seeds drafts, exposes failure fallback, and approval still uses the original posting RPC', async () => {
  const [server, page] = await Promise.all([
    read('../src/lib/invoice-processing.functions.ts'),
    read('../src/components/invoice-processing/InvoiceReviewPage.tsx'),
  ]);
  assert.match(server, /runExtractionPipeline/);
  assert.match(server, /getExtractionProviders\(context\.enableMockInvoiceExtraction\)/);
  assert.match(server, /status === 'uploaded' && providers/);
  assert.match(server, /invoice_items'\)\.insert/);
  assert.match(server, /Extraction is optional/);
  assert.match(page, /Automatic extraction unavailable/);
  assert.match(page, /Automatic extraction is not configured/);
  assert.match(server, /rpc\('post_reviewed_invoice'/);
  assert.equal((server.match(/rpc\('post_reviewed_invoice'/g) ?? []).length, 1);
});

test('all extracted review values remain backed by existing editable save controls', async () => {
  const [header, item] = await Promise.all([
    read('../src/components/invoice-processing/InvoiceHeaderForm.tsx'),
    read('../src/components/invoice-processing/InvoiceItemDialog.tsx'),
  ]);
  for (const value of ['vendorName', 'invoiceNumber', 'invoiceDate', 'purchaseOrder', 'subtotal', 'tax', 'shipping', 'invoiceTotal']) {
    assert.match(header, new RegExp(`form\\.${value}`));
  }
  for (const value of ['sku', 'description', 'manufacturer', 'category', 'quantity', 'unitOfMeasure', 'unitPrice', 'totalPrice']) {
    assert.match(item, new RegExp(`form\\.${value}`));
  }
});
