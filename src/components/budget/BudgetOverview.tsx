import type { ReactNode } from 'react';
import { formatPeriod, formatUSD, type BudgetSummary } from '../../budget/budget.ts';

export function BudgetEmptyState({ action }: { action: ReactNode }) {
  return <section className="rounded-xl border bg-card p-8 text-center"><h2 className="text-xl font-semibold">Set your operating budget</h2><p className="mb-5 mt-2 text-sm text-muted-foreground">Track actual posted spend against a defined budget period.</p>{action}</section>;
}
export function BudgetOverview({ summary }: { summary: BudgetSummary }) {
  return <section className="space-y-5" aria-label="Budget summary">
    <div><h2 className="text-xl font-semibold">{summary.budget_name}</h2><p className="text-sm text-muted-foreground">{formatPeriod(summary.period_start, summary.period_end)}</p></div>
    <dl className="grid gap-4 lg:grid-cols-3">
      {[['Budget', summary.budget_amount], ['Actual spend', summary.actual_spend], ['Remaining', summary.remaining_amount]].map(([label, value]) => <div key={label} className={`rounded-xl border bg-card p-5 ${label === 'Remaining' && Number(value) < 0 ? 'border-orange-300 bg-orange-50/50' : ''}`}><dt className="text-sm text-muted-foreground">{label}</dt><dd className="mt-2 break-words text-3xl font-semibold tracking-tight tabular-nums">{formatUSD(Number(value))}</dd></div>)}
    </dl>
    {summary.remaining_amount < 0 && <p role="status" className="text-sm text-orange-800">Posted spend exceeds this budget by {formatUSD(-summary.remaining_amount)}.</p>}
    <p className="text-sm text-muted-foreground">{summary.posted_invoice_count.toLocaleString('en-US')} posted {summary.posted_invoice_count === 1 ? 'invoice' : 'invoices'} · Organization-wide · USD</p>
    <p className="text-xs text-muted-foreground">Actual spend includes posted invoices dated within this period, using the posting date when an invoice date is unavailable.</p>
  </section>;
}
