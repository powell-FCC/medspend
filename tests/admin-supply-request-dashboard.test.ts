import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  buildAdminRequestDashboard,
  requestAgeInDays,
  translateAdminRequestStatus,
  type AdminSupplyRequestViewModel,
} from "../src/supply-requests/admin-dashboard.ts";
import type { SupplyRequestStatus } from "../src/supply-requests/lifecycle.ts";

test("admin lifecycle states translate into operational queues and next actions", () => {
  const expected = {
    submitted: ["NEEDS_REVIEW", "Review Request"],
    under_review: ["NEEDS_REVIEW", "Approve or Decline"],
    approved: ["AWAITING_ORDER", "Mark Ordered"],
    ordered: ["AWAITING_DELIVERY", "Mark Received"],
    received: ["READY_FOR_STAFF", "Complete Request"],
    completed: ["COMPLETED", null],
    denied: ["COMPLETED", null],
  } as const;
  for (const [status, result] of Object.entries(expected)) {
    const translated = translateAdminRequestStatus(status as SupplyRequestStatus);
    assert.deepEqual([translated.queueGroup, translated.nextAction], result);
  }
  assert.equal(translateAdminRequestStatus("denied").statusLabel, "Denied");
});

function request(status: SupplyRequestStatus): AdminSupplyRequestViewModel {
  const translated = translateAdminRequestStatus(status);
  return {
    id: status, itemName: "Athletic Tape", quantity: 2, unit: "box",
    requesterName: "Staff Member", team: "Medical", location: "Training Room",
    requestTypeLabel: "Supply Request", ...translated, lifecycleStatus: status,
    submittedAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-01T00:00:00Z",
    ageInDays: 1, staffNote: null, latestStaffMessage: null, latestInternalNote: null,
    latestUpdateAt: "2026-08-01T00:00:00Z", hasExistingProduct: true, isNewItem: false,
  };
}

test("summary counts are centralized and completed or denied requests are excluded from active queues", () => {
  const dashboard = buildAdminRequestDashboard([
    request("submitted"), request("under_review"), request("approved"), request("ordered"),
    request("received"), request("completed"), request("denied"),
  ]);
  assert.deepEqual(dashboard.summary, {
    needsReview: 2, awaitingOrder: 1, awaitingDelivery: 1, readyForStaff: 1, completed: 2,
  });
  assert.equal(dashboard.queues.completed.length, 2);
  for (const queue of [dashboard.queues.needsReview, dashboard.queues.awaitingOrder,
    dashboard.queues.awaitingDelivery, dashboard.queues.readyForStaff]) {
    assert.equal(queue.some((item) => ["completed", "denied"].includes(item.lifecycleStatus)), false);
  }
});

test("admin dashboard function is role-protected, organization-scoped, and includes separated communications", async () => {
  const server = await readFile(new URL("../src/lib/supply-requests.functions.ts", import.meta.url), "utf8");
  const dashboard = server.slice(
    server.indexOf("export const getAdminSupplyRequestDashboardFn"),
    server.indexOf("export const updateRequestStatusFn"),
  );
  assert.match(dashboard, /requireAdmin\(context, data\.organizationId\)/);
  assert.match(dashboard, /eq\("organization_id", data\.organizationId\)/);
  assert.match(dashboard, /internal_note,staff_visible_note/);
  assert.match(dashboard, /latestStaffMessage/);
  assert.match(dashboard, /latestInternalNote/);
});

test("staff-facing functions remain unable to select or return internal notes", async () => {
  const server = await readFile(new URL("../src/lib/supply-requests.functions.ts", import.meta.url), "utf8");
  const staff = server.slice(server.indexOf("export const getStaffDashboardFn"), server.indexOf("export const listOrgRequestsFn"));
  assert.doesNotMatch(staff, /internal_note|latestInternalNote/);
  assert.match(staff, /eq\("requested_by", context\.userId\)/);
});

test("request age uses completed calendar-day intervals and never becomes negative", () => {
  assert.equal(requestAgeInDays("2026-08-10T12:00:00Z", new Date("2026-08-10T20:00:00Z")), 0);
  assert.equal(requestAgeInDays("2026-08-10T12:00:00Z", new Date("2026-08-12T12:00:00Z")), 2);
  assert.equal(requestAgeInDays("2026-08-13T12:00:00Z", new Date("2026-08-12T12:00:00Z")), 0);
});
