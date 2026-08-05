import { useState } from 'react';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import type { InventoryCategory } from '@/types/inventory';

export function CategoryDialog({ open, onOpenChange, categories, onSave, onDelete }: { open: boolean; onOpenChange: (open: boolean) => void; categories: InventoryCategory[]; onSave: (name: string, id?: string) => Promise<void>; onDelete: (id: string) => Promise<void> }) {
  const [name, setName] = useState(''); const [editing, setEditing] = useState<InventoryCategory>(); const [error, setError] = useState('');
  async function submit(event: React.FormEvent) { event.preventDefault(); setError(''); try { await onSave(name, editing?.id); setName(''); setEditing(undefined); } catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not save category.'); } }
  return <Dialog open={open} onOpenChange={onOpenChange}><DialogContent><DialogHeader><DialogTitle>Inventory categories</DialogTitle><DialogDescription>Create, rename, or delete unused categories.</DialogDescription></DialogHeader>
    <form onSubmit={submit} className="flex gap-2"><Input aria-label="Category name" placeholder="Category name" value={name} onChange={(e) => setName(e.target.value)} required /><Button>{editing ? 'Save' : 'Add'}</Button>{editing && <Button type="button" variant="ghost" onClick={() => { setEditing(undefined); setName(''); }}>Cancel</Button>}</form>
    {error && <p role="alert" className="text-sm text-destructive">{error}</p>}<div className="max-h-72 space-y-2 overflow-auto">{categories.map((category) => <div key={category.id} className="flex items-center justify-between rounded-lg border px-3 py-2"><span className="text-sm font-medium">{category.name}</span><div className="flex gap-1"><Button size="sm" variant="ghost" onClick={() => { setEditing(category); setName(category.name); }}>Edit</Button><Button size="sm" variant="ghost" className="text-destructive" onClick={async () => { setError(''); try { await onDelete(category.id); } catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not delete category.'); } }}>Delete</Button></div></div>)}</div>
  </DialogContent></Dialog>;
}
