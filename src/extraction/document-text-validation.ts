export interface UsableTextValidation {
  usable: boolean;
  normalizedText: string;
  characterCount: number;
  printableRatio: number;
  lineCount: number;
  invoiceTokenCount: number;
  reason?: string;
}

const INVOICE_TOKENS = /\b(invoice|subtotal|total|tax|shipping|amount due|purchase order|quantity|unit price|vendor)\b/gi;

export function normalizeDocumentText(value: string): string {
  return value.normalize('NFKC').replace(/\u00a0/g, ' ').replace(/\r\n?/g, '\n')
    .split('\n').map((line) => line.replace(/[\t ]+/g, ' ').trim()).join('\n')
    .replace(/\n{3,}/g, '\n\n').trim();
}

export function validateUsableDocumentText(value: string): UsableTextValidation {
  const normalizedText = normalizeDocumentText(value);
  const characterCount = normalizedText.length;
  const lineCount = normalizedText ? normalizedText.split('\n').filter(Boolean).length : 0;
  const invoiceTokenCount = normalizedText.match(INVOICE_TOKENS)?.length ?? 0;
  const nonWhitespace = [...normalizedText].filter((character) => !/\s/u.test(character));
  const printable = nonWhitespace.filter((character) => !/[\p{Cc}\p{Cs}]/u.test(character));
  const printableRatio = nonWhitespace.length ? printable.length / nonWhitespace.length : 0;
  let reason: string | undefined;
  if (characterCount < 80) reason = 'Extracted text is too short.';
  else if (printableRatio < 0.9) reason = 'Extracted text contains too many non-printable characters.';
  else if (lineCount < 3 && invoiceTokenCount < 2) reason = 'Extracted text lacks sufficient document structure.';
  return { usable: !reason, normalizedText: reason ? '' : normalizedText, characterCount, printableRatio, lineCount, invoiceTokenCount, reason };
}

