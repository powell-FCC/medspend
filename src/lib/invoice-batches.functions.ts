import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import {
  batchKey,
  getInvoiceBatch,
  getInvoiceProvenance,
  intakeInput,
  intakeInvoiceUpload,
  listInvoiceBatches,
  processInput,
  processInvoiceBatch,
  provenanceKey,
  releaseInvoiceBatchSegment,
  segmentKey,
  supabasePacketStorage,
} from "@/invoice-batch/intake-actions";
import type {
  InvoiceBatch,
  InvoiceBatchListEntry,
  InvoiceIntakeResult,
  InvoiceProvenance,
} from "@/types/invoice-batch";

// Phase 6C.4. Owner only, like every invoice upload and review path; the database functions
// check membership again. Storage is accessed with the caller's own token (owner storage policies).

export const intakeInvoiceUploadFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => intakeInput.parse(value))
  .handler(
    ({ data, context }): Promise<InvoiceIntakeResult> =>
      intakeInvoiceUpload(
        context.supabase,
        supabasePacketStorage(context.supabase),
        context.userId,
        data,
      ),
  );

export const getInvoiceBatchFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => batchKey.parse(value))
  .handler(
    ({ data, context }): Promise<InvoiceBatch> =>
      getInvoiceBatch(context.supabase, context.userId, data),
  );

export const processInvoiceBatchFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => processInput.parse(value))
  .handler(
    ({ data, context }): Promise<InvoiceBatch> =>
      processInvoiceBatch(
        context.supabase,
        supabasePacketStorage(context.supabase),
        context.userId,
        data,
      ),
  );

export const releaseInvoiceBatchSegmentFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => segmentKey.parse(value))
  .handler(({ data, context }) =>
    releaseInvoiceBatchSegment(context.supabase, context.userId, data),
  );

export const listInvoiceBatchesFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: z.string().uuid() }).parse(value))
  .handler(
    ({ data, context }): Promise<InvoiceBatchListEntry[]> =>
      listInvoiceBatches(context.supabase, context.userId, data.organizationId),
  );

export const getInvoiceProvenanceFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => provenanceKey.parse(value))
  .handler(
    ({ data, context }): Promise<InvoiceProvenance | null> =>
      getInvoiceProvenance(context.supabase, context.userId, data),
  );
