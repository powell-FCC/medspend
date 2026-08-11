import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { DeterministicInvoiceExtractionProvider } from '../src/extraction/deterministic-invoice-provider.ts';
import { validateExtraction } from '../src/extraction/validation.ts';

const fixture = (name: string) => readFile(new URL(`fixtures/invoices/${name}.txt`, import.meta.url), 'utf8');

const cases = [
  { name: 'standard', headers: ['Northstar Medical Supply, Inc.', 'INV-1042', '2026-08-10', 'PO-88', 406.32, 28.44, 10, 444.76], items: [['A100', 4, 87, 348], ['B200', 12, 4.86, 58.32]] },
  { name: 'wrapped-description', headers: ['Acme Healthcare, LLC', 'INV-22', '2026-08-09', '', 25, 0, null, 25], items: [['G100', 2, 12.5, 25]] },
  { name: 'no-po-zero-tax', headers: ['Central Clinical Supply Corp.', 'C-500', '2026-08-08', '', 30, 0, null, 30], items: [['C500', 2, 15, 30]] },
  { name: 'freight', headers: ['Regional Medical Company', 'R-77', '2026-08-07', 'P-19', 30, null, 5, 35], items: [['R100', 3, 10, 30]] },
] as const;

test('fixture benchmark reports exact header and line-item accuracy with no false positives', async (t) => {
  let headerCorrect = 0; let headerExpected = 0; let expectedItems = 0; let extractedItems = 0;
  let skuCorrect = 0; let quantityCorrect = 0; let unitPriceCorrect = 0; let lineTotalCorrect = 0;
  for (const scenario of cases) {
    const extraction = validateExtraction(await new DeterministicInvoiceExtractionProvider().extractInvoice(await fixture(scenario.name)));
    const actualHeaders = [extraction.header.vendor.value, extraction.header.invoiceNumber.value, extraction.header.invoiceDate.value,
      extraction.header.purchaseOrder.value, extraction.header.subtotal.value, extraction.header.tax.value,
      extraction.header.shipping.value, extraction.header.total.value];
    scenario.headers.forEach((expected, index) => { headerExpected++; if (actualHeaders[index] === expected) headerCorrect++; });
    expectedItems += scenario.items.length; extractedItems += extraction.items.length;
    scenario.items.forEach((expected, index) => {
      const actual = extraction.items[index];
      if (actual?.sku.value === expected[0]) skuCorrect++;
      if (actual?.quantity.value === expected[1]) quantityCorrect++;
      if (actual?.unitPrice.value === expected[2]) unitPriceCorrect++;
      if (actual?.lineTotal.value === expected[3]) lineTotalCorrect++;
    });
  }
  const report = { headerCorrect, headerExpected, expectedItems, extractedItems, skuCorrect, quantityCorrect, unitPriceCorrect, lineTotalCorrect, falsePositives: Math.max(0, extractedItems - expectedItems) };
  t.diagnostic(`extraction benchmark ${JSON.stringify(report)}`);
  assert.deepEqual(report, { headerCorrect: 32, headerExpected: 32, expectedItems: 5, extractedItems: 5, skuCorrect: 5, quantityCorrect: 5, unitPriceCorrect: 5, lineTotalCorrect: 5, falsePositives: 0 });
});

test('sanitized email-header regression cannot populate identity fields and is partial, not full success', async () => {
  const extraction = validateExtraction(await new DeterministicInvoiceExtractionProvider().extractInvoice(await fixture('email-near-header')));
  assert.equal(extraction.header.vendor.value, '');
  assert.equal(extraction.header.purchaseOrder.value, '');
  assert.equal(extraction.header.invoiceNumber.value, '');
  assert.ok(extraction.items.every((item) => !item.sku.value.includes('@')));
  assert.equal(extraction.items.length, 1);
  assert.equal(extraction.quality?.state, 'STRUCTURED_PARTIAL');
});

test('ambiguous and unstructured documents create no guessed fields', async () => {
  for (const name of ['ambiguous-identifiers', 'unstructured']) {
    await assert.rejects(() => fixture(name).then((text) => new DeterministicInvoiceExtractionProvider().extractInvoice(text)), /recognizable invoice structure/);
  }
});

test('unsafe rows are not fabricated and zero line items cannot be full success', async () => {
  const extraction = validateExtraction(await new DeterministicInvoiceExtractionProvider().extractInvoice(await fixture('unsafe-rows')));
  assert.equal(extraction.items.length, 0);
  assert.notEqual(extraction.quality?.state, 'STRUCTURED_SUCCESS');
  assert.ok(extraction.quality?.reasonCodes.includes('NO_LINE_ITEMS'));
});
