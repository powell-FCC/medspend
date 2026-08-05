import assert from 'node:assert/strict';
import test from 'node:test';
import { calculateInvoiceLineTotal } from '../src/invoice/line-item.ts';

test('invoice line totals multiply quantity by unit price', () => {
  assert.equal(calculateInvoiceLineTotal(4, 12.5), 50);
});

test('invoice line totals round monetary values to cents', () => {
  assert.equal(calculateInvoiceLineTotal(3, 10.005), 30.02);
});

test('invoice line totals reject invalid negative values', () => {
  assert.equal(calculateInvoiceLineTotal(-1, 10), 0);
  assert.equal(calculateInvoiceLineTotal(1, Number.NaN), 0);
});

