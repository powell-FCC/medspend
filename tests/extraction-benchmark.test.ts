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
  { name: 'displaced-multi-row-order', headers: ['', '', '', '', null, 10, 4.25, 178], items: [['AX1001', 2, 12, 24], ['BX2002', 3, 11.25, 33.75], ['CX3003', 5, 6.2, 31], ['DX4004', 4, 18.75, 75]] },
] as const;

test('fixture benchmark reports exact header and line-item accuracy with no false positives', async (t) => {
  let headerCorrect = 0; let headerExpected = 0; let populatedHeaders = 0; let expectedPopulatedHeaders = 0; let headerFalsePositives = 0;
  let expectedItems = 0; let extractedItems = 0; let correctRows = 0;
  let skuCorrect = 0; let quantityCorrect = 0; let unitPriceCorrect = 0; let lineTotalCorrect = 0;
  for (const scenario of cases) {
    const extraction = validateExtraction(await new DeterministicInvoiceExtractionProvider().extractInvoice(await fixture(scenario.name)));
    const actualHeaders = [extraction.header.vendor.value, extraction.header.invoiceNumber.value, extraction.header.invoiceDate.value,
      extraction.header.purchaseOrder.value, extraction.header.subtotal.value, extraction.header.tax.value,
      extraction.header.shipping.value, extraction.header.total.value];
    scenario.headers.forEach((expected, index) => {
      const actual = actualHeaders[index]; const expectedPresent = expected !== '' && expected !== null; const actualPresent = actual !== '' && actual !== null;
      headerExpected++; if (actual === expected) headerCorrect++;
      if (expectedPresent) expectedPopulatedHeaders++; if (actualPresent) populatedHeaders++;
      if (actualPresent && actual !== expected) headerFalsePositives++;
    });
    expectedItems += scenario.items.length; extractedItems += extraction.items.length;
    scenario.items.forEach((expected, index) => {
      const actual = extraction.items[index];
      if (actual?.sku.value === expected[0]) skuCorrect++;
      if (actual?.quantity.value === expected[1]) quantityCorrect++;
      if (actual?.unitPrice.value === expected[2]) unitPriceCorrect++;
      if (actual?.lineTotal.value === expected[3]) lineTotalCorrect++;
      if (actual?.sku.value === expected[0] && actual.quantity.value === expected[1] && actual.unitPrice.value === expected[2] && actual.lineTotal.value === expected[3]) correctRows++;
    });
  }
  const fabricatedRows = Math.max(0, extractedItems - correctRows); const missedRows = Math.max(0, expectedItems - correctRows);
  const correctPopulatedHeaders = populatedHeaders - headerFalsePositives;
  const report = {
    headerCorrect, headerExpected,
    headerPrecision: correctPopulatedHeaders / populatedHeaders, headerRecall: correctPopulatedHeaders / expectedPopulatedHeaders,
    expectedItems, extractedItems, correctRows, missedRows, fabricatedRows,
    lineItemPrecision: correctRows / extractedItems, lineItemRecall: correctRows / expectedItems,
    skuCorrect, quantityCorrect, unitPriceCorrect, lineTotalCorrect, falsePositives: headerFalsePositives + fabricatedRows,
  };
  t.diagnostic(`extraction benchmark ${JSON.stringify(report)}`);
  assert.deepEqual(report, { headerCorrect: 40, headerExpected: 40, headerPrecision: 1, headerRecall: 1, expectedItems: 9, extractedItems: 9, correctRows: 9, missedRows: 0, fabricatedRows: 0, lineItemPrecision: 1, lineItemRecall: 1, skuCorrect: 9, quantityCorrect: 9, unitPriceCorrect: 9, lineTotalCorrect: 9, falsePositives: 0 });
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
