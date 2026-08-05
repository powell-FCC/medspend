import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import type { ReviewItem } from '@/types/invoice-processing';

export function ReviewItemsTable({ items, approved, onChange }: {
  items: ReviewItem[]; approved: Set<string>; onChange: (id: string, approved: boolean) => void;
}) {
  return (
    <div className="overflow-hidden rounded-xl border bg-card">
      <Table>
        <TableHeader><TableRow><TableHead>Item</TableHead><TableHead>SKU</TableHead><TableHead>Quantity</TableHead><TableHead>Price</TableHead><TableHead>Category</TableHead><TableHead className="text-right">Decision</TableHead></TableRow></TableHeader>
        <TableBody>{items.map((item) => {
          const isApproved = approved.has(item.id);
          return <TableRow key={item.id}>
            <TableCell className="font-medium">{item.description}</TableCell><TableCell>{item.sku || '—'}</TableCell>
            <TableCell>{item.quantity} {item.unitOfMeasure}</TableCell><TableCell>${item.unitPrice.toFixed(2)}</TableCell>
            <TableCell><Badge variant="secondary">{item.category || 'Uncategorized'}</Badge></TableCell>
            <TableCell><div className="flex justify-end gap-2">
              <Button size="sm" variant={isApproved ? 'default' : 'outline'} onClick={() => onChange(item.id, true)}>Approve</Button>
              <Button size="sm" variant={!isApproved ? 'destructive' : 'outline'} onClick={() => onChange(item.id, false)}>Reject</Button>
            </div></TableCell>
          </TableRow>;
        })}</TableBody>
      </Table>
    </div>
  );
}
