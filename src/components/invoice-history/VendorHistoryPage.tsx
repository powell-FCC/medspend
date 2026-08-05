import { useQuery } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { Building2 } from 'lucide-react';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useActiveOrg } from '@/hooks/use-active-org';
import { listVendorHistoryFn } from '@/lib/invoice-history.functions';
import { EmptyState, OwnerRequired, PageHeading } from './InvoiceListPage';

export function VendorHistoryPage() {
  const { active } = useActiveOrg(); const list = useServerFn(listVendorHistoryFn); const owner = active?.role === 'owner';
  const vendors = useQuery({ queryKey: ['vendor-history', active?.organizationId], queryFn: () => list({ data: { organizationId: active!.organizationId } }), enabled: Boolean(active?.organizationId && owner) });
  if (!active) return null; if (!owner) return <OwnerRequired message="Only organization owners can view invoice vendor history." />;
  return <div className="mx-auto max-w-5xl px-5 py-8 sm:px-8"><PageHeading title="Vendors" subtitle="Vendors identified from processed invoice history." />
    {vendors.error && <p role="alert" className="mb-5 text-sm text-destructive">{vendors.error.message}</p>}
    {!vendors.isLoading && !vendors.data?.length ? <EmptyState icon={<Building2 className="h-6 w-6" />} title="No vendors found" text="Vendor history will appear after invoice details are reviewed." /> : <div className="overflow-hidden rounded-xl border bg-card"><Table><TableHeader><TableRow><TableHead>Vendor Name</TableHead><TableHead>Invoices</TableHead><TableHead>Last Purchase Date</TableHead></TableRow></TableHeader><TableBody>{vendors.data?.map((vendor) => <TableRow key={vendor.vendorName}><TableCell className="font-medium">{vendor.vendorName}</TableCell><TableCell>{vendor.invoiceCount}</TableCell><TableCell>{vendor.lastPurchaseDate ? new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' }).format(new Date(vendor.lastPurchaseDate)) : '—'}</TableCell></TableRow>)}</TableBody></Table></div>}
  </div>;
}
