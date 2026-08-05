import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import type { InventoryCategory, InventoryItem, InventoryItemInput } from '@/types/inventory';

const empty = { name: '', description: '', sku: '', vendorName: '', category: '', manufacturer: '', quantity: 0, unit: 'each', parLevel: null as number | null };

export function InventoryItemDialog({ open, onOpenChange, organizationId, item, categories, onSave }: {
  open: boolean; onOpenChange: (open: boolean) => void; organizationId: string; item?: InventoryItem;
  categories: InventoryCategory[]; onSave: (input: InventoryItemInput) => Promise<void>;
}) {
  const [form, setForm] = useState(empty); const [saving, setSaving] = useState(false); const [error, setError] = useState('');
  useEffect(() => { setForm(item ? { name: item.name, description: item.description ?? '', sku: item.sku ?? '', vendorName: item.vendorName ?? '', category: item.category ?? '', manufacturer: item.manufacturer ?? '', quantity: item.quantity, unit: item.unit, parLevel: item.parLevel } : empty); setError(''); }, [item, open]);
  const update = <K extends keyof typeof empty>(key: K, value: (typeof empty)[K]) => setForm((current) => ({ ...current, [key]: value }));
  async function submit(event: React.FormEvent) { event.preventDefault(); setSaving(true); setError(''); try { await onSave({ id: item?.id, organizationId, ...form }); onOpenChange(false); } catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not save item.'); } finally { setSaving(false); } }
  return <Dialog open={open} onOpenChange={onOpenChange}><DialogContent className="max-w-2xl"><DialogHeader><DialogTitle>{item ? 'Edit inventory item' : 'Add inventory item'}</DialogTitle><DialogDescription>Maintain the supply details staff will use when requesting items.</DialogDescription></DialogHeader>
    <form onSubmit={submit} className="space-y-5"><div className="grid gap-4 sm:grid-cols-2">
      <Field label="Name"><Input value={form.name} onChange={(e) => update('name', e.target.value)} required /></Field>
      <Field label="SKU"><Input value={form.sku} onChange={(e) => update('sku', e.target.value)} /></Field>
      <Field label="Category"><select className="h-9 w-full rounded-md border bg-background px-3 text-sm" value={form.category} onChange={(e) => update('category', e.target.value)}><option value="">Uncategorized</option>{categories.map((category) => <option key={category.id}>{category.name}</option>)}</select></Field>
      <Field label="Vendor"><Input value={form.vendorName} onChange={(e) => update('vendorName', e.target.value)} /></Field>
      <Field label="Manufacturer"><Input value={form.manufacturer} onChange={(e) => update('manufacturer', e.target.value)} /></Field>
      <Field label="Unit"><Input value={form.unit} onChange={(e) => update('unit', e.target.value)} required /></Field>
      <Field label="Quantity"><Input type="number" min="0" step="any" value={form.quantity} onChange={(e) => update('quantity', Number(e.target.value))} required /></Field>
      <Field label="Par level"><Input type="number" min="0" step="any" value={form.parLevel ?? ''} onChange={(e) => update('parLevel', e.target.value === '' ? null : Number(e.target.value))} /></Field>
      <Field label="Description" className="sm:col-span-2"><Input value={form.description} onChange={(e) => update('description', e.target.value)} /></Field>
    </div>{error && <p role="alert" className="text-sm text-destructive">{error}</p>}<DialogFooter><Button type="button" variant="outline" onClick={() => onOpenChange(false)}>Cancel</Button><Button disabled={saving}>{saving ? 'Saving…' : 'Save item'}</Button></DialogFooter></form>
  </DialogContent></Dialog>;
}

function Field({ label, className, children }: { label: string; className?: string; children: React.ReactNode }) { return <div className={className}><Label className="mb-2 block">{label}</Label>{children}</div>; }
