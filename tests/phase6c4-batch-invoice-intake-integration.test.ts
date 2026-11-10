// Phase 6C.4 integration: batch invoice intake through the real server path, against a local
// Postgres (every migration applied) behind a real PostgREST, with supabase-js and signed user
// JWTs. Started by supabase/tests/run_phase6c4_batch_intake_integration.sh; skipped by a plain
// `npm test`.
//
// Exercised for real: intakeInvoiceUpload / processInvoiceBatch / getInvoiceBatch (the code the
// createServerFn handlers call), the unchanged single-upload insert, every RPC with RLS and
// role switching, the existing processing-job trigger, and then, for created invoices, the
// existing review path (embedded text -> deterministic parser -> seed_structured_invoice_draft),
// product creation, post_reviewed_invoice and delete_invoice_permanently.
// Stand-in: Supabase Storage. A local Storage API is not part of this stack, so files live in an
// in-memory map behind the same PacketStorage interface the server uses (bucket policies are
// covered by the existing owner-only storage policies, unchanged).
import assert from "node:assert/strict";
import { createHmac, randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import test from "node:test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { DeterministicInvoiceExtractionProvider } from "../src/extraction/deterministic-invoice-provider.ts";
import { EmbeddedPdfTextProvider } from "../src/extraction/embedded-pdf-text-provider.ts";
import { runDocumentTextExtraction } from "../src/extraction/pipeline.ts";
import { validateExtraction } from "../src/extraction/validation.ts";
import type { Database, Json } from "../src/integrations/supabase/types.ts";
import {
  getInvoiceBatch,
  getInvoiceProvenance,
  intakeInvoiceUpload,
  listInvoiceBatches,
  processInvoiceBatch,
  releaseInvoiceBatchSegment,
  type PacketStorage,
} from "../src/invoice-batch/intake-actions.ts";
import { readPacketPages } from "../src/invoice-batch/packet.ts";
import { batchRowStatus } from "../src/invoice-batch/status.ts";
import type { InvoiceBatch } from "../src/types/invoice-batch.ts";
import {
  buildFixturePdf,
  henryScheinInvoicePages,
  invoiceAmounts,
  lines,
  structuralPacket,
  type FixtureInvoice,
} from "./support/invoice-packet-fixtures.ts";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase6c4_batch_intake_integration.sh";

const id = (suffix: string) => `6c4e0000-0000-4000-8000-000000000${suffix}`;
const OWNER = id("001");
const ADMIN = id("002");
const STAFF = id("003");
const OTHER_OWNER = id("004");
const ORG = id("101");
const OTHER_ORG = id("102");
const HENRY_SCHEIN = id("301");

const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
function signToken(claims: Record<string, unknown>) {
  const body = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ ...claims, exp: Math.floor(Date.now() / 1000) + 3600 })}`;
  return `${body}.${createHmac("sha256", JWT_SECRET).update(body).digest("base64url")}`;
}
function clientFor(claims: Record<string, unknown> | null): SupabaseClient<Database> {
  return createClient<Database>(REST_URL, "local-publishable-key", {
    global: {
      headers: claims ? { Authorization: `Bearer ${signToken(claims)}` } : {},
      fetch: (input, init) => fetch(String(input).replace("/rest/v1", ""), init),
    },
    auth: { storage: undefined, persistSession: false, autoRefreshToken: false },
  });
}
const owner = configured ? clientFor({ role: "authenticated", sub: OWNER }) : (null as never);
const admin = configured ? clientFor({ role: "authenticated", sub: ADMIN }) : (null as never);
const staff = configured ? clientFor({ role: "authenticated", sub: STAFF }) : (null as never);
const otherOwner = configured
  ? clientFor({ role: "authenticated", sub: OTHER_OWNER })
  : (null as never);
const anon = configured ? clientFor(null) : (null as never);
const inspect = configured ? clientFor({ role: "service_role" }) : (null as never);

class MemoryStorage implements PacketStorage {
  files = new Map<string, Uint8Array>();
  failUploads = new Set<number>();
  uploads = 0;
  async download(path: string) {
    const file = this.files.get(path);
    if (!file) throw new Error(`Object not found: ${path}`);
    return file.slice();
  }
  async upload(path: string, bytes: Uint8Array) {
    this.uploads++;
    if (this.failUploads.has(this.uploads)) throw new Error("Simulated storage outage");
    if (this.files.has(path)) throw new Error("The resource already exists");
    this.files.set(path, bytes.slice());
  }
  async remove(path: string) {
    this.files.delete(path);
  }
  put(bytes: Uint8Array, org = ORG) {
    const path = `${org}/${randomUUID()}.pdf`;
    this.files.set(path, bytes.slice());
    return path;
  }
}

const intake = (
  client: SupabaseClient<Database>,
  user: string,
  storage: MemoryStorage,
  path: string,
  bytes: Uint8Array,
  name = "Packet.pdf",
  org = ORG,
) =>
  intakeInvoiceUpload(client, storage, user, {
    organizationId: org,
    storagePath: path,
    originalFilename: name,
    fileSize: bytes.byteLength,
    mimeType: "application/pdf",
  });

async function processAll(
  storage: MemoryStorage,
  batchId: string,
  retryFailed = false,
): Promise<InvoiceBatch> {
  let batch = await getInvoiceBatch(owner, OWNER, { organizationId: ORG, batchId });
  let retry = retryFailed;
  while (batch.segments.some((segment) => segment.status === "pending") || retry) {
    batch = await processInvoiceBatch(owner, storage, OWNER, {
      organizationId: ORG,
      batchId,
      limit: 3,
      retryFailed: retry,
    });
    retry = false;
  }
  return batch;
}

// Exactly what getInvoiceReviewFn does for an uploaded invoice the first time it is opened
// (src/lib/invoice-processing.functions.ts): draft row, embedded text, deterministic parser,
// seed_structured_invoice_draft. Nothing batch-specific.
async function openReview(storage: MemoryStorage, sourceFileId: string) {
  const { data: source } = await owner
    .from("vendor_invoices")
    .select("storage_path")
    .eq("id", sourceFileId)
    .single();
  const { data: invoice, error: upsertError } = await owner
    .from("invoices")
    .upsert(
      { organization_id: ORG, source_file_id: sourceFileId, processing_status: "review_required" },
      { onConflict: "source_file_id" },
    )
    .select("id")
    .single();
  assert.equal(upsertError, null);
  const { data: claimed } = await owner
    .from("invoice_processing_jobs")
    .update({ status: "processing", document_text_status: "pending" })
    .eq("invoice_id", sourceFileId)
    .eq("organization_id", ORG)
    .eq("status", "uploaded")
    .select("id")
    .maybeSingle();
  assert.ok(claimed, "the job was waiting, exactly like a fresh upload");
  const text = await runDocumentTextExtraction(
    await storage.download(source!.storage_path),
    new EmbeddedPdfTextProvider(),
  );
  await owner
    .from("invoice_processing_jobs")
    .update({
      status: "review_required",
      document_text_status: text.status,
      raw_extracted_text: text.text,
      document_page_count: text.pageCount ?? null,
    })
    .eq("invoice_id", sourceFileId)
    .eq("organization_id", ORG);
  const extraction = validateExtraction(
    await new DeterministicInvoiceExtractionProvider().extractInvoice(text.text),
  );
  const { data: seeded, error } = await owner.rpc("seed_structured_invoice_draft", {
    _organization_id: ORG,
    _source_file_id: sourceFileId,
    _extraction: extraction as unknown as Json,
    _provider: "deterministic-invoice-v2",
  });
  assert.equal(error, null);
  assert.equal(seeded, true);
  return { invoiceId: invoice!.id, pageCount: text.pageCount, extraction };
}

const vendorInvoiceCount = async (org = ORG) =>
  (
    await inspect
      .from("vendor_invoices")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", org)
  ).count ?? 0;

const storage = new MemoryStorage();
const invoices = structuralPacket();
let packetBytes: Uint8Array;
let packetPath: string;
let batchId: string;
let firstBatch: InvoiceBatch;

test(
  "a one-page invoice PDF is recorded exactly as before: one upload, no packet",
  { skip },
  async () => {
    const bytes = await buildFixturePdf(henryScheinInvoicePages(invoices[0]));
    const path = storage.put(bytes);
    const before = await vendorInvoiceCount();
    const result = await intake(owner, OWNER, storage, path, bytes, "Single.pdf");
    assert.equal(result.kind, "single");
    assert.equal(result.kind === "single" && result.invoice.storagePath, path);
    assert.equal(result.kind === "single" && result.invoice.originalFilename, "Single.pdf");
    assert.equal(await vendorInvoiceCount(), before + 1);
    assert.equal((await listInvoiceBatches(owner, OWNER, ORG)).length, 0);
    assert.ok(storage.files.has(path), "the uploaded file stays where it was stored");
  },
);

test(
  "a two-page single invoice and a text-less PDF also stay single uploads",
  { skip },
  async () => {
    const twoPage = await buildFixturePdf(henryScheinInvoicePages(invoices[2]));
    const scanned = await buildFixturePdf([[], []]);
    const garbage = new TextEncoder().encode("%PDF-1.4 not really a pdf");
    for (const bytes of [twoPage, scanned, garbage]) {
      const result = await intake(owner, OWNER, storage, storage.put(bytes), bytes, "One.pdf");
      assert.equal(result.kind, "single");
    }
    assert.equal((await listInvoiceBatches(owner, OWNER, ORG)).length, 0);
  },
);

test(
  "a multi-invoice packet becomes one packet record with its page allocation",
  { skip },
  async () => {
    packetBytes = await buildFixturePdf(invoices.flatMap(henryScheinInvoicePages));
    packetPath = storage.put(packetBytes);
    const before = await vendorInvoiceCount();
    const result = await intake(
      owner,
      OWNER,
      storage,
      packetPath,
      packetBytes,
      "Henry Schein packet.pdf",
    );
    assert.equal(result.kind, "batch");
    if (result.kind !== "batch") return;
    assert.equal(result.existing, false);
    assert.equal(result.invoiceCount, 7);
    assert.equal(result.pageCount, 11);
    batchId = result.batchId;
    assert.equal(await vendorInvoiceCount(), before, "nothing is created before processing");
    const batch = await getInvoiceBatch(owner, OWNER, { organizationId: ORG, batchId });
    assert.deepEqual(
      batch.segments.map((s) => `${s.pageStart}-${s.pageEnd}:${s.invoiceNumber}:${s.status}`),
      [
        "1-1:60000001:pending",
        "2-2:60000002:pending",
        "3-4:60000003:pending",
        "5-8:60000004:pending",
        "9-9:60000005:pending",
        "10-10:60000006:pending",
        "11-11:60000007:pending",
      ],
    );
    assert.deepEqual(
      batch.segments.map((s) => s.parsedItemCount),
      [1, 1, 15, 33, 1, 0, 2],
    );
    assert.equal(batch.segments[3].parsedTotal, invoiceAmounts(invoices[3]).total);
    assert.equal(batch.vendorName, "Henry Schein, Inc.");
    assert.ok(storage.files.has(packetPath), "the original packet is kept");
  },
);

test(
  "processing creates one ordinary upload per invoice, each a PDF of exactly its pages",
  { skip },
  async () => {
    const before = await vendorInvoiceCount();
    firstBatch = await processAll(storage, batchId);
    assert.ok(firstBatch.segments.every((s) => s.status === "created" && s.sourceFileId));
    assert.equal(await vendorInvoiceCount(), before + 7);
    const packetPages = await readPacketPages(packetBytes);
    for (const segment of firstBatch.segments) {
      const { data: row } = await inspect
        .from("vendor_invoices")
        .select("storage_path,original_filename,uploaded_by,file_size")
        .eq("id", segment.sourceFileId!)
        .single();
      const file = await storage.download(row!.storage_path);
      assert.equal(file.byteLength, row!.file_size);
      const { text, pageCount } = await new EmbeddedPdfTextProvider().extractText(file);
      assert.equal(pageCount, segment.pageEnd - segment.pageStart + 1);
      assert.equal(
        text,
        packetPages.slice(segment.pageStart - 1, segment.pageEnd).join("\n\n"),
        `pages of ${segment.invoiceNumber}`,
      );
      assert.equal(row!.uploaded_by, OWNER);
      assert.match(row!.original_filename, new RegExp(`invoice ${segment.invoiceNumber} \\(page`));
      const { data: job } = await inspect
        .from("invoice_processing_jobs")
        .select("status")
        .eq("invoice_id", segment.sourceFileId!)
        .single();
      assert.equal(job!.status, "uploaded", "waits for review like any upload");
    }
    const { count: invoiceRows } = await inspect
      .from("invoices")
      .select("id", { count: "exact", head: true })
      .in(
        "source_file_id",
        firstBatch.segments.map((s) => s.sourceFileId!),
      );
    assert.equal(invoiceRows, 0, "nothing is parsed into drafts or posted by batch intake");
    const provenance = await getInvoiceProvenance(owner, OWNER, {
      organizationId: ORG,
      sourceFileId: firstBatch.segments[3].sourceFileId!,
    });
    assert.deepEqual(provenance, {
      batchId,
      originalFilename: "Henry Schein packet.pdf",
      packetPageCount: 11,
      pageStart: 5,
      pageEnd: 8,
      segmentIndex: 4,
    });
  },
);

test(
  "each created invoice goes through the existing review path with its own lines and totals",
  { skip },
  async () => {
    for (const [position, segment] of firstBatch.segments.entries()) {
      const fixture = invoices[position];
      const { invoiceId, pageCount, extraction } = await openReview(storage, segment.sourceFileId!);
      assert.equal(pageCount, segment.pageEnd - segment.pageStart + 1);
      const { data: header } = await inspect
        .from("invoices")
        .select("invoice_number,invoice_total,subtotal,vendor_name")
        .eq("id", invoiceId)
        .single();
      const { data: items } = await inspect
        .from("invoice_items")
        .select("line_number,sku,quantity,total_price")
        .eq("invoice_id", invoiceId)
        .order("line_number");
      const shipped = fixture.pages.flat().filter((line) => line.shipped > 0);
      assert.equal(header!.invoice_number, fixture.number);
      assert.equal(header!.vendor_name, "Henry Schein, Inc.");
      assert.equal(Number(header!.invoice_total), invoiceAmounts(fixture).total);
      assert.deepEqual(
        items!.map((item) => item.sku),
        shipped.map((line) => line.sku),
      );
      assert.equal(
        items!.length,
        segment.parsedItemCount,
        "the packet summary matched what review produced",
      );
      assert.equal(extraction.header.total.value, segment.parsedTotal);
    }
    const batch = await getInvoiceBatch(owner, OWNER, { organizationId: ORG, batchId });
    assert.equal(batch.segments[3].invoice?.itemCount, 33);
    assert.deepEqual(batch.segments.map(batchRowStatus), [
      "ready",
      "ready",
      "ready",
      "ready",
      "ready",
      "needs_review",
      "ready",
    ]);
  },
);

test("retrying is idempotent: no new invoices, no stray files", { skip }, async () => {
  const before = await vendorInvoiceCount();
  const files = storage.files.size;
  const again = await processInvoiceBatch(owner, storage, OWNER, {
    organizationId: ORG,
    batchId,
    limit: 10,
    retryFailed: true,
  });
  assert.deepEqual(
    again.segments.map((s) => s.sourceFileId),
    firstBatch.segments.map((s) => s.sourceFileId),
  );
  // A direct second registration of a created segment returns it and the caller removes its file.
  const { data } = await owner.rpc("register_invoice_batch_segment", {
    _organization_id: ORG,
    _segment_id: firstBatch.segments[0].id,
    _storage_path: `${ORG}/${randomUUID()}.pdf`,
    _file_size: 10,
  });
  assert.deepEqual(data, {
    status: "created",
    sourceFileId: firstBatch.segments[0].sourceFileId,
    existing: true,
  });
  assert.equal(await vendorInvoiceCount(), before);
  assert.equal(storage.files.size, files);
});

test(
  "the same packet uploaded again returns the first packet and keeps one copy of the file",
  { skip },
  async () => {
    const before = await vendorInvoiceCount();
    const path = storage.put(packetBytes);
    const result = await intake(owner, OWNER, storage, path, packetBytes, "Again.pdf");
    assert.equal(result.kind === "batch" && result.batchId, batchId);
    assert.equal(result.kind === "batch" && result.existing, true);
    assert.equal(storage.files.has(path), false, "the second copy is removed");
    assert.equal(await vendorInvoiceCount(), before);
  },
);

test(
  "a different packet repeating invoices already present: duplicates, and only the new invoice is created",
  { skip },
  async () => {
    const fresh: FixtureInvoice = {
      number: "60000008",
      date: "07/01/26",
      po: "JULY",
      order: "70000008",
      pages: [lines(40, 2)],
      tax: 0.4,
    };
    const bytes = await buildFixturePdf(
      [invoices[0], fresh, invoices[3]].flatMap(henryScheinInvoicePages),
    );
    const before = await vendorInvoiceCount();
    const result = await intake(owner, OWNER, storage, storage.put(bytes), bytes, "Overlap.pdf");
    assert.equal(result.kind, "batch");
    const batch = await processAll(storage, result.kind === "batch" ? result.batchId : "");
    assert.deepEqual(
      batch.segments.map((s) => `${s.invoiceNumber}:${s.status}`),
      ["60000001:duplicate", "60000008:created", "60000004:duplicate"],
    );
    assert.equal(batch.segments[0].duplicateOfSourceFileId, firstBatch.segments[0].sourceFileId);
    assert.equal(await vendorInvoiceCount(), before + 1);
  },
);

test(
  "an invoice uploaded on its own earlier is recognized when it later arrives in a packet",
  { skip },
  async () => {
    const lone: FixtureInvoice = {
      number: "60000020",
      date: "08/01/26",
      po: "AUG",
      order: "70000020",
      pages: [lines(30, 1)],
    };
    const loneBytes = await buildFixturePdf(henryScheinInvoicePages(lone));
    const single = await intake(
      owner,
      OWNER,
      storage,
      storage.put(loneBytes),
      loneBytes,
      "Lone.pdf",
    );
    assert.equal(single.kind, "single");
    if (single.kind === "single") await openReview(storage, single.invoice.id);
    const other: FixtureInvoice = {
      number: "60000021",
      date: "08/02/26",
      po: "AUG",
      order: "70000021",
      pages: [lines(31, 1)],
    };
    const bytes = await buildFixturePdf([lone, other].flatMap(henryScheinInvoicePages));
    const result = await intake(owner, OWNER, storage, storage.put(bytes), bytes, "Later.pdf");
    const batch = await processAll(storage, result.kind === "batch" ? result.batchId : "");
    assert.deepEqual(
      batch.segments.map((s) => s.status),
      ["duplicate", "created"],
    );
    assert.equal(
      single.kind === "single" && batch.segments[0].duplicateOfSourceFileId,
      single.kind === "single" && single.invoice.id,
    );
  },
);

test(
  "partial failure: one invoice failing leaves the others usable, and a retry completes it",
  { skip },
  async () => {
    const set: FixtureInvoice[] = [30, 31, 32, 33].map((n) => ({
      number: `600000${n}`,
      date: "09/01/26",
      po: "SEPT",
      order: "70000030",
      pages: [lines(n, 1)],
    }));
    const bytes = await buildFixturePdf(set.flatMap(henryScheinInvoicePages));
    const result = await intake(owner, OWNER, storage, storage.put(bytes), bytes, "Flaky.pdf");
    const id = result.kind === "batch" ? result.batchId : "";
    storage.failUploads = new Set([storage.uploads + 2]);
    const filesBefore = storage.files.size;
    const batch = await processAll(storage, id);
    assert.deepEqual(
      batch.segments.map((s) => s.status),
      ["created", "failed", "created", "created"],
    );
    assert.equal(batch.segments[1].error, "Simulated storage outage");
    assert.equal(storage.files.size, filesBefore + 3, "no orphaned file for the failed invoice");
    const retried = await processAll(storage, id, true);
    assert.deepEqual(
      retried.segments.map((s) => s.status),
      ["created", "created", "created", "created"],
    );
    storage.failUploads = new Set();
  },
);

test(
  "a packet whose stored file vanished fails per invoice with a clear message, never silently",
  { skip },
  async () => {
    const set: FixtureInvoice[] = [40, 41].map((n) => ({
      number: `600000${n}`,
      date: "09/02/26",
      po: "X",
      order: "70000040",
      pages: [lines(n, 1)],
    }));
    const bytes = await buildFixturePdf(set.flatMap(henryScheinInvoicePages));
    const path = storage.put(bytes);
    const result = await intake(owner, OWNER, storage, path, bytes, "Vanished.pdf");
    await storage.remove(path);
    const batch = await processAll(storage, result.kind === "batch" ? result.batchId : "");
    assert.ok(
      batch.segments.every((s) => s.status === "failed" && /Object not found/.test(s.error ?? "")),
    );
  },
);

test(
  "held ranges: an unresolved page is shown, never created, until the owner confirms it",
  { skip },
  async () => {
    const set = structuralPacket().slice(2, 5);
    set[1] = {
      ...set[1],
      footerless: [1],
      pageMarkers: ["Page 1 of 4", null, "Page 3 of 4", "Page 4 of 4"],
    };
    const bytes = await buildFixturePdf(set.flatMap(henryScheinInvoicePages));
    const result = await intake(owner, OWNER, storage, storage.put(bytes), bytes, "Held.pdf");
    let batch = await processAll(storage, result.kind === "batch" ? result.batchId : "");
    assert.deepEqual(
      batch.segments.map((s) => `${s.kind}:${s.pageStart}-${s.pageEnd}:${s.status}`),
      [
        "invoice:1-2:duplicate",
        "invoice:3-3:held",
        "unresolved:4-4:held",
        "invoice:5-6:held",
        "invoice:7-7:duplicate",
      ],
    );
    const unresolved = batch.segments[2];
    await releaseInvoiceBatchSegment(owner, OWNER, {
      organizationId: ORG,
      segmentId: unresolved.id,
    });
    batch = await processAll(storage, batch.id);
    assert.equal(batch.segments[2].status, "created");
    assert.equal(
      batch.segments.reduce((sum, s) => sum + s.pageEnd - s.pageStart + 1, 0),
      7,
      "every page still accounted for",
    );
  },
);

test(
  "a created invoice posts and deletes exactly like an individual upload",
  { skip },
  async () => {
    const segment = firstBatch.segments[0];
    const { data: invoice } = await inspect
      .from("invoices")
      .select("id")
      .eq("source_file_id", segment.sourceFileId!)
      .single();
    const { data: item } = await inspect
      .from("invoice_items")
      .select("id")
      .eq("invoice_id", invoice!.id)
      .single();
    const { error: vendorError } = await owner
      .from("invoices")
      .update({
        vendor_id: HENRY_SCHEIN,
        vendor_name: "Henry Schein",
        vendor_identity_reviewed: true,
      })
      .eq("id", invoice!.id);
    assert.equal(vendorError, null);
    const created = await owner.rpc("create_product_from_invoice_item", {
      _organization_id: ORG,
      _source_file_id: segment.sourceFileId!,
      _invoice_item_id: item!.id,
    });
    assert.equal(created.error, null);
    const confirmed = await owner.rpc("confirm_invoice_item_product", {
      _organization_id: ORG,
      _source_file_id: segment.sourceFileId!,
      _invoice_item_id: item!.id,
      _product_id: String((created.data as { productId: string }).productId),
      _remember_vendor_sku: true,
    });
    assert.equal(confirmed.error, null);
    const posted = await owner.rpc("post_reviewed_invoice", {
      _organization_id: ORG,
      _source_file_id: segment.sourceFileId!,
    });
    assert.equal(posted.error, null);
    assert.equal((posted.data as { createdInventoryItems: number }).createdInventoryItems, 1);
    let batch = await getInvoiceBatch(owner, OWNER, { organizationId: ORG, batchId });
    assert.equal(batchRowStatus(batch.segments[0]), "posted");
    const { count: prices } = await inspect
      .from("inventory_price_history")
      .select("id", { count: "exact", head: true })
      .eq("invoice_id", invoice!.id);
    assert.equal(prices, 1);

    const deleted = await owner.rpc("delete_invoice_permanently", {
      _organization_id: ORG,
      _source_file_id: segment.sourceFileId!,
    });
    assert.equal(deleted.error, null);
    const removedPath = (deleted.data as { storagePath: string }).storagePath;
    assert.notEqual(removedPath, packetPath, "deleting an invoice never names the packet file");
    await storage.remove(removedPath);
    batch = await getInvoiceBatch(owner, OWNER, { organizationId: ORG, batchId });
    assert.equal(batchRowStatus(batch.segments[0]), "removed");
    assert.ok(storage.files.has(packetPath), "the packet and its other invoices remain");
    assert.ok(batch.segments.slice(1).every((s) => s.sourceFileId));
  },
);

test(
  "owner only: admin, staff, other organizations and anonymous callers are refused",
  { skip },
  async () => {
    const bytes = packetBytes;
    for (const [client, user] of [
      [admin, ADMIN],
      [staff, STAFF],
      [otherOwner, OTHER_OWNER],
    ] as const) {
      await assert.rejects(
        intake(client, user, storage, storage.put(bytes), bytes),
        /owner access required/,
      );
      await assert.rejects(
        getInvoiceBatch(client, user, { organizationId: ORG, batchId }),
        /owner access required/,
      );
      await assert.rejects(
        processInvoiceBatch(client, storage, user, {
          organizationId: ORG,
          batchId,
          limit: 1,
          retryFailed: true,
        }),
        /owner access required/,
      );
      await assert.rejects(listInvoiceBatches(client, user, ORG), /owner access required/);
      // Straight to the database, past the server-side check.
      const direct = await client.rpc("get_invoice_upload_batch", {
        _organization_id: ORG,
        _batch_id: batchId,
      });
      assert.match(direct.error?.message ?? "", /owner access required/);
    }
    const crossOrg = await otherOwner.rpc("get_invoice_upload_batch", {
      _organization_id: OTHER_ORG,
      _batch_id: batchId,
    });
    assert.match(crossOrg.error?.message ?? "", /not found/);
    const crossRegister = await otherOwner.rpc("register_invoice_batch_segment", {
      _organization_id: OTHER_ORG,
      _segment_id: firstBatch.segments[1].id,
      _storage_path: `${OTHER_ORG}/${randomUUID()}.pdf`,
      _file_size: 1,
    });
    assert.match(crossRegister.error?.message ?? "", /not found/);
    const raw = await owner.from("invoice_upload_batch_segments" as never).select("*");
    assert.match(raw.error?.message ?? "", /permission denied/);
    const anonymous = await anon.rpc("get_invoice_upload_batch", {
      _organization_id: ORG,
      _batch_id: batchId,
    });
    assert.ok(anonymous.error, "anon is refused");
    assert.equal(await vendorInvoiceCount(OTHER_ORG), 0);
  },
);

const CANONICAL =
  process.env.MEDSPEND_CANONICAL_PACKET ?? `${homedir()}/Downloads/Requested_Documents.pdf`;
test(
  "canonical 26-page Henry Schein packet: upload -> 22 invoices -> existing parser -> review drafts",
  { skip: skip || (existsSync(CANONICAL) ? false : "canonical packet not present locally") },
  async () => {
    const bytes = new Uint8Array(await readFile(CANONICAL));
    const canonicalStorage = new MemoryStorage();
    const started = performance.now();
    const result = await intake(
      owner,
      OWNER,
      canonicalStorage,
      canonicalStorage.put(bytes),
      bytes,
      "Requested_Documents.pdf",
    );
    const intakeMs = performance.now() - started;
    assert.equal(result.kind, "batch");
    if (result.kind !== "batch") return;
    assert.equal(result.invoiceCount, 22);
    const processStarted = performance.now();
    const batch = await processAll(canonicalStorage, result.batchId);
    const processMs = performance.now() - processStarted;
    assert.ok(batch.segments.every((s) => s.status === "created"));
    const byNumber = new Map(batch.segments.map((s) => [s.invoiceNumber, s]));
    assert.deepEqual(
      [byNumber.get("50902751")!.pageStart, byNumber.get("50902751")!.pageEnd],
      [1, 1],
    );
    assert.deepEqual(
      [byNumber.get("52093808")!.pageStart, byNumber.get("52093808")!.pageEnd],
      [4, 5],
    );
    assert.deepEqual(
      [byNumber.get("52103732")!.pageStart, byNumber.get("52103732")!.pageEnd],
      [7, 10],
    );
    const reviewStarted = performance.now();
    const first = await openReview(canonicalStorage, byNumber.get("50902751")!.sourceFileId!);
    const long = await openReview(canonicalStorage, byNumber.get("52103732")!.sourceFileId!);
    const reviewMs = performance.now() - reviewStarted;
    const total = async (invoiceId: string) =>
      (await inspect.from("invoices").select("invoice_total").eq("id", invoiceId).single()).data!
        .invoice_total;
    const count = async (invoiceId: string) =>
      (
        await inspect
          .from("invoice_items")
          .select("id", { count: "exact", head: true })
          .eq("invoice_id", invoiceId)
      ).count;
    assert.equal(Number(await total(first.invoiceId)), 19054.88);
    assert.equal(await count(first.invoiceId), 1);
    assert.equal(Number(await total(long.invoiceId)), 1126.91);
    assert.equal(await count(long.invoiceId), 33);
    const provenance = await getInvoiceProvenance(owner, OWNER, {
      organizationId: ORG,
      sourceFileId: byNumber.get("52103732")!.sourceFileId!,
    });
    assert.equal(provenance?.pageStart, 7);
    assert.equal(provenance?.pageEnd, 10);
    const stored = [...canonicalStorage.files.values()].reduce(
      (sum, file) => sum + file.byteLength,
      0,
    );
    console.log(
      `[6c4 canonical integration] intake ${intakeMs.toFixed(0)} ms (text ${result.timings.textMs}, segmentation ${result.timings.segmentationMs}, parsing ${result.timings.parsingMs}), prepare 22 invoices ${processMs.toFixed(0)} ms, open 2 reviews ${reviewMs.toFixed(0)} ms, stored ${(stored / 1e6).toFixed(1)} MB (packet ${(bytes.byteLength / 1e6).toFixed(1)} MB), rss ${(process.memoryUsage().rss / 1e6).toFixed(0)} MB`,
    );
  },
);
