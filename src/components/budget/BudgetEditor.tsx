import { useState, type FormEvent } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { toast } from 'sonner';
import { saveBudgetFn } from '@/lib/budget.functions';
import { budgetFormSchema, type Budget, type BudgetInput } from '@/budget/budget';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from '@/components/ui/dialog';

// Create/edit dialog for an organization budget period, used by the Budget & Purchasing page.
export function BudgetEditor({ organizationId, budget, onClose, onSaved }: { organizationId: string; budget: Budget | null; onClose: () => void; onSaved: (id: string) => void }) {
  const save = useServerFn(saveBudgetFn);
  const client = useQueryClient();
  const [fields, setFields] = useState({ name: budget?.name ?? '', amount: budget ? String(budget.amount) : '', period_start: budget?.period_start ?? '', period_end: budget?.period_end ?? '' });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const mutation = useMutation({ mutationFn: (data: BudgetInput) => save({ data }),
    onSuccess: (row) => {
      void client.invalidateQueries({ queryKey: ['budgets', organizationId] });
      void client.invalidateQueries({ queryKey: ['budget-summary', organizationId] });
      toast.success(budget ? 'Budget updated.' : 'Budget created.');
      onSaved(row.id);
    },
    onError: () => toast.error('Budget could not be saved. Review the error and try again.'),
  });
  function submit(event: FormEvent) {
    event.preventDefault();
    const parsed = budgetFormSchema.safeParse(fields);
    if (!parsed.success) {
      setErrors(Object.fromEntries(parsed.error.issues.map((issue) => [issue.path[0], issue.message])));
      return;
    }
    setErrors({});
    mutation.mutate({ ...parsed.data, organizationId, ...(budget ? { id: budget.id } : {}) });
  }
  return <Dialog open onOpenChange={(open) => { if (!open && !mutation.isPending) onClose(); }}><DialogContent><DialogHeader><DialogTitle>{budget ? 'Edit budget' : 'Create budget'}</DialogTitle><DialogDescription>Define an organization-wide operating budget in USD.</DialogDescription></DialogHeader>
    <form noValidate onSubmit={submit} className="space-y-4">
      {([['name', 'Budget name', 'text'], ['amount', 'Budget amount (USD)', 'number'], ['period_start', 'Period start', 'date'], ['period_end', 'Period end', 'date']] as const).map(([key, label, type]) => <div key={key} className="space-y-2"><Label htmlFor={`budget-${key}`}>{label}</Label><Input id={`budget-${key}`} type={type} required value={fields[key]} disabled={mutation.isPending} min={key === 'amount' ? 0 : undefined} step={key === 'amount' ? 'any' : undefined} aria-invalid={!!errors[key]} aria-describedby={errors[key] ? `error-${key}` : undefined} onChange={(e) => setFields({ ...fields, [key]: e.target.value })} />{errors[key] && <p id={`error-${key}`} role="alert" className="text-sm text-destructive">{errors[key]}</p>}</div>)}
      {mutation.isError && <p role="alert" className="text-sm text-destructive">{mutation.error.message}</p>}
      <div className="flex justify-end gap-2"><Button type="button" variant="outline" disabled={mutation.isPending} onClick={onClose}>Cancel</Button><Button type="submit" disabled={mutation.isPending}>{mutation.isPending ? 'Saving…' : budget ? 'Save changes' : 'Create budget'}</Button></div>
    </form>
  </DialogContent></Dialog>;
}
