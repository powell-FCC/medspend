import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  SUPPLY_REQUEST_STATUSES,
  canRequesterEditSupplyRequest,
  canTransitionSupplyRequest,
  requesterEditGuidance,
} from "../src/supply-requests/lifecycle.ts";
import {
  cartItemFromRequestItem,
  changeCartItemQuantity,
  createCustomCartItem,
  describeSubmission,
  editRequestTypeIntent,
  removeCartItem,
  resolveEditRequestContextId,
  resolveStaffRequestType,
  toSubmissionItem,
} from "../src/supply-requests/staff-request-cart.ts";
import {
  multiItemSupplyRequestInputSchema,
  updateSubmittedSupplyRequestInputSchema,
} from "../src/supply-requests/validation.ts";
import { adminRequestDecisionSchema } from "../src/supply-requests/admin-request-inbox.ts";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const migration = read("../supabase/migrations/20261009120000_phase6c_staff_request_forgiveness.sql");
const migrationCode = migration.replace(/--.*$/gm, "");
const behavior = read("../supabase/tests/phase6c_staff_request_forgiveness_behavior.sql");
const server = read("../src/lib/supply-requests.functions.ts");
const composer = read("../src/routes/_authenticated/staff/request.tsx");
const staffDetail = read("../src/routes/_authenticated/staff/requests.$id.tsx");
const adminDetail = read("../src/components/admin/supply-requests/AdminRequestDetail.tsx");
const adminRoute = read("../src/routes/_authenticated/supply-requests.tsx");
const types = read("../src/integrations/supabase/types.ts");

const between = (source: string, start: string, end?: string) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = end ? source.indexOf(end, from + start.length) : source.length;
  assert.ok(to > from, `missing ${end}`);
  return source.slice(from, to);
};

const editFunction = between(
  migration,
  "CREATE FUNCTION public.update_submitted_supply_request",
  "REVOKE ALL ON FUNCTION public.update_submitted_supply_request",
);
const submitFunction = between(
  migration,
  "CREATE OR REPLACE FUNCTION public.submit_supply_request",
  "REVOKE ALL ON FUNCTION public.submit_supply_request",
);
const decideFunction = between(
  migration,
  "CREATE FUNCTION public.decide_supply_request",
  "REVOKE ALL ON FUNCTION public.decide_supply_request",
);
const lineHelper = between(
  migration,
  "CREATE FUNCTION public.replace_supply_request_items",
  "REVOKE ALL ON FUNCTION public.replace_supply_request_items",
);

const requestId = "11111111-1111-4111-8111-111111111111";
const organizationId = "22222222-2222-4222-8222-222222222222";
const inventoryItemId = "33333333-3333-4333-8333-333333333333";
const productId = "44444444-4444-4444-8444-444444444444";
const vendorProductId = "55555555-5555-4555-8555-555555555555";
const catalogVendorProductId = "66666666-6666-4666-8666-666666666666";

const storedLines = [
  {
    id: "a1111111-1111-4111-8111-111111111111",
    productId,
    inventoryItemId,
    vendorProductId,
    catalogVendorProductId,
    name: "Elastic tape",
    quantity: 4,
    unit: "roll",
    freeTextItem: null,
    manufacturer: "Acme",
    vendorName: "Supply Co",
    vendorSku: "TAPE-1",
    packageDisplay: "Box of 12",
  },
  {
    id: "a2222222-2222-4222-8222-222222222222",
    productId,
    inventoryItemId: null,
    vendorProductId: null,
    catalogVendorProductId: null,
    name: "Organization gauze",
    quantity: 2,
    unit: "each",
    freeTextItem: null,
  },
  {
    id: "a3333333-3333-4333-8333-333333333333",
    productId: null,
    inventoryItemId: null,
    vendorProductId: null,
    catalogVendorProductId,
    name: "Catalog cold pack",
    quantity: 1,
    unit: null,
    freeTextItem: null,
    packageDisplay: null,
  },
  {
    id: "a4444444-4444-4444-8444-444444444444",
    productId: null,
    inventoryItemId: null,
    vendorProductId: null,
    catalogVendorProductId: null,
    name: "Ankle brace",
    quantity: 3,
    unit: null,
    freeTextItem: "Ankle brace",
  },
];

test("only submitted requests are requester-editable; review and every later status lock", () => {
  for (const status of SUPPLY_REQUEST_STATUSES) {
    assert.equal(canRequesterEditSupplyRequest(status), status === "submitted", status);
  }
  assert.equal(
    requesterEditGuidance("submitted"),
    "You can make changes until this request enters review.",
  );
  assert.equal(
    requesterEditGuidance("under_review"),
    "This request is being reviewed and can no longer be edited.",
  );
  for (const status of ["approved", "ordered", "received", "completed", "denied"] as const) {
    assert.equal(requesterEditGuidance(status), null, status);
  }
});

test("the lifecycle graph is unchanged: no regression to submitted and no new statuses", () => {
  assert.deepEqual(
    [...SUPPLY_REQUEST_STATUSES],
    ["submitted", "under_review", "approved", "ordered", "received", "completed", "denied"],
  );
  for (const status of SUPPLY_REQUEST_STATUSES) {
    assert.equal(canTransitionSupplyRequest(status, "submitted"), false, status);
  }
  assert.doesNotMatch(migration, /ALTER TYPE public\.supply_request_status/);
  assert.doesNotMatch(migration, /'draft'|'withdrawn'|'cancelled'/);
});

test("edit mode preloads stored lines with their exact identities and quantities", () => {
  const cart = storedLines.map(cartItemFromRequestItem);
  assert.deepEqual(
    cart.map((item) => [item.key, item.kind, item.name, item.quantity]),
    [
      [storedLines[0].id, "structured", "Elastic tape", 4],
      [storedLines[1].id, "structured", "Organization gauze", 2],
      [storedLines[2].id, "structured", "Catalog cold pack", 1],
      [storedLines[3].id, "custom", "Ankle brace", 3],
    ],
  );
  assert.deepEqual(cart.map(toSubmissionItem), [
    { productId, inventoryItemId, vendorProductId, catalogVendorProductId, freeTextItem: null, quantity: 4 },
    { productId, inventoryItemId: null, vendorProductId: null, catalogVendorProductId: null, freeTextItem: null, quantity: 2 },
    { productId: null, inventoryItemId: null, vendorProductId: null, catalogVendorProductId, freeTextItem: null, quantity: 1 },
    { productId: null, inventoryItemId: null, vendorProductId: null, catalogVendorProductId: null, freeTextItem: "Ankle brace", quantity: 3 },
  ]);
  const structured = cart[0];
  assert.equal(structured.kind, "structured");
  if (structured.kind === "structured") {
    assert.equal(structured.vendorSku, "TAPE-1");
    assert.equal(structured.packageDisplay, "Box of 12");
    assert.equal(structured.specification, null);
  }
});

test("edit mode supports changing quantity, removing a line, and adding a mixed line", () => {
  let cart = storedLines.map(cartItemFromRequestItem);
  cart = changeCartItemQuantity(cart, storedLines[0].id, 2);
  cart = removeCartItem(cart, storedLines[1].id);
  cart = [...cart, createCustomCartItem("new-line", "  Knee sleeve ", 1)];
  const payload = updateSubmittedSupplyRequestInputSchema.parse({
    organizationId,
    requestId,
    requestType: resolveStaffRequestType(editRequestTypeIntent("reorder"), cart),
    items: cart.map(toSubmissionItem),
    notes: "Updated",
  });
  assert.equal(payload.requestId, requestId);
  assert.equal(payload.requestType, "new_item");
  assert.deepEqual(payload.items.map((item) => item.quantity), [6, 1, 3, 1]);
  assert.equal(payload.items.some((item) => item.productId === productId && !item.inventoryItemId), false);
  assert.equal(payload.items.at(-1)?.freeTextItem, "Knee sleeve");
});

test("edit payloads reuse submission validation for quantities and identities", () => {
  const base = { organizationId, requestId, requestType: "reorder" as const };
  for (const quantity of [0, -1, 1.5]) {
    assert.equal(
      updateSubmittedSupplyRequestInputSchema.safeParse({
        ...base,
        items: [{ freeTextItem: "Tape", quantity }],
      }).success,
      false,
      String(quantity),
    );
  }
  assert.equal(updateSubmittedSupplyRequestInputSchema.safeParse({ ...base, items: [] }).success, false);
  assert.equal(
    updateSubmittedSupplyRequestInputSchema.safeParse({
      ...base,
      items: [{ productId, freeTextItem: "Spoofed", quantity: 1 }],
    }).success,
    false,
  );
  assert.equal(
    updateSubmittedSupplyRequestInputSchema.safeParse({
      organizationId,
      requestType: "reorder",
      items: [{ freeTextItem: "Tape", quantity: 1 }],
    }).success,
    false,
    "requestId is required",
  );
  assert.equal(
    updateSubmittedSupplyRequestInputSchema.safeParse({ ...base, requestId: "not-a-uuid", items: [{ freeTextItem: "Tape", quantity: 1 }] }).success,
    false,
  );
  // Create payloads are unchanged.
  assert.equal(
    multiItemSupplyRequestInputSchema.safeParse({
      organizationId,
      requestType: "reorder",
      items: [{ inventoryItemId, quantity: 1 }, { freeTextItem: "Tape", quantity: 2 }],
    }).success,
    true,
  );
});

test("explicit low/out-of-stock reports survive edits while reorder/new_item follows the cart", () => {
  const custom = [createCustomCartItem("c", "Brace", 1)];
  const structured = storedLines.slice(0, 1).map(cartItemFromRequestItem);
  assert.equal(resolveStaffRequestType(editRequestTypeIntent("low_stock"), custom), "low_stock");
  assert.equal(resolveStaffRequestType(editRequestTypeIntent("out_of_stock"), custom), "out_of_stock");
  assert.equal(resolveStaffRequestType(editRequestTypeIntent("new_item"), structured), "reorder");
  assert.equal(resolveStaffRequestType(editRequestTypeIntent("reorder"), custom), "new_item");
  // Create mode keeps its original expression semantics.
  assert.equal(resolveStaffRequestType(undefined, structured), "reorder");
  assert.equal(resolveStaffRequestType("new_item", structured), "new_item");
});

test("edit mode keeps the request's context unless the requester changes it", () => {
  const options = [{ id: "team-a" }, { id: "team-b" }, { id: "team-default" }];
  assert.equal(resolveEditRequestContextId("team-a", "", "team-default", options), "team-a");
  assert.equal(resolveEditRequestContextId("team-a", "team-b", "team-default", options), "team-b");
  assert.equal(resolveEditRequestContextId("archived", "", "team-default", options), "team-default");
  assert.equal(resolveEditRequestContextId("archived", "", null, [{ id: "only" }]), "only");
  assert.equal(resolveEditRequestContextId("archived", "", null, options), null);
});

test("submission confirmation summarizes item count and context", () => {
  const cart = storedLines.map(cartItemFromRequestItem);
  assert.deepEqual(describeSubmission(cart, { teamName: "Football", locationName: "Main Room" }), {
    title: "Submit this request?",
    body: "4 items will be sent for review.",
    context: "Football · Main Room",
  });
  assert.equal(describeSubmission(cart.slice(0, 1)).body, "1 item will be sent for review.");
  assert.equal(describeSubmission(cart.slice(0, 1)).context, null);
});

test("the edit RPC authenticates, scopes, locks, and enforces ownership and the submitted boundary", () => {
  assert.match(editFunction, /SECURITY DEFINER\s+SET search_path = public/);
  assert.match(editFunction, /IF _uid IS NULL THEN\s+RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501'/);
  assert.match(editFunction, /IF NOT public\.is_org_member\(_organization_id, _uid\)/);
  assert.match(
    editFunction,
    /WHERE id = _request_id\s+AND organization_id = _organization_id\s+FOR UPDATE;/,
  );
  assert.match(editFunction, /_request\.requested_by IS DISTINCT FROM _uid/);
  assert.match(editFunction, /'Supply request not found' USING ERRCODE = 'P0002'/);
  assert.match(editFunction, /_request\.status <> 'submitted'/);
  assert.match(
    editFunction,
    /'This request has already entered review and can no longer be edited\.'\s+USING ERRCODE = '55000'/,
  );
  assert.match(editFunction, /'This request has been declined and can no longer be edited\.'/);
  // The lock is checked before any write.
  const lock = editFunction.indexOf("FOR UPDATE");
  const statusCheck = editFunction.indexOf("_request.status <> 'submitted'");
  const firstWrite = editFunction.indexOf("UPDATE public.supply_requests");
  assert.ok(lock < statusCheck && statusCheck < firstWrite);
  assert.match(migration, /REVOKE ALL ON FUNCTION public\.update_submitted_supply_request\([\s\S]*?\) FROM PUBLIC, anon;/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.update_submitted_supply_request\([\s\S]*?\) TO authenticated;/);
});

test("the edit preserves the request row, its status, and creates no second request", () => {
  assert.doesNotMatch(editFunction, /INSERT INTO public\.supply_requests\b/);
  assert.doesNotMatch(editFunction, /DELETE FROM public\.supply_requests\b/);
  const requestSet = between(editFunction, "UPDATE public.supply_requests\n  SET", "WHERE");
  assert.doesNotMatch(requestSet, /\bstatus\b|requested_by|organization_id|created_at|\bid\s*=/);
  assert.match(editFunction, /WHERE id = _request\.id\s+AND organization_id = _organization_id;/);
  assert.match(editFunction, /'id', _request\.id,\s+'status', _request\.status/);
});

test("submission and editing share one context helper and one line-validation helper", () => {
  assert.match(submitFunction, /public\.resolve_supply_request_context\(_organization_id, _uid, _team_id, _location_id\)/);
  assert.match(submitFunction, /PERFORM public\.replace_supply_request_items\(_organization_id, _request_id, _items\)/);
  assert.match(editFunction, /public\.resolve_supply_request_context\(/);
  assert.match(editFunction, /public\.replace_supply_request_items\(_organization_id, _request\.id, _items\)/);
  for (const rule of [
    "Each requested quantity must be a positive whole number",
    "A custom request line cannot include structured identity IDs",
    "Each line must contain a structured identity or one custom item",
    "A selected inventory item is unavailable for this organization",
    "The selected inventory item has no proven product identity chain",
    "A selected vendor product is unavailable for this organization",
    "The selected vendor product has no proven global catalog link",
    "A selected product is unavailable for this organization",
    "A selected global catalog product is unavailable",
    "A local product cannot claim an unproven global catalog identity",
    "Add at least one item to the request",
  ]) {
    assert.ok(lineHelper.includes(rule), rule);
  }
  assert.match(lineHelper, /AND staff_requestable = true/);
  assert.match(lineHelper, /catalog_vendor_product\.discontinued = false/);
  assert.match(migration, /team\.organization_id = _organization_id\s+AND team\.active = true/);
  assert.match(migration, /location\.organization_id = _organization_id\s+AND location\.active = true/);
  assert.match(migration, /coalesce\(_team_id, _membership\.default_team_id\)/);
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.resolve_supply_request_context\(uuid, uuid, uuid, uuid\)\s+FROM PUBLIC, anon, authenticated;/,
  );
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.replace_supply_request_items\(uuid, uuid, jsonb\)\s+FROM PUBLIC, anon, authenticated;/,
  );
});

test("requester edits are audited in the existing update history without admin notes", () => {
  assert.match(migration, /ALTER TABLE public\.supply_request_updates\s+ADD COLUMN event_kind text/);
  assert.match(
    migration,
    /event_kind = 'requester_edited'\s+AND status_from IS NULL\s+AND status_to IS NULL\s+AND internal_note IS NULL\s+AND staff_visible_note IS NULL/,
  );
  assert.match(
    editFunction,
    /INSERT INTO public\.supply_request_updates\s+\(organization_id, supply_request_id, author_id, event_kind\)\s+VALUES\s+\(_organization_id, _request\.id, _uid, 'requester_edited'\)/,
  );
  const staffUpdates = between(migration, "CREATE FUNCTION public.list_staff_supply_request_updates", "REVOKE ALL ON FUNCTION public.list_staff_supply_request_updates");
  assert.doesNotMatch(staffUpdates, /internal_note/);
  assert.match(staffUpdates, /r\.requested_by = auth\.uid\(\)/);
  assert.match(staffUpdates, /u\.event_kind = 'requester_edited'/);
});

test("editing has no commitment, budget, purchasing, invoice, or price-intelligence effect", () => {
  // The private transition body is a verbatim copy of the Phase 6A.2 lifecycle body
  // (asserted below), so it is the only place commitment and lifecycle-timestamp logic
  // may appear. Everything Phase 6C adds is checked without it.
  const transitionStart = migrationCode.indexOf("CREATE FUNCTION public.apply_supply_request_transition");
  const transitionEnd = migrationCode.indexOf("REVOKE ALL ON FUNCTION public.apply_supply_request_transition");
  assert.ok(transitionStart >= 0 && transitionEnd > transitionStart);
  const phase6cCode = migrationCode.slice(0, transitionStart) + migrationCode.slice(transitionEnd);
  assert.doesNotMatch(phase6cCode, /create_supply_request_commitment|release_supply_request_commitment/);
  assert.doesNotMatch(migrationCode, /INSERT INTO public\.supply_request_commitment/);
  assert.doesNotMatch(migrationCode, /\binvoice|organization_budgets|inventory_price_history|price_intelligence/i);
  assert.doesNotMatch(migrationCode, /FUNCTION public\.(?:create|release)_supply_request_commitment/);
  assert.doesNotMatch(editFunction, /transition_supply_request|decide_supply_request/);
  assert.match(editFunction, /FROM public\.supply_request_commitments commitment/);
  assert.doesNotMatch(phase6cCode, /ordered_at|received_at/);
});

test("the server function delegates the edit to the RPC with the shared line payload", () => {
  const update = between(server, "export const updateSubmittedSupplyRequestFn", "export const listMyRequestsFn");
  assert.match(update, /updateSubmittedSupplyRequestInputSchema\.parse/);
  assert.match(update, /requireMembership\(context, data\.organizationId\)/);
  assert.match(update, /rpc\("update_submitted_supply_request"/);
  assert.match(update, /_request_id: data\.requestId/);
  assert.match(update, /_items: toRequestLinePayload\(data\.items\)/);
  assert.doesNotMatch(update, /submit_supply_request|\.delete\(|\.insert\(|\.from\("supply_request/);
  const submit = between(server, "export const submitSupplyRequestFn", "export const updateSubmittedSupplyRequestFn");
  assert.match(submit, /_items: toRequestLinePayload\(data\.items\)/);
});

test("staff detail exposes edit eligibility and the edit event without admin-only data", () => {
  const detail = between(server, "export const getStaffRequestDetailFn", "export const listOrgRequestsFn");
  assert.match(detail, /canEdit: canRequesterEditSupplyRequest\(lifecycleStatus\)/);
  assert.match(detail, /editGuidance: requesterEditGuidance\(lifecycleStatus\)/);
  assert.match(detail, /eq\("requested_by", context\.userId\)/);
  assert.match(detail, /update\.event_kind === "requester_edited"/);
  assert.match(detail, /You edited this request/);
  assert.doesNotMatch(detail, /internal_note|internalNote|invoice|purchase/);

  assert.match(staffDetail, /request\.data\.canEdit \?/);
  assert.match(staffDetail, /to="\/staff\/request" search=\{\{ edit: request\.data\.id \}\}/);
  assert.match(staffDetail, /Edit request/);
  assert.match(staffDetail, /request\.data\.editGuidance/);
});

test("composer edit mode preloads the request and saves instead of submitting", () => {
  assert.match(composer, /edit: z\.string\(\)\.uuid\(\)\.optional\(\)/);
  assert.match(composer, /<RequestPage key=\{edit \?\? "new"\} \/>/);
  assert.match(composer, /setItems\(editingRequest\.items\.map\(cartItemFromRequestItem\)\)/);
  assert.match(composer, /setNotes\(editingRequest\.notes \?\? ""\)/);
  assert.match(composer, /setTeamId\(editingRequest\.teamId \?\? ""\)/);
  assert.match(composer, /setLocationId\(editingRequest\.locationId \?\? ""\)/);
  assert.match(composer, /"Save changes"/);
  const save = between(composer, "async function saveChanges()", "if (submittedRequestId)");
  assert.match(save, /updateFn\(/);
  assert.match(save, /requestId: editingRequest\.id/);
  assert.doesNotMatch(save, /submitFn/);
  assert.match(composer, /editingRequest && !editingRequest\.canEdit/);
});

test("initial submission requires confirmation and Enter cannot submit accidentally", () => {
  const submit = between(composer, "function submit(event: React.FormEvent)", "async function confirmSubmit()");
  assert.doesNotMatch(submit, /submitFn|updateFn\(/);
  assert.match(submit, /else setConfirmingSubmit\(true\)/);
  const confirm = between(composer, "async function confirmSubmit()", "async function saveChanges()");
  assert.match(confirm, /submitFn\(/);
  assert.match(composer, /<AlertDialog open=\{confirmingSubmit\}/);
  assert.match(composer, /Keep editing/);
  assert.match(composer, />\s*Submit request\s*</);
  assert.match(composer, /describeSubmission\(items/);
  assert.match(composer, /if \(event\.key === "Enter"\) event\.preventDefault\(\);/);
  assert.match(composer, /if \(event\.key !== "Enter"\) return;\s+event\.preventDefault\(\);\s+addItem\(\);/);
});

test("successful submission explains the edit-until-review rule and links to the request", () => {
  assert.match(composer, /Request Submitted/);
  assert.match(composer, /You can still edit this request until review begins\./);
  assert.match(composer, /to="\/staff\/requests\/\$id"\s+params=\{\{ id: submittedRequestId \}\}/);
  assert.match(composer, /View request/);
});

test("admin history labels requester edits", () => {
  assert.match(adminDetail, /update\.eventKind === "requester_edited" \? "Requester edited request"/);
});

test("SQL behavioral coverage is rollback-only and covers the race and status locks", () => {
  assert.match(behavior, /^-- Phase 6C rollback-only behavioral verification\./);
  assert.match(behavior, /\nBEGIN;\n/);
  assert.match(behavior, /\nROLLBACK;\n$/);
  assert.doesNotMatch(behavior, /\bCOMMIT\b/);
  for (const status of ["under_review", "approved", "ordered", "received", "completed", "denied"]) {
    assert.ok(behavior.includes(`'${status}'`), status);
  }
  assert.match(behavior, /A stale save overwrote the reviewed request/);
  assert.match(behavior, /A requester edit created a commitment/);
});

const STALE_MESSAGE =
  "This request changed while you were reviewing it. Refresh the request and review the latest details before making a decision.";

test("admin decisions require the reviewed request version", () => {
  const base = {
    organizationId,
    id: requestId,
    decision: "approved" as const,
    expectedUpdatedAt: "2026-10-09T17:32:03.560832+00:00",
  };
  assert.equal(adminRequestDecisionSchema.safeParse(base).success, true);
  assert.equal(
    adminRequestDecisionSchema.safeParse({ ...base, expectedUpdatedAt: "2026-10-09T17:32:03+00:00" }).success,
    true,
  );
  const { expectedUpdatedAt: _omitted, ...withoutVersion } = base;
  assert.equal(adminRequestDecisionSchema.safeParse(withoutVersion).success, false);
  for (const expectedUpdatedAt of ["", "yesterday", null]) {
    assert.equal(adminRequestDecisionSchema.safeParse({ ...base, expectedUpdatedAt }).success, false);
  }
  assert.equal(
    adminRequestDecisionSchema.parse({ ...base, decision: "denied", staffVisibleNote: "In storage" }).expectedUpdatedAt,
    base.expectedUpdatedAt,
  );
});

test("the decision RPC compares the version under the row lock before any write", () => {
  assert.match(
    migration,
    /DROP FUNCTION public\.decide_supply_request\(\s*uuid, uuid, public\.supply_request_status, text, text\s*\);/,
  );
  assert.match(decideFunction, /_internal_note text DEFAULT NULL,\s+_expected_updated_at timestamptz DEFAULT NULL\s+\)/);
  assert.match(decideFunction, /IF NOT public\.is_org_admin\(_organization_id, auth\.uid\(\)\)/);
  assert.match(decideFunction, /WHERE id = _request_id AND organization_id = _organization_id\s+FOR UPDATE;/);
  assert.match(
    decideFunction,
    /IF _expected_updated_at IS NULL OR _request\.updated_at IS DISTINCT FROM _expected_updated_at THEN/,
  );
  assert.ok(decideFunction.includes(`'${STALE_MESSAGE}'`));
  assert.match(decideFunction, /USING ERRCODE = '40001'/);

  const order = [
    "is_org_admin",
    "FOR UPDATE",
    "IF _request.status = _decision THEN",
    "IF _request.status NOT IN ('submitted', 'under_review') THEN",
    "_request.updated_at IS DISTINCT FROM _expected_updated_at",
    "PERFORM public.apply_supply_request_transition",
    "_result := public.apply_supply_request_transition(",
  ].map((marker) => {
    const position = decideFunction.indexOf(marker);
    assert.ok(position >= 0, marker);
    return position;
  });
  assert.deepEqual(order, [...order].sort((a, b) => a - b), "guard order changed");

  // Commitment creation stays inside the private transition body, after the guard.
  assert.doesNotMatch(decideFunction, /create_supply_request_commitment|INSERT INTO/);
  assert.match(
    migration,
    /GRANT EXECUTE ON FUNCTION public\.decide_supply_request\(\s*uuid, uuid, public\.supply_request_status, text, text, timestamptz\s*\) TO authenticated;/,
  );
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.decide_supply_request\(\s*uuid, uuid, public\.supply_request_status, text, text, timestamptz\s*\) FROM PUBLIC, anon;/,
  );
});

test("the admin decision sends the version the screen rendered and refreshes on rejection", () => {
  const decide = between(server, "export const decideSupplyRequestFn", "export const getSupplyRequestBudgetImpactFn");
  assert.match(decide, /_expected_updated_at: data\.expectedUpdatedAt/);
  assert.match(decide, /requireAdmin\(context, data\.organizationId\)/);
  assert.match(decide, /if \(error\) throw new Error\(error\.message\)/);

  const transition = between(adminRoute, "async function transition(", "async function release(");
  assert.match(transition, /decide\(\{ data: \{ \.\.\.data, decision: status, expectedUpdatedAt: selected\.updatedAt \} \}\)/);
  const failure = between(transition, "} catch (error) {", "} finally {");
  assert.match(failure, /setMutationError\(error instanceof Error \? error\.message/);
  assert.match(failure, /invalidateQueries\(\{ queryKey: \["org", organizationId, "requests"\] \}\)/);
  // A rejected decision never retries or re-submits by itself.
  assert.doesNotMatch(failure, /decide\(|updateStatus\(/);

  const dashboard = between(server, "export const getAdminSupplyRequestDashboardFn", "export const decideSupplyRequestFn");
  assert.match(dashboard, /updatedAt: row\.updated_at/);
  assert.match(types, /_internal_note\?: string\n\s+_expected_updated_at\?: string\n/);
});

test("SQL behavioral coverage exercises stale approve/decline and reload", () => {
  for (const marker of [
    "A stale decision created a commitment",
    "A stale decision wrote an approval or decline audit event",
    "Requester edit did not advance the request version",
    "Commitment did not snapshot the latest reviewed lines exactly once",
    "Stale-version retry was not idempotent",
    "Matching-version decline is incorrect",
    "Under-review approval after reload is incorrect",
    "Version text round trip lost precision",
  ]) {
    assert.ok(behavior.includes(marker), marker);
  }
  assert.ok(behavior.includes("current_setting('phase6c.v914_loaded')"), "cross-request version check");
});

const transitionWrapper = between(
  migration,
  "CREATE OR REPLACE FUNCTION public.transition_supply_request",
  "REVOKE ALL ON FUNCTION public.transition_supply_request",
);
const privateTransition = between(
  migration,
  "CREATE FUNCTION public.apply_supply_request_transition",
  "REVOKE ALL ON FUNCTION public.apply_supply_request_transition",
);

test("the private transition body is the unchanged Phase 6A.2 lifecycle body", () => {
  const phase6a2 = read("../supabase/migrations/20260914120000_phase6a2_request_commitments.sql");
  const original = between(
    phase6a2,
    "CREATE OR REPLACE FUNCTION public.transition_supply_request",
    "REVOKE ALL ON FUNCTION public.transition_supply_request",
  );
  const strip = (definition: string) => definition.slice(definition.indexOf("(")).trim();
  assert.equal(strip(privateTransition), strip(original));
  assert.match(privateTransition, /PERFORM public\.create_supply_request_commitment\(/);
  assert.match(privateTransition, /PERFORM public\.release_supply_request_commitment\(/);
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.apply_supply_request_transition\(\s*uuid, uuid, public\.supply_request_status, text, text\s*\) FROM PUBLIC, anon, authenticated;/,
  );
  assert.doesNotMatch(migration, /GRANT EXECUTE ON FUNCTION public\.apply_supply_request_transition/);
});

test("transition_supply_request refuses pending approve/deny and delegates everything else", () => {
  assert.match(transitionWrapper, /SECURITY DEFINER\s+SET search_path = public/);
  const guard = transitionWrapper.indexOf(
    "IF _request.status IN ('submitted', 'under_review') AND _status IN ('approved', 'denied') THEN",
  );
  const lock = transitionWrapper.indexOf("FOR UPDATE");
  const auth = transitionWrapper.indexOf("public.has_org_role(");
  const delegate = transitionWrapper.indexOf("RETURN public.apply_supply_request_transition(");
  assert.ok(auth >= 0 && auth < lock && lock < guard && guard < delegate, "auth, lock, guard, delegate order");
  assert.match(transitionWrapper, /'Approve or decline this request through the request decision workflow\.'\s+USING ERRCODE = '42501'/);
  assert.doesNotMatch(transitionWrapper, /UPDATE public\.supply_requests|INSERT INTO|commitment/);
  assert.match(
    migration,
    /GRANT EXECUTE ON FUNCTION public\.transition_supply_request\(\s*uuid, uuid, public\.supply_request_status, text, text\s*\) TO authenticated;/,
  );
  // decide_supply_request no longer calls the public wrapper.
  assert.doesNotMatch(decideFunction, /public\.transition_supply_request\(/);
});

test("direct table writes cannot set or change a request's status", () => {
  const guard = between(migration, "CREATE FUNCTION public.guard_supply_request_lifecycle", "REVOKE ALL ON FUNCTION public.guard_supply_request_lifecycle");
  assert.doesNotMatch(guard, /SECURITY DEFINER/);
  assert.match(guard, /IF current_user IN \('authenticated', 'anon'\) THEN/);
  assert.match(guard, /TG_OP = 'INSERT' AND NEW\.status IS DISTINCT FROM 'submitted'/);
  assert.match(guard, /TG_OP = 'UPDATE' AND NEW\.status IS DISTINCT FROM OLD\.status/);
  assert.match(
    migration,
    /CREATE TRIGGER supply_requests_lifecycle_guard\s+BEFORE INSERT OR UPDATE OF status ON public\.supply_requests/,
  );
});

test("the admin UI routes pending approve/decline only to the decision RPC", () => {
  const transition = between(adminRoute, "async function transition(", "async function release(");
  assert.match(
    transition,
    /const pending = selected\.lifecycleStatus === "submitted" \|\| selected\.lifecycleStatus === "under_review";\s+if \(pending && \(status === "approved" \|\| status === "denied"\)\) \{/,
  );
});

test("SQL behavioral coverage proves decide_supply_request is the exclusive decision path", () => {
  for (const marker of [
    "Private transition helper was executable by an admin client",
    "Admin direct status update succeeded",
    "Staff inserted an already-approved request",
    "Canonical approval from under_review failed",
    "Canonical decline from submitted failed",
    "approved -> ordered -> received -> completed regressed",
    "Denial after approval no longer releases its commitment",
    "Invalid supply request transition: approved to received",
    "Invalid supply request transition: denied to approved",
  ]) {
    assert.ok(behavior.includes(marker), marker);
  }
  assert.equal(
    behavior.match(/'Approve or decline this request through the request decision workflow\.', '42501'\)/g)?.length,
    4,
  );
});
