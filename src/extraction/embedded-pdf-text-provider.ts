import { extractText } from 'unpdf';
import type { OCRProvider } from './providers.ts';

export class EmbeddedPdfTextProvider implements OCRProvider {
  readonly name = 'unpdf-embedded-text';

  async extractText(pdfBytes: Uint8Array) {
    const { text, totalPages } = await extractText(pdfBytes, { mergePages: false });
    return { text: text.join('\n\n'), provider: this.name, pageCount: totalPages };
  }
}
