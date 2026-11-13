import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/integrations/supabase/types";
import type {
  ReplenishmentCategory,
  ReplenishmentCountState,
  ReplenishmentCursor,
  ReplenishmentDonor,
  ReplenishmentInactiveReason,
  ReplenishmentPage,
  ReplenishmentRow,
  ReplenishmentRuleResult,
  ReplenishmentSummary,
  ReplenishmentView,
} from "@/types/inventory-replenishment";

// Phase 7D Replenishment reads and owner writes behind the server functions. Reads go through
// owner+admin SECURITY DEFINER functions; writes through owner-only functions. The database
// calculates everything (inventory_replenishment_rows); nothing here re-derives a quantity or
// a category.

type Db = SupabaseClient<Database>;
type JsonRow = Record<string, unknown>;

export const REPLENISHMENT_PAGE = 100;
export const LOCATION_RULE_PAGE = 500;

const num = (value: unknown) => (value === null || value === undefined ? 0 : Number(value));

function toDonors(value: unknown): ReplenishmentDonor[] {
  if (!Array.isArray(value)) return [];
  return value.map((donor: JsonRow) => ({
    locationId: String(donor.locationId),
    name: String(donor.name),
    kind: donor.kind === "unassigned" ? "unassigned" : "storage",
    spareQuantity: num(donor.spareQuantity),
    moveQuantity: num(donor.moveQuantity),
  }));
}

// Rows arrive with snake_case keys, from the table function or as jsonb.
export function toReplenishmentRow(row: JsonRow): ReplenishmentRow {
  return {
    ruleId: String(row.rule_id),
    inventoryItemId: String(row.inventory_item_id),
    itemName: String(row.item_name),
    itemUnit: String(row.item_unit),
    itemActive: Boolean(row.item_active),
    inventoryLocationId: String(row.inventory_location_id),
    locationName: String(row.location_name),
    locationActive: Boolean(row.location_active),
    minimumQuantity: num(row.minimum_quantity),
    targetQuantity: num(row.target_quantity),
    enabled: Boolean(row.enabled),
    updatedAt: String(row.updated_at),
    category: row.category as ReplenishmentCategory,
    inactiveReason: (row.inactive_reason as ReplenishmentInactiveReason | null) ?? null,
    currentQuantity: num(row.current_quantity),
    notStockedHere: Boolean(row.not_stocked_here),
    shortageQuantity: num(row.shortage_quantity),
    availableQuantity: num(row.available_quantity),
    moveQuantity: num(row.move_quantity),
    externalQuantity: num(row.external_quantity),
    organizationQuantity: num(row.organization_quantity),
    unassignedQuantity: num(row.unassigned_quantity),
    donors: toDonors(row.donors),
    otherShortLocationCount: num(row.other_short_location_count),
    lastCountedAt: (row.last_counted_at as string | null) ?? null,
    locationCountState: (row.location_count_state as ReplenishmentCountState | null) ?? null,
    openRequestCount: num(row.open_request_count),
    openApprovedRequestCount: num(row.open_approved_request_count),
    openOrderedRequestCount: num(row.open_ordered_request_count),
  };
}

export async function listReplenishmentPage(
  db: Db,
  input: {
    organizationId: string;
    view: ReplenishmentView;
    locationId?: string | null;
    cursor?: ReplenishmentCursor | null;
    limit?: number;
  },
): Promise<ReplenishmentPage> {
  const limit = input.limit ?? REPLENISHMENT_PAGE;
  const { data, error } = await db.rpc("list_inventory_replenishment", {
    _organization_id: input.organizationId,
    _view: input.view,
    _limit: limit,
    ...(input.locationId ? { _inventory_location_id: input.locationId } : {}),
    ...(input.cursor
      ? {
          _after_rank: input.cursor.rank,
          _after_item: input.cursor.item,
          _after_location: input.cursor.location,
          _after_id: input.cursor.id,
        }
      : {}),
  });
  if (error) throw new Error(error.message);
  const raw = (data ?? []) as JsonRow[];
  const last = raw[raw.length - 1];
  return {
    rows: raw.map(toReplenishmentRow),
    nextCursor:
      raw.length === limit && last
        ? {
            rank: Number(last.sort_rank),
            item: String(last.sort_item),
            location: String(last.sort_location),
            id: String(last.rule_id),
          }
        : null,
  };
}

export async function getReplenishmentSummary(
  db: Db,
  organizationId: string,
): Promise<ReplenishmentSummary> {
  const { data, error } = await db.rpc("get_inventory_replenishment_summary", {
    _organization_id: organizationId,
  });
  if (error) throw new Error(error.message);
  const value = data as JsonRow;
  const rules = value.rules as JsonRow;
  const categories = value.categories as JsonRow;
  const items = value.items as JsonRow;
  const locations = value.locations as JsonRow;
  return {
    rules: {
      total: num(rules.total),
      active: num(rules.active),
      inactive: num(rules.inactive),
      disabled: num(rules.disabled),
    },
    categories: {
      moveAvailable: num(categories.moveAvailable),
      partlyCovered: num(categories.partlyCovered),
      needsPurchasing: num(categories.needsPurchasing),
      ok: num(categories.ok),
      inactive: num(categories.inactive),
    },
    notStockedHere: num(value.notStockedHere),
    items: {
      active: num(items.active),
      withRule: num(items.withRule),
      withoutRule: num(items.withoutRule),
    },
    locations: {
      activeStorage: num(locations.activeStorage),
      withRule: num(locations.withRule),
      withoutRule: num(locations.withoutRule),
    },
  };
}

// Every rule at one location, page by page (by item name), so the answer never depends on the
// API row cap.
export async function listLocationReplenishmentRules(
  db: Db,
  organizationId: string,
  locationId: string,
): Promise<ReplenishmentRow[]> {
  const rows: ReplenishmentRow[] = [];
  let after: { item: string; id: string } | null = null;
  for (;;) {
    const { data, error } = await db.rpc("list_inventory_location_replenishment_rules", {
      _organization_id: organizationId,
      _inventory_location_id: locationId,
      _limit: LOCATION_RULE_PAGE,
      ...(after ? { _after_item: after.item, _after_id: after.id } : {}),
    });
    if (error) throw new Error(error.message);
    const raw = (data ?? []) as unknown as JsonRow[];
    rows.push(...raw.map(toReplenishmentRow));
    if (raw.length < LOCATION_RULE_PAGE) return rows;
    const last = raw[raw.length - 1];
    after = { item: String(last.sort_item), id: String(last.rule_id) };
  }
}

const toRuleResult = (value: JsonRow): ReplenishmentRuleResult => ({
  ruleId: String(value.ruleId),
  inventoryItemId: String(value.inventoryItemId),
  inventoryLocationId: String(value.inventoryLocationId),
  minimumQuantity: num(value.minimumQuantity),
  targetQuantity: num(value.targetQuantity),
  enabled: Boolean(value.enabled),
  updatedAt: String(value.updatedAt),
});

export async function setReplenishmentRule(
  db: Db,
  input: {
    organizationId: string;
    inventoryItemId: string;
    locationId: string;
    minimumQuantity: number;
    targetQuantity: number;
    expectedUpdatedAt: string | null;
  },
): Promise<ReplenishmentRuleResult> {
  const { data, error } = await db.rpc("set_inventory_replenishment_rule", {
    _organization_id: input.organizationId,
    _inventory_item_id: input.inventoryItemId,
    _inventory_location_id: input.locationId,
    _minimum_quantity: input.minimumQuantity,
    _target_quantity: input.targetQuantity,
    // Null creates; the version the screen showed edits.
    ...(input.expectedUpdatedAt ? { _expected_updated_at: input.expectedUpdatedAt } : {}),
  });
  if (error) throw new Error(error.message);
  return toRuleResult(data as JsonRow);
}

export async function setReplenishmentRuleEnabled(
  db: Db,
  input: { organizationId: string; ruleId: string; enabled: boolean; expectedUpdatedAt: string },
): Promise<ReplenishmentRuleResult> {
  const { data, error } = await db.rpc("set_inventory_replenishment_rule_enabled", {
    _organization_id: input.organizationId,
    _rule_id: input.ruleId,
    _enabled: input.enabled,
    _expected_updated_at: input.expectedUpdatedAt,
  });
  if (error) throw new Error(error.message);
  return toRuleResult(data as JsonRow);
}
