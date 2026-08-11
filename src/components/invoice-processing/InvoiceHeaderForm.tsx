import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import type { InvoiceHeaderInput, InvoiceReviewHeader, InvoiceReviewVendor } from '@/types/invoice-processing';

type HeaderForm = {
  vendorId: string;
  vendorName: string;
  documentType: InvoiceReviewHeader['documentType'];
  orderNumber: string;
  orderDate: string;
  invoiceNumber: string;
  invoiceDate: string;
  invoiceTotal: string;
  purchaseOrder: string;
  subtotal: string;
  tax: string;
  shipping: string;
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
        documentType: form.documentType,
        orderNumber: form.orderNumber,
        orderDate: form.orderDate,
        invoiceNumber: form.invoiceNumber,
        invoiceDate: form.invoiceDate,
        invoiceTotal: form.invoiceTotal === '' ? null : Number(form.invoiceTotal),
        purchaseOrder: form.purchaseOrder,
        subtotal: numberOrNull(form.subtotal),
        tax: numberOrNull(form.tax),
        shipping: numberOrNull(form.shipping),
      });
      setMessage('Invoice details saved.');
    } catch (error) { setMessage(error instanceof Error ? error.message : 'Could not save invoice details.'); }
    finally { setSaving(false); }
  }
  return <form onSubmit={submit} className="rounded-xl border bg-card p-5">
    {header.vendorMatchState === 'SUGGESTED' && header.suggestedVendorId && <div className="mb-4 flex items-center justify-between gap-3 rounded-lg border border-amber-200 bg-amber-50/50 p-3 text-sm"><span>Suggested vendor: <strong>{header.suggestedVendorName}</strong></span><Button type="button" size="sm" variant="outline" onClick={() => setForm((current) => ({ ...current, vendorId: header.suggestedVendorId ?? '', vendorName: header.suggestedVendorName }))}>Use vendor</Button></div>}
    <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
      <Field label="Document"><select disabled={disabled} className="h-9 w-full rounded-md border bg-background px-3 text-sm" value={form.documentType} onChange={(event) => update('documentType', event.target.value as HeaderForm['documentType'])}><option value="INVOICE">Invoice</option><option value="ORDER_CONFIRMATION">Order Confirmation</option><option value="PURCHASE_ORDER">Purchase Order</option><option value="CREDIT_MEMO">Credit Memo</option><option value="STATEMENT">Statement</option><option value="UNKNOWN">Unknown</option></select></Field>
      <Field label="Existing vendor"><select disabled={disabled} className="h-9 w-full rounded-md border bg-background px-3 text-sm" value={form.vendorId} onChange={(event) => { const vendor = vendors.find((candidate) => candidate.id === event.target.value); setForm((current) => ({ ...current, vendorId: event.target.value, vendorName: vendor?.name ?? current.vendorName })); }}><option value="">New or unlinked vendor</option>{vendors.map((vendor) => <option key={vendor.id} value={vendor.id}>{vendor.name}</option>)}</select></Field>
      <Field label={`Vendor${header.vendorMatchState === 'MATCHED' || header.vendorMatchState === 'CONFIRMED' ? ' · Matched' : ''}`} confidence={header.extractionConfidence?.vendor}><Input disabled={disabled || Boolean(form.vendorId)} value={form.vendorName} onChange={(event) => update('vendorName', event.target.value)} required /></Field>
      {form.documentType === 'INVOICE' && <Field label="Invoice number" confidence={header.extractionConfidence?.invoiceNumber}><Input disabled={disabled} value={form.invoiceNumber} onChange={(event) => update('invoiceNumber', event.target.value)} /></Field>}
      {form.documentType === 'INVOICE' && <Field label="Invoice date" confidence={header.extractionConfidence?.invoiceDate}><Input disabled={disabled} type="date" value={form.invoiceDate} onChange={(event) => update('invoiceDate', event.target.value)} /></Field>}
      {form.documentType === 'ORDER_CONFIRMATION' && <Field label="Order number" confidence={header.extractionConfidence?.orderNumber}><Input disabled={disabled} value={form.orderNumber} onChange={(event) => update('orderNumber', event.target.value)} /></Field>}
      {form.documentType === 'ORDER_CONFIRMATION' && <Field label="Order date" confidence={header.extractionConfidence?.orderDate}><Input disabled={disabled} type="date" value={form.orderDate} onChange={(event) => update('orderDate', event.target.value)} /></Field>}
      <Field label="Purchase order" confidence={header.extractionConfidence?.purchaseOrder}><Input disabled={disabled} value={form.purchaseOrder} onChange={(event) => update('purchaseOrder', event.target.value)} /></Field>
      <Field label="Subtotal" confidence={header.extractionConfidence?.subtotal}><Input disabled={disabled} type="number" min="0" step="0.01" value={form.subtotal} onChange={(event) => update('subtotal', event.target.value)} /></Field>
      <Field label="Tax" confidence={header.extractionConfidence?.tax}><Input disabled={disabled} type="number" min="0" step="0.01" value={form.tax} onChange={(event) => update('tax', event.target.value)} /></Field>
      <Field label="Shipping" confidence={header.extractionConfidence?.shipping}><Input disabled={disabled} type="number" min="0" step="0.01" value={form.shipping} onChange={(event) => update('shipping', event.target.value)} /></Field>
      <Field label="Invoice total" confidence={header.extractionConfidence?.total}><Input disabled={disabled} type="number" min="0" step="0.01" value={form.invoiceTotal} onChange={(event) => update('invoiceTotal', event.target.value)} /></Field>
    </div>
    {!disabled && <div className="mt-5 flex items-center gap-3"><Button disabled={saving}>{saving ? 'Saving...' : 'Save invoice details'}</Button>{message && <p role="status" className="text-sm text-muted-foreground">{message}</p>}</div>}
  </form>;
}

const fromHeader = (header: InvoiceReviewHeader): HeaderForm => ({ vendorId: header.vendorId ?? '', vendorName: header.vendorName, documentType: header.documentType, orderNumber: header.orderNumber, orderDate: header.orderDate, invoiceNumber: header.invoiceNumber, invoiceDate: header.invoiceDate, invoiceTotal: header.invoiceTotal?.toString() ?? '', purchaseOrder: header.purchaseOrder, subtotal: header.subtotal?.toString() ?? '', tax: header.tax?.toString() ?? '', shipping: header.shipping?.toString() ?? '' });
const numberOrNull = (value: string) => value === '' ? null : Number(value);
function Field({ label, confidence, children }: { label: string; confidence?: number; children: React.ReactNode }) { const low = confidence !== undefined && confidence < 75; return <div className={low ? 'rounded-md border border-amber-300/70 bg-amber-50/40 p-2' : ''}><Label className="mb-2 flex items-center gap-2">{label}{low && <span className="text-xs font-normal text-amber-700" title={`Extraction confidence: ${confidence}%`}>Review suggested</span>}</Label>{children}</div>; }
