import assert from 'node:assert/strict';
import test from 'node:test';
import { EmbeddedPdfTextProvider } from '../src/extraction/embedded-pdf-text-provider.ts';
import { runDocumentTextExtraction } from '../src/extraction/pipeline.ts';
import { normalizeDocumentText, validateUsableDocumentText } from '../src/extraction/document-text-validation.ts';

function makePdf(lines: string[]): Uint8Array {
  const escape = (value: string) => value.replace(/([\\()])/g, '\\$1');
  const commands = lines.length
    ? `BT /F1 12 Tf 72 720 Td ${lines.map((line, index) => `${index ? '0 -18 Td ' : ''}(${escape(line)}) Tj`).join(' ')} ET`
    : '';
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    `<< /Length ${commands.length} >>\nstream\n${commands}\nendstream`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  let pdf = '%PDF-1.4\n';
  const offsets = [0];
  objects.forEach((object, index) => { offsets.push(pdf.length); pdf += `${index + 1} 0 obj\n${object}\nendobj\n`; });
  const xref = pdf.length;
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  pdf += offsets.slice(1).map((offset) => `${offset.toString().padStart(10, '0')} 00000 n \n`).join('');
  pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF`;
  return new TextEncoder().encode(pdf);
}

test('digital PDF embedded text is normalized with provider and page metadata', async () => {
  const pdf = makePdf([
    'HENRY SCHEIN INVOICE', 'Invoice Number HS-12345', 'Purchase Order PO-1002',
    'Gloves Quantity 4 Unit Price 18.75', 'Subtotal 75.00 Tax 5.25 Total 80.25',
  ]);
  const result = await runDocumentTextExtraction(pdf, new EmbeddedPdfTextProvider());
  assert.equal(result.status, 'success');
  assert.equal(result.ocrRequired, false);
  assert.equal(result.provider, 'unpdf-embedded-text');
  assert.equal(result.pageCount, 1);
  assert.match(result.text, /HENRY SCHEIN INVOICE/);
  assert.ok(result.durationMs >= 0);
});

test('PDF with no embedded text requires OCR and never fabricates text', async () => {
  const result = await runDocumentTextExtraction(makePdf([]), new EmbeddedPdfTextProvider());
  assert.equal(result.status, 'ocr_required');
  assert.equal(result.ocrRequired, true);
  assert.equal(result.text, '');
  assert.equal(result.pageCount, 1);
});

test('corrupt PDF rejects so the persistence boundary can record failure', async () => {
  await assert.rejects(
    () => runDocumentTextExtraction(new TextEncoder().encode('not a PDF'), new EmbeddedPdfTextProvider()),
  );
});

test('usable-text validation rejects short and binary-looking output deterministically', () => {
  assert.equal(validateUsableDocumentText('Invoice 1').usable, false);
  assert.equal(validateUsableDocumentText(`Invoice Total ${'\u0000'.repeat(100)}`).usable, false);
  const normalized = normalizeDocumentText(' Invoice\u00a0Number   123 \r\n Total  42.00 ');
  assert.equal(normalized, 'Invoice Number  123\nTotal  42.00');
});
