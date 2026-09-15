import type { ReactNode } from 'react';
import { formatPeriod, formatUSD, type BudgetSummary } from '../../budget/budget.ts';

export function BudgetEmptyState({ action }: { action: ReactNode }) {
  return <section className="rounded-xl border bg-card p-8 text-center"><h2 className="text-xl font-semibold">Set your operating budget</h2><p className="mb-5 mt-2 text-sm text-muted-foreground">Track actual and committed spend against a defined budget period.</p>{action}</section>;
}
export function BudgetOverview({ summary }: { summary: BudgetSummary }) {
  return <section className="space-y-5" aria-label="Budget summary">
    <div><h2 className="text-xl font-semibold">{summary.budget_name}</h2><p className="text-sm text-muted-foreground">{formatPeriod(summary.period_start, summary.period_end)}</p></div>
    <dl className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      {[['Budget', summary.budget_amount], ['Actual spend', summary.actual_spend], ['Committed spend', summary.committed_spend], ['Available budget', summary.available_amount]].map(([label, value]) => <div key={label} className={`rounded-xl border bg-card p-5 ${label === 'Available budget' && Number(value) < 0 ? 'border-orange-300 bg-orange-50/50' : ''}`}><dt className="text-sm text-muted-foreground">{label}</dt><dd className="mt-2 break-words text-3xl font-semibold tracking-tight tabular-nums">{formatUSD(Number(value))}</dd></div>)}
    </dl>
    {summary.available_amount < 0 && <p role="status" className="text-sm text-orange-800">Actual and committed spend exceed this budget by {formatUSD(-summary.available_amount)}.</p>}
    {summary.incomplete_commitment_count > 0 && <p role="status" className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">{summary.incomplete_commitment_count.toLocaleString('en-US')} active {summary.incomplete_commitment_count === 1 ? 'commitment has' : 'commitments have'} unpriced items. Available budget subtracts known committed costs only.</p>}
    <p className="text-sm text-muted-foreground">{summary.posted_invoice_count.toLocaleString('en-US')} posted {summary.posted_invoice_count === 1 ? 'invoice' : 'invoices'} · {summary.active_commitment_count.toLocaleString('en-US')} active {summary.active_commitment_count === 1 ? 'commitment' : 'commitments'} · Organization-wide · USD</p>
    <p className="text-xs text-muted-foreground">Actual spend includes posted invoices dated within this period. Commitments use immutable request costs captured at approval and remain active until released by a denial or audited admin action.</p>
  </section>;
}
