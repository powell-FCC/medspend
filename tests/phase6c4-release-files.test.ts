// Phase 6C.4 structural checks: release files, migration grants, server-function wiring and
// the intake UI. Behaviour is proven by the SQL suite, the integration test and the unit tests.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path: string) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const migration = read("supabase/migrations/20261109120000_phase6c4_batch_invoice_intake.sql");
const CLIENT_FUNCTIONS = [
  "create_invoice_upload_batch(uuid, text, text, bigint, text, integer, text, text, text, jsonb)",
  "register_invoice_batch_segment(uuid, uuid, text, bigint)",
  "fail_invoice_batch_segment(uuid, uuid, text)",
  "release_invoice_batch_segment(uuid, uuid)",
  "get_invoice_upload_batch(uuid, uuid)",
  "list_invoice_upload_batches(uuid, integer)",
  "get_invoice_source_provenance(uuid, uuid)",
];

test("precheck and postcheck end with exactly the shared fingerprint SELECT", () => {
  const fingerprint = read("supabase/release/phase6c4/fingerprint.sql");
  const select = fingerprint.slice(fingerprint.indexOf("SELECT section, key, value FROM ("));
  for (const file of ["precheck", "postcheck"]) {
    const text = read(`supabase/release/phase6c4/${file}.sql`);
    assert.ok(text.endsWith(select), `${file}.sql ends with the fingerprint`);
    assert.doesNotMatch(
      text,
      /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im,
      `${file}.sql has no transaction control`,
    );
    assert.doesNotMatch(text, /^\\/m, `${file}.sql has no psql meta-commands`);
  }
  const precheck = read("supabase/release/phase6c4/precheck.sql");
  assert.match(
    precheck,
    /expected functions 140, tables 46, indexes 171, policies 58, triggers 75/,
  );
  assert.match(
    precheck,
    /\('post_reviewed_invoice', '[0-9a-f]{32} secdef=true authenticated=true anon=false public=false'\)/,
  );
  assert.match(precheck, /\('search_supply_request_products_with_signals', '[0-9a-f]{32} /);
  assert.match(
    read("supabase/release/phase6c4/postcheck.sql"),
    /expected functions 149, tables 48, indexes 181, policies 58, triggers 76/,
  );
});

test("the migration is one transaction, enables RLS itself and grants nothing to anon", () => {
  assert.equal(migration.match(/^BEGIN;$/gm)?.length, 1);
  assert.equal(migration.match(/^COMMIT;$/gm)?.length, 1);
  assert.doesNotMatch(migration, /create\s+temp/i);
  for (const table of ["invoice_upload_batches", "invoice_upload_batch_segments"]) {
    assert.match(migration, new RegExp(`ALTER TABLE public\\.${table} ENABLE ROW LEVEL SECURITY;`));
    assert.match(
      migration,
      new RegExp(`REVOKE ALL ON public\\.${table} FROM PUBLIC, anon, authenticated, service_role;`),
    );
    assert.doesNotMatch(migration, new RegExp(`CREATE POLICY [a-z_]+ ON public\\.${table}`));
  }
  for (const signature of CLIENT_FUNCTIONS) {
    assert.ok(
      migration.includes(`REVOKE ALL ON FUNCTION public.${signature} FROM PUBLIC, anon;`),
      signature,
    );
    assert.ok(
      migration.includes(`GRANT EXECUTE ON FUNCTION public.${signature} TO authenticated;`),
      signature,
    );
  }
  assert.doesNotMatch(migration, /TO anon/);
  assert.equal(
    migration.match(
      /has_org_role\(_organization_id, auth\.uid\(\), ARRAY\['owner'\]::public\.org_role\[\]\)/g,
    )?.length,
    7,
  );
  // Existing objects are never altered.
  assert.doesNotMatch(
    migration,
    /ALTER TABLE public\.(vendor_invoices|invoices|invoice_items|invoice_processing_jobs)\b/,
  );
  assert.doesNotMatch(migration, /CREATE OR REPLACE FUNCTION/);
});

test("server functions require an authenticated caller and use the shared actions", () => {
  const functions = read("src/lib/invoice-batches.functions.ts");
  assert.equal(functions.match(/createServerFn\(/g)?.length, 6);
  assert.equal(functions.match(/\.middleware\(\[requireSupabaseAuth\]\)/g)?.length, 6);
  assert.match(functions, /supabasePacketStorage\(context\.supabase\)/);
  assert.doesNotMatch(functions, /service_role|SUPABASE_SERVICE/i);
  const actions = read("src/invoice-batch/intake-actions.ts");
  assert.equal(
    actions.match(/await assertOwner\(/g)?.length,
    5,
    "every action checks the owner first (processing via getInvoiceBatch)",
  );
  assert.doesNotMatch(
    actions,
    /post_reviewed_invoice|seed_structured_invoice_draft/,
    "batch intake never seeds or posts",
  );
});

test("a single-invoice upload keeps the exact insert recordVendorInvoiceFn always made", () => {
  const vendorInvoices = read("src/lib/vendor-invoices.functions.ts");
  assert.match(
    vendorInvoices,
    /export const recordVendorInvoiceFn[\s\S]*assertOwner\(context\.supabase, context\.userId, data\.organizationId\);\s*return recordVendorInvoiceRow\(context\.supabase, context\.userId, data\);/,
  );
  const record = read("src/invoice/upload-record.ts");
  assert.match(
    record,
    /uploaded_by: userId,\s*storage_path: data\.storagePath,\s*original_filename: data\.originalFilename,\s*file_size: data\.fileSize,\s*mime_type: data\.mimeType,/,
  );
  assert.match(record, /\^\$\{data\.organizationId\}\/\[0-9a-f-\]\{36\}\\\\\.pdf\$/);
});

test("upload page: single uploads open review as before; packets open the packet page", () => {
  const page = read("src/components/invoices/InvoiceUploadPage.tsx");
  assert.match(page, /intakeUpload\(/);
  assert.match(page, /to: '\/invoices\/\$invoiceId', params: \{ invoiceId: intake\.invoice\.id \}/);
  assert.match(
    page,
    /to: '\/invoices\/batches\/\$batchId', params: \{ batchId: intake\.batchId \}/,
  );
  assert.match(
    page,
    /rollbackUploadedInvoice\(storagePath, error, deleteVendorInvoice\)/,
    "a failed intake still removes the uploaded file",
  );
  const batch = read("src/components/invoices/InvoiceBatchPage.tsx");
  assert.match(batch, /Detected \{counts\.invoices\} invoice/);
  assert.match(batch, /Nothing is posted automatically/);
  assert.match(batch, /md:hidden/, "phone layout");
  const review = read("src/components/invoice-processing/InvoiceReviewPage.tsx");
  assert.match(
    review,
    /<InvoiceSourcePacket organizationId=\{data\.header\.organizationId\} sourceFileId=\{data\.header\.sourceFileId\} \/>/,
  );
  const route = read("src/routes/_authenticated/invoices.batches.$batchId.tsx");
  assert.match(route, /createFileRoute\(["']\/_authenticated\/invoices\/batches\/\$batchId["']\)/);
  assert.match(
    read("src/routes/_authenticated/route.tsx"),
    /"\/invoices"/,
    "the packet page sits under the owner/admin-only /invoices gate",
  );
});

test("generated types list every new client RPC", () => {
  const types = read("src/integrations/supabase/types.ts");
  for (const name of [
    "create_invoice_upload_batch",
    "register_invoice_batch_segment",
    "fail_invoice_batch_segment",
    "release_invoice_batch_segment",
    "get_invoice_upload_batch",
    "list_invoice_upload_batches",
    "get_invoice_source_provenance",
  ]) {
    assert.match(types, new RegExp(`\\n      ${name}: \\{\\n        Args`), name);
  }
});

test("pdf-lib is pinned exactly", () => {
  const pkg = JSON.parse(read("package.json")) as { dependencies: Record<string, string> };
  assert.equal(pkg.dependencies["pdf-lib"], "1.17.1");
});

test("release evidence pins the 5A.10, request, catalog, inventory and invoice pipeline foundation", () => {
  const fingerprint = read("supabase/release/phase6c4/fingerprint.sql");
  const precheck = read("supabase/release/phase6c4/precheck.sql");
  const postcheck = read("supabase/release/phase6c4/postcheck.sql");
  const neighbours = [
    "apply_supply_request_transition",
    "transition_supply_request",
    "guard_supply_request_lifecycle",
    "replace_supply_request_items",
    "update_submitted_supply_request",
    "cancel_submitted_supply_request",
    "resolve_supply_request_context",
    "resolve_supply_request_item_costs",
    "get_supply_request_budget_impact",
    "get_supply_request_inventory_identities",
    "get_supply_request_product_specifications",
    "supply_request_product_history",
    "supply_request_product_identities",
    "list_staff_supply_request_updates",
    "adopt_catalog_vendor_product",
    "stock_catalog_vendor_product",
    "get_catalog_vendor_product_admin_detail",
    "get_catalog_vendor_product_effective_specifications",
    "validate_catalog_parent_link_change",
    "catalog_product_normalize_row",
    "catalog_vendor_product_normalize_row",
    "catalog_source_record_preserve_raw",
    "catalog_search_text",
    "catalog_search_token_pattern",
    "catalog_search_edit_distance",
    "normalize_catalog_text",
    "normalize_catalog_search_text",
    "normalize_catalog_sku",
    "normalize_catalog_sku_match_key",
    "tg_catalog_products_search_document",
    "tg_catalog_vendor_products_search_document",
    "tg_catalog_source_records_search_document",
    "tg_catalog_vendors_search_document",
    "get_inventory_count_policy",
    "get_inventory_count_freshness",
    "inventory_location_count_freshness",
    "staff_saved_product_identity_check",
  ];
  assert.equal(neighbours.length, 37);
  for (const name of neighbours) {
    assert.ok(fingerprint.includes(`    ('${name}')`), `${name} fingerprinted`);
    for (const [file, text] of [
      ["precheck", precheck],
      ["postcheck", postcheck],
    ]) {
      assert.match(
        text,
        new RegExp(`\\('${name}', '[0-9a-f]{32} secdef=(true|false) `),
        `${name} asserted in ${file}`,
      );
    }
  }
  for (const table of [
    "supply_request_items",
    "catalog_products",
    "catalog_vendor_products",
    "catalog_vendors",
    "catalog_source_records",
    "product_aliases",
    "inventory_location_balances",
    "inventory_transfers",
    "inventory_count_sessions",
    "inventory_count_lines",
    "invoice_extraction_runs",
    "invoice_extraction_candidates",
    "invoice_line_items",
    "vendor_identity_signatures",
    "vendors",
  ]) {
    assert.ok(fingerprint.includes(`'rows', '${table} hash'`), `${table} rows hashed`);
  }
  for (const table of [
    "staff_saved_products",
    "catalog_search_terms",
    "catalog_vendor_product_search_documents",
    "invoice_extraction_runs",
    "invoice_extraction_candidates",
    "invoice_line_items",
    "vendor_identity_signatures",
    "vendors",
  ]) {
    for (const [file, text] of [
      ["precheck", precheck],
      ["postcheck", postcheck],
    ]) {
      assert.match(
        text,
        new RegExp(`\\('${table}', '[0-9a-f]{32} rls=(true|false)'\\)`),
        `${table} definition asserted in ${file}`,
      );
    }
  }
  assert.match(fingerprint, /SELECT 5, 'constraint', t\.relname \|\| '\.' \|\| con\.conname/);
  for (const text of [precheck, postcheck]) {
    assert.match(
      text,
      /con\.confrelid = 'public\.vendor_invoices'::regclass AND con\.confdeltype = 'n'/,
    );
    assert.match(text, /attname = 'storage_path'/);
    assert.match(
      text,
      /Generated by\s+(--\s+)?supabase\/tests\/support\/phase6c4_release_generate\.mjs/,
    );
  }
  assert.ok(fingerprint.includes("'rows', 'staff_saved_products count'"));
});
