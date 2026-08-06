import { useState } from 'react';
import { Link } from '@tanstack/react-router';
import { useQuery } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { AlertCircle, FileText } from 'lucide-react';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useActiveOrg } from '@/hooks/use-active-org';
import { invoiceReviewParams } from '@/invoice/review-route';
import { listInvoiceHistoryFn } from '@/lib/invoice-history.functions';

const statusLabel = { uploaded: 'Uploaded', processing: 'Processing', review_required: 'Review Required', completed: 'Completed', failed: 'Failed' };
const statusTone = { uploaded: 'bg-slate-100 text-slate-700', processing: 'bg-blue-100 text-blue-800', review_required: 'bg-amber-100 text-amber-800', completed: 'bg-emerald-100 text-emerald-800', failed: 'bg-red-100 text-red-800' };

export function InvoiceListPage() {
  const { active } = useActiveOrg(); const list = useServerFn(listInvoiceHistoryFn); const [details, setDetails] = useState<string>();
  const owner = active?.role === 'owner'; const invoices = useQuery({ queryKey: ['invoice-history', active?.organizationId], queryFn: () => list({ data: { organizationId: active!.organizationId } }), enabled: Boolean(active?.organizationId && owner) });
  if (!active) return null;
  if (!owner) return <OwnerRequired message="Only organization owners can view invoice processing history." />;
  return <div className="mx-auto max-w-7xl px-5 py-8 sm:px-8"><PageHeading title="Invoices" subtitle="Review uploaded vendor invoices and inventory processing status." />
    {invoices.error && <Alert variant="destructive" className="mb-5"><AlertCircle /><AlertTitle>Could not load invoices</AlertTitle><AlertDescription>{invoices.error.message}</AlertDescription></Alert>}
    {!invoices.isLoading && !invoices.data?.length ? <EmptyState icon={<FileText className="h-6 w-6" />} title="No invoices uploaded yet" text="Uploaded vendor invoices will appear here." /> : <div className="overflow-hidden rounded-xl border bg-card"><Table><TableHeader><TableRow><TableHead>Filename</TableHead><TableHead>Vendor</TableHead><TableHead>Uploaded Date</TableHead><TableHead>Status</TableHead><TableHead>Items Processed</TableHead><TableHead className="text-right">Actions</TableHead></TableRow></TableHeader><TableBody>
      {invoices.data?.map((invoice) => <><TableRow key={invoice.vendorInvoiceId}><TableCell className="max-w-72 truncate font-medium">{invoice.filename}</TableCell><TableCell>{invoice.vendor ?? 'Pending extraction'}</TableCell><TableCell>{formatDate(invoice.uploadedAt)}</TableCell><TableCell><Badge className={statusTone[invoice.status]}>{statusLabel[invoice.status]}</Badge></TableCell><TableCell>{invoice.itemsProcessed}</TableCell><TableCell><div className="flex justify-end gap-2"><Button size="sm" variant="outline" asChild><Link to="/invoices/$invoiceId" params={invoiceReviewParams(invoice.vendorInvoiceId)}>View Review</Link></Button><Button size="sm" variant="ghost" onClick={() => setDetails(details === invoice.vendorInvoiceId ? undefined : invoice.vendorInvoiceId)}>View Details</Button></div></TableCell></TableRow>
        {details === invoice.vendorInvoiceId && <TableRow key={`${invoice.vendorInvoiceId}-details`}><TableCell colSpan={6}><div className="grid gap-3 rounded-lg bg-muted/50 p-4 text-xs sm:grid-cols-3"><div><span className="text-muted-foreground">Storage path</span><p className="mt-1 break-all font-mono">{invoice.storagePath}</p></div><div><span className="text-muted-foreground">File size</span><p className="mt-1 font-medium">{formatSize(invoice.fileSize)}</p></div><div><span className="text-muted-foreground">Processing result</span><p className="mt-1 font-medium">{invoice.itemsProcessed} item{invoice.itemsProcessed === 1 ? '' : 's'}</p></div></div></TableCell></TableRow>}
      </>)}
    </TableBody></Table></div>}
  </div>;
}

export function PageHeading({ title, subtitle }: { title: string; subtitle: string }) { return <div className="mb-7"><p className="text-sm font-medium text-primary">Owner workspace</p><h1 className="mt-1 text-3xl font-semibold tracking-tight">{title}</h1><p className="mt-2 text-sm text-muted-foreground">{subtitle}</p></div>; }
export function EmptyState({ icon, title, text }: { icon: React.ReactNode; title: string; text: string }) { return <div className="rounded-xl border border-dashed bg-card px-6 py-16 text-center"><div className="mx-auto mb-3 flex h-11 w-11 items-center justify-center rounded-full bg-muted text-muted-foreground">{icon}</div><p className="font-medium">{title}</p><p className="mt-1 text-sm text-muted-foreground">{text}</p></div>; }
export function OwnerRequired({ message }: { message: string }) { return <div className="mx-auto max-w-3xl px-6 py-16"><Alert variant="destructive"><AlertCircle /><AlertTitle>Owner access required</AlertTitle><AlertDescription>{message}</AlertDescription></Alert></div>; }
const formatDate = (value: string) => new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' }).format(new Date(value));
const formatSize = (value: number) => value >= 1024 * 1024 ? `${(value / 1024 / 1024).toFixed(1)} MB` : `${Math.ceil(value / 1024)} KB`;
