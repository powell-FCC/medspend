import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { AlertCircle, CheckCircle2, Loader2, ShieldCheck } from 'lucide-react';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Progress } from '@/components/ui/progress';
import { useActiveOrg } from '@/hooks/use-active-org';
import { listVendorInvoicesFn, recordVendorInvoiceFn } from '@/lib/vendor-invoices.functions';
import { deleteVendorInvoice, uploadVendorInvoice, validateInvoiceFile } from '@/storage/vendor-invoices';
import { rollbackUploadedInvoice } from '@/storage/upload-rollback';
import { InvoiceDropzone } from './InvoiceDropzone';
import { InvoiceTable } from './InvoiceTable';

type UploadState =
  | { kind: 'idle' }
  | { kind: 'uploading'; filename: string; progress: number }
  | { kind: 'success'; filename: string }
  | { kind: 'error'; message: string };

export function InvoiceUploadPage() {
  const { active } = useActiveOrg();
  const listInvoices = useServerFn(listVendorInvoicesFn);
  const recordInvoice = useServerFn(recordVendorInvoiceFn);
  const queryClient = useQueryClient();
  const [uploadState, setUploadState] = useState<UploadState>({ kind: 'idle' });
  const organizationId = active?.organizationId;
  const owner = active?.role === 'owner';
  const queryKey = ['vendor-invoices', organizationId];

  const invoices = useQuery({
    queryKey,
    queryFn: () => listInvoices({ data: { organizationId: organizationId! } }),
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
      await recordInvoice({
        data: {
          organizationId,
          storagePath,
          originalFilename: file.name,
          fileSize: file.size,
          mimeType: 'application/pdf',
        },
      });
      setUploadState({ kind: 'uploading', filename: file.name, progress: 100 });
      await queryClient.invalidateQueries({ queryKey });
      setUploadState({ kind: 'success', filename: file.name });
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

  const busy = uploadState.kind === 'uploading';
  return (
    <div className="mx-auto max-w-6xl px-5 py-8 sm:px-8" data-page="invoice-upload">
      <div className="mb-8 flex flex-wrap items-start justify-between gap-4">
        <div><p className="text-sm font-medium text-primary">Owner workspace</p><h1 className="mt-1 text-3xl font-semibold tracking-tight">Upload invoice</h1><p className="mt-2 text-sm text-muted-foreground">Securely store vendor invoice PDFs for {active.organizationName}.</p></div>
        <div className="flex items-center gap-2 rounded-full border bg-card px-3 py-2 text-xs text-muted-foreground"><ShieldCheck className="h-4 w-4 text-primary" />Private organization storage</div>
      </div>

      <InvoiceDropzone disabled={busy} onSelect={upload} />

      <div className="my-5 min-h-20" aria-live="polite">
        {uploadState.kind === 'uploading' && <div className="rounded-xl border bg-card p-4"><div className="mb-3 flex items-center justify-between gap-3 text-sm"><span className="flex min-w-0 items-center gap-2 font-medium"><Loader2 className="h-4 w-4 animate-spin" /><span className="truncate">Uploading {uploadState.filename}</span></span><span>{uploadState.progress}%</span></div><Progress value={uploadState.progress} /></div>}
        {uploadState.kind === 'success' && <Alert className="border-emerald-200 bg-emerald-50 text-emerald-950"><CheckCircle2 className="text-emerald-600" /><AlertTitle>Invoice uploaded</AlertTitle><AlertDescription>{uploadState.filename} is securely stored and ready for future processing.</AlertDescription></Alert>}
        {uploadState.kind === 'error' && <Alert variant="destructive"><AlertCircle /><AlertTitle>Upload failed</AlertTitle><AlertDescription>{uploadState.message}</AlertDescription></Alert>}
      </div>

      {invoices.error && <Alert variant="destructive" className="mb-5"><AlertCircle /><AlertTitle>Could not load invoices</AlertTitle><AlertDescription>{invoices.error.message}</AlertDescription></Alert>}
      <InvoiceTable invoices={invoices.data ?? []} />
    </div>
  );
}
