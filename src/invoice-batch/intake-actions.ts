// Phase 6C.4 batch intake actions: what the invoice-batch server functions do once the caller
// is authenticated. Free of framework and path-alias imports so the integration tests run this
// exact code against a local Postgres + PostgREST.
//
// Flow:  upload (unchanged) -> intakeInvoiceUpload: read page text, segment
//        -> fewer than two invoices: record the upload exactly as before (single invoice)
//        -> two or more: create_invoice_upload_batch (allocation + statuses, idempotent per file)
//        -> processInvoiceBatch, a few segments per call: page-subset PDF -> storage ->
//           register_invoice_batch_segment -> an ordinary vendor_invoices row.
// Every created invoice is then opened, parsed, matched, reviewed and posted by the existing
// per-upload workflow. Nothing here posts.
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import type { Database, Json } from "../integrations/supabase/types.ts";
import { assertOwner } from "../invoice/review-actions.ts";
import { recordVendorInvoiceRow } from "../invoice/upload-record.ts";
import type {
  InvoiceBatch,
  InvoiceBatchListEntry,
  InvoiceBatchSegment,
  InvoiceIntakeResult,
  InvoiceProvenance,
} from "../types/invoice-batch.ts";
import { segmentInvoicePacket } from "./detectors.ts";
import {
  buildSegmentPdf,
  loadPacket,
  MAX_PACKET_PAGES,
  readPacketPages,
  sha256Hex,
  summarizeSegment,
} from "./packet.ts";
import { invoiceSegments, isMultiInvoicePacket, type PacketSegmentation } from "./segmentation.ts";

type Db = SupabaseClient<Database>;

export interface PacketStorage {
  download(path: string): Promise<Uint8Array>;
  upload(path: string, bytes: Uint8Array): Promise<void>;
  remove(path: string): Promise<void>;
}

export const INVOICE_BUCKET = "vendor-invoices";

export function supabasePacketStorage(db: Db): PacketStorage {
  const bucket = () => db.storage.from(INVOICE_BUCKET);
  return {
    async download(path) {
      const { data, error } = await bucket().download(path);
      if (error) throw new Error(error.message);
      return new Uint8Array(await data.arrayBuffer());
    },
    async upload(path, bytes) {
      const { error } = await bucket().upload(path, bytes, {
        cacheControl: "3600",
        contentType: "application/pdf",
        upsert: false,
      });
      if (error) throw new Error(error.message);
    },
    async remove(path) {
      const { error } = await bucket().remove([path]);
      if (error) throw new Error(error.message);
    },
  };
}

const uuid = z.string().uuid();
export const intakeInput = z.object({
  organizationId: uuid,
  storagePath: z.string().min(1).max(500),
  originalFilename: z.string().trim().min(1).max(255),
  fileSize: z
    .number()
    .int()
    .positive()
    .max(25 * 1024 * 1024),
  mimeType: z.literal("application/pdf"),
});
export const batchKey = z.object({ organizationId: uuid, batchId: uuid });
export const processInput = batchKey.extend({
  limit: z.number().int().min(1).max(10).default(4),
  retryFailed: z.boolean().default(false),
});
export const segmentKey = z.object({ organizationId: uuid, segmentId: uuid });
export const provenanceKey = z.object({ organizationId: uuid, sourceFileId: uuid });

const elapsed = (since: number) => Math.max(0, Math.round(performance.now() - since));
const message = (cause: unknown, fallback: string) =>
  cause instanceof Error && cause.message ? cause.message : fallback;

export interface IntakeOptions {
  /** Test seam: observe the segmentation that was used. */
  onSegmentation?: (segmentation: PacketSegmentation) => void;
}

export async function intakeInvoiceUpload(
  db: Db,
  storage: PacketStorage,
  userId: string,
  input: z.infer<typeof intakeInput>,
  options: IntakeOptions = {},
): Promise<InvoiceIntakeResult> {
  await assertOwner(db, userId, input.organizationId);
  const expectedPath = new RegExp(`^${input.organizationId}/[0-9a-f-]{36}\\.pdf$`, "i");
  if (!expectedPath.test(input.storagePath)) throw new Error("Invalid invoice storage path");
  const started = performance.now();

  // Anything that cannot be read as a multi-invoice packet stays exactly today's single upload,
  // including scanned PDFs without text and files the reader rejects.
  let pages: string[] | null = null;
  let bytes: Uint8Array | null = null;
  let textMs = 0;
  try {
    bytes = await storage.download(input.storagePath);
    const textStarted = performance.now();
    pages = await readPacketPages(bytes);
    textMs = elapsed(textStarted);
  } catch {
    pages = null;
  }
  const single = async (): Promise<InvoiceIntakeResult> => ({
    kind: "single",
    invoice: await recordVendorInvoiceRow(db, userId, input),
  });
  if (!pages || !bytes || pages.length < 2 || pages.length > MAX_PACKET_PAGES) return single();

  const segmentationStarted = performance.now();
  const segmentation = segmentInvoicePacket(pages);
  const segmentationMs = elapsed(segmentationStarted);
  options.onSegmentation?.(segmentation);
  if (!isMultiInvoicePacket(segmentation)) return single();

  const parsingStarted = performance.now();
  const summaries = new Map<number, Awaited<ReturnType<typeof summarizeSegment>>>();
  for (const segment of invoiceSegments(segmentation)) {
    summaries.set(segment.index, await summarizeSegment(pages, segment.startPage, segment.endPage));
  }
  const parsingMs = elapsed(parsingStarted);
  const contentSha256 = await sha256Hex(bytes);

  const { data, error } = await db.rpc("create_invoice_upload_batch", {
    _organization_id: input.organizationId,
    _storage_path: input.storagePath,
    _original_filename: input.originalFilename,
    _file_size: input.fileSize,
    _content_sha256: contentSha256,
    _page_count: segmentation.pageCount,
    _detector: segmentation.detector,
    // PostgreSQL accepts NULL; the generated argument types only model required strings.
    _vendor_name: segmentation.vendorName as string,
    _vendor_key: segmentation.vendorKey as string,
    _segments: segmentation.segments.map((segment) => {
      const summary = summaries.get(segment.index);
      return {
        index: segment.index,
        kind: segment.kind,
        startPage: segment.startPage,
        endPage: segment.endPage,
        invoiceNumber: segment.invoiceNumber,
        invoiceDate: segment.invoiceDate,
        reasons: segment.reasons,
        duplicateOfIndex: segment.duplicateOfIndex,
        parse: summary
          ? {
              state: summary.state,
              itemCount: summary.itemCount,
              total: summary.total,
              needsReview: summary.needsReview,
            }
          : null,
      };
    }) as unknown as Json,
  });
  if (error) throw new Error(error.message);
  const result = data as { batchId: string; existing: boolean };
  // The same packet was already uploaded: keep the first copy, drop this one.
  if (result.existing) await storage.remove(input.storagePath).catch(() => undefined);
  return {
    kind: "batch",
    batchId: result.batchId,
    existing: result.existing,
    pageCount: segmentation.pageCount,
    invoiceCount: invoiceSegments(segmentation).length,
    timings: { textMs, segmentationMs, parsingMs, totalMs: elapsed(started) },
  };
}

function toSegment(value: Record<string, unknown>): InvoiceBatchSegment {
  const invoice = value.invoice as Record<string, unknown> | null;
  const number = (key: string) =>
    value[key] === null || value[key] === undefined ? null : Number(value[key]);
  return {
    id: String(value.id),
    index: Number(value.index),
    kind: value.kind as InvoiceBatchSegment["kind"],
    status: value.status as InvoiceBatchSegment["status"],
    pageStart: Number(value.pageStart),
    pageEnd: Number(value.pageEnd),
    invoiceNumber: (value.invoiceNumber as string | null) ?? null,
    invoiceDate: (value.invoiceDate as string | null) ?? null,
    reasons: (value.reasons as string[] | null) ?? [],
    duplicateOfIndex: number("duplicateOfIndex"),
    duplicateOfSourceFileId: (value.duplicateOfSourceFileId as string | null) ?? null,
    parseState: (value.parseState as string | null) ?? null,
    parsedItemCount: number("parsedItemCount"),
    parsedTotal: number("parsedTotal"),
    parseNeedsReview: Boolean(value.parseNeedsReview),
    error: (value.error as string | null) ?? null,
    sourceFileId: (value.sourceFileId as string | null) ?? null,
    invoice: invoice
      ? {
          processingStatus: String(invoice.processingStatus),
          itemCount: Number(invoice.itemCount ?? 0),
          total:
            invoice.total === null || invoice.total === undefined ? null : Number(invoice.total),
        }
      : null,
  };
}

export async function getInvoiceBatch(
  db: Db,
  userId: string,
  input: z.infer<typeof batchKey>,
): Promise<InvoiceBatch> {
  await assertOwner(db, userId, input.organizationId);
  const { data, error } = await db.rpc("get_invoice_upload_batch", {
    _organization_id: input.organizationId,
    _batch_id: input.batchId,
  });
  if (error) throw new Error(error.message);
  const value = data as { batch: Record<string, unknown>; segments: Record<string, unknown>[] };
  return {
    id: String(value.batch.id),
    originalFilename: String(value.batch.originalFilename),
    storagePath: String(value.batch.storagePath),
    fileSize: Number(value.batch.fileSize),
    pageCount: Number(value.batch.pageCount),
    detector: String(value.batch.detector),
    vendorName: (value.batch.vendorName as string | null) ?? null,
    createdAt: String(value.batch.createdAt),
    segments: value.segments.map(toSegment),
  };
}

/**
 * Prepares up to `limit` pending segments (and failed ones when retryFailed), each on its own:
 * one failure is recorded on that segment and the rest continue. Safe to repeat: a created
 * segment is never created twice, and a stored file that did not become a new invoice is removed.
 */
export async function processInvoiceBatch(
  db: Db,
  storage: PacketStorage,
  userId: string,
  input: z.infer<typeof processInput>,
): Promise<InvoiceBatch> {
  const batch = await getInvoiceBatch(db, userId, input);
  const targets = batch.segments
    .filter(
      (segment) =>
        segment.status === "pending" || (input.retryFailed && segment.status === "failed"),
    )
    .slice(0, input.limit);
  if (!targets.length) return batch;

  let packet: Awaited<ReturnType<typeof loadPacket>> | null = null;
  let packetError: string | null = null;
  try {
    packet = await loadPacket(await storage.download(batch.storagePath));
    if (packet.getPageCount() !== batch.pageCount)
      throw new Error("The stored packet no longer matches its page count");
  } catch (cause) {
    packetError = message(cause, "The uploaded packet could not be read.");
  }

  for (const segment of targets) {
    let storedPath: string | null = null;
    try {
      if (!packet) throw new Error(packetError ?? "The uploaded packet could not be read.");
      const pdf = await buildSegmentPdf(packet, segment.pageStart, segment.pageEnd);
      storedPath = `${input.organizationId}/${crypto.randomUUID()}.pdf`;
      await storage.upload(storedPath, pdf);
      const { data, error } = await db.rpc("register_invoice_batch_segment", {
        _organization_id: input.organizationId,
        _segment_id: segment.id,
        _storage_path: storedPath,
        _file_size: pdf.byteLength,
      });
      if (error) throw new Error(error.message);
      const result = data as { status: string; existing: boolean };
      if (result.status !== "created" || result.existing)
        await storage.remove(storedPath).catch(() => undefined);
    } catch (cause) {
      if (storedPath) await storage.remove(storedPath).catch(() => undefined);
      const { error } = await db.rpc("fail_invoice_batch_segment", {
        _organization_id: input.organizationId,
        _segment_id: segment.id,
        _error: message(cause, "Preparing this invoice failed."),
      });
      if (error) throw new Error(error.message);
    }
  }
  return getInvoiceBatch(db, userId, input);
}

export async function releaseInvoiceBatchSegment(
  db: Db,
  userId: string,
  input: z.infer<typeof segmentKey>,
) {
  await assertOwner(db, userId, input.organizationId);
  const { error } = await db.rpc("release_invoice_batch_segment", {
    _organization_id: input.organizationId,
    _segment_id: input.segmentId,
  });
  if (error) throw new Error(error.message);
  return { ok: true };
}

export async function listInvoiceBatches(
  db: Db,
  userId: string,
  organizationId: string,
): Promise<InvoiceBatchListEntry[]> {
  await assertOwner(db, userId, organizationId);
  const { data, error } = await db.rpc("list_invoice_upload_batches", {
    _organization_id: organizationId,
    _limit: 10,
  });
  if (error) throw new Error(error.message);
  return ((data as Record<string, unknown>[] | null) ?? []).map((entry) => ({
    id: String(entry.id),
    originalFilename: String(entry.originalFilename),
    pageCount: Number(entry.pageCount),
    createdAt: String(entry.createdAt),
    invoiceCount: Number(entry.invoiceCount),
    createdCount: Number(entry.createdCount),
    attentionCount: Number(entry.attentionCount),
  }));
}

export async function getInvoiceProvenance(
  db: Db,
  userId: string,
  input: z.infer<typeof provenanceKey>,
): Promise<InvoiceProvenance | null> {
  await assertOwner(db, userId, input.organizationId);
  const { data, error } = await db.rpc("get_invoice_source_provenance", {
    _organization_id: input.organizationId,
    _source_file_id: input.sourceFileId,
  });
  if (error) throw new Error(error.message);
  if (!data) return null;
  const value = data as Record<string, unknown>;
  return {
    batchId: String(value.batchId),
    originalFilename: String(value.originalFilename),
    packetPageCount: Number(value.packetPageCount),
    pageStart: Number(value.pageStart),
    pageEnd: Number(value.pageEnd),
    segmentIndex: Number(value.segmentIndex),
  };
}
