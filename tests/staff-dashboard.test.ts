import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  summarizeStaffRequests,
  translateStaffRequestStatus,
  type StaffRequestViewModel,
} from "../src/supply-requests/staff-dashboard.ts";
import type { SupplyRequestStatus } from "../src/supply-requests/lifecycle.ts";

test("staff lifecycle values have friendly labels and groups", () => {
  const expected = {
    submitted: ["Submitted", "ACTIVE"],
    under_review: ["Reviewing", "ACTIVE"],
    approved: ["Approved", "ACTIVE"],
    ordered: ["Ordered", "ACTIVE"],
    received: ["Ready", "READY"],
    completed: ["Completed", "COMPLETED"],
    denied: ["Not Approved", "ACTION_REQUIRED"],
  } as const;
  for (const [status, translated] of Object.entries(expected)) {
    const result = translateStaffRequestStatus(status as SupplyRequestStatus);
    assert.deepEqual([result.label, result.group], translated);
    assert.equal(result.label.includes("_"), false);
  }
});

test("summary counts active, ready, and completed without counting completed as active", () => {
  const request = (statusGroup: StaffRequestViewModel["statusGroup"]): StaffRequestViewModel => ({
    id: crypto.randomUUID(), itemName: "Tape", quantity: 1, unit: "roll",
    statusLabel: "Status", statusGroup, submittedAt: "2026-01-01T00:00:00Z",
    lastUpdatedAt: "2026-01-01T00:00:00Z", staffMessage: null,
  });
  assert.deepEqual(
    summarizeStaffRequests([
      request("ACTIVE"), request("ACTIVE"), request("READY"), request("COMPLETED"),
      request("ACTION_REQUIRED"),
    ]),
    { activeRequests: 2, readyRequests: 1, completedRequests: 1 },
  );
});

test("dashboard query is user-owned, organization-scoped, and exposes only staff-safe updates", async () => {
  const server = await readFile(new URL("../src/lib/supply-requests.functions.ts", import.meta.url), "utf8");
  const dashboard = server.slice(
    server.indexOf("export const getStaffDashboardFn"),
    server.indexOf("export const listOrgRequestsFn"),
  );
  assert.match(dashboard, /requireMembership\(context, data\.organizationId\)/);
  assert.match(dashboard, /eq\("organization_id", data\.organizationId\)/);
  assert.match(dashboard, /eq\("requested_by", context\.userId\)/);
  assert.match(dashboard, /staff_visible_note/);
  assert.match(dashboard, /staffMessage: message\?\.message \?\? null/);
  assert.doesNotMatch(dashboard, /internal_note|internalNote|vendor|invoice|purchase/);
});

test("both staff routes consume the shared dashboard model and request card", async () => {
  for (const path of [
    "../src/routes/_authenticated/staff/index.tsx",
    "../src/routes/_authenticated/staff/requests.tsx",
  ]) {
    const route = await readFile(new URL(path, import.meta.url), "utf8");
    assert.match(route, /getStaffDashboardFn/);
    assert.match(route, /RequestSummaryCard/);
    assert.doesNotMatch(route, /listMyRequestsFn/);
  }
});

test("staff request history renders its nested detail route instead of the list", async () => {
  const route = await readFile(new URL("../src/routes/_authenticated/staff/requests.tsx", import.meta.url), "utf8");
  assert.match(route, /import \{[^}]*Outlet[^}]*useMatch[^}]*\} from "@tanstack\/react-router"/);
  assert.match(route, /component: StaffRequests/);
  assert.match(route, /function StaffRequests\(\) \{\s*const detailMatch = useMatch\(\{\s*from: "\/_authenticated\/staff\/requests\/\$id",\s*shouldThrow: false,?\s*\}\);\s*return detailMatch \? <Outlet \/> : <MyRequests \/>;/);
});

test("staff request detail enforces ownership and organization boundaries without selecting internal notes", async () => {
  const server = await readFile(new URL("../src/lib/supply-requests.functions.ts", import.meta.url), "utf8");
  const detail = server.slice(
    server.indexOf("export const getStaffRequestDetailFn"),
    server.indexOf("export const listOrgRequestsFn"),
  );
  assert.match(detail, /requireMembership\(context, data\.organizationId\)/);
  assert.match(detail, /eq\("id", data\.requestId\)/);
  assert.match(detail, /eq\("organization_id", data\.organizationId\)/);
  assert.match(detail, /eq\("requested_by", context\.userId\)/);
  assert.match(detail, /select\("status_to,staff_visible_note,created_at"\)/);
  assert.doesNotMatch(detail, /internal_note|internalNote|vendor|invoice|purchase/);
});

test("mobile request flow keeps request categories out of the visible interface", async () => {
  const route = await readFile(new URL("../src/routes/_authenticated/staff/request.tsx", import.meta.url), "utf8");
  assert.match(route, /What do you need\?/);
  assert.match(route, /Search supplies/);
  assert.match(route, /Request Submitted/);
  assert.doesNotMatch(route, />Type</);
  assert.doesNotMatch(route, /Report low stock|Report out of stock/);
});
