import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { useRouter } from '@tanstack/react-router';
import { AlertCircle, CheckCircle2, FileStack, Loader2, ShieldCheck } from 'lucide-react';
import { Link } from '@tanstack/react-router';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Progress } from '@/components/ui/progress';
import { useActiveOrg } from '@/hooks/use-active-org';
import { listVendorInvoicesFn } from '@/lib/vendor-invoices.functions';
import { intakeInvoiceUploadFn, listInvoiceBatchesFn } from '@/lib/invoice-batches.functions';
import { deleteVendorInvoice, uploadVendorInvoice, validateInvoiceFile } from '@/storage/vendor-invoices';
import { rollbackUploadedInvoice } from '@/storage/upload-rollback';
import { InvoiceDropzone } from './InvoiceDropzone';
import { InvoiceTable } from './InvoiceTable';

type UploadState =
  | { kind: 'idle' }
  | { kind: 'uploading'; filename: string; progress: number }
  | { kind: 'analyzing'; filename: string }
  | { kind: 'success'; filename: string; invoiceId: string }
  | { kind: 'packet'; filename: string; batchId: string; invoiceCount: number; pageCount: number; existing: boolean }
  | { kind: 'error'; message: string };

export function InvoiceUploadPage() {
  const { active } = useActiveOrg();
  const listInvoices = useServerFn(listVendorInvoicesFn);
  const intakeUpload = useServerFn(intakeInvoiceUploadFn);
  const listBatches = useServerFn(listInvoiceBatchesFn);
  const queryClient = useQueryClient();
  const router = useRouter();
  const [uploadState, setUploadState] = useState<UploadState>({ kind: 'idle' });
  const organizationId = active?.organizationId;
  const owner = active?.role === 'owner';
  const queryKey = ['vendor-invoices', organizationId];

  const invoices = useQuery({
    queryKey,
    queryFn: () => listInvoices({ data: { organizationId: organizationId! } }),
    enabled: Boolean(organizationId && owner),
  });
  const batches = useQuery({
    queryKey: ['invoice-batches', organizationId],
    queryFn: () => listBatches({ data: { organizationId: organizationId! } }),
    enabled: Boolean(organizationId && owner),
  });

  async function upload(file: File) {
    if (!organizationId || !owner) return;
    const validationError = validateInvoiceFile(file);
    if (validationError) { setUploadState({ kind: 'error', message: validationError }); return; }

    setUploadState({ kind: 'uploading', filename: file.name, progress: 5 });
    let storagePath: string | undefined;
    try {
      storagePath = await uploadVendorInvoice(organizationId, file, (progress) =>
        setUploadState({ kind: 'uploading', filename: file.name, progress }),
      );
      setUploadState({ kind: 'analyzing', filename: file.name });
      // One invoice: recorded exactly as before. Two or more invoices in one PDF: a packet.
      const intake = await intakeUpload({
        data: {
          organizationId,
          storagePath,
          originalFilename: file.name,
          fileSize: file.size,
          mimeType: 'application/pdf',
        },
      });
      await queryClient.invalidateQueries({ queryKey });
      if (intake.kind === 'batch') {
        await queryClient.invalidateQueries({ queryKey: ['invoice-batches', organizationId] });
        setUploadState({ kind: 'packet', filename: file.name, batchId: intake.batchId, invoiceCount: intake.invoiceCount, pageCount: intake.pageCount, existing: intake.existing });
        window.setTimeout(() => router.navigate({ to: '/invoices/batches/$batchId', params: { batchId: intake.batchId } }), 900);
        return;
      }
      setUploadState({ kind: 'uploading', filename: file.name, progress: 100 });
      setUploadState({ kind: 'success', filename: file.name, invoiceId: intake.invoice.id });
      window.setTimeout(() => router.navigate({ to: '/invoices/$invoiceId', params: { invoiceId: intake.invoice.id } }), 900);
    } catch (error) {
      if (storagePath) {
        try {
          await rollbackUploadedInvoice(storagePath, error, deleteVendorInvoice);
        } catch (rollbackError) { error = rollbackError; }
      }
      const message = error instanceof Error ? error.message : 'Upload failed. Try again.';
      setUploadState({ kind: 'error', message });
    }
  }

  if (!active) return null;
  if (!owner) {
    return <div className="mx-auto max-w-3xl px-6 py-16"><Alert variant="destructive"><AlertCircle /><AlertTitle>Owner access required</AlertTitle><AlertDescription>Only organization owners can upload or view vendor invoices.</AlertDescription></Alert></div>;
  }

  const busy = uploadState.kind === 'uploading' || uploadState.kind === 'analyzing';
  return (
    <div className="mx-auto max-w-6xl px-5 py-8 sm:px-8" data-page="invoice-upload">
      <div className="mb-8 flex flex-wrap items-start justify-between gap-4">
        <div><p className="text-sm font-medium text-primary">Owner workspace</p><h1 className="mt-1 text-3xl font-semibold tracking-tight">Upload invoice</h1><p className="mt-2 text-sm text-muted-foreground">Securely store vendor invoice PDFs for {active.organizationName}.</p></div>
        <div className="flex items-center gap-2 rounded-full border bg-card px-3 py-2 text-xs text-muted-foreground"><ShieldCheck className="h-4 w-4 text-primary" />Private organization storage</div>
      </div>

      <InvoiceDropzone disabled={busy} onSelect={upload} />

      <div className="my-5 min-h-20" aria-live="polite">
        {uploadState.kind === 'uploading' && <div className="rounded-xl border bg-card p-4"><div className="mb-3 flex items-center justify-between gap-3 text-sm"><span className="flex min-w-0 items-center gap-2 font-medium"><Loader2 className="h-4 w-4 animate-spin" /><span className="truncate">Uploading {uploadState.filename}</span></span><span>{uploadState.progress}%</span></div><Progress value={uploadState.progress} /></div>}
        {uploadState.kind === 'analyzing' && <div className="rounded-xl border bg-card p-4 text-sm"><span className="flex min-w-0 items-center gap-2 font-medium"><Loader2 className="h-4 w-4 shrink-0 animate-spin" /><span className="truncate">Analyzing {uploadState.filename}…</span></span><p className="mt-1 text-xs text-muted-foreground">Checking whether this PDF holds more than one invoice.</p></div>}
        {uploadState.kind === 'packet' && <Alert className="border-emerald-200 bg-emerald-50 text-emerald-950"><FileStack className="text-emerald-700" /><AlertTitle>{uploadState.existing ? 'This packet was already uploaded' : `${uploadState.invoiceCount} invoices detected`}</AlertTitle><AlertDescription>{uploadState.existing ? 'Opening the packet you uploaded before. Nothing was added twice.' : `${uploadState.filename} has ${uploadState.pageCount} pages. Opening the packet…`}</AlertDescription></Alert>}
        {uploadState.kind === 'success' && <Alert className="border-emerald-200 bg-emerald-50 text-emerald-950"><CheckCircle2 className="text-emerald-600" /><AlertTitle>Invoice Uploaded Successfully</AlertTitle><AlertDescription>{uploadState.filename} is securely stored. Status: Processing. Opening invoice review…</AlertDescription></Alert>}
        {uploadState.kind === 'error' && <Alert variant="destructive"><AlertCircle /><AlertTitle>Upload failed</AlertTitle><AlertDescription>{uploadState.message}</AlertDescription></Alert>}
      </div>

      {invoices.error && <Alert variant="destructive" className="mb-5"><AlertCircle /><AlertTitle>Could not load invoices</AlertTitle><AlertDescription>{invoices.error.message}</AlertDescription></Alert>}
      {(batches.data?.length ?? 0) > 0 && (
        <section className="mb-5 rounded-xl border bg-card" data-testid="recent-packets">
          <div className="border-b px-5 py-4"><h2 className="font-semibold">Invoice packets</h2><p className="mt-1 text-sm text-muted-foreground">PDFs that held more than one invoice.</p></div>
          <ul className="divide-y">
            {batches.data!.map((batch) => (
              <li key={batch.id} className="flex flex-wrap items-center justify-between gap-3 px-5 py-3 text-sm">
                <span className="flex min-w-0 items-center gap-2"><FileStack className="h-4 w-4 shrink-0 text-muted-foreground" /><span className="truncate font-medium">{batch.originalFilename}</span></span>
                <span className="flex items-center gap-3 text-muted-foreground">{batch.invoiceCount} invoices · {batch.pageCount} pages<Link className="font-medium text-primary underline-offset-2 hover:underline" to="/invoices/batches/$batchId" params={{ batchId: batch.id }}>Open</Link></span>
              </li>
            ))}
          </ul>
        </section>
      )}
      <InvoiceTable invoices={invoices.data ?? []} />
    </div>
  );
}
