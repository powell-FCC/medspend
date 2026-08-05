import { useEffect, useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { AlertCircle, CheckCircle2, FileSearch, Loader2 } from 'lucide-react';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { useActiveOrg } from '@/hooks/use-active-org';
import { addApprovedItemsToInventoryFn, getInvoiceReviewFn } from '@/lib/invoice-processing.functions';
import { ReviewItemsTable } from './ReviewItemsTable';

export function InvoiceReviewPage({ sourceFileId }: { sourceFileId: string }) {
  const { active } = useActiveOrg();
  const getReview = useServerFn(getInvoiceReviewFn);
  const addToInventory = useServerFn(addApprovedItemsToInventoryFn);
  const [approved, setApproved] = useState<Set<string>>(new Set());
  const [result, setResult] = useState<string>();
  const [submitting, setSubmitting] = useState(false);
  const owner = active?.role === 'owner';
  const review = useQuery({
    queryKey: ['invoice-review', active?.organizationId, sourceFileId],
    queryFn: () => getReview({ data: { sourceFileId, organizationId: active!.organizationId } }),
    enabled: Boolean(active?.organizationId && owner),
  });
  useEffect(() => { if (review.data) setApproved(new Set(review.data.items.map((item) => item.id))); }, [review.data]);
  const approvedItems = useMemo(() => review.data?.items.filter((item) => approved.has(item.id)) ?? [], [approved, review.data]);

  async function createInventory() {
    if (!review.data || !approvedItems.length) return;
    setSubmitting(true); setResult(undefined);
    try {
      const response = await addToInventory({ data: { sourceFileId, organizationId: review.data.organizationId, items: approvedItems } });
      setResult(`${response.createdInventoryItems} approved item${response.createdInventoryItems === 1 ? '' : 's'} added to inventory.`);
      await review.refetch();
    } catch (error) { setResult(error instanceof Error ? error.message : 'Could not create inventory items.'); }
    finally { setSubmitting(false); }
  }

  if (!active) return null;
  if (!owner) return <div className="mx-auto max-w-3xl px-6 py-16"><Alert variant="destructive"><AlertCircle /><AlertTitle>Owner access required</AlertTitle><AlertDescription>Only organization owners can review invoices.</AlertDescription></Alert></div>;
  if (review.isLoading) return <div className="flex min-h-64 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-primary" /></div>;
  if (review.error || !review.data) return <div className="mx-auto max-w-3xl px-6 py-16"><Alert variant="destructive"><AlertCircle /><AlertTitle>Could not load invoice</AlertTitle><AlertDescription>{review.error?.message ?? 'Invoice not found.'}</AlertDescription></Alert></div>;

  const data = review.data;
  return <div className="mx-auto max-w-6xl px-5 py-8 sm:px-8">
    <div className="mb-7"><p className="text-sm font-medium text-primary">Invoice processing</p><h1 className="mt-1 text-3xl font-semibold tracking-tight">Invoice review</h1><p className="mt-2 text-sm text-muted-foreground">Review placeholder data before creating inventory records.</p></div>
    <Alert className="mb-6 border-amber-200 bg-amber-50"><FileSearch className="text-amber-700" /><AlertTitle>Extraction is not enabled</AlertTitle><AlertDescription>The item below is mock data for validating the review workflow. No information was extracted from the PDF.</AlertDescription></Alert>
    <Card className="mb-6"><CardHeader><div className="flex flex-wrap items-center justify-between gap-3"><CardTitle>{data.originalFilename}</CardTitle><Badge variant={data.status === 'completed' ? 'default' : 'secondary'}>{data.status === 'review_required' ? 'Awaiting Review' : data.status.replace('_', ' ')}</Badge></div></CardHeader>
      <CardContent className="grid gap-4 text-sm sm:grid-cols-4"><div><p className="text-muted-foreground">Vendor</p><p className="font-medium">{data.vendorName ?? 'Pending extraction'}</p></div><div><p className="text-muted-foreground">Invoice number</p><p className="font-medium">{data.invoiceNumber ?? 'Pending extraction'}</p></div><div><p className="text-muted-foreground">Date</p><p className="font-medium">{data.invoiceDate ?? 'Pending extraction'}</p></div><div><p className="text-muted-foreground">Items detected</p><p className="font-medium">{data.items.length} mock item</p></div></CardContent>
    </Card>
    <ReviewItemsTable items={data.items} approved={approved} onChange={(id, value) => setApproved((current) => { const next = new Set(current); value ? next.add(id) : next.delete(id); return next; })} />
    <div className="mt-6 flex flex-wrap items-center justify-between gap-4"><p className="text-sm text-muted-foreground">{approvedItems.length} of {data.items.length} items approved</p><Button size="lg" disabled={!approvedItems.length || submitting || data.status === 'completed'} onClick={createInventory}>{submitting && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Add Approved Items To Inventory</Button></div>
    {result && <Alert className="mt-5"><CheckCircle2 /><AlertTitle>Inventory update</AlertTitle><AlertDescription>{result}</AlertDescription></Alert>}
  </div>;
}
