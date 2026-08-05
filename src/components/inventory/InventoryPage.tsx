import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { AlertCircle, FolderPlus, PackagePlus, Search } from 'lucide-react';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { useActiveOrg } from '@/hooks/use-active-org';
import { adjustInventoryQuantityFn, deleteInventoryCategoryFn, listInventoryFn, saveInventoryCategoryFn, saveInventoryItemFn, setInventoryItemActiveFn } from '@/lib/inventory.functions';
import type { AdjustmentReason, InventoryItem, InventoryItemInput } from '@/types/inventory';
import { CategoryDialog } from './CategoryDialog';
import { InventoryItemDialog } from './InventoryItemDialog';
import { InventoryTable } from './InventoryTable';
import { QuantityAdjustmentDialog } from './QuantityAdjustmentDialog';

export function InventoryPage() {
  const { active } = useActiveOrg(); const queryClient = useQueryClient();
  const list = useServerFn(listInventoryFn); const saveItem = useServerFn(saveInventoryItemFn); const setActive = useServerFn(setInventoryItemActiveFn);
  const adjust = useServerFn(adjustInventoryQuantityFn); const saveCategory = useServerFn(saveInventoryCategoryFn); const deleteCategory = useServerFn(deleteInventoryCategoryFn);
  const [search, setSearch] = useState(''); const [category, setCategory] = useState(''); const [status, setStatus] = useState<'all' | 'active' | 'archived'>('active'); const [lowStock, setLowStock] = useState(false);
  const [itemOpen, setItemOpen] = useState(false); const [categoryOpen, setCategoryOpen] = useState(false); const [editing, setEditing] = useState<InventoryItem>(); const [adjusting, setAdjusting] = useState<InventoryItem>();
  const owner = active?.role === 'owner'; const queryKey = ['inventory', active?.organizationId, search, category, status, lowStock];
  const inventory = useQuery({ queryKey, queryFn: () => list({ data: { organizationId: active!.organizationId, search, category, status, lowStock } }), enabled: Boolean(active?.organizationId && owner) });
  const refresh = () => queryClient.invalidateQueries({ queryKey: ['inventory', active?.organizationId] });
  if (!active) return null;
  if (!owner) return <div className="mx-auto max-w-3xl px-6 py-16"><Alert variant="destructive"><AlertCircle /><AlertTitle>Owner access required</AlertTitle><AlertDescription>Only organization owners can manage inventory.</AlertDescription></Alert></div>;
  return <div className="mx-auto max-w-7xl px-5 py-8 sm:px-8" data-page="inventory"><div className="flex flex-wrap items-start justify-between gap-4"><div><p className="text-sm font-medium text-primary">Owner workspace</p><h1 className="mt-1 text-3xl font-semibold tracking-tight">Inventory</h1><p className="mt-2 text-sm text-muted-foreground">Manage supplies available for staff requests.</p></div><div className="flex gap-2"><Button variant="outline" onClick={() => setCategoryOpen(true)}><FolderPlus className="mr-2 h-4 w-4" />Add Category</Button><Button onClick={() => { setEditing(undefined); setItemOpen(true); }}><PackagePlus className="mr-2 h-4 w-4" />Add Item</Button></div></div>
    <div className="my-6 grid gap-3 rounded-xl border bg-card p-4 md:grid-cols-[minmax(240px,1fr)_200px_160px_auto]"><div className="relative"><Search className="absolute left-3 top-2.5 h-4 w-4 text-muted-foreground" /><Input aria-label="Search inventory" className="pl-9" placeholder="Search inventory..." value={search} onChange={(e) => setSearch(e.target.value)} /></div><select aria-label="Category filter" className="h-9 rounded-md border bg-background px-3 text-sm" value={category} onChange={(e) => setCategory(e.target.value)}><option value="">All categories</option>{inventory.data?.categories.map((row) => <option key={row.id}>{row.name}</option>)}</select><select aria-label="Status filter" className="h-9 rounded-md border bg-background px-3 text-sm" value={status} onChange={(e) => setStatus(e.target.value as typeof status)}><option value="active">Active</option><option value="archived">Archived</option><option value="all">All status</option></select><label className="flex h-9 items-center gap-2 rounded-md border px-3 text-sm"><input type="checkbox" checked={lowStock} onChange={(e) => setLowStock(e.target.checked)} />Low Stock</label></div>
    {inventory.error && <Alert variant="destructive" className="mb-5"><AlertCircle /><AlertTitle>Could not load inventory</AlertTitle><AlertDescription>{inventory.error.message}</AlertDescription></Alert>}
    {inventory.isLoading ? <p className="py-12 text-center text-sm text-muted-foreground">Loading inventory…</p> : <InventoryTable items={inventory.data?.items ?? []} onEdit={(item) => { setEditing(item); setItemOpen(true); }} onAdjust={setAdjusting} onArchive={async (item) => { await setActive({ data: { organizationId: active.organizationId, id: item.id, active: !item.active } }); await refresh(); }} />}
    <InventoryItemDialog open={itemOpen} onOpenChange={setItemOpen} organizationId={active.organizationId} item={editing} categories={inventory.data?.categories ?? []} onSave={async (input: InventoryItemInput) => { await saveItem({ data: input }); await refresh(); }} />
    <QuantityAdjustmentDialog item={adjusting} onOpenChange={(open) => { if (!open) setAdjusting(undefined); }} onAdjust={async (amount: number, reason: AdjustmentReason) => { if (!adjusting) return; await adjust({ data: { organizationId: active.organizationId, inventoryItemId: adjusting.id, amount, reason } }); await refresh(); }} />
    <CategoryDialog open={categoryOpen} onOpenChange={setCategoryOpen} categories={inventory.data?.categories ?? []} onSave={async (name, id) => { await saveCategory({ data: { organizationId: active.organizationId, id, name } }); await refresh(); }} onDelete={async (id) => { await deleteCategory({ data: { organizationId: active.organizationId, id } }); await refresh(); }} />
  </div>;
}
