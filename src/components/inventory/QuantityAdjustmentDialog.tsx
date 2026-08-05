import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import type { AdjustmentReason, InventoryItem } from '@/types/inventory';

const reasons: AdjustmentReason[] = ['Invoice received', 'Manual adjustment', 'Damaged', 'Expired', 'Correction'];

export function QuantityAdjustmentDialog({ item, onOpenChange, onAdjust }: { item?: InventoryItem; onOpenChange: (open: boolean) => void; onAdjust: (amount: number, reason: AdjustmentReason) => Promise<void> }) {
  const [amount, setAmount] = useState(0); const [reason, setReason] = useState<AdjustmentReason>('Manual adjustment'); const [error, setError] = useState(''); const [saving, setSaving] = useState(false);
  useEffect(() => { setAmount(0); setReason('Manual adjustment'); setError(''); }, [item]);
  async function submit(event: React.FormEvent) { event.preventDefault(); setSaving(true); setError(''); try { await onAdjust(amount, reason); onOpenChange(false); } catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not adjust quantity.'); } finally { setSaving(false); } }
  return <Dialog open={Boolean(item)} onOpenChange={onOpenChange}><DialogContent><DialogHeader><DialogTitle>Adjust quantity</DialogTitle><DialogDescription>{item?.name}: currently {item?.quantity} {item?.unit}</DialogDescription></DialogHeader>
    <form onSubmit={submit} className="space-y-4"><div><Label className="mb-2 block">Adjustment amount</Label><Input type="number" step="any" value={amount} onChange={(e) => setAmount(Number(e.target.value))} required /><p className="mt-1 text-xs text-muted-foreground">Use a negative number to reduce stock.</p></div>
      <div><Label className="mb-2 block">Reason</Label><select className="h-9 w-full rounded-md border bg-background px-3 text-sm" value={reason} onChange={(e) => setReason(e.target.value as AdjustmentReason)}>{reasons.map((value) => <option key={value}>{value}</option>)}</select></div>
      {error && <p role="alert" className="text-sm text-destructive">{error}</p>}<DialogFooter><Button type="button" variant="outline" onClick={() => onOpenChange(false)}>Cancel</Button><Button disabled={!amount || saving}>{saving ? 'Saving…' : 'Apply adjustment'}</Button></DialogFooter>
    </form></DialogContent></Dialog>;
}
