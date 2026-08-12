import { Fragment, useState } from 'react';
import { Link } from '@tanstack/react-router';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { AlertCircle, FileText, Trash2 } from 'lucide-react';
import { toast } from 'sonner';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { AlertDialog, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from '@/components/ui/alert-dialog';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useActiveOrg } from '@/hooks/use-active-org';
import { invoiceReviewParams } from '@/invoice/review-route';
import { documentTypeLabel } from '@/invoice/deletion';
import { deleteInvoiceFn, listInvoiceHistoryFn } from '@/lib/invoice-history.functions';
import type { InvoiceHistoryRow } from '@/types/invoice-history';

const statusLabel = { uploaded: 'Uploaded', processing: 'Processing', review_required: 'Review Required', completed: 'Completed', failed: 'Failed' };
const statusTone = { uploaded: 'bg-slate-100 text-slate-700', processing: 'bg-blue-100 text-blue-800', review_required: 'bg-amber-100 text-amber-800', completed: 'bg-emerald-100 text-emerald-800', failed: 'bg-red-100 text-red-800' };

export function InvoiceListPage() {
  const { active } = useActiveOrg(); const list = useServerFn(listInvoiceHistoryFn); const remove = useServerFn(deleteInvoiceFn);
  const [details, setDetails] = useState<string>(); const [selected, setSelected] = useState<InvoiceHistoryRow>();
  const queryClient = useQueryClient(); const owner = active?.role === 'owner'; const queryKey = ['invoice-history', active?.organizationId];
  const invoices = useQuery({ queryKey, queryFn: () => list({ data: { organizationId: active!.organizationId } }), enabled: Boolean(active?.organizationId && owner) });
  const deletion = useMutation({ mutationFn: (invoice: InvoiceHistoryRow) => remove({ data: { organizationId: active!.organizationId, invoiceId: invoice.vendorInvoiceId } }),
    onSuccess: (result, invoice) => { queryClient.setQueryData<InvoiceHistoryRow[]>(queryKey, (current) => current?.filter((row) => row.vendorInvoiceId !== invoice.vendorInvoiceId));
      setDetails(undefined); setSelected(undefined);
      for (const key of ['invoice-history', 'purchase-history', 'vendor-history', 'inventory-intelligence', 'inventory']) void queryClient.invalidateQueries({ queryKey: [key, active?.organizationId] });
      result.warning ? toast.warning(result.warning) : toast.success(`${capitalize(documentTypeLabel(invoice.documentType))} permanently deleted.`); },
  });
  if (!active) return null;
  if (!owner) return <OwnerRequired message="Only organization owners can view invoice processing history." />;
  return <div className="mx-auto max-w-7xl px-5 py-8 sm:px-8"><PageHeading title="Invoices" subtitle="Review uploaded vendor invoices and inventory processing status." />
    {invoices.error && <Alert variant="destructive" className="mb-5"><AlertCircle /><AlertTitle>Could not load invoices</AlertTitle><AlertDescription>{invoices.error.message}</AlertDescription></Alert>}
    {!invoices.isLoading && !invoices.data?.length ? <EmptyState icon={<FileText className="h-6 w-6" />} title="No invoices uploaded yet" text="Uploaded vendor invoices will appear here." /> : <div className="overflow-hidden rounded-xl border bg-card"><Table><TableHeader><TableRow><TableHead>Filename</TableHead><TableHead>Vendor</TableHead><TableHead>Uploaded Date</TableHead><TableHead>Status</TableHead><TableHead>Items Processed</TableHead><TableHead className="text-right">Actions</TableHead></TableRow></TableHeader><TableBody>
      {invoices.data?.map((invoice) => <Fragment key={invoice.vendorInvoiceId}><TableRow><TableCell className="max-w-72 truncate font-medium">{invoice.filename}</TableCell><TableCell>{invoice.vendor ?? 'Pending extraction'}</TableCell><TableCell>{formatDate(invoice.uploadedAt)}</TableCell><TableCell><Badge className={statusTone[invoice.status]}>{statusLabel[invoice.status]}</Badge></TableCell><TableCell>{invoice.itemsProcessed}</TableCell><TableCell><div className="flex justify-end gap-2"><Button size="sm" variant="outline" asChild><Link to="/invoices/$invoiceId" params={invoiceReviewParams(invoice.vendorInvoiceId)}>View Review</Link></Button><Button size="sm" variant="ghost" onClick={() => setDetails(details === invoice.vendorInvoiceId ? undefined : invoice.vendorInvoiceId)}>View Details</Button><Button size="sm" variant="ghost" className="text-destructive hover:text-destructive" disabled={!invoice.deletionEligibility.eligible} title={invoice.deletionEligibility.reason ?? `Delete ${documentTypeLabel(invoice.documentType)}`} onClick={() => { deletion.reset(); setSelected(invoice); }}><Trash2 className="mr-1 h-4 w-4" />Delete</Button></div></TableCell></TableRow>
        {details === invoice.vendorInvoiceId && <TableRow key={`${invoice.vendorInvoiceId}-details`}><TableCell colSpan={6}><div className="grid gap-3 rounded-lg bg-muted/50 p-4 text-xs sm:grid-cols-3"><div><span className="text-muted-foreground">Storage path</span><p className="mt-1 break-all font-mono">{invoice.storagePath}</p></div><div><span className="text-muted-foreground">File size</span><p className="mt-1 font-medium">{formatSize(invoice.fileSize)}</p></div><div><span className="text-muted-foreground">Processing result</span><p className="mt-1 font-medium">{invoice.itemsProcessed} item{invoice.itemsProcessed === 1 ? '' : 's'}</p></div></div></TableCell></TableRow>}
      </Fragment>)}
    </TableBody></Table></div>}
    <AlertDialog open={Boolean(selected)} onOpenChange={(open) => { if (!open && !deletion.isPending) setSelected(undefined); }}><AlertDialogContent><AlertDialogHeader>
      <AlertDialogTitle>Permanently delete {selected?.posted ? 'posted ' : ''}{selected ? documentTypeLabel(selected.documentType) : 'uploaded document'}?</AlertDialogTitle>
      <AlertDialogDescription>{selected?.posted ? 'This document has already affected MedSpend data. Deleting it will permanently remove the document and reconcile its inventory receipts, purchasing history, price history, and spend totals.' : 'This will permanently remove this uploaded document and its processing history.'} After deletion, MedSpend will behave as though this document was never uploaded. This cannot be undone.</AlertDialogDescription>
    </AlertDialogHeader>{selected && <div className="rounded-lg bg-muted/50 p-4 text-sm"><p className="font-medium">{selected.vendor ?? selected.filename}</p>{selected.documentNumber && <p>{selected.documentNumber}</p>}{selected.total !== null && <p>{formatCurrency(selected.total)}</p>}<p className="text-muted-foreground">{selected.documentDate ? formatDate(selected.documentDate) : formatDate(selected.uploadedAt)}</p>{selected.posted && <div className="mt-3 border-t pt-3 text-muted-foreground"><p>{selected.itemsProcessed} invoice line{selected.itemsProcessed === 1 ? '' : 's'} will be removed.</p><p>Inventory and purchase history will be reconciled transactionally.</p></div>}</div>}
      {deletion.error && <Alert variant="destructive"><AlertCircle /><AlertTitle>Could not delete document</AlertTitle><AlertDescription>{deletion.error.message}</AlertDescription></Alert>}
      <AlertDialogFooter><AlertDialogCancel disabled={deletion.isPending}>Cancel</AlertDialogCancel><Button variant="destructive" disabled={!selected || deletion.isPending} onClick={() => selected && deletion.mutate(selected)}>{deletion.isPending ? 'Deleting…' : 'Delete Permanently'}</Button></AlertDialogFooter>
    </AlertDialogContent></AlertDialog>
  </div>;
}

export function PageHeading({ title, subtitle }: { title: string; subtitle: string }) { return <div className="mb-7"><p className="text-sm font-medium text-primary">Owner workspace</p><h1 className="mt-1 text-3xl font-semibold tracking-tight">{title}</h1><p className="mt-2 text-sm text-muted-foreground">{subtitle}</p></div>; }
export function EmptyState({ icon, title, text }: { icon: React.ReactNode; title: string; text: string }) { return <div className="rounded-xl border border-dashed bg-card px-6 py-16 text-center"><div className="mx-auto mb-3 flex h-11 w-11 items-center justify-center rounded-full bg-muted text-muted-foreground">{icon}</div><p className="font-medium">{title}</p><p className="mt-1 text-sm text-muted-foreground">{text}</p></div>; }
export function OwnerRequired({ message }: { message: string }) { return <div className="mx-auto max-w-3xl px-6 py-16"><Alert variant="destructive"><AlertCircle /><AlertTitle>Owner access required</AlertTitle><AlertDescription>{message}</AlertDescription></Alert></div>; }
const formatDate = (value: string) => new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' }).format(new Date(value));
const formatSize = (value: number) => value >= 1024 * 1024 ? `${(value / 1024 / 1024).toFixed(1)} MB` : `${Math.ceil(value / 1024)} KB`;
const formatCurrency = (value: number) => new Intl.NumberFormat(undefined, { style: 'currency', currency: 'USD' }).format(value);
const capitalize = (value: string) => value.charAt(0).toUpperCase() + value.slice(1);
