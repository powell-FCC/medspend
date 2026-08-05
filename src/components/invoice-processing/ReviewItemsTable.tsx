import { Pencil, Trash2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import type { ReviewItem } from '@/types/invoice-processing';

export function ReviewItemsTable({ items, completed, onEdit, onRemove }: {
  items: ReviewItem[];
  completed: boolean;
  onEdit: (item: ReviewItem) => void;
  onRemove: (item: ReviewItem) => void;
}) {
  if (!items.length) return <div className="rounded-xl border border-dashed bg-card px-6 py-14 text-center"><p className="font-medium">No line items yet.</p><p className="mt-1 text-sm text-muted-foreground">Add each product from the invoice before approval.</p></div>;
  return <div className="overflow-x-auto rounded-xl border bg-card"><Table><TableHeader><TableRow><TableHead>SKU</TableHead><TableHead>Product description</TableHead><TableHead>Manufacturer</TableHead><TableHead>Category</TableHead><TableHead>Quantity</TableHead><TableHead>Unit</TableHead><TableHead className="text-right">Unit price</TableHead><TableHead className="text-right">Total price</TableHead>{!completed && <TableHead className="text-right">Actions</TableHead>}</TableRow></TableHeader>
    <TableBody>{items.map((item) => <TableRow key={item.id}><TableCell className="font-mono text-xs">{item.sku || '—'}</TableCell><TableCell className="min-w-52 font-medium">{item.description}</TableCell><TableCell>{item.manufacturer || '—'}</TableCell><TableCell>{item.category || '—'}</TableCell><TableCell>{item.quantity}</TableCell><TableCell>{item.unitOfMeasure}</TableCell><TableCell className="text-right">{money(item.unitPrice)}</TableCell><TableCell className="text-right font-medium">{money(item.totalPrice)}</TableCell>{!completed && <TableCell><div className="flex justify-end gap-1"><Button size="sm" variant="ghost" aria-label={`Edit ${item.description}`} onClick={() => onEdit(item)}><Pencil className="h-4 w-4" /></Button><Button size="sm" variant="ghost" aria-label={`Remove ${item.description}`} onClick={() => onRemove(item)}><Trash2 className="h-4 w-4 text-destructive" /></Button></div></TableCell>}</TableRow>)}</TableBody>
  </Table></div>;
}

const money = (value: number) => new Intl.NumberFormat(undefined, { style: 'currency', currency: 'USD' }).format(value);
