import { useState, type FormEvent } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { toast } from 'sonner';
import { useActiveOrg } from '@/hooks/use-active-org';
import { listBudgetsFn, getBudgetSummaryFn, saveBudgetFn } from '@/lib/budget.functions';
import { budgetFormSchema, canAccessBudget, formatPeriod, localToday, selectActiveBudget, type Budget, type BudgetInput } from '@/budget/budget';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from '@/components/ui/dialog';
import { BudgetEmptyState, BudgetOverview } from './BudgetOverview';

export function BudgetPage() {
  const { active, loading } = useActiveOrg();
  if (loading) return <p role="status" className="p-6">Loading budget…</p>;
  if (!active || !canAccessBudget(active.role)) return <p role="alert" className="p-6">Budget access is restricted to organization owners and admins.</p>;
  return <OrganizationBudget key={active.organizationId} organizationId={active.organizationId} />;
}
function OrganizationBudget({ organizationId }: { organizationId: string }) {
  const list = useServerFn(listBudgetsFn);
  const getSummary = useServerFn(getBudgetSummaryFn);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [editor, setEditor] = useState<Budget | 'new' | null>(null);
  const budgets = useQuery({ queryKey: ['budgets', organizationId], queryFn: () => list({ data: { organizationId } }) });
  const today = localToday();
  const selected = budgets.data?.find((b) => b.id === selectedId) ?? selectActiveBudget(budgets.data ?? [], today);
  const summary = useQuery({ queryKey: ['budget-summary', organizationId, selected?.id], enabled: !!selected,
    queryFn: () => getSummary({ data: { organizationId, budgetId: selected!.id } }) });
  const createButton = <Button onClick={() => setEditor('new')}>Create budget</Button>;
  return <div className="mx-auto max-w-6xl space-y-6 p-4 md:p-8">
    <header className="flex flex-wrap items-start justify-between gap-4"><div><h1 className="text-2xl font-semibold tracking-tight">Budget</h1><p className="mt-1 text-sm text-muted-foreground">Operating budget and actual posted spend</p></div>{selected && <Button variant="outline" onClick={() => setEditor(selected)}>Edit budget</Button>}</header>
    {budgets.isPending ? <p role="status">Loading budget…</p> : budgets.isError ? <ErrorState message="Could not load budgets." retry={() => budgets.refetch()} /> : !selected ? <BudgetEmptyState action={createButton} /> : <>
      {(budgets.data?.length ?? 0) > 1 && <div className="space-y-2"><Label htmlFor="budget-selection">Active budgets</Label><select id="budget-selection" className="block w-full rounded-md border bg-background p-2 text-sm" value={selected.id} onChange={(e) => setSelectedId(e.target.value)}>{budgets.data?.map((b) => <option key={b.id} value={b.id}>{b.name} · {formatPeriod(b.period_start, b.period_end)}</option>)}</select><p className="text-xs text-muted-foreground">Initially shows a period containing today, choosing the latest start if periods overlap. Otherwise shows the latest starting active period.</p></div>}
      {!(selected.period_start <= today && selected.period_end >= today) && <p role="status" className="rounded-lg border bg-muted/40 p-3 text-sm">The selected active budget does not cover today. Amounts below apply only to {formatPeriod(selected.period_start, selected.period_end)}.</p>}
      {summary.isPending ? <p role="status">Loading budget summary…</p> : summary.isError ? <ErrorState message="Could not load the budget summary." retry={() => summary.refetch()} /> : <BudgetOverview summary={summary.data} />}
    </>}
    {editor && <BudgetEditor organizationId={organizationId} budget={editor === 'new' ? null : editor} onClose={() => setEditor(null)} onSaved={(id) => { setSelectedId(id); setEditor(null); }} />}
  </div>;
}
function ErrorState({ message, retry }: { message: string; retry: () => unknown }) {
  return <div role="alert" className="rounded-lg border p-4"><p className="mb-3 text-sm">{message} Please try again.</p><Button variant="outline" onClick={retry}>Retry</Button></div>;
}
function BudgetEditor({ organizationId, budget, onClose, onSaved }: { organizationId: string; budget: Budget | null; onClose: () => void; onSaved: (id: string) => void }) {
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
