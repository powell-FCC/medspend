import { useState } from 'react';
import { Link } from '@tanstack/react-router';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { AlertCircle, ArrowLeft, CheckCircle2, FileText, Loader2, Plus } from 'lucide-react';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { useActiveOrg } from '@/hooks/use-active-org';
import { approveInvoiceFn, deleteInvoiceItemFn, getInvoiceReviewFn, saveInvoiceHeaderFn, saveInvoiceItemFn } from '@/lib/invoice-processing.functions';
import type { InvoiceHeaderInput, InvoiceItemInput, ReviewItem } from '@/types/invoice-processing';
import { InvoiceHeaderForm } from './InvoiceHeaderForm';
import { InvoiceItemDialog } from './InvoiceItemDialog';
import { ReviewItemsTable } from './ReviewItemsTable';

export function InvoiceReviewPage({ sourceFileId }: { sourceFileId: string }) {
  const { active } = useActiveOrg(); const queryClient = useQueryClient();
  const getReview = useServerFn(getInvoiceReviewFn); const saveHeader = useServerFn(saveInvoiceHeaderFn);
  const saveItem = useServerFn(saveInvoiceItemFn); const deleteItem = useServerFn(deleteInvoiceItemFn); const approve = useServerFn(approveInvoiceFn);
  const [itemOpen, setItemOpen] = useState(false); const [editing, setEditing] = useState<ReviewItem>();
  const [submitting, setSubmitting] = useState(false); const [result, setResult] = useState(''); const [error, setError] = useState('');
  const owner = active?.role === 'owner';
  const review = useQuery({ queryKey: ['invoice-review', active?.organizationId, sourceFileId], queryFn: () => getReview({ data: { sourceFileId, organizationId: active!.organizationId } }), enabled: Boolean(active?.organizationId && owner) });
  const refresh = () => review.refetch();

  async function approveInvoice() {
    if (!active || !review.data) return; setSubmitting(true); setError(''); setResult('');
    try {
      const response = await approve({ data: { sourceFileId, organizationId: active.organizationId } });
      setResult(response.alreadyCompleted ? 'This invoice was already completed.' : `Invoice approved. ${response.createdInventoryItems} inventory item${response.createdInventoryItems === 1 ? '' : 's'} created and ${response.updatedInventoryItems} updated.`);
      await Promise.all([refresh(), queryClient.invalidateQueries({ queryKey: ['inventory', active.organizationId] }), queryClient.invalidateQueries({ queryKey: ['invoice-history', active.organizationId] }), queryClient.invalidateQueries({ queryKey: ['purchase-history', active.organizationId] }), queryClient.invalidateQueries({ queryKey: ['vendor-history', active.organizationId] })]);
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not approve invoice.'); }
    finally { setSubmitting(false); }
  }

  if (!active) return <PageMessage text="Loading invoice review..." />;
  if (!owner) return <div className="mx-auto max-w-3xl px-6 py-16"><Alert variant="destructive"><AlertCircle /><AlertTitle>Owner access required</AlertTitle><AlertDescription>Only organization owners can review invoices.</AlertDescription></Alert></div>;
  if (review.isLoading) return <PageMessage text="Loading invoice review..." busy />;
  if (review.error || !review.data) return <div className="mx-auto max-w-3xl px-6 py-16"><Alert variant="destructive"><AlertCircle /><AlertTitle>Could not load invoice</AlertTitle><AlertDescription>{review.error?.message ?? 'Invoice not found.'}</AlertDescription></Alert></div>;

  const data = review.data; const completed = data.header.status === 'completed';
  const availableMappings = data.header.vendorId ? data.vendorProducts.filter((mapping) => mapping.vendorId === data.header.vendorId) : data.vendorProducts;
  return <div className="mx-auto max-w-7xl px-5 py-8 sm:px-8">
    <Button variant="ghost" size="sm" asChild className="mb-5"><Link to="/invoices"><ArrowLeft className="mr-2 h-4 w-4" />Back to invoices</Link></Button>
    <div className="mb-7 flex flex-wrap items-start justify-between gap-4"><div><p className="text-sm font-medium text-primary">Invoice processing</p><h1 className="mt-1 text-3xl font-semibold tracking-tight">Invoice review</h1><p className="mt-2 text-sm text-muted-foreground">Review invoice details and line items before adding supplies to inventory.</p></div><Badge variant={completed ? 'default' : 'secondary'}>{completed ? 'Completed' : 'Review Required'}</Badge></div>
    <div className="mb-6 flex items-start gap-3 rounded-xl border bg-card p-4"><FileText className="mt-0.5 h-5 w-5 text-primary" /><div><p className="font-medium">{data.header.originalFilename}</p><p className="mt-1 text-xs text-muted-foreground">Uploaded {formatDate(data.header.uploadedAt)}</p></div></div>
    {data.header.extractionStatus === 'succeeded' && <Alert className="mb-5 border-emerald-200 bg-emerald-50"><CheckCircle2 className="text-emerald-700" /><AlertTitle>Invoice details extracted.</AlertTitle><AlertDescription>Review the pre-filled details and line items, then correct anything that does not match the PDF.</AlertDescription></Alert>}
    {data.header.documentTextStatus === 'success' && data.header.extractionStatus !== 'succeeded' && <Alert className="mb-5"><FileText /><AlertTitle>Document text extracted successfully.</AlertTitle><AlertDescription>Invoice structure could not be determined reliably. Manual review remains fully available.</AlertDescription></Alert>}
    {data.header.totalsNeedReview && <Alert className="mb-5 border-amber-200 bg-amber-50/50"><AlertCircle className="text-amber-700" /><AlertTitle>Invoice totals may need review.</AlertTitle><AlertDescription>The line items or subtotal, tax, shipping, and total do not reconcile within rounding tolerance.</AlertDescription></Alert>}
    {data.header.documentTextStatus === 'ocr_required' && <Alert className="mb-5"><FileText /><AlertTitle>OCR is required for this PDF.</AlertTitle><AlertDescription>No usable embedded text was found. Manual review is fully available.</AlertDescription></Alert>}
    {data.header.documentTextStatus === 'failed' && <Alert className="mb-5"><AlertCircle /><AlertTitle>Document text extraction failed.</AlertTitle><AlertDescription>Manual review is still available and every field remains editable.</AlertDescription></Alert>}
    {data.header.documentTextStatus === 'pending' && data.header.extractionStatus === 'not_started' && <Alert className="mb-5"><FileText /><AlertTitle>Ready for review</AlertTitle><AlertDescription>Complete or edit the invoice details manually.</AlertDescription></Alert>}
    {data.header.extractionStatus === 'failed' && data.header.documentTextStatus !== 'failed' && <Alert className="mb-5"><AlertCircle /><AlertTitle>Automatic extraction unavailable</AlertTitle><AlertDescription>The invoice is still ready for manual review. Every field remains editable.</AlertDescription></Alert>}
    <InvoiceHeaderForm header={data.header} vendors={data.vendors} disabled={completed} onSave={async (input: InvoiceHeaderInput) => { await saveHeader({ data: input }); await refresh(); }} />
    <div className="mb-4 mt-8 flex items-center justify-between gap-4"><div><h2 className="text-xl font-semibold">Line items</h2><p className="mt-1 text-sm text-muted-foreground">{data.items.length} item{data.items.length === 1 ? '' : 's'} ready for review</p></div>{!completed && <Button onClick={() => { setEditing(undefined); setItemOpen(true); }}><Plus className="mr-2 h-4 w-4" />Add line item</Button>}</div>
    <ReviewItemsTable items={data.items} completed={completed} onEdit={(item) => { setEditing(item); setItemOpen(true); }} onRemove={async (item) => { if (!window.confirm(`Remove ${item.description} from this invoice?`)) return; setError(''); try { await deleteItem({ data: { id: item.id, sourceFileId, organizationId: active.organizationId } }); await refresh(); } catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not remove line item.'); } }} />
    {!completed && <div className="mt-6 flex flex-wrap items-center justify-between gap-4 rounded-xl border bg-card p-5"><div><p className="font-medium">Ready to update inventory?</p><p className="mt-1 text-sm text-muted-foreground">Approval is final and posts every listed item as received stock.</p></div><Button size="lg" disabled={submitting || !data.items.length || !data.header.vendorName} onClick={approveInvoice}>{submitting && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Approve invoice</Button></div>}
    {error && <Alert variant="destructive" className="mt-5"><AlertCircle /><AlertTitle>Invoice approval failed</AlertTitle><AlertDescription>{error}</AlertDescription></Alert>}
    {result && <Alert className="mt-5 border-emerald-200 bg-emerald-50"><CheckCircle2 className="text-emerald-700" /><AlertTitle>Inventory updated</AlertTitle><AlertDescription>{result}</AlertDescription></Alert>}
    <InvoiceItemDialog open={itemOpen} onOpenChange={setItemOpen} organizationId={active.organizationId} sourceFileId={sourceFileId} item={editing} categories={data.categories} vendorProducts={availableMappings} onSave={async (input: InvoiceItemInput) => { await saveItem({ data: input }); await refresh(); }} />
  </div>;
}

function PageMessage({ text, busy = false }: { text: string; busy?: boolean }) { return <div className="flex min-h-64 items-center justify-center gap-2 text-sm text-muted-foreground">{busy && <Loader2 className="h-4 w-4 animate-spin" />}{text}</div>; }
const formatDate = (value: string) => new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value));
