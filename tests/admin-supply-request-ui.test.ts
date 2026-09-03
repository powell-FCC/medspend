import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("admin supply request route renders the operational queue instead of a table", async () => {
  const route = await readFile(new URL("../src/routes/_authenticated/supply-requests.tsx", import.meta.url), "utf8");
  assert.match(route, /AdminQueueTabs/);
  assert.match(route, /AdminRequestCard/);
  assert.match(route, /AdminRequestDetail/);
  assert.match(route, /getAdminSupplyRequestDashboardFn/);
  assert.doesNotMatch(route, /<table|<thead|<tbody/);
});

test("detail workflow sends staff and internal communication through distinct fields", async () => {
  const route = await readFile(new URL("../src/routes/_authenticated/supply-requests.tsx", import.meta.url), "utf8");
  const detail = await readFile(new URL("../src/components/admin/supply-requests/AdminRequestDetail.tsx", import.meta.url), "utf8");
  const messages = await readFile(new URL("../src/components/admin/supply-requests/AdminMessagePanel.tsx", import.meta.url), "utf8");
  assert.match(route, /staffVisibleNote: staffMessage\.trim\(\) \|\| null/);
  assert.match(route, /internalNote: internalNote\.trim\(\) \|\| null/);
  assert.match(messages, /Message to Staff/);
  assert.match(messages, /Visible to requester/);
  assert.match(messages, /Internal Admin Note/);
  assert.match(messages, /Admins only — never visible to staff/);
  assert.match(detail, /primaryTransition/);
  assert.match(route, /decideSupplyRequestFn/);
});

test("contextual actions preserve the enforced lifecycle order", async () => {
  const detail = await readFile(new URL("../src/components/admin/supply-requests/AdminRequestDetail.tsx", import.meta.url), "utf8");
  for (const transition of [
    'submitted: "approved"', 'under_review: "approved"', 'approved: "ordered"',
    'ordered: "received"', 'received: "completed"',
  ]) assert.match(detail, new RegExp(transition.replace(/["_]/g, (value) => `\\${value}`)));
  assert.doesNotMatch(detail, /submitted: "completed"|approved: "received"/);
  const sql = await readFile(new URL("../supabase/migrations/20260903140000_phase5a9_admin_request_decisions.sql", import.meta.url), "utf8");
  assert.match(sql, /transition_supply_request\(_organization_id, _request_id, 'under_review'\)/);
});

test("denial requires a requester-visible explanation and communication has stage guidance", async () => {
  const detail = await readFile(new URL("../src/components/admin/supply-requests/AdminRequestDetail.tsx", import.meta.url), "utf8");
  const panel = await readFile(new URL("../src/components/admin/supply-requests/AdminMessagePanel.tsx", import.meta.url), "utf8");
  assert.match(detail, /declining && !staffMessage.trim\(\)/);
  assert.match(detail, /Add a short reason so staff understand the decision/);
  assert.match(panel, /Reason for decline \(required\)/);
  assert.match(panel, /Visible to requester/);
  assert.match(panel, /Admins only — never visible to staff/);
});

test("admin dashboard consumes the shared queue summary without duplicate lifecycle calculations", async () => {
  const dashboard = await readFile(new URL("../src/routes/_authenticated/dashboard.tsx", import.meta.url), "utf8");
  assert.match(dashboard, /getAdminSupplyRequestDashboardFn/);
  for (const count of ["needsReview", "awaitingOrder", "awaitingDelivery", "readyForStaff", "completed"]) assert.match(dashboard, new RegExp(`summary\\?\\.${count}`));
  assert.doesNotMatch(dashboard, /\.filter\(|submitted|under_review|approved|ordered|received/);
});

test("admin timeline clearly separates staff communication from internal notes", async () => {
  const detail = await readFile(new URL("../src/components/admin/supply-requests/AdminRequestDetail.tsx", import.meta.url), "utf8");
  assert.match(detail, /Staff Communication/);
  assert.match(detail, /Internal Note · Admins only/);
  assert.match(detail, /translateAdminRequestStatus\(update\.statusTo\)\.statusLabel/);
});
