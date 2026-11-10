import { extractText } from 'unpdf';
import type { OCRProvider } from './providers.ts';

export class EmbeddedPdfTextProvider implements OCRProvider {
  readonly name = 'unpdf-embedded-text';

  // Phase 6C.4: batch intake reads the same per-page text to find invoice boundaries.
  async extractPages(pdfBytes: Uint8Array) {
    const { text, totalPages } = await extractText(pdfBytes, { mergePages: false });
    return { pages: text, pageCount: totalPages };
  }

  async extractText(pdfBytes: Uint8Array) {
    const { pages, pageCount } = await this.extractPages(pdfBytes);
    return { text: pages.join('\n\n'), provider: this.name, pageCount };
  }
}
