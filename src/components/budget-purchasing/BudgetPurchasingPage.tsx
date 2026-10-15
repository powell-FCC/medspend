import { useState } from 'react';
import { Link } from '@tanstack/react-router';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { useActiveOrg } from '@/hooks/use-active-org';
import { getBudgetLineageFn, getCommandCenterOverviewFn, getPriceIntelligenceOverviewFn } from '@/lib/budget-purchasing.functions';
import { canAccessBudget, formatPeriod, localToday, type Budget } from '@/budget/budget';
import {
  attentionItems, budgetsOverlap, defaultScopeId, scopeOptions, summarizeScope,
  type BudgetRow, type PriceRow,
} from '@/budget-purchasing/command-center';
import { BudgetEditor } from '@/components/budget/BudgetEditor';
import { Button } from '@/components/ui/button';
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from '@/components/ui/sheet';
import { ProductPriceIntelligence } from '@/components/catalog/ProductPriceIntelligence';
import {
  BudgetLineagePanel, BudgetTable, FinancialSummary, NeedsAttention, NoBudgetState, PriceEvidence,
  PriceIntelligenceTable, RecentPurchasing, SectionError, SectionLoading, type RenderLink,
} from './CommandCenterSections';

// Router-aware links for the presentational sections. Hash targets stay on this page.
const renderLink: RenderLink = ({ to, search, className, children }) => to.startsWith('#')
  ? <a href={to} className={className}>{children}</a>
  : <Link to={to as never} search={search as never} className={className}>{children}</Link>;

export function BudgetPurchasingPage() {
  const { active, loading } = useActiveOrg();
  if (loading) return <p role="status" className="p-6">Loading budget and purchasing…</p>;
  if (!active || !canAccessBudget(active.role)) return <p role="alert" className="p-6">Budget & Purchasing is restricted to organization owners and admins.</p>;
  return <CommandCenter key={active.organizationId} organizationId={active.organizationId} organizationName={active.organizationName} />;
}

function CommandCenter({ organizationId, organizationName }: { organizationId: string; organizationName: string }) {
  const fetchOverview = useServerFn(getCommandCenterOverviewFn);
  const fetchPrices = useServerFn(getPriceIntelligenceOverviewFn);
  const queryClient = useQueryClient();
  const today = localToday();
  const [scopeId, setScopeId] = useState<string | null>(null);
  const [lineageBudget, setLineageBudget] = useState<BudgetRow | null>(null);
  const [priceRow, setPriceRow] = useState<PriceRow | null>(null);
  const [editor, setEditor] = useState<Budget | 'new' | null>(null);

  const overview = useQuery({ queryKey: ['budget-purchasing', organizationId, 'overview'], queryFn: () => fetchOverview({ data: { organizationId } }) });
  const prices = useQuery({ queryKey: ['budget-purchasing', organizationId, 'prices'], queryFn: () => fetchPrices({ data: { organizationId } }) });

  const budgets = overview.data?.budgets ?? [];
  const options = scopeOptions(budgets);
  const effectiveScope = scopeId && options.some((o) => o.id === scopeId) ? scopeId : defaultScopeId(budgets, today);
  const summary = summarizeScope(budgets, effectiveScope);
  const scopedBudget = budgets.find((b) => b.budgetId === effectiveScope);

  return <div className="min-h-screen bg-[#f5f7f9] px-4 py-6 sm:px-6 lg:px-8">
    <div className="mx-auto max-w-7xl space-y-5">
      <header className="flex flex-wrap items-end justify-between gap-4">
        <div className="min-w-0">
          <p className="text-xs font-semibold uppercase tracking-[0.15em] text-[#718092]">{organizationName}</p>
          <h1 className="mt-1 text-2xl font-semibold tracking-tight text-[#102a49] sm:text-3xl">Budget & Purchasing</h1>
          {summary && <p className="mt-1 text-sm text-[#697687]">Viewing <span className="font-medium text-[#102a49]">{summary.label}</span> · {formatPeriod(summary.periodStart, summary.periodEnd)} · Organization-wide · USD</p>}
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {options.length > 1 && <label className="flex items-center gap-2 text-sm text-[#536174]">Budget period
            <select className="rounded-md border border-[#dfe5eb] bg-white px-2 py-2 text-sm" value={effectiveScope ?? ''} onChange={(e) => setScopeId(e.target.value)}>
              {options.map((o) => <option key={o.id} value={o.id}>{o.label} · {formatPeriod(o.periodStart, o.periodEnd)}</option>)}
            </select></label>}
          {scopedBudget && <Button variant="outline" onClick={() => setEditor({ id: scopedBudget.budgetId, name: scopedBudget.budgetName, amount: scopedBudget.budgetAmount, period_start: scopedBudget.periodStart, period_end: scopedBudget.periodEnd, active: true })}>Edit budget</Button>}
          {budgets.length > 0 && <Button variant="outline" onClick={() => setEditor('new')}>New budget</Button>}
        </div>
      </header>
      {budgets.length > 1 && budgetsOverlap(budgets) && <p className="text-xs text-[#697687]">Some active budget periods overlap, so they are shown one at a time rather than combined (combining would count the same spend twice).</p>}

      {overview.isPending ? <SectionLoading label="Loading budget figures…" />
        : overview.isError ? <SectionError message="Budget figures could not be loaded." onRetry={() => overview.refetch()} />
        : <>
          {summary ? <FinancialSummary summary={summary} today={today} /> : <NoBudgetState action={<Button onClick={() => setEditor('new')}>Create budget</Button>} />}
          <div className="grid grid-cols-1 gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,2fr)] xl:grid-cols-[320px_minmax(0,1fr)]">
            <NeedsAttention items={attentionItems(overview.data, today)} renderLink={renderLink} invoiceDetailHidden={!overview.data.viewerIsOwner} />
            {budgets.length > 0 && <BudgetTable budgets={budgets} scopeBudgetIds={summary?.budgetIds ?? []} onSelect={(id) => setLineageBudget(budgets.find((b) => b.budgetId === id) ?? null)} />}
          </div>
        </>}

      {prices.isPending ? <SectionLoading label="Loading price intelligence…" />
        : prices.isError ? <SectionError message="Price intelligence could not be loaded." onRetry={() => prices.refetch()} />
        : <PriceIntelligenceTable overview={prices.data} today={today} selectedProductId={priceRow?.productId} onSelect={setPriceRow} />}

      {overview.data?.recentPurchases && <RecentPurchasing purchases={overview.data.recentPurchases} renderLink={renderLink} />}
    </div>

    <Sheet open={!!lineageBudget} onOpenChange={(open) => { if (!open) setLineageBudget(null); }}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-lg">
        {lineageBudget && <>
          <SheetHeader className="mb-4"><SheetTitle>{lineageBudget.budgetName}</SheetTitle><SheetDescription>{formatPeriod(lineageBudget.periodStart, lineageBudget.periodEnd)}</SheetDescription></SheetHeader>
          <BudgetLineage organizationId={organizationId} budget={lineageBudget} />
          <div className="mt-6 flex gap-2">
            <Button variant="outline" size="sm" onClick={() => { setScopeId(lineageBudget.budgetId); setLineageBudget(null); }}>View this period</Button>
          </div>
        </>}
      </SheetContent>
    </Sheet>

    <Sheet open={!!priceRow} onOpenChange={(open) => { if (!open) setPriceRow(null); }}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-2xl">
        {priceRow && <>
          <SheetHeader className="mb-4"><SheetTitle>{priceRow.productName}</SheetTitle><SheetDescription>Why this price is flagged</SheetDescription></SheetHeader>
          <PriceEvidence row={priceRow} today={today} />
          <div className="mt-6"><ProductPriceIntelligence organizationId={organizationId} productId={priceRow.productId} /></div>
        </>}
      </SheetContent>
    </Sheet>

    {editor && <BudgetEditor organizationId={organizationId} budget={editor === 'new' ? null : editor} onClose={() => setEditor(null)}
      onSaved={(id) => { setEditor(null); setScopeId(id); void queryClient.invalidateQueries({ queryKey: ['budget-purchasing', organizationId] }); }} />}
  </div>;
}

function BudgetLineage({ organizationId, budget }: { organizationId: string; budget: BudgetRow }) {
  const fetchLineage = useServerFn(getBudgetLineageFn);
  const lineage = useQuery({ queryKey: ['budget-purchasing', organizationId, 'lineage', budget.budgetId], queryFn: () => fetchLineage({ data: { organizationId, budgetId: budget.budgetId } }) });
  if (lineage.isPending) return <SectionLoading label="Loading commitments and spend…" />;
  if (lineage.isError) return <SectionError message="Budget detail could not be loaded." onRetry={() => lineage.refetch()} />;
  return <BudgetLineagePanel budget={budget} lineage={lineage.data} renderLink={renderLink} />;
}

