import { MoreHorizontal } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from '@/components/ui/dropdown-menu';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { getInventoryStatus, inventoryStatusLabel } from '@/inventory/status';
import type { InventoryItem } from '@/types/inventory';

const tones = { healthy: 'bg-emerald-100 text-emerald-800', low: 'bg-amber-100 text-amber-800', critical: 'bg-red-100 text-red-800', inactive: 'bg-slate-100 text-slate-700' };

export function InventoryTable({ items, onEdit, onArchive, onAdjust }: { items: InventoryItem[]; onEdit: (item: InventoryItem) => void; onArchive: (item: InventoryItem) => void; onAdjust: (item: InventoryItem) => void }) {
  if (!items.length) return <div className="rounded-xl border border-dashed bg-card px-6 py-16 text-center"><p className="font-medium">No inventory items found</p><p className="mt-1 text-sm text-muted-foreground">Add an item or adjust the filters.</p></div>;
  return <div className="overflow-hidden rounded-xl border bg-card"><Table><TableHeader><TableRow><TableHead>Item</TableHead><TableHead>SKU</TableHead><TableHead>Category</TableHead><TableHead>Vendor</TableHead><TableHead>Quantity</TableHead><TableHead>Unit</TableHead><TableHead>Par Level</TableHead><TableHead>Status</TableHead><TableHead className="w-12"><span className="sr-only">Actions</span></TableHead></TableRow></TableHeader>
    <TableBody>{items.map((item) => { const status = getInventoryStatus(item.quantity, item.parLevel, item.active); return <TableRow key={item.id}><TableCell><div className="font-medium">{item.name}</div>{item.manufacturer && <div className="text-xs text-muted-foreground">{item.manufacturer}</div>}</TableCell><TableCell className="font-mono text-xs">{item.sku || '—'}</TableCell><TableCell>{item.category || '—'}</TableCell><TableCell>{item.vendorName || '—'}</TableCell><TableCell className="font-semibold tabular-nums">{item.quantity}</TableCell><TableCell>{item.unit}</TableCell><TableCell>{item.parLevel ?? '—'}</TableCell><TableCell><Badge className={tones[status]}>{inventoryStatusLabel[status]}</Badge></TableCell><TableCell>
      <DropdownMenu><DropdownMenuTrigger asChild><Button size="icon" variant="ghost" aria-label={`Actions for ${item.name}`}><MoreHorizontal className="h-4 w-4" /></Button></DropdownMenuTrigger><DropdownMenuContent align="end"><DropdownMenuItem onClick={() => onEdit(item)}>Edit</DropdownMenuItem><DropdownMenuItem onClick={() => onAdjust(item)}>Adjust quantity</DropdownMenuItem><DropdownMenuItem onClick={() => onArchive(item)}>{item.active ? 'Archive' : 'Restore'}</DropdownMenuItem></DropdownMenuContent></DropdownMenu>
    </TableCell></TableRow>; })}</TableBody></Table></div>;
}
