import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { calculateInvoiceLineTotal } from '@/invoice/line-item';
import type { InvoiceItemInput, InvoiceReviewVendorProduct, ReviewItem } from '@/types/invoice-processing';

type ItemForm = { sku: string; description: string; manufacturer: string; category: string; quantity: number; unitOfMeasure: string; unitPrice: number; totalPrice: number; packageSize: string; vendorProductId: string };
const empty: ItemForm = { sku: '', description: '', manufacturer: '', category: '', quantity: 1, unitOfMeasure: 'each', unitPrice: 0, totalPrice: 0, packageSize: '', vendorProductId: '' };

export function InvoiceItemDialog({ open, onOpenChange, organizationId, sourceFileId, item, categories, vendorProducts, onSave }: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  organizationId: string;
  sourceFileId: string;
  item?: ReviewItem;
  categories: string[];
  vendorProducts: InvoiceReviewVendorProduct[];
  onSave: (input: InvoiceItemInput) => Promise<void>;
}) {
  const [form, setForm] = useState<ItemForm>(empty); const [saving, setSaving] = useState(false); const [error, setError] = useState('');
  useEffect(() => { setForm(item ? { sku: item.sku, description: item.description, manufacturer: item.manufacturer, category: item.category, quantity: item.quantity, unitOfMeasure: item.unitOfMeasure, unitPrice: item.unitPrice, totalPrice: item.totalPrice, packageSize: item.packageSize, vendorProductId: item.vendorProductId ?? '' } : empty); setError(''); }, [item, open]);
  const update = <K extends keyof ItemForm>(key: K, value: ItemForm[K]) => setForm((current) => ({ ...current, [key]: value }));
  const updatePrice = (key: 'quantity' | 'unitPrice', value: number) => setForm((current) => ({ ...current, [key]: value, totalPrice: calculateInvoiceLineTotal(key === 'quantity' ? value : current.quantity, key === 'unitPrice' ? value : current.unitPrice) }));
  async function submit(event: React.FormEvent) { event.preventDefault(); setSaving(true); setError(''); try { await onSave({ id: item?.id, organizationId, sourceFileId, ...form, vendorProductId: form.vendorProductId || null }); onOpenChange(false); } catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not save line item.'); } finally { setSaving(false); } }
  return <Dialog open={open} onOpenChange={onOpenChange}><DialogContent className="max-w-3xl"><DialogHeader><DialogTitle>{item ? 'Edit line item' : 'Add line item'}</DialogTitle><DialogDescription>Enter the supply details exactly as they appear on the invoice.</DialogDescription></DialogHeader>
    <form onSubmit={submit} className="space-y-5"><div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      <Field label="Vendor product" className="sm:col-span-2 lg:col-span-3"><select className="h-9 w-full rounded-md border bg-background px-3 text-sm" value={form.vendorProductId} onChange={(event) => { const mapping = vendorProducts.find((candidate) => candidate.id === event.target.value); setForm((current) => ({ ...current, vendorProductId: event.target.value, sku: mapping?.vendorSku ?? current.sku, description: mapping?.productName ?? current.description, unitOfMeasure: mapping?.unitOfMeasure || current.unitOfMeasure, packageSize: mapping?.packageSize || current.packageSize })); }}><option value="">No existing vendor product</option>{vendorProducts.map((mapping) => <option key={mapping.id} value={mapping.id}>{mapping.vendorName} · {mapping.vendorSku} · {mapping.productName}</option>)}</select></Field>
      <Field label="SKU"><Input value={form.sku} onChange={(event) => update('sku', event.target.value)} /></Field>
      <Field label="Product description" className="sm:col-span-2"><Input value={form.description} onChange={(event) => update('description', event.target.value)} required /></Field>
      <Field label="Manufacturer"><Input value={form.manufacturer} onChange={(event) => update('manufacturer', event.target.value)} /></Field>
      <Field label="Category"><select className="h-9 w-full rounded-md border bg-background px-3 text-sm" value={form.category} onChange={(event) => update('category', event.target.value)}><option value="">Uncategorized</option>{categories.map((category) => <option key={category}>{category}</option>)}</select></Field>
      <Field label="Package size"><Input value={form.packageSize} onChange={(event) => update('packageSize', event.target.value)} /></Field>
      <Field label="Quantity"><Input type="number" min="0.0001" step="any" value={form.quantity} onChange={(event) => updatePrice('quantity', Number(event.target.value))} required /></Field>
      <Field label="Unit"><Input value={form.unitOfMeasure} onChange={(event) => update('unitOfMeasure', event.target.value)} required /></Field>
      <Field label="Unit price"><Input type="number" min="0" step="0.01" value={form.unitPrice} onChange={(event) => updatePrice('unitPrice', Number(event.target.value))} required /></Field>
      <Field label="Total price"><Input type="number" min="0" step="0.01" value={form.totalPrice} onChange={(event) => update('totalPrice', Number(event.target.value))} required /></Field>
    </div>{error && <p role="alert" className="text-sm text-destructive">{error}</p>}<DialogFooter><Button type="button" variant="outline" onClick={() => onOpenChange(false)}>Cancel</Button><Button disabled={saving}>{saving ? 'Saving...' : 'Save line item'}</Button></DialogFooter></form>
  </DialogContent></Dialog>;
}

function Field({ label, className, children }: { label: string; className?: string; children: React.ReactNode }) { return <div className={className}><Label className="mb-2 block">{label}</Label>{children}</div>; }
