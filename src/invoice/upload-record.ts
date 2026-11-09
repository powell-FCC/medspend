// Records an uploaded invoice PDF as one vendor_invoices row: the single-invoice upload, exactly
// as recordVendorInvoiceFn has always done it. Shared with Phase 6C.4 batch intake, which takes
// this path for every upload that is not a multi-invoice packet.
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../integrations/supabase/types.ts";
import type { InvoiceUploadMetadata, VendorInvoice } from "../types/vendor-invoice.ts";

const COLUMNS =
  "id,organization_id,uploaded_by,storage_path,original_filename,file_size,mime_type,status,created_at";

export function toVendorInvoice(row: {
  id: string;
  organization_id: string;
  uploaded_by: string;
  storage_path: string;
  original_filename: string;
  file_size: number;
  mime_type: string;
  status: string;
  created_at: string;
}): VendorInvoice {
  return {
    id: row.id,
    organizationId: row.organization_id,
    uploadedBy: row.uploaded_by,
    storagePath: row.storage_path,
    originalFilename: row.original_filename,
    fileSize: row.file_size,
    mimeType: "application/pdf",
    status: "uploaded",
    createdAt: row.created_at,
  };
}

/** The caller has verified owner access. */
export async function recordVendorInvoiceRow(
  db: SupabaseClient<Database>,
  userId: string,
  data: InvoiceUploadMetadata,
): Promise<VendorInvoice> {
  const expectedPath = new RegExp(`^${data.organizationId}/[0-9a-f-]{36}\\.pdf$`, "i");
  if (!expectedPath.test(data.storagePath)) throw new Error("Invalid invoice storage path");
  const { data: row, error } = await db
    .from("vendor_invoices")
    .insert({
      organization_id: data.organizationId,
      uploaded_by: userId,
      storage_path: data.storagePath,
      original_filename: data.originalFilename,
      file_size: data.fileSize,
      mime_type: data.mimeType,
    })
    .select(COLUMNS)
    .single();
  if (error) throw new Error(error.message);
  return toVendorInvoice(row);
}

export const VENDOR_INVOICE_COLUMNS = COLUMNS;
