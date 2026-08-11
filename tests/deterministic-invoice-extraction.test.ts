import assert from 'node:assert/strict';
import test from 'node:test';
import { DeterministicInvoiceExtractionProvider } from '../src/extraction/deterministic-invoice-provider.ts';
import { validateExtraction } from '../src/extraction/validation.ts';

const realisticInvoice = `Henry Schein, Inc.
Invoice Number: 12345678
Invoice Date: 08/10/2026
Purchase Order: ABC-123

SKU  Description  Qty Unit Unit Price Line Total
123456  White Athletic Tape  4 case 87.00 348.00
654321  PowerFlex 4 inch  12 each 4.86 58.32

Subtotal: $406.32
Tax: $28.44
Shipping: $10.00
Total: $444.76`;

test('extracts canonical headers and multiple line items from realistic embedded text', async () => {
  const extraction = validateExtraction(await new DeterministicInvoiceExtractionProvider().extractInvoice(realisticInvoice));
  assert.equal(extraction.header.vendor.value, 'Henry Schein, Inc.');
  assert.equal(extraction.header.invoiceNumber.value, '12345678');
  assert.equal(extraction.header.invoiceDate.value, '2026-08-10');
  assert.equal(extraction.header.purchaseOrder.value, 'ABC-123');
  assert.deepEqual(
    [extraction.header.subtotal.value, extraction.header.tax.value, extraction.header.shipping.value, extraction.header.total.value],
    [406.32, 28.44, 10, 444.76],
  );
  assert.equal(extraction.items.length, 2);
  assert.deepEqual(extraction.items.map(({ sku, quantity, unitPrice, lineTotal }) =>
    [sku.value, quantity.value, unitPrice.value, lineTotal.value]), [
    ['123456', 4, 87, 348], ['654321', 12, 4.86, 58.32],
  ]);
  assert.equal(extraction.reconciliation?.needsReview, false);
  assert.equal(extraction.header.vendor.source, 'Parser');
});

test('preserves missing optional values as low-confidence blanks', async () => {
  const extraction = validateExtraction(await new DeterministicInvoiceExtractionProvider().extractInvoice(
    `Acme Medical\nInvoice #: INV-9\nA100  Gauze Pads  2 box 5.00 10.00\nTotal: 10.00`,
  ));
  assert.equal(extraction.header.purchaseOrder.value, '');
  assert.equal(extraction.header.purchaseOrder.confidence, 0);
  assert.equal(extraction.items[0].manufacturer.value, '');
  assert.equal(extraction.items[0].suggestedCategory.value, '');
});

test('flags low-confidence line math and financial reconciliation mismatches without rejecting review', async () => {
  const extraction = validateExtraction(await new DeterministicInvoiceExtractionProvider().extractInvoice(
    realisticInvoice.replace('58.32', '60.00').replace('Subtotal: $406.32', 'Subtotal: $999.00'),
  ));
  assert.ok(extraction.items[1].lineTotal.confidence < 75);
  assert.equal(extraction.reconciliation?.lineItemsMatchSubtotal, false);
  assert.equal(extraction.reconciliation?.componentsMatchTotal, false);
  assert.equal(extraction.reconciliation?.needsReview, true);
});

test('malformed text fails safely', async () => {
  await assert.rejects(
    () => new DeterministicInvoiceExtractionProvider().extractInvoice('unstructured words with no recognizable fields'),
    /recognizable invoice structure/,
  );
});
