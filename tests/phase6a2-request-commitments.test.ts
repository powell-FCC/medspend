import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  pricingDescription,
  releaseCommitmentSchema,
  type RequestBudgetImpact,
} from "../src/supply-requests/commitments.ts";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const migration = read("../supabase/migrations/20260914120000_phase6a2_request_commitments.sql");
const server = read("../src/lib/supply-requests.functions.ts");
const route = read("../src/routes/_authenticated/supply-requests.tsx");
const detail = read("../src/components/admin/supply-requests/AdminRequestDetail.tsx");
const budgetOverview = read("../src/components/budget/BudgetOverview.tsx");
const staffShell = read("../src/components/app/StaffAppShell.tsx");
const id = "11111111-1111-4111-8111-111111111111";

test("6A.2 is one additive migration with parent and item-level snapshots", () => {
  assert.match(migration, /CREATE TABLE public\.supply_request_commitments/);
  assert.match(migration, /CREATE TABLE public\.supply_request_commitment_items/);
  assert.match(migration, /supply_request_id uuid NOT NULL UNIQUE/);
  assert.match(migration, /supply_request_item_id uuid NOT NULL UNIQUE/);
  assert.doesNotMatch(
    migration,
    /DROP (?:TABLE|COLUMN)|ALTER TABLE public\.(?:supply_requests|supply_request_items) DROP/,
  );
});

test("approval snapshots all lines atomically while the organization request is locked", () => {
  const create = migration.slice(
    migration.indexOf("CREATE FUNCTION public.create_supply_request_commitment"),
    migration.indexOf("CREATE FUNCTION public.supply_request_commitment_parent_immutable"),
  );
  assert.match(
    create,
    /WHERE id = _request_id AND organization_id = _organization_id\s+FOR UPDATE/,
  );
  assert.match(create, /WITH estimates AS MATERIALIZED/);
  assert.match(create, /INSERT INTO public\.supply_request_commitments/);
  assert.match(create, /INSERT INTO public\.supply_request_commitment_items/);
  assert.match(create, /quantity_snapshot/);
});

test("approval and lifecycle retries cannot create duplicate commitments", () => {
  assert.match(migration, /supply_request_id uuid NOT NULL UNIQUE/);
  assert.match(migration, /ON CONFLICT \(supply_request_id\) DO NOTHING/);
  assert.match(migration, /IF _request\.status = _decision THEN[\s\S]*alreadyDecided/);
});

test("committed amounts cannot follow later catalog, vendor, inventory, or product changes", () => {
  assert.match(migration, /Committed financial snapshots are immutable/);
  assert.match(migration, /Committed item snapshots are immutable/);
  assert.match(migration, /BEFORE UPDATE OR DELETE ON public\.supply_request_commitment_items/);
  const budget = migration.slice(migration.indexOf("CREATE FUNCTION public.get_budget_summary"));
  assert.match(budget, /SUM\(commitment\.amount\)/);
  assert.doesNotMatch(budget, /source_catalog_price|last_purchase_price|inventory_price_history/);
});

test("cost resolution uses the explicit authority order and accepts only USD catalog prices", () => {
  const resolver = migration.slice(
    migration.indexOf("CREATE FUNCTION public.resolve_supply_request_item_costs"),
    migration.indexOf("CREATE FUNCTION public.create_supply_request_commitment"),
  );
  const sources = [
    "vendor_purchase_history",
    "inventory_last_purchase",
    "product_purchase_history",
    "catalog_source_price",
  ];
  let previous = -1;
  for (const source of sources) {
    const position = resolver.indexOf(source);
    assert.ok(position > previous, source);
    previous = position;
  }
  assert.match(resolver, /catalog\.currency_code = 'USD'/);
  assert.match(resolver, /COALESCE\(price\.price_source, 'unpriced'\)/);
});

test("unpriced and partially priced requests are explicit and never fabricate line values", () => {
  assert.match(migration, /pricing_status IN \('fully_priced', 'partially_priced', 'unpriced'\)/);
  assert.match(migration, /price_source = 'unpriced' AND unit_cost_snapshot IS NULL/);
  assert.match(migration, /COUNT\(unit_cost\)::integer AS priced_item_count/);
  assert.match(migration, /COALESCE\(SUM\(line_amount\), 0\)/);
  const partial = {
    pricingStatus: "partially_priced",
    pricedItemCount: 1,
    totalItemCount: 2,
  } as RequestBudgetImpact;
  assert.match(pricingDescription(partial), /1 of 2 requested items are priced/);
  assert.match(
    pricingDescription({ ...partial, pricingStatus: "unpriced" }),
    /No reliable USD price/,
  );
});

test("approved and ordered requests stay committed", () => {
  const transition = migration.slice(
    migration.indexOf("CREATE OR REPLACE FUNCTION public.transition_supply_request"),
    migration.indexOf("CREATE OR REPLACE FUNCTION public.decide_supply_request"),
  );
  assert.match(transition, /IF _status = 'approved' THEN[\s\S]*create_supply_request_commitment/);
  assert.equal((transition.match(/release_supply_request_commitment/g) ?? []).length, 1);
  assert.match(transition, /ELSIF _status = 'denied'[\s\S]*release_supply_request_commitment/);
});

test("received and completed deliberately do not infer invoice settlement", () => {
  assert.match(migration, /Received\/completed intentionally do not[\s\S]*release commitments/);
  const transition = migration.slice(
    migration.indexOf("CREATE OR REPLACE FUNCTION public.transition_supply_request"),
    migration.indexOf("CREATE OR REPLACE FUNCTION public.decide_supply_request"),
  );
  assert.equal((transition.match(/release_supply_request_commitment/g) ?? []).length, 1);
  assert.match(transition, /ELSIF _status = 'denied'/);
});

test("denial safely releases a prior active commitment with an audit reason", () => {
  assert.match(migration, /ELSIF _status = 'denied' AND EXISTS/);
  assert.match(migration, /'denied', 'Request denied through request lifecycle'/);
  assert.match(
    migration,
    /released_at = now\(\)[\s\S]*released_by = auth\.uid\(\)[\s\S]*release_reason = btrim/,
  );
});

test("manual release is admin-only, reasoned, one-way, and retry-safe", () => {
  const release = migration.slice(
    migration.indexOf("CREATE FUNCTION public.release_supply_request_commitment"),
    migration.indexOf("CREATE OR REPLACE FUNCTION public.transition_supply_request"),
  );
  assert.match(release, /is_org_admin\(_organization_id, auth\.uid\(\)\)/);
  assert.match(release, /FOR UPDATE/);
  assert.match(release, /IF _commitment\.status = 'released'[\s\S]*alreadyReleased/);
  assert.match(migration, /Released commitments are immutable/);
  assert.equal(
    releaseCommitmentSchema.safeParse({
      organizationId: id,
      requestId: id,
      releaseKind: "settled",
      releaseReason: "Invoice posted",
    }).success,
    true,
  );
  assert.equal(
    releaseCommitmentSchema.safeParse({
      organizationId: id,
      requestId: id,
      releaseKind: "settled",
      releaseReason: "  ",
    }).success,
    false,
  );
});

test("budget math preserves actual spend and subtracts active known commitments", () => {
  const budget = migration.slice(
    migration.indexOf("CREATE FUNCTION public.get_budget_summary"),
    migration.indexOf("CREATE FUNCTION public.get_supply_request_budget_impact"),
  );
  assert.match(budget, /invoice\.posted_at IS NOT NULL/);
  assert.match(budget, /commitment\.status = 'active'/);
  assert.match(budget, /totals\.amount - totals\.actual_spend - totals\.committed_spend/);
  assert.match(budget, /totals\.amount - totals\.actual_spend\)::numeric/);
});

test("approval impact returns all required current and projected budget values", () => {
  const impact = migration.slice(
    migration.indexOf("CREATE FUNCTION public.get_supply_request_budget_impact"),
  );
  for (const field of [
    "estimated_amount",
    "actual_spend",
    "committed_spend",
    "available_amount",
    "projected_available_after_approval",
  ])
    assert.match(impact, new RegExp(field));
  assert.match(impact, /cost\.lifecycle_status IN \('submitted', 'under_review'\)/);
  assert.match(impact, /cost\.pricing_status = 'unpriced' THEN NULL/);
});

test("database and server boundaries enforce organization isolation", () => {
  assert.match(
    migration,
    /supply_request_commitments_admin_select[\s\S]*is_org_admin\(organization_id, auth\.uid\(\)\)/,
  );
  assert.match(
    migration,
    /WHERE request\.id = _request_id AND request\.organization_id = _organization_id/,
  );
  assert.match(
    server,
    /getSupplyRequestBudgetImpactFn[\s\S]*requireAdmin\(context, data\.organizationId\)[\s\S]*_organization_id: data\.organizationId/,
  );
  assert.match(
    server,
    /releaseSupplyRequestCommitmentFn[\s\S]*requireAdmin\(context, data\.organizationId\)/,
  );
});

test("legacy committed requests are backfilled as unknown rather than repriced from mutable data", () => {
  const backfill = migration.slice(
    migration.indexOf("Historical prices at approval"),
    migration.indexOf("DROP FUNCTION public.get_budget_summary"),
  );
  assert.match(backfill, /request\.status IN \('approved', 'ordered', 'received', 'completed'\)/);
  assert.match(backfill, /'unpriced'/);
  assert.match(backfill, /Historical request was denied after approval/);
  assert.doesNotMatch(backfill, /source_catalog_price|last_purchase_price|inventory_price_history/);
});

test("no request-to-invoice heuristic or purchasing workflow is introduced", () => {
  const lower = migration.toLowerCase();
  assert.doesNotMatch(
    lower,
    /request.*(?:vendor|sku|name|price).*invoice|invoice.*(?:vendor|sku|name|price).*request/,
  );
  assert.doesNotMatch(
    migration,
    /CREATE TABLE public\.(?:purchase_orders|orders)|INSERT INTO public\.invoices/,
  );
});

test("admin detail shows dense budget context and an explicit release workflow", () => {
  for (const label of [
    "Estimated request cost",
    "Actual spend",
    "Committed spend",
    "Available budget",
    "Available after approval",
  ])
    assert.match(detail, new RegExp(label));
  assert.match(detail, /Release Commitment/);
  assert.match(detail, /SportSpend does not match invoices to requests automatically/);
  assert.match(route, /getSupplyRequestBudgetImpactFn/);
  assert.match(route, /releaseSupplyRequestCommitmentFn/);
});

test("staff request UX remains free of commitment accounting", () => {
  assert.doesNotMatch(staffShell, /commitment|budget impact|available after approval/i);
  for (const file of [
    "../src/routes/_authenticated/staff/request.tsx",
    "../src/routes/_authenticated/staff/requests.tsx",
    "../src/routes/_authenticated/staff/requests.$id.tsx",
  ]) {
    assert.doesNotMatch(
      read(file),
      /getSupplyRequestBudgetImpactFn|releaseSupplyRequestCommitmentFn|Committed spend/,
    );
  }
});

test("the budget view extends 6A.1 with four metrics and incomplete-pricing disclosure", () => {
  for (const label of ["Budget", "Actual spend", "Committed spend", "Available budget"])
    assert.match(budgetOverview, new RegExp(label));
  assert.match(budgetOverview, /incomplete_commitment_count/);
  assert.match(budgetOverview, /subtracts known committed costs only/);
});

test("generated Supabase types expose the new tables and RPCs", () => {
  const types = read("../src/integrations/supabase/types.ts");
  for (const name of [
    "supply_request_commitments",
    "supply_request_commitment_items",
    "get_supply_request_budget_impact",
    "release_supply_request_commitment",
    "committed_spend",
    "available_amount",
  ])
    assert.match(types, new RegExp(name));
});

test("rollback-only database behavior covers the financial lifecycle and isolation matrix", () => {
  const behavior = read("../supabase/tests/phase6a2_request_commitments_behavior.sql");
  assert.match(behavior, /^-- Phase 6A\.2 rollback-only behavioral verification/);
  assert.match(behavior, /BEGIN;/);
  assert.match(behavior, /ROLLBACK;\s*$/);
  for (const marker of [
    "phase6a2_preview",
    "phase6a2_approval",
    "phase6a2_retry",
    "phase6a2_immutable",
    "phase6a2_completed_active",
    "phase6a2_release",
    "phase6a2_incomplete",
    "phase6a2_denial",
    "phase6a2_budget",
    "phase6a2_staff_isolation",
    "phase6a2_org_isolation",
  ]) {
    assert.match(behavior, new RegExp(marker));
  }
});
