import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { adminRequestDecisionSchema, requestItemIsCustom, trustedRequestPackage } from "../src/supply-requests/admin-request-inbox.ts";
import { buildAdminRequestDashboard, translateAdminRequestStatus } from "../src/supply-requests/admin-dashboard.ts";
import type { AdminSupplyRequestViewModel } from "../src/supply-requests/admin-dashboard.ts";
import type { SupplyRequestItemViewModel } from "../src/supply-requests/staff-dashboard.ts";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const server = read("../src/lib/supply-requests.functions.ts");
const sql = read("../supabase/migrations/20260903140000_phase5a9_admin_request_decisions.sql");
const route = read("../src/routes/_authenticated/supply-requests.tsx");
const detail = read("../src/components/admin/supply-requests/AdminRequestDetail.tsx");
const id = "11111111-1111-4111-8111-111111111111";
const line: SupplyRequestItemViewModel = { id, name: "Tape", productId: null, inventoryItemId: null, vendorProductId: null, catalogVendorProductId: id, quantity: 4, unit: null, manufacturer: "Maker", vendorName: "Supplier", vendorSku: "TAPE-01", packageDisplay: "12 rolls" };

test("submitted and in-review requests remain in the decision inbox with a single review entry point", () => {
  for (const status of ["submitted", "under_review"] as const) {
    const translation = translateAdminRequestStatus(status);
    assert.equal(translation.queueGroup, "NEEDS_REVIEW");
    assert.equal(translation.nextAction, "View Request");
    const request = { id, items: [line, { ...line, id: "custom", catalogVendorProductId: null, freeTextItem: "Travel supplies" }], itemCount: 2, lifecycleStatus: status, ...translation } as AdminSupplyRequestViewModel;
    const dashboard = buildAdminRequestDashboard([request]);
    assert.equal(dashboard.summary.needsReview, 1);
    assert.deepEqual(dashboard.queues.needsReview[0].items, request.items);
  }
});

test("all four structured identities distinguish catalog lines from custom and legacy free text", () => {
  for (const field of ["inventoryItemId", "vendorProductId", "productId", "catalogVendorProductId"] as const) {
    assert.equal(requestItemIsCustom({ ...line, catalogVendorProductId: null, [field]: id }), false);
  }
  assert.equal(requestItemIsCustom({ ...line, catalogVendorProductId: null, freeTextItem: "Custom tape" }), true);
});

test("human-readable packages respect verified, source-only, and unknown evidence", () => {
  const value = { package_status: "verified", package_quantity: 12, package_unit: "rolls", package_description: "unverified alternate text" };
  assert.equal(trustedRequestPackage(value), "12 rolls");
  assert.equal(trustedRequestPackage({ ...value, package_status: "source_only" }), "unverified alternate text");
  assert.equal(trustedRequestPackage({ ...value, package_status: "unknown" }), null);
  assert.equal(trustedRequestPackage({ ...value, package_quantity: null }), null);
});

test("decisions accept only approve/decline and require a trimmed public decline reason", () => {
  const base = { organizationId: id, id, decision: "approved" };
  assert.equal(adminRequestDecisionSchema.safeParse(base).success, true);
  for (const staffVisibleNote of [null, undefined, "", "  "]) {
    assert.equal(adminRequestDecisionSchema.safeParse({ ...base, decision: "denied", staffVisibleNote }).success, false);
  }
  const parsed = adminRequestDecisionSchema.parse({ ...base, decision: "denied", staffVisibleNote: "  Already in storage  ", internalNote: " private " });
  assert.equal(parsed.staffVisibleNote, "Already in storage");
  assert.equal(parsed.internalNote, "private");
  assert.equal(adminRequestDecisionSchema.safeParse({ ...base, decision: "ordered" }).success, false);
  assert.equal(adminRequestDecisionSchema.safeParse({ ...base, staffVisibleNote: "x".repeat(5001) }).success, false);
});

test("approve/decline use an authenticated admin-scoped server RPC, not client lifecycle choreography", () => {
  const decision = server.slice(server.indexOf("export const decideSupplyRequestFn"), server.indexOf("export const updateRequestStatusFn"));
  assert.match(decision, /middleware\(\[requireSupabaseAuth\]\)/);
  assert.match(decision, /requireAdmin\(context, data.organizationId\)/);
  assert.match(decision, /rpc\("decide_supply_request"/);
  assert.match(decision, /_organization_id: data.organizationId/);
  assert.match(route, /useServerFn\(decideSupplyRequestFn\)/);
  assert.match(route, /submitting.current/);
  assert.match(detail, /disabled=\{busy\}/);
  assert.match(detail, /Dialog.Root/);
});

test("the decision transaction locks one organization-owned request, audits both approval steps, and rejects stale decisions", () => {
  const decision = sql.slice(0, sql.indexOf("CREATE OR REPLACE FUNCTION public.list_staff"));
  assert.match(decision, /is_org_admin\(_organization_id, auth.uid\(\)\)/);
  assert.match(decision, /WHERE id = _request_id AND organization_id = _organization_id\s+FOR UPDATE/);
  assert.match(decision, /IF _request.status = _decision THEN[\s\S]*alreadyDecided/);
  assert.match(decision, /_request.status NOT IN \('submitted', 'under_review'\)/);
  assert.match(decision, /transition_supply_request\(_organization_id, _request_id, 'under_review'\)/);
  assert.match(decision, /_organization_id, _request_id, _decision, _internal_note, _staff_visible_note/);
  assert.doesNotMatch(decision, /\b(?:INSERT\s+INTO|UPDATE\s+(?:public\.)?\w+\s+SET|DELETE\s+FROM)\b/);
  assert.doesNotMatch(decision, /adopt_catalog|stock_catalog|purchase_order/);
});

test("staff update projection preserves public decisions without exposing private mixed rows or other users", () => {
  assert.match(sql, /internal_note IS NULL\s+AND staff_visible_note IS NOT NULL/);
  const projection = sql.slice(sql.indexOf("CREATE OR REPLACE FUNCTION public.list_staff"), sql.indexOf('ALTER POLICY'));
  assert.match(projection, /is_org_member\(_organization_id, auth.uid\(\)\)/);
  assert.match(projection, /r.organization_id = _organization_id/);
  assert.match(projection, /r.requested_by = auth.uid\(\)/);
  assert.doesNotMatch(projection, /internal_note/);
  assert.match(projection, /FROM PUBLIC, anon/);
  for (const start of ["listMyRequestsFn", "getStaffDashboardFn", "getStaffRequestDetailFn"]) {
    const body = server.slice(server.indexOf("export const " + start), server.indexOf("export const ", server.indexOf("export const " + start) + 1));
    assert.match(body, /rpc\("list_staff_supply_request_updates"/);
    assert.doesNotMatch(body, /internal_note/);
  }
});

test("detail renders every item with trustworthy identity, while legacy lines retain their fallback", () => {
  assert.match(detail, /aria-label="Requested items"/);
  assert.match(detail, /request.items.map/);
  for (const property of ["name", "quantity", "manufacturer", "vendorName", "vendorSku", "packageDisplay"]) assert.match(detail, new RegExp("item\\." + property));
  assert.match(detail, /requestItemIsCustom\(item\)/);
  assert.doesNotMatch(detail, /item\.(?:productId|inventoryItemId|vendorProductId|catalogVendorProductId)\}/);
  assert.match(server, /id: `legacy:\$\{request.id\}`/);
  assert.match(server, /freeTextItem: request.free_text_item/);
});
