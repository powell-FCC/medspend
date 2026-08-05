import { supabase } from '@/integrations/supabase/client';

export const VENDOR_INVOICE_BUCKET = 'vendor-invoices';
export const MAX_INVOICE_BYTES = 25 * 1024 * 1024;
export const INVOICE_MIME_TYPE = 'application/pdf';

export function validateInvoiceFile(file: File): string | null {
  if (file.type !== INVOICE_MIME_TYPE) return 'Choose a PDF file.';
  if (file.size === 0) return 'The selected PDF is empty.';
  if (file.size > MAX_INVOICE_BYTES) return 'PDFs must be 25 MB or smaller.';
  return null;
}

export function createInvoiceStoragePath(organizationId: string): string {
  return `${organizationId}/${crypto.randomUUID()}.pdf`;
}

export async function uploadVendorInvoice(
  organizationId: string,
  file: File,
  onProgress: (value: number) => void,
): Promise<string> {
  const validationError = validateInvoiceFile(file);
  if (validationError) throw new Error(validationError);

  const storagePath = createInvoiceStoragePath(organizationId);
  onProgress(15);
  const { error } = await supabase.storage.from(VENDOR_INVOICE_BUCKET).upload(storagePath, file, {
    cacheControl: '3600',
    contentType: INVOICE_MIME_TYPE,
    upsert: false,
  });
  if (error) throw new Error(error.message);
  onProgress(75);
  return storagePath;
}

export async function deleteVendorInvoice(storagePath: string): Promise<void> {
  const { error } = await supabase.storage.from(VENDOR_INVOICE_BUCKET).remove([storagePath]);
  if (error) throw new Error(error.message);
}
