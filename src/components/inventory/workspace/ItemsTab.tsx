import { useEffect, useState } from "react";
import { useInfiniteQuery, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { FolderPlus, PackagePlus, Search } from "lucide-react";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  deleteInventoryCategoryFn,
  saveInventoryCategoryFn,
  saveInventoryItemFn,
  setInventoryItemActiveFn,
} from "@/lib/inventory.functions";
import {
  listWorkspaceCategoriesFn,
  listWorkspaceItemsFn,
} from "@/lib/inventory-workspace.functions";
import { workspaceQueryKey } from "@/inventory/workspace";
import type { InventoryItemInput } from "@/types/inventory";
import type { InventoryWorkspaceStatusFilter, WorkspaceItem } from "@/types/inventory-workspace";
import { CategoryDialog } from "../CategoryDialog";
import { InventoryItemDialog } from "../InventoryItemDialog";
import { InventoryTable } from "../InventoryTable";
import { ItemStockDialogs, type ItemStockAction } from "./ItemStockDialogs";

const PAGE = 100;

function useDebounced<T>(value: T, delay = 250) {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const timer = window.setTimeout(() => setDebounced(value), delay);
    return () => window.clearTimeout(timer);
  }, [value, delay]);
  return debounced;
}

// Items, filtered and paged by the database. Owners add, edit, archive, move and adjust;
// admins see the same rows and nothing that changes them.
export function ItemsTab({
  organizationId,
  canManage,
}: {
  organizationId: string;
  canManage: boolean;
}) {
  const queryClient = useQueryClient();
  const listItems = useServerFn(listWorkspaceItemsFn);
  const listCategories = useServerFn(listWorkspaceCategoriesFn);
  const saveItem = useServerFn(saveInventoryItemFn);
  const setActive = useServerFn(setInventoryItemActiveFn);
  const saveCategory = useServerFn(saveInventoryCategoryFn);
  const deleteCategory = useServerFn(deleteInventoryCategoryFn);
  const [search, setSearch] = useState("");
  const [category, setCategory] = useState("");
  const [status, setStatus] = useState<InventoryWorkspaceStatusFilter>("active");
  const [lowStock, setLowStock] = useState(false);
  const [itemOpen, setItemOpen] = useState(false);
  const [categoryOpen, setCategoryOpen] = useState(false);
  const [editing, setEditing] = useState<WorkspaceItem>();
  const [stockAction, setStockAction] = useState<ItemStockAction>();
  const [error, setError] = useState("");
  const query = useDebounced(search.trim());
  const filters = { search: query, category, status, lowStock };
  const items = useInfiniteQuery({
    queryKey: [...workspaceQueryKey(organizationId), "items", filters],
    queryFn: ({ pageParam }) =>
      listItems({ data: { organizationId, ...filters, cursor: pageParam, limit: PAGE } }),
    initialPageParam: null as { name: string; id: string } | null,
    getNextPageParam: (page) => page.nextCursor,
  });
  const categories = useQuery({
    queryKey: [...workspaceQueryKey(organizationId), "categories"],
    queryFn: () => listCategories({ data: { organizationId } }),
  });
  const refresh = () =>
    queryClient.invalidateQueries({ queryKey: workspaceQueryKey(organizationId) });
  const rows = items.data?.pages.flatMap((page) => page.rows) ?? [];
  const filtered = Boolean(query || category || status !== "active" || lowStock);

  return (
    <div>
      {canManage && (
        <div className="mb-4 flex flex-wrap justify-end gap-2">
          <Button variant="outline" onClick={() => setCategoryOpen(true)}>
            <FolderPlus className="mr-2 h-4 w-4" />
            Add Category
          </Button>
          <Button
            onClick={() => {
              setEditing(undefined);
              setItemOpen(true);
            }}
          >
            <PackagePlus className="mr-2 h-4 w-4" />
            Add Item
          </Button>
        </div>
      )}
      <div className="mb-4 grid gap-3 rounded-xl border bg-card p-4 md:grid-cols-[minmax(240px,1fr)_200px_160px_auto]">
        <div className="relative">
          <Search className="absolute left-3 top-2.5 h-4 w-4 text-muted-foreground" />
          <Input
            aria-label="Search inventory"
            className="pl-9"
            placeholder="Search name, SKU, vendor or manufacturer..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </div>
        <select
          aria-label="Category filter"
          className="h-9 min-w-0 rounded-md border bg-background px-3 text-sm"
          value={category}
          onChange={(e) => setCategory(e.target.value)}
        >
          <option value="">All categories</option>
          {categories.data?.map((row) => (
            <option key={row.id}>{row.name}</option>
          ))}
        </select>
        <select
          aria-label="Status filter"
          className="h-9 min-w-0 rounded-md border bg-background px-3 text-sm"
          value={status}
          onChange={(e) => setStatus(e.target.value as InventoryWorkspaceStatusFilter)}
        >
          <option value="active">Active</option>
          <option value="archived">Archived</option>
          <option value="all">All status</option>
        </select>
        <label className="flex h-9 items-center gap-2 whitespace-nowrap rounded-md border px-3 text-sm">
          <input
            type="checkbox"
            checked={lowStock}
            onChange={(e) => setLowStock(e.target.checked)}
          />
          Low Stock
        </label>
      </div>
      {error && (
        <p role="alert" className="mb-3 text-sm text-destructive">
          {error}
        </p>
      )}
      {items.isLoading && (
        <p className="py-12 text-center text-sm text-muted-foreground">Loading inventory...</p>
      )}
      {items.isError && (
        <Alert variant="destructive">
          <AlertTitle>Could not load inventory</AlertTitle>
          <AlertDescription>
            {items.error instanceof Error ? items.error.message : "Try again."}
          </AlertDescription>
        </Alert>
      )}
      {items.isSuccess && rows.length === 0 && !filtered ? (
        <div className="rounded-xl border border-dashed bg-card px-6 py-16 text-center">
          <p className="font-medium">No inventory items yet.</p>
          {canManage && (
            <>
              <p className="mx-auto mt-2 max-w-lg text-sm text-muted-foreground">
                Upload and approve an invoice to automatically create your inventory catalog.
              </p>
              <Button asChild className="mt-5">
                <Link to="/upload">Upload Invoice</Link>
              </Button>
            </>
          )}
        </div>
      ) : (
        items.isSuccess && (
          <div className="space-y-3">
            <InventoryTable
              items={rows}
              canManage={canManage}
              onEdit={(item) => {
                setEditing(item);
                setItemOpen(true);
              }}
              onLocations={(item) => setStockAction({ kind: "move", item })}
              onAdjust={(item) => setStockAction({ kind: "adjust", item })}
              onArchive={async (item) => {
                setError("");
                try {
                  await setActive({ data: { organizationId, id: item.id, active: !item.active } });
                } catch (cause) {
                  setError(cause instanceof Error ? cause.message : "Could not update the item.");
                } finally {
                  await refresh();
                }
              }}
            />
            {items.hasNextPage && (
              <div className="text-center">
                <Button
                  variant="outline"
                  disabled={items.isFetchingNextPage}
                  onClick={() => void items.fetchNextPage()}
                >
                  {items.isFetchingNextPage ? "Loading…" : "Load more"}
                </Button>
              </div>
            )}
          </div>
        )
      )}
      {canManage && (
        <>
          <InventoryItemDialog
            open={itemOpen}
            onOpenChange={setItemOpen}
            organizationId={organizationId}
            item={editing}
            categories={categories.data ?? []}
            onSave={async (input: InventoryItemInput) => {
              await saveItem({ data: input });
              await refresh();
            }}
          />
          <CategoryDialog
            open={categoryOpen}
            onOpenChange={setCategoryOpen}
            categories={categories.data ?? []}
            onSave={async (name, id) => {
              await saveCategory({ data: { organizationId, id, name } });
              await refresh();
            }}
            onDelete={async (id) => {
              await deleteCategory({ data: { organizationId, id } });
              await refresh();
            }}
          />
          <ItemStockDialogs
            organizationId={organizationId}
            action={stockAction}
            onClose={() => setStockAction(undefined)}
          />
        </>
      )}
    </div>
  );
}
