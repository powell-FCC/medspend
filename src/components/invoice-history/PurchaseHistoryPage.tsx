import { useQuery } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { ReceiptText } from 'lucide-react';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useActiveOrg } from '@/hooks/use-active-org';
import { listPurchaseHistoryFn } from '@/lib/invoice-history.functions';
import { EmptyState, OwnerRequired, PageHeading } from './InvoiceListPage';

export function PurchaseHistoryPage() {
  const { active } = useActiveOrg(); const list = useServerFn(listPurchaseHistoryFn); const owner = active?.role === 'owner';
  const purchases = useQuery({ queryKey: ['purchase-history', active?.organizationId], queryFn: () => list({ data: { organizationId: active!.organizationId } }), enabled: Boolean(active?.organizationId && owner) });
  if (!active) return null; if (!owner) return <OwnerRequired message="Only organization owners can view purchase history." />;
  return <div className="mx-auto max-w-6xl px-5 py-8 sm:px-8"><PageHeading title="Purchases" subtitle="Track supply purchases from vendor invoices." />
    {purchases.isLoading && <p className="py-12 text-center text-sm text-muted-foreground">Loading purchases...</p>}
    {purchases.isError && <p role="alert" className="rounded-xl border border-destructive/40 bg-destructive/5 px-5 py-4 text-sm text-destructive">Could not load purchase history: {purchases.error.message}</p>}
    {purchases.isSuccess && purchases.data.length === 0 && <EmptyState icon={<ReceiptText className="h-6 w-6" />} title="No purchase records yet." text="Completed vendor invoices will appear here as purchasing history." />}
    {purchases.isSuccess && purchases.data.length > 0 && <div className="overflow-hidden rounded-xl border bg-card"><Table><TableHeader><TableRow><TableHead>Date</TableHead><TableHead>Vendor</TableHead><TableHead>Invoice Number</TableHead><TableHead>Items</TableHead><TableHead className="text-right">Total</TableHead></TableRow></TableHeader><TableBody>{purchases.data.map((row) => <TableRow key={row.invoiceId}><TableCell>{row.date ? new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' }).format(new Date(row.date)) : '—'}</TableCell><TableCell className="font-medium">{row.vendor}</TableCell><TableCell>{row.invoiceNumber ?? '—'}</TableCell><TableCell>{row.itemCount}</TableCell><TableCell className="text-right font-medium">{row.total === null ? '—' : new Intl.NumberFormat(undefined, { style: 'currency', currency: 'USD' }).format(row.total)}</TableCell></TableRow>)}</TableBody></Table></div>}
  </div>;
}
