import type { InvoiceExtractionProvider } from './providers.ts';
import type { CanonicalInvoiceExtraction, ExtractedField } from './types.ts';

const parsed = <T>(value: T, confidence: number): ExtractedField<T> => ({ value, confidence, source: 'Parser', reviewed: false });
const money = (value?: string) => value ? Number(value.replace(/[$,]/g, '')) : null;

function label(text: string, names: string[]) {
  for (const name of names) {
    const match = text.match(new RegExp(`(?:^|\\n)\\s*${name}\\s*[:#]?\\s*([^\\n]+)`, 'im'));
    if (match) return match[1].trim();
  }
  return '';
}

function amount(text: string, names: string[]) {
  const value = label(text, names).match(/\$?\s*([\d,]+(?:\.\d{2})?)/)?.[1];
  return money(value);
}

function date(value: string) {
  const match = value.match(/(\d{1,4})[\/-](\d{1,2})[\/-](\d{1,4})/);
  if (!match) return '';
  const [, first, second, last] = match;
  let year = last; let month = first; let day = second;
  if (first.length === 4) { year = first; month = second; day = last; }
  if (year.length === 2) year = `20${year}`;
  const normalized = `${year}-${month.padStart(2, '0')}-${day.padStart(2, '0')}`;
  const parsedDate = new Date(`${normalized}T00:00:00Z`);
  return Number.isNaN(parsedDate.valueOf()) || parsedDate.toISOString().slice(0, 10) !== normalized ? '' : normalized;
}

function parseItems(text: string) {
  const items: CanonicalInvoiceExtraction['items'] = [];
  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    const match = line.match(/^(\S*[A-Za-z0-9][A-Za-z0-9-]*)\s{2,}(.+?)\s{2,}(\d+(?:\.\d+)?)\s+([A-Za-z][A-Za-z0-9 /-]*)\s+\$?([\d,]+(?:\.\d{2}))\s+\$?([\d,]+(?:\.\d{2}))$/)
      ?? line.match(/^([A-Za-z0-9][A-Za-z0-9-]{2,})\s+(.+?)\s+(\d+(?:\.\d+)?)\s+([A-Za-z][A-Za-z0-9/-]*)\s+\$?([\d,]+\.\d{2})\s+\$?([\d,]+\.\d{2})$/);
    if (!match || /^(sku|item|product)$/i.test(match[1])) continue;
    const quantity = Number(match[3]); const unitPrice = money(match[5]); const lineTotal = money(match[6]);
    if (!(quantity > 0) || unitPrice === null || lineTotal === null) continue;
    const plausible = Math.abs(quantity * unitPrice - lineTotal) <= Math.max(0.02, lineTotal * 0.01);
    items.push({
      sku: parsed(match[1], 88), description: parsed(match[2].trim(), 86), manufacturer: parsed('', 0),
      quantity: parsed(quantity, 92), unit: parsed(match[4].trim(), 82), unitPrice: parsed(unitPrice, 94),
      lineTotal: parsed(lineTotal, plausible ? 94 : 55), suggestedCategory: parsed('', 0),
    });
  }
  return items;
}

export class DeterministicInvoiceExtractionProvider implements InvoiceExtractionProvider {
  readonly name = 'deterministic-invoice-v1';
  async extractInvoice(rawText: string): Promise<CanonicalInvoiceExtraction> {
    const text = rawText.replace(/\r/g, '').replace(/[^\S\n]+/g, ' ').trim();
    if (!text) throw new Error('No document text is available to structure');
    const invoiceNumber = label(text, ['invoice\\s*(?:number|no\\.?|#)']);
    const invoiceDateRaw = label(text, ['invoice\\s*date', 'date']);
    const purchaseOrder = label(text, ['purchase\\s*order', 'p\\.?o\\.?\\s*(?:number|no\\.?|#)?']);
    const firstLine = text.split('\n').map((line) => line.trim()).find((line) => line && !/invoice/i.test(line)) ?? '';
    const vendor = label(text, ['vendor']) || firstLine;
    const result: CanonicalInvoiceExtraction = {
      header: {
        vendor: parsed(vendor, vendor ? 72 : 0), invoiceNumber: parsed(invoiceNumber, invoiceNumber ? 91 : 0),
        invoiceDate: parsed(date(invoiceDateRaw), date(invoiceDateRaw) ? 88 : 0),
        purchaseOrder: parsed(purchaseOrder, purchaseOrder ? 80 : 0),
        subtotal: parsed(amount(text, ['subtotal']), 90), tax: parsed(amount(text, ['(?:sales\\s+)?tax']), 86),
        shipping: parsed(amount(text, ['shipping', 'freight']), 82), total: parsed(amount(text, ['(?:invoice\\s+)?total', 'amount\\s+due']), 92),
      },
      items: parseItems(text),
    };
    for (const field of [result.header.subtotal, result.header.tax, result.header.shipping, result.header.total]) {
      if (field.value === null) field.confidence = 0;
    }
    const hasRecognizableHeader = Boolean(invoiceNumber || invoiceDateRaw || purchaseOrder
      || result.header.subtotal.value !== null || result.header.total.value !== null);
    if (!hasRecognizableHeader && !result.items.length) {
      throw new Error('Document text does not contain a recognizable invoice structure');
    }
    return result;
  }
}
