import { Link2, Pencil, Trash2 } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import type { ReviewItem } from '@/types/invoice-processing';

export function ReviewItemsTable({ items, completed, onEdit, onRemove, onMatch }: { items: ReviewItem[]; completed: boolean; onEdit: (item: ReviewItem) => void; onRemove: (item: ReviewItem) => void; onMatch: (item: ReviewItem) => void }) {
  if (!items.length)
    return (
      <div className="rounded-xl border border-dashed bg-card px-6 py-14 text-center">
        <p className="font-medium">No line items yet.</p>
        <p className="mt-1 text-sm text-muted-foreground">Add each product from the invoice before approval.</p>
      </div>
    );
  return (
    <div className="overflow-x-auto rounded-xl border bg-card">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>SKU</TableHead>
            <TableHead>Product description</TableHead>
            <TableHead>Product match</TableHead>
            <TableHead>Manufacturer</TableHead>
            <TableHead>Category</TableHead>
            <TableHead>Quantity</TableHead>
            <TableHead>Unit</TableHead>
            <TableHead className="text-right">Unit price</TableHead>
            <TableHead className="text-right">Total price</TableHead>
            {!completed && <TableHead className="text-right">Actions</TableHead>}
          </TableRow>
        </TableHeader>
        <TableBody>
          {items.map((item) => (
            <TableRow key={item.id} className={item.extractionConfidence !== undefined && item.extractionConfidence < 75 ? 'bg-amber-50/40' : undefined}>
              <TableCell className="font-mono text-xs">{item.sku || '—'}</TableCell>
              <TableCell className="min-w-52 font-medium">
                {item.description}
                {item.extractionConfidence !== undefined && item.extractionConfidence < 75 && (
                  <span className="ml-2 text-xs font-normal text-amber-700" title={`Lowest field confidence: ${item.extractionConfidence}%`}>
                    Review
                  </span>
                )}
              </TableCell>
              <TableCell className="min-w-48">
                <button type="button" disabled={completed} onClick={() => onMatch(item)} className="text-left disabled:cursor-default">
                  <Badge variant={item.productMatch.state === 'UNRESOLVED' ? 'destructive' : item.productMatch.state === 'SUGGESTED' ? 'secondary' : 'default'}>
                    {item.productMatch.state === 'UNRESOLVED' ? 'Needs matching' : item.productMatch.state === 'SUGGESTED' ? 'Suggested match' : 'Matched'}
                  </Badge>
                  {item.productMatch.productName && <p className="mt-1 max-w-48 truncate text-xs text-muted-foreground">{item.productMatch.productName}</p>}
                </button>
              </TableCell>
              <TableCell>{item.manufacturer || '—'}</TableCell>
              <TableCell>{item.category || '—'}</TableCell>
              <TableCell>{item.quantity}</TableCell>
              <TableCell>{item.unitOfMeasure}</TableCell>
              <TableCell className="text-right">{money(item.unitPrice)}</TableCell>
              <TableCell className="text-right font-medium">{money(item.totalPrice)}</TableCell>
              {!completed && (
                <TableCell>
                  <div className="flex justify-end gap-1">
                    <Button size="sm" variant="ghost" aria-label={`Match ${item.description}`} onClick={() => onMatch(item)}>
                      <Link2 className="h-4 w-4" />
                    </Button>
                    <Button size="sm" variant="ghost" aria-label={`Edit ${item.description}`} onClick={() => onEdit(item)}>
                      <Pencil className="h-4 w-4" />
                    </Button>
                    <Button size="sm" variant="ghost" aria-label={`Remove ${item.description}`} onClick={() => onRemove(item)}>
                      <Trash2 className="h-4 w-4 text-destructive" />
                    </Button>
                  </div>
                </TableCell>
              )}
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}

const money = (value: number) => new Intl.NumberFormat(undefined, { style: 'currency', currency: 'USD' }).format(value);
