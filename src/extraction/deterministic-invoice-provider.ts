import type { InvoiceExtractionProvider } from './providers.ts';
import type { CanonicalInvoiceExtraction, ExtractedField } from './types.ts';
import { classifyDocument, extractVendorEvidence } from './document-identity.ts';

export interface ExtractionCandidateDiagnostic {
  field: string;
  value: string;
  accepted: boolean;
  reason: string;
  confidence: number;
  line: number;
}

export interface DeterministicExtractionDiagnostics {
  normalizedText: string;
  lines: string[];
  headerCandidates: ExtractionCandidateDiagnostic[];
  tableRegions: Array<{ startLine: number; endLine: number; headings: string[] }>;
  lineItemCandidates: Array<{ line: number; accepted: boolean; reason: string; value: string; quantity?: number; unitPrice?: number; expectedExtension?: number; matchedExtensionLine?: number }>;
  extensionCandidates: Array<{ line: number; value: number; usedBySku?: string }>;
  summary: { lineCount: number; detectedHeaderFields: number; detectedLineItems: number; reasonCodes: string[] };
  extraction: CanonicalInvoiceExtraction;
}

const parsed = <T>(value: T, confidence: number): ExtractedField<T> => ({ value, confidence, source: 'Parser', reviewed: false });
const EMAIL = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i;
const URL = /(?:https?:\/\/|www\.)\S+/i;
const PHONE = /(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}/;
const MONEY = /^\$?\s*\d{1,3}(?:,\d{3})*(?:\.\d{2})$|^\$?\s*\d+\.\d{2}$/;

const normalize = (value: string) => value.normalize('NFKC').replace(/\u00a0/g, ' ').replace(/\r/g, '')
  .split('\n').map((line) => line.replace(/\t/g, ' ').replace(/ {3,}/g, '  ').trim()).filter(Boolean);
const amount = (value: string) => Number(value.replace(/[$,\s]/g, ''));
const invalidIdentity = (value: string) => !value || EMAIL.test(value) || URL.test(value) || PHONE.test(value) || /^\d+$/.test(value);
const invalidIdentifier = (value: string) => !value || EMAIL.test(value) || value.includes('@') || URL.test(value) || PHONE.test(value) || /^(?:total|subtotal|tax|shipping|freight|invoice|order|ship|due)\b/i.test(value);

function normalizeDate(value: string) {
  const match = value.match(/\b(\d{1,4})[\/-](\d{1,2})[\/-](\d{1,4})\b/);
  if (!match) {
    const named = value.match(/\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2}),\s*(\d{4})\b/i);
    if (!named) return '';
    const parsedDate = new Date(`${named[1]} ${named[2]}, ${named[3]} 00:00:00 UTC`);
    return Number.isNaN(parsedDate.valueOf()) ? '' : parsedDate.toISOString().slice(0, 10);
  }
  const [, first, second, last] = match;
  let year = last; let month = first; let day = second;
  if (first.length === 4) { year = first; month = second; day = last; }
  if (year.length === 2) year = `20${year}`;
  const result = `${year}-${month.padStart(2, '0')}-${day.padStart(2, '0')}`;
  const date = new Date(`${result}T00:00:00Z`);
  return !Number.isNaN(date.valueOf()) && date.toISOString().slice(0, 10) === result ? result : '';
}

function candidateAfterLabel(lines: string[], pattern: RegExp) {
  for (let index = 0; index < lines.length; index++) {
    const match = lines[index].match(pattern);
    if (!match) continue;
    const sameLine = match[1]?.trim();
    if (sameLine) return { value: sameLine, line: index, relationship: 'same-line' as const };
    const next = lines[index + 1]?.trim();
    if (next && !/:$/.test(next)) return { value: next, line: index + 1, relationship: 'next-line' as const };
  }
  return null;
}

function findMoney(lines: string[], labels: RegExp) {
  const found = candidateAfterLabel(lines, labels);
  if (!found) return null;
  const match = found.value.match(/\$?\s*[\d,]+\.\d{2}\b/);
  return match && MONEY.test(match[0]) ? { ...found, value: match[0] } : null;
}

function findNumberedCharge(lines: string[], label: RegExp) {
  for (let index = 0; index < lines.length; index++) {
    const match = lines[index].match(/^\d+\s+(.+?)\s+([\d,]+\.\d{2})$/);
    if (match && label.test(match[1])) return { value: match[2], line: index, relationship: 'same-line' as const };
  }
  return null;
}

function findCorroboratedTotal(lines: string[], expected: number) {
  for (let index = 0; index < lines.length; index++) {
    if (!/^\s*total\s+amount\s*$/i.test(lines[index])) continue;
    const values = lines.slice(index + 1, index + 8).flatMap((line, offset) =>
      (line.match(/\b[\d,]+\.\d{2}\b/g) ?? []).map((value) => ({ value, line: index + offset + 1 })));
    const match = values.find((candidate) => Math.abs(amount(candidate.value) - expected) <= 0.02);
    if (match) return { ...match, relationship: 'nearby-arithmetic' as const };
  }
  return null;
}

function detectVendor(lines: string[], diagnostics: ExtractionCandidateDiagnostic[]) {
  const explicit = candidateAfterLabel(lines.slice(0, 30), /^\s*(?:vendor|seller|sold by)\s*[:#-]?\s*(.*)$/i);
  if (explicit) {
    const valid = !invalidIdentity(explicit.value) && !/^(?:ship|bill)\s+to/i.test(explicit.value);
    diagnostics.push({ field: 'vendor', value: explicit.value, accepted: valid, reason: valid ? 'EXPLICIT_VENDOR_LABEL' : 'INVALID_IDENTITY_VALUE', confidence: valid ? 94 : 0, line: explicit.line });
    if (valid) return parsed(explicit.value, 94);
  }
  for (let index = 0; index < Math.min(lines.length, 12); index++) {
    const value = lines[index];
    if (invalidIdentity(value)) {
      if (EMAIL.test(value)) diagnostics.push({ field: 'vendor', value, accepted: false, reason: 'EMAIL_ADDRESS', confidence: 0, line: index });
      continue;
    }
    const companySignal = /\b(?:inc\.?|llc|ltd\.?|corp(?:oration)?|company|medical|supply|supplies)\b/i.test(value);
    const excluded = /^(?:invoice|order confirmation|statement|ship to|bill to|purchase order)\b/i.test(value);
    const customerSection = lines.slice(0, index + 1).some((line) => /\b(?:ship|bill)[ -]?to\b/i.test(line));
    if (companySignal && !excluded && !customerSection) {
      diagnostics.push({ field: 'vendor', value, accepted: true, reason: 'TOP_COMPANY_IDENTITY', confidence: 76, line: index });
      return parsed(value, 76);
    }
  }
  return parsed('', 0);
}

function tableRegions(lines: string[]) {
  const regions: DeterministicExtractionDiagnostics['tableRegions'] = [];
  for (let i = 0; i < lines.length; i++) {
    const window = lines.slice(i, i + 10).join(' ').toLowerCase();
    const headings = ['item', 'description', 'qty', 'quantity', 'unit price', 'price', 'extension', 'amount', 'sku', 'code']
      .filter((heading) => window.includes(heading));
    if (new Set(headings).size >= 4) { regions.push({ startLine: i, endLine: lines.length - 1, headings }); break; }
  }
  return regions;
}

function parseColumnarInvoiceItems(
  lines: string[], region: DeterministicExtractionDiagnostics['tableRegions'][number],
  diagnostics: DeterministicExtractionDiagnostics['lineItemCandidates'],
) {
  const heading = lines[region.startLine].toLowerCase();
  const recognized = /\b(?:item|sku|product|catalog)\b/.test(heading) && /\b(?:quantity|qty)\b/.test(heading)
    && /\bunit\s+price\b/.test(heading) && /\b(?:line\s+amount|extension|extended|amount)\b/.test(heading);
  if (!recognized) return [];
  const end = lines.findIndex((line, index) => index > region.startLine && /^\s*subtotal\b/i.test(line));
  const rows: CanonicalInvoiceExtraction['items'] = [];
  const full = /^([A-Za-z0-9][A-Za-z0-9-]{2,})\s+(.+?)\s+(\S+)\s+(\d{1,2}[\/-]\d{1,2}[\/-]\d{2,4})\s+(\d+(?:\.\d+)?)\s+([A-Za-z][A-Za-z0-9/-]*)\s+([\d,]+\.\d{2})\s+(\d+(?:\.\d+)?)\s+([\d,]+\.\d{2})$/;
  const detail = /^(\S+)\s+(\d{1,2}[\/-]\d{1,2}[\/-]\d{2,4})\s+(\d+(?:\.\d+)?)\s+([A-Za-z][A-Za-z0-9/-]*)\s+([\d,]+\.\d{2})\s+(\d+(?:\.\d+)?)\s+([\d,]+\.\d{2})$/;
  for (let index = region.startLine + 1; index < (end >= 0 ? end : region.endLine + 1); index++) {
    let match = lines[index].match(full);
    let sku = ''; let description = ''; let quantity = 0; let unit = ''; let unitPrice = 0; let discount = 0; let lineTotal = 0;
    if (match) {
      sku = match[1]; description = match[2]; quantity = Number(match[5]); unit = match[6];
      unitPrice = amount(match[7]); discount = Number(match[8]); lineTotal = amount(match[9]);
    } else {
      const start = lines[index].match(/^([A-Za-z0-9][A-Za-z0-9-]{2,})\s+(.+)$/);
      if (!start) continue;
      sku = start[1]; let descriptionParts = [start[2]];
      let detailMatch: RegExpMatchArray | null = null; let detailIndex = index + 1;
      for (; detailIndex <= Math.min(index + 3, (end >= 0 ? end : region.endLine)); detailIndex++) {
        detailMatch = lines[detailIndex].match(detail);
        if (detailMatch) break;
        const nestedStart = lines[detailIndex].match(/^([A-Za-z0-9-]*[A-Za-z][A-Za-z0-9-]*\d[A-Za-z0-9-]*)\s+(.+)$/);
        if (nestedStart) { sku = nestedStart[1]; descriptionParts = [nestedStart[2]]; continue; }
        descriptionParts.push(lines[detailIndex]);
      }
      if (!detailMatch) { diagnostics.push({ line: index, accepted: false, reason: 'INCOMPLETE_COLUMNAR_ROW', value: lines[index] }); continue; }
      description = descriptionParts.join(' ');
      quantity = Number(detailMatch[3]); unit = detailMatch[4]; unitPrice = amount(detailMatch[5]);
      discount = Number(detailMatch[6]); lineTotal = amount(detailMatch[7]); index = detailIndex;
    }
    const expected = Math.round(quantity * unitPrice * (1 - discount / 100) * 100) / 100;
    const accepted = quantity > 0 && discount >= 0 && discount <= 100 && Math.abs(expected - lineTotal) <= 0.02;
    diagnostics.push({ line: index, accepted, reason: accepted ? 'DISCOUNTED_COLUMNAR_ROW_ARITHMETIC_MATCH' : 'DISCOUNTED_ROW_ARITHMETIC_MISMATCH', value: lines[index], quantity, unitPrice, expectedExtension: expected });
    if (!accepted) continue;
    rows.push({
      sku: parsed(sku, 94), description: parsed(description, 88), manufacturer: parsed('', 0), quantity: parsed(quantity, 96),
      unit: parsed(unit, 94), unitPrice: parsed(unitPrice, 96), lineTotal: parsed(lineTotal, 98), suggestedCategory: parsed('', 0),
      discountPercent: parsed(discount, 94),
    });
  }
  return rows;
}

function parseItems(
  lines: string[], regions: DeterministicExtractionDiagnostics['tableRegions'],
  diagnostics: DeterministicExtractionDiagnostics['lineItemCandidates'],
  extensionCandidates: DeterministicExtractionDiagnostics['extensionCandidates'],
) {
  if (!regions.length) return [];
  const items: CanonicalInvoiceExtraction['items'] = [];
  const start = regions[0].startLine;
  const columnar = parseColumnarInvoiceItems(lines, regions[0], diagnostics);
  if (columnar.length) return columnar;
  const firstProductLine = lines.findIndex((line, index) => index >= start && /^\d+\s+[A-Za-z0-9-]{3,}\s+\S+\s+/.test(line));
  for (let index = Math.max(start, firstProductLine + 1); index < lines.length; index++) {
    if (/^\$?[\d,]+\.\d{2}$/.test(lines[index])) extensionCandidates.push({ line: index, value: amount(lines[index]) });
  }
  for (let index = start; index < lines.length; index++) {
    const line = lines[index];
    const combined = `${line} ${lines[index + 1] ?? ''}`;
    const standard = line.match(/^([A-Za-z0-9][A-Za-z0-9-]{2,})\s+(.+?)\s+(\d+(?:\.\d+)?)\s+([A-Za-z][A-Za-z0-9/-]*)\s+\$?([\d,]+\.\d{2})\s+\$?([\d,]+\.\d{2})$/)
      ?? combined.match(/^([A-Za-z0-9][A-Za-z0-9-]{2,})\s+(.+?)\s+(\d+(?:\.\d+)?)\s+([A-Za-z][A-Za-z0-9/-]*)\s+\$?([\d,]+\.\d{2})\s+\$?([\d,]+\.\d{2})$/);
    if (standard && !/^(?:item|sku|code)$/i.test(standard[1])) {
      const quantity = Number(standard[3]); const unitPrice = amount(standard[5]); const lineTotal = amount(standard[6]);
      const plausible = Math.abs(quantity * unitPrice - lineTotal) <= Math.max(0.02, lineTotal * 0.01);
      diagnostics.push({ line: index, accepted: plausible, reason: plausible ? 'COMPLETE_ROW_ARITHMETIC_MATCH' : 'ROW_ARITHMETIC_MISMATCH', value: line, quantity, unitPrice, expectedExtension: Math.round(quantity * unitPrice * 100) / 100 });
      if (!plausible) continue;
      items.push({ sku: parsed(standard[1], 92), description: parsed(standard[2], 90), manufacturer: parsed('', 0), quantity: parsed(quantity, 96), unit: parsed(standard[4], 86), unitPrice: parsed(unitPrice, 96), lineTotal: parsed(lineTotal, 98), suggestedCategory: parsed('', 0) });
      if (!line.match(/\d+\.\d{2}\s+\$?[\d,]+\.\d{2}$/)) index++;
      continue;
    }
    const split = line.match(/^\d+\s+([A-Za-z0-9-]{3,})\s+(\S+)\s+(.+)\s+(\d+(?:\.\d+)?)\s+((?:drop\s+ship|shipping|shipped|backordered?|pending)(?:\s+\S+)*)\s+([\d,]+\.\d{2})$/i);
    if (!split) continue;
    const [, sku, packageUnit, description, quantityText, , unitPriceText] = split;
    const quantity = Number(quantityText); const unitPrice = amount(unitPriceText);
    const expected = Math.round(quantity * unitPrice * 100) / 100;
    const matches = extensionCandidates.filter((candidate) => candidate.usedBySku === undefined && candidate.line > index && Math.abs(candidate.value - expected) <= 0.02);
    const extension = matches.length === 1 ? matches[0] : undefined;
    const accepted = extension !== undefined && description.length >= 3;
    diagnostics.push({ line: index, accepted, reason: accepted ? 'SPLIT_ROW_ARITHMETIC_RECONSTRUCTION' : matches.length > 1 ? 'AMBIGUOUS_CORROBORATING_EXTENSION' : 'MISSING_CORROBORATING_EXTENSION', value: line, quantity, unitPrice, expectedExtension: expected, matchedExtensionLine: extension?.line });
    if (!accepted) continue;
    extension.usedBySku = sku;
    const unit = packageUnit.includes('/') ? packageUnit.split('/').at(-1) ?? '' : packageUnit;
    items.push({ sku: parsed(sku, 90), description: parsed(description, 78), manufacturer: parsed('', 0), quantity: parsed(quantity, 94), unit: parsed(unit, 70), unitPrice: parsed(unitPrice, 94), lineTotal: parsed(extension.value, 98), suggestedCategory: parsed('', 0) });
  }
  return items;
}

export class DeterministicInvoiceExtractionProvider implements InvoiceExtractionProvider {
  readonly name = 'deterministic-invoice-v2';
  async extractInvoice(rawText: string) { return (await this.extractInvoiceWithDiagnostics(rawText)).extraction; }

  async extractInvoiceWithDiagnostics(rawText: string): Promise<DeterministicExtractionDiagnostics> {
    const lines = normalize(rawText);
    if (!lines.length) throw new Error('No document text is available to structure');
    const headerCandidates: ExtractionCandidateDiagnostic[] = [];
    const classification = classifyDocument(lines.join('\n'));
    headerCandidates.push({ field: 'documentType', value: classification.type, accepted: classification.type !== 'UNKNOWN', reason: classification.evidence || 'NO_EXPLICIT_DOCUMENT_LABEL', confidence: classification.confidence, line: 0 });
    const pairedIndex = lines.findIndex((line) => /invoice\s*(?:number|no\.?|#)/i.test(line) && /invoice\s+date/i.test(line));
    const pairedValues = pairedIndex >= 0 ? lines[pairedIndex + 1]?.split(/\s{2,}/) : undefined;
    const invoiceNumberCandidate = classification.type === 'INVOICE' && pairedValues?.[0]
      ? { value: pairedValues[0], line: pairedIndex + 1, relationship: 'next-line' as const }
      : classification.type === 'INVOICE' ? (candidateAfterLabel(lines, /^\s*(?:sales\s+)?(?:invoice|inv)\s+(?:number|no\.?)\s*[:#-]?\s*(\S.*)$/i)
        ?? candidateAfterLabel(lines, /^\s*(?:sales\s+)?(?:invoice|inv)\s*(?:#|:|-)\s*(\S.*)$/i)) : null;
    const invoiceDateCandidate = classification.type === 'INVOICE' && pairedValues?.[1]
      ? { value: pairedValues[1], line: pairedIndex + 1, relationship: 'next-line' as const }
      : classification.type === 'INVOICE' ? candidateAfterLabel(lines, /^\s*(?:invoice\s+date|date\s+of\s+invoice)\s*[:#-]?\s*(.*)$/i) : null;
    const poCandidate = candidateAfterLabel(lines, /^\s*(?:purchase\s+order|p\.?o\.?)(?:\s*(?:number|no\.?|#))?\s*[:#-]?\s*(.*)$/i)
      ?? candidateAfterLabel(lines, /^\s*customer\s+(?:purchase\s+order|p\.?o\.?)(?:\s*(?:number|no\.?|#))?\s*[:#-]+\s*(\S.*)$/i);
    const orderNumberText = classification.type === 'ORDER_CONFIRMATION'
      ? rawText.match(/\byour\s+order\s+([A-Z0-9-]{4,})\b/i)?.[1] ?? rawText.match(/\border\s+(?:number|no\.?|#)\s*[:#-]?\s*([A-Z0-9-]{4,})\b/i)?.[1] ?? '' : '';
    const orderDateIndex = classification.type === 'ORDER_CONFIRMATION' ? lines.findIndex((line) => /order\s+date/i.test(line)) : -1;
    const orderDateValue = orderDateIndex >= 0 ? lines.slice(orderDateIndex, orderDateIndex + 7).map(normalizeDate).find(Boolean) ?? '' : '';
    const acceptIdentifier = (field: string, candidate: ReturnType<typeof candidateAfterLabel>, confidence: number) => {
      if (!candidate) return parsed('', 0);
      const valid = !invalidIdentifier(candidate.value);
      headerCandidates.push({ field, value: candidate.value, accepted: valid, reason: valid ? `EXPLICIT_LABEL_${candidate.relationship.toUpperCase()}` : 'INVALID_IDENTIFIER_VALUE', confidence: valid ? confidence : 0, line: candidate.line });
      return parsed(valid ? candidate.value : '', valid ? confidence : 0);
    };
    const contextualDate = !invoiceDateCandidate && invoiceNumberCandidate
      ? lines.slice(Math.max(0, invoiceNumberCandidate.line - 2), invoiceNumberCandidate.line + 3)
        .map((value, offset) => ({ value, line: Math.max(0, invoiceNumberCandidate.line - 2) + offset }))
        .filter((candidate) => Boolean(normalizeDate(candidate.value)))
        .sort((left, right) => Math.abs(left.line - invoiceNumberCandidate.line) - Math.abs(right.line - invoiceNumberCandidate.line))[0] ?? null : null;
    const selectedDate = invoiceDateCandidate ?? (contextualDate ? { ...contextualDate, relationship: 'invoice-context' as const } : null);
    const invoiceDateValue = selectedDate ? normalizeDate(selectedDate.value) : '';
    if (selectedDate) headerCandidates.push({ field: 'invoiceDate', value: selectedDate.value, accepted: Boolean(invoiceDateValue), reason: invoiceDateValue ? (invoiceDateCandidate ? 'EXPLICIT_INVOICE_DATE' : 'DATE_ADJACENT_TO_INVOICE_IDENTITY') : 'INVALID_DATE', confidence: invoiceDateValue ? (invoiceDateCandidate ? 92 : 88) : 0, line: selectedDate.line });
    const monetary = (field: string, labels: RegExp, confidence: number, fallback?: { value: string; line: number; relationship: string } | null) => {
      const found = findMoney(lines, labels) ?? fallback ?? null;
      if (found) headerCandidates.push({ field, value: found.value, accepted: true, reason: 'EXPLICIT_MONETARY_LABEL', confidence, line: found.line });
      return parsed(found ? amount(found.value) : null, found ? confidence : 0);
    };
    const regions = tableRegions(lines); const lineItemCandidates: DeterministicExtractionDiagnostics['lineItemCandidates'] = [];
    const extensionCandidates: DeterministicExtractionDiagnostics['extensionCandidates'] = [];
    const items = parseItems(lines, regions, lineItemCandidates, extensionCandidates);
    const shippingFallback = findNumberedCharge(lines, /^(?:shipping|freight)(?:\s+and\/or\s+handling)?$/i);
    const taxFallback = findNumberedCharge(lines, /^(?:sales\s+)?tax$/i);
    const itemSum = items.reduce((sum, item) => sum + item.lineTotal.value, 0);
    const expectedTotal = itemSum + (shippingFallback ? amount(shippingFallback.value) : 0) + (taxFallback ? amount(taxFallback.value) : 0);
    const totalFallback = expectedTotal > 0 ? findCorroboratedTotal(lines, expectedTotal) : null;
    const extraction: CanonicalInvoiceExtraction = {
      header: {
        documentType: parsed(classification.type, classification.confidence),
        vendor: detectVendor(lines, headerCandidates), invoiceNumber: acceptIdentifier('invoiceNumber', invoiceNumberCandidate, 94),
        invoiceDate: parsed(invoiceDateValue, invoiceDateValue ? 92 : 0), orderNumber: parsed(orderNumberText, orderNumberText ? 94 : 0),
        orderDate: parsed(orderDateValue, orderDateValue ? 92 : 0), purchaseOrder: acceptIdentifier('purchaseOrder', poCandidate, 90),
        subtotal: monetary('subtotal', /^\s*subtotal\s*[:#-]?\s*(.*)$/i, 94),
        tax: monetary('tax', /^\s*(?:(?:total|sales)\s+tax|tax)\s*[:#-]?\s*(.*)$/i, 92, taxFallback),
        shipping: monetary('shipping', /^\s*(?:shipping|freight)(?:\s+(?:and\/or\s+)?handling)?\s*[:#-]?\s*(.*)$/i, 88, shippingFallback),
        total: monetary('total', /^\s*(?:grand\s+total|invoice\s+total|total\s+(?:amount|usd)|amount\s+due|total(?!\s+(?:tax|applied)))\s*[:#-]?\s*(.*)$/i, 94, totalFallback),
      },
      vendorEvidence: extractVendorEvidence(rawText),
      items,
    };
    const recognizable = Object.entries(extraction.header).some(([name, field]) => name !== 'documentType' && field.value !== '' && field.value !== null) || extraction.items.length;
    if (!recognizable) throw new Error('Document text does not contain a recognizable invoice structure');
    return {
      normalizedText: lines.join('\n'), lines, headerCandidates, tableRegions: regions, lineItemCandidates, extensionCandidates,
      summary: { lineCount: lines.length, detectedHeaderFields: Object.values(extraction.header).filter((field) => field.value !== '' && field.value !== null).length, detectedLineItems: extraction.items.length, reasonCodes: [] },
      extraction,
    };
  }
}
