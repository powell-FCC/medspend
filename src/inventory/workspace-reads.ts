import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/integrations/supabase/types";
import type { InventoryLocationBalance, InventoryStatus } from "@/types/inventory";
import type {
  InventoryWorkspaceStatusFilter,
  WorkspaceItem,
  WorkspaceLocation,
  WorkspaceLocationDetail,
  WorkspacePage,
  WorkspaceStockRow,
} from "@/types/inventory-workspace";

// Phase 7B.1 Inventory workspace reads behind the server functions. Every call goes through
// an owner+admin SECURITY DEFINER function that checks the caller's role itself; nothing here
// reads inventory tables directly, so admins never need raw-table access. Lists page by
// keyset, so no answer depends on the API row cap.

type Db = SupabaseClient<Database>;
type Cursor = { name: string; id: string } | null;
type LocationRow =
  Database["public"]["Functions"]["list_inventory_workspace_locations"]["Returns"][number];

export const WORKSPACE_LOCATION_PAGE = 200;

const toLocation = (row: LocationRow): WorkspaceLocation => ({
  id: row.inventory_location_id,
  name: row.name,
  description: row.description ?? null,
  kind: row.kind === "unassigned" ? "unassigned" : "storage",
  active: row.active,
  stockedItemCount: row.stocked_item_count,
  countableItemCount: row.countable_item_count ?? null,
  lastCountedAt: row.last_counted_at ?? null,
  lastCountedByName: row.last_counted_by_name ?? null,
  activeLabelCount: row.active_label_count ?? null,
  lastLabelIssuedAt: row.last_label_issued_at ?? null,
});

const nullableNumber = (value: unknown) =>
  value === null || value === undefined ? null : Number(value);

// Every location of the organization, page by page. Organizations have dozens of locations,
// not thousands, but the loop keeps the answer complete either way.
export async function listAllWorkspaceLocations(
  db: Db,
  organizationId: string,
  status: InventoryWorkspaceStatusFilter,
  pageSize = WORKSPACE_LOCATION_PAGE,
): Promise<WorkspaceLocation[]> {
  const locations: WorkspaceLocation[] = [];
  let after: LocationRow | undefined;
  for (;;) {
    const { data, error } = await db.rpc("list_inventory_workspace_locations", {
      _organization_id: organizationId,
      _status: status,
      _limit: pageSize,
      ...(after
        ? {
            _after_sort_group: after.sort_group,
            _after_name: after.sort_name,
            _after_id: after.inventory_location_id,
          }
        : {}),
    });
    if (error) throw new Error(error.message);
    const rows = data ?? [];
    locations.push(...rows.map(toLocation));
    if (rows.length < pageSize) return locations;
    after = rows[rows.length - 1];
  }
}

export async function getWorkspaceLocation(
  db: Db,
  organizationId: string,
  locationId: string,
): Promise<WorkspaceLocationDetail> {
  const { data, error } = await db.rpc("get_inventory_workspace_location", {
    _organization_id: organizationId,
    _inventory_location_id: locationId,
  });
  if (error) throw new Error(error.message);
  const row = data as Record<string, unknown>;
  return {
    id: row.id as string,
    name: row.name as string,
    description: (row.description as string | null) ?? null,
    kind: row.kind === "unassigned" ? "unassigned" : "storage",
    active: row.active as boolean,
    stockedItemCount: Number(row.stockedItemCount),
    archivedStockedItemCount: Number(row.archivedStockedItemCount),
    countableItemCount: nullableNumber(row.countableItemCount),
    lastCountedAt: (row.lastCountedAt as string | null) ?? null,
    lastCountedByName: (row.lastCountedByName as string | null) ?? null,
    activeLabelCount: nullableNumber(row.activeLabelCount),
    lastLabelIssuedAt: (row.lastLabelIssuedAt as string | null) ?? null,
  };
}

export async function listWorkspaceLocationStockPage(
  db: Db,
  input: { organizationId: string; locationId: string; cursor: Cursor; limit: number },
): Promise<WorkspacePage<WorkspaceStockRow>> {
  const { data, error } = await db.rpc("list_inventory_workspace_location_stock", {
    _organization_id: input.organizationId,
    _inventory_location_id: input.locationId,
    _limit: input.limit,
    ...(input.cursor ? { _after_name: input.cursor.name, _after_id: input.cursor.id } : {}),
  });
  if (error) throw new Error(error.message);
  const page = data ?? [];
  const last = page[page.length - 1];
  return {
    rows: page.map((row) => ({
      inventoryItemId: row.inventory_item_id,
      name: row.name,
      sku: row.sku ?? null,
      unit: row.unit,
      quantity: Number(row.quantity),
      itemActive: row.item_active,
      organizationQuantity: Number(row.organization_quantity),
      organizationParLevel: nullableNumber(row.organization_par_level),
      organizationStockStatus: row.organization_stock_status as InventoryStatus,
      lastCountedAt: row.last_counted_at ?? null,
    })),
    nextCursor:
      page.length === input.limit && last
        ? { name: last.sort_name, id: last.inventory_item_id }
        : null,
  };
}

export async function listWorkspaceItemsPage(
  db: Db,
  input: {
    organizationId: string;
    search: string;
    category: string;
    status: InventoryWorkspaceStatusFilter;
    lowStock: boolean;
    cursor: Cursor;
    limit: number;
  },
): Promise<WorkspacePage<WorkspaceItem>> {
  const { data, error } = await db.rpc("list_inventory_workspace_items", {
    _organization_id: input.organizationId,
    _search: input.search.trim(),
    _category: input.category,
    _status: input.status,
    _stock_status: input.lowStock ? "low" : "all",
    _limit: input.limit,
    ...(input.cursor ? { _after_name: input.cursor.name, _after_id: input.cursor.id } : {}),
  });
  if (error) throw new Error(error.message);
  const page = data ?? [];
  const last = page[page.length - 1];
  return {
    rows: page.map((row) => ({
      id: row.inventory_item_id,
      name: row.name,
      description: row.description ?? null,
      sku: row.sku ?? null,
      vendorName: row.vendor_name ?? null,
      manufacturer: row.manufacturer ?? null,
      category: row.category ?? null,
      unit: row.unit,
      active: row.active,
      quantity: Number(row.quantity),
      parLevel: nullableNumber(row.par_level),
      stockStatus: row.stock_status as InventoryStatus,
      unassignedQuantity: Number(row.unassigned_quantity),
      physicalQuantity: Number(row.physical_quantity),
      physicalLocationCount: row.physical_location_count,
      singlePhysicalLocationName: row.single_physical_location_name ?? null,
    })),
    nextCursor:
      page.length === input.limit && last
        ? { name: last.sort_name, id: last.inventory_item_id }
        : null,
  };
}

export async function getWorkspaceItemBalances(
  db: Db,
  organizationId: string,
  inventoryItemId: string,
): Promise<{ quantity: number; balances: InventoryLocationBalance[] }> {
  const { data, error } = await db.rpc("list_inventory_workspace_item_balances", {
    _organization_id: organizationId,
    _inventory_item_id: inventoryItemId,
  });
  if (error) throw new Error(error.message);
  const value = data as {
    inventoryItemId: string;
    quantity: number;
    balances: Array<{
      inventoryLocationId: string;
      quantity: number;
      version: number;
      updatedAt: string;
    }>;
  };
  return {
    quantity: Number(value.quantity),
    balances: value.balances.map((balance) => ({
      inventoryItemId: value.inventoryItemId,
      inventoryLocationId: balance.inventoryLocationId,
      quantity: Number(balance.quantity),
      version: balance.version,
      updatedAt: balance.updatedAt,
    })),
  };
}

// Owner: revoke every active label and issue one replacement, atomically in the database.
export async function replaceLocationLabels(db: Db, organizationId: string, locationId: string) {
  const { data, error } = await db.rpc("replace_inventory_location_labels", {
    _organization_id: organizationId,
    _inventory_location_id: locationId,
  });
  if (error) throw new Error(error.message);
  return data as unknown as {
    labelId: string;
    token: string;
    issuedAt: string;
    locationId: string;
    locationName: string;
    revokedCount: number;
  };
}
