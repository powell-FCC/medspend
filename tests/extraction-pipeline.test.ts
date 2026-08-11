import assert from 'node:assert/strict';
import test from 'node:test';
import { HENRY_SCHEIN_MOCK_EXTRACTION, MockInvoiceExtractionProvider, MockOCRProvider } from '../src/extraction/mock-providers.ts';
import { getExtractionProviders, runExtractionPipeline } from '../src/extraction/pipeline.ts';
import type { InvoiceExtractionProvider, OCRProvider } from '../src/extraction/providers.ts';
import { validateExtraction } from '../src/extraction/validation.ts';

test('mock extraction deterministically produces a realistic Henry Schein invoice', async () => {
  const result = await runExtractionPipeline(new Uint8Array([37, 80, 68, 70]), {
    ocr: new MockOCRProvider(), invoice: new MockInvoiceExtractionProvider(),
  });
  assert.deepEqual(result.extraction, HENRY_SCHEIN_MOCK_EXTRACTION);
  assert.equal(result.extraction.header.vendor.value, 'Henry Schein, Inc.');
  assert.equal(result.extraction.items.length, 4);
  const lineTotal = Math.round(result.extraction.items.reduce((sum, item) => sum + item.lineTotal.value, 0) * 100) / 100;
  assert.equal(lineTotal, result.extraction.header.subtotal.value);
});

test('all canonical fields carry bounded confidence, source, and reviewed metadata', () => {
  const extraction = validateExtraction(structuredClone(HENRY_SCHEIN_MOCK_EXTRACTION));
  const fields = [...Object.values(extraction.header), ...extraction.items.flatMap(Object.values)];
  assert.ok(fields.length > 0);
  for (const field of fields) {
    assert.ok(field.confidence >= 0 && field.confidence <= 100);
    assert.ok(['OCR', 'Parser', 'LLM', 'User'].includes(field.source));
    assert.equal(field.reviewed, false);
  }
});

test('providers are injectable and pipeline failures are observable to the fallback boundary', async () => {
  const failingOCR: OCRProvider = { name: 'failing-ocr', extractText: async () => { throw new Error('mock OCR failure'); } };
  const unusedExtraction: InvoiceExtractionProvider = { name: 'unused', extractInvoice: async () => HENRY_SCHEIN_MOCK_EXTRACTION };
  await assert.rejects(() => runExtractionPipeline(new Uint8Array(), { ocr: failingOCR, invoice: unusedExtraction }), /mock OCR failure/);
});

test('mock providers are disabled by default and only selected explicitly', () => {
  assert.equal(getExtractionProviders(), null);
  assert.equal(getExtractionProviders(false), null);
  const providers = getExtractionProviders(true);
  assert.ok(providers);
  assert.equal(providers.ocr.name, 'mock-ocr');
  assert.equal(providers.invoice.name, 'mock-invoice-extraction');
});
