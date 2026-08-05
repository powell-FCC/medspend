import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import type { InvoiceHeaderInput, InvoiceReviewHeader, InvoiceReviewVendor } from '@/types/invoice-processing';

type HeaderForm = {
  vendorId: string;
  vendorName: string;
  invoiceNumber: string;
  invoiceDate: string;
  invoiceTotal: string;
};

export function InvoiceHeaderForm({ header, vendors, disabled, onSave }: {
  header: InvoiceReviewHeader;
  vendors: InvoiceReviewVendor[];
  disabled: boolean;
  onSave: (input: InvoiceHeaderInput) => Promise<void>;
}) {
  const [form, setForm] = useState<HeaderForm>(() => fromHeader(header));
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState('');
  useEffect(() => setForm(fromHeader(header)), [header]);
  const update = (key: keyof HeaderForm, value: string) => setForm((current) => ({ ...current, [key]: value }));
  async function submit(event: React.FormEvent) {
    event.preventDefault(); setSaving(true); setMessage('');
    try {
      await onSave({
        organizationId: header.organizationId,
        sourceFileId: header.sourceFileId,
        vendorId: form.vendorId || null,
        vendorName: form.vendorName,
        invoiceNumber: form.invoiceNumber,
        invoiceDate: form.invoiceDate,
        invoiceTotal: form.invoiceTotal === '' ? null : Number(form.invoiceTotal),
      });
      setMessage('Invoice details saved.');
    } catch (error) { setMessage(error instanceof Error ? error.message : 'Could not save invoice details.'); }
    finally { setSaving(false); }
  }
  return <form onSubmit={submit} className="rounded-xl border bg-card p-5">
    <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
      <Field label="Existing vendor"><select disabled={disabled} className="h-9 w-full rounded-md border bg-background px-3 text-sm" value={form.vendorId} onChange={(event) => { const vendor = vendors.find((candidate) => candidate.id === event.target.value); setForm((current) => ({ ...current, vendorId: event.target.value, vendorName: vendor?.name ?? current.vendorName })); }}><option value="">New or unlinked vendor</option>{vendors.map((vendor) => <option key={vendor.id} value={vendor.id}>{vendor.name}</option>)}</select></Field>
      <Field label="Vendor"><Input disabled={disabled || Boolean(form.vendorId)} value={form.vendorName} onChange={(event) => update('vendorName', event.target.value)} required /></Field>
      <Field label="Invoice number"><Input disabled={disabled} value={form.invoiceNumber} onChange={(event) => update('invoiceNumber', event.target.value)} /></Field>
      <Field label="Invoice date"><Input disabled={disabled} type="date" value={form.invoiceDate} onChange={(event) => update('invoiceDate', event.target.value)} /></Field>
      <Field label="Invoice total"><Input disabled={disabled} type="number" min="0" step="0.01" value={form.invoiceTotal} onChange={(event) => update('invoiceTotal', event.target.value)} /></Field>
    </div>
    {!disabled && <div className="mt-5 flex items-center gap-3"><Button disabled={saving}>{saving ? 'Saving...' : 'Save invoice details'}</Button>{message && <p role="status" className="text-sm text-muted-foreground">{message}</p>}</div>}
  </form>;
}

const fromHeader = (header: InvoiceReviewHeader): HeaderForm => ({ vendorId: header.vendorId ?? '', vendorName: header.vendorName, invoiceNumber: header.invoiceNumber, invoiceDate: header.invoiceDate, invoiceTotal: header.invoiceTotal?.toString() ?? '' });
function Field({ label, children }: { label: string; children: React.ReactNode }) { return <div><Label className="mb-2 block">{label}</Label>{children}</div>; }

