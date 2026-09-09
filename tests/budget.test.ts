import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import ts from 'typescript';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { budgetFormSchema, budgetInputSchema, canAccessBudget, formatUSD, formatPeriod, selectActiveBudget } from '../src/budget/budget.ts';
import { getBudgetSummary, listBudgets, saveBudget } from '../src/budget/data.ts';

// Render the real presentational components using the existing Node test runner.
const path = new URL('../src/components/budget/BudgetOverview.tsx', import.meta.url);
const compiled = ts.transpileModule(readFileSync(path, 'utf8'), { compilerOptions: { jsx: ts.JsxEmit.ReactJSX, module: ts.ModuleKind.CommonJS } }).outputText;
const exports: any = {};
new Function('require', 'exports', compiled)(createRequire(path), exports);
const summary = { budget_id: 'budget', budget_name: 'Operating 2026', period_start: '2026-01-01', period_end: '2026-12-31', budget_amount: 1000, actual_spend: 250, remaining_amount: 750, posted_invoice_count: 2 };
const render = (value = summary) => renderToStaticMarkup(createElement(exports.BudgetOverview, { summary: value }));
const fields = { name: 'Operating', amount: '0', period_start: '2026-01-01', period_end: '2026-12-31' };
const org = '00000000-0000-4000-8000-000000000001';
const id = '00000000-0000-4000-8000-000000000002';

test('no-budget state provides setup and create action', () => {
  const html = renderToStaticMarkup(createElement(exports.BudgetEmptyState, { action: createElement('button', null, 'Create budget') }));
  assert.match(html, /Set your operating budget/);
  assert.match(html, /Track actual posted spend against a defined budget period/);
  assert.match(html, /Create budget/);
});
test('creation validation rejects missing, negative, invalid and reversed fields', () => {
  assert.equal(budgetFormSchema.parse(fields).amount, 0);
  for (const patch of [{ name: ' ' }, { amount: '' }, { amount: '-1' }, { amount: 'Infinity' }, { amount: 'abc' }, { period_start: '' }, { period_start: '2026-02-30' }, { period_end: '2025-01-01' }]) {
    assert.equal(budgetFormSchema.safeParse({ ...fields, ...patch }).success, false, JSON.stringify(patch));
  }
  assert.equal(budgetInputSchema.safeParse({ ...fields, amount: -1, organizationId: org }).success, false);
});
test('summary renders RPC values, USD, period, and posted count', () => {
  const html = render();
  for (const text of ['Operating 2026', '$1,000.00', '$250.00', '$750.00', 'Jan 1, 2026 – Dec 31, 2026', '2 posted invoices']) assert.ok(html.includes(text), text);
  assert.equal(formatUSD(12345.6), '$12,345.60');
  assert.equal(formatPeriod('2026-01-01', '2026-01-01'), 'Jan 1, 2026 – Jan 1, 2026');
});
test('negative remaining remains negative and identifies overage', () => {
  const html = render({ ...summary, actual_spend: 1100, remaining_amount: -100 });
  assert.match(html, /-\$100\.00/);
  assert.match(html, /exceeds this budget by \$100\.00/);
});
test('zero budgets do not display percentages or non-finite values', () => {
  for (const actual_spend of [0, 100]) {
    const html = render({ ...summary, budget_amount: 0, actual_spend, remaining_amount: -actual_spend });
    assert.match(html, /\$0\.00/);
    assert.doesNotMatch(html, /NaN|Infinity|%/);
  }
});
test('selection ignores inactive budgets and chooses current then latest start deterministically', () => {
  const b = (id: string, start: string, end: string, active = true) => ({ id, name: id, amount: 100, period_start: start, period_end: end, active });
  const rows = [b('future', '2027-01-01', '2027-12-31'), b('current', '2026-01-01', '2026-12-31'), b('inactive', '2026-09-01', '2026-12-31', false)];
  assert.equal(selectActiveBudget(rows, '2026-09-09')?.id, 'current');
  assert.equal(selectActiveBudget(rows, '2028-01-01')?.id, 'future');
  assert.equal(selectActiveBudget([], '2026-09-09'), null);
  assert.equal(selectActiveBudget([...rows, b('overlap', '2026-09-01', '2026-10-01')], '2026-09-09')?.id, 'overlap');
});
function mockDb(role: string | null = 'owner', rpcError: any = null) {
  const calls: any[] = [];
  let table = '';
  const query: any = {};
  for (const method of ['select', 'eq', 'order', 'insert', 'update']) query[method] = (...args: unknown[]) => { calls.push([method, ...args]); return query; };
  query.maybeSingle = async () => ({ data: role ? { role } : null, error: null });
  query.single = async () => ({ data: { id }, error: null });
  query.then = (resolve: any) => resolve({ data: [], error: null });
  const db: any = { from: (value: string) => { table = value; calls.push(['from', table]); return query; }, rpc: async (...args: any[]) => { calls.push(['rpc', ...args]); return { data: [summary], error: rpcError }; } };
  return { db, calls };
}
test('staff and nonmembers are denied before budget data calls', async () => {
  for (const role of ['staff', null]) {
    assert.equal(canAccessBudget(role ?? undefined), false);
    for (const action of [getBudgetSummary, listBudgets]) {
      const { db, calls } = mockDb(role);
      await assert.rejects(() => action(db, 'user', org, id), /Forbidden/);
      assert.equal(calls.some((c) => c[0] === 'rpc' || c[1] === 'organization_budgets'), false);
    }
    for (const budgetId of [undefined, id]) {
      const { db, calls } = mockDb(role);
      await assert.rejects(() => saveBudget(db, 'user', { ...fields, amount: 0, organizationId: org, id: budgetId }), /Forbidden/);
      assert.equal(calls.some((c) => c[1] === 'organization_budgets'), false);
    }
  }
});
test('summary calls the canonical RPC with organization and budget IDs, propagates errors', async () => {
  const { db, calls } = mockDb();
  assert.deepEqual(await getBudgetSummary(db, 'user', org, id), summary);
  assert.deepEqual(calls.find((c) => c[0] === 'rpc'), ['rpc', 'get_budget_summary', { _organization_id: org, _budget_id: id }]);
  await assert.rejects(() => getBudgetSummary(mockDb('owner', { message: 'RPC failed' }).db, 'user', org, id), /RPC failed/);
});
test('list scopes active budgets; edits UPDATE the existing scoped row', async () => {
  const { db, calls } = mockDb();
  await listBudgets(db, 'user', org);
  assert.ok(calls.some((c) => c[0] === 'eq' && c[1] === 'active' && c[2] === true));
  await saveBudget(db, 'user', { ...fields, amount: 500, organizationId: org, id });
  assert.ok(calls.some((c) => c[0] === 'update' && c[1].amount === 500));
  assert.ok(calls.some((c) => c[0] === 'eq' && c[1] === 'id' && c[2] === id));
  assert.ok(calls.some((c) => c[0] === 'eq' && c[1] === 'organization_id' && c[2] === org));
  assert.equal(calls.some((c) => c[0] === 'insert'), false);
});
test('route and navigation enforce access before rendering budget queries', () => {
  const read = (file: string) => readFileSync(new URL(`../src/${file}`, import.meta.url), 'utf8');
  assert.match(read('routes/_authenticated/route.tsx'), /ADMIN_ROUTES = \["\/budget"/);
  assert.match(read('components/app/AdminAppShell.tsx'), /to: "\/budget", label: "Budget", icon: Wallet \}/);
  assert.doesNotMatch(read('components/app/StaffAppShell.tsx'), /\/budget/);
  assert.match(read('components/budget/BudgetPage.tsx'), /!canAccessBudget\(active.role\)/);
  assert.equal((read('lib/budget.functions.ts').match(/middleware\(\[requireSupabaseAuth\]\)/g) ?? []).length, 3);
});
test('creation inserts the authenticated organization scope with validated fields', async () => {
  const { db, calls } = mockDb();
  assert.deepEqual(await saveBudget(db, 'user', { ...fields, name: ' Operating ', amount: 0, organizationId: org }), { id });
  const insert = calls.find((c) => c[0] === 'insert');
  assert.equal(insert[1].organization_id, org);
  assert.equal(insert[1].name, 'Operating');
  assert.equal(insert[1].active, true);
  assert.equal(calls.some((c) => c[0] === 'update'), false);
});
test('missing summary is an error rather than a zero-spend budget', async () => {
  const { db } = mockDb();
  db.rpc = async () => ({ data: [], error: null });
  await assert.rejects(() => getBudgetSummary(db, 'user', org, id), /summary is unavailable/);
});

for (const role of ['owner', 'admin']) {
  test(`${role} can list, read, create and update organization budgets`, async () => {
    assert.equal(canAccessBudget(role), true);
    const { db, calls } = mockDb(role);
    assert.deepEqual(await listBudgets(db, 'user', org), []);
    assert.deepEqual(await getBudgetSummary(db, 'user', org, id), summary);
    assert.deepEqual(await saveBudget(db, 'user', { ...fields, amount: 0, organizationId: org }), { id });
    assert.deepEqual(await saveBudget(db, 'user', { ...fields, amount: 500, organizationId: org, id }), { id });
    assert.equal(calls.filter((c) => c[0] === 'from' && c[1] === 'organization_memberships').length, 4);
    assert.equal(calls.filter((c) => c[0] === 'eq' && c[1] === 'user_id' && c[2] === 'user').length, 4);
    assert.equal(calls.filter((c) => c[0] === 'eq' && c[1] === 'organization_id' && c[2] === org).length, 6);
  });
}

// Render the actual shell with only its router/auth context replaced.
function renderAdminNavigation(role: string) {
  const shellPath = new URL('../src/components/app/AdminAppShell.tsx', import.meta.url);
  const shell = ts.transpileModule(readFileSync(shellPath, 'utf8'), { compilerOptions: { jsx: ts.JsxEmit.ReactJSX, module: ts.ModuleKind.CommonJS } }).outputText;
  const require = createRequire(shellPath);
  const shellExports: any = {};
  const stubs: Record<string, unknown> = {
    '@tanstack/react-router': {
      Link: ({ to, children, ...props }: any) => createElement('a', { ...props, href: to }, children),
      useRouter: () => ({ navigate() {} }),
      useRouterState: () => '/budget',
    },
    '@/hooks/use-active-org': { useActiveOrg: () => ({ active: { role, organizationId: org, organizationName: 'Test organization' }, memberships: [], setActiveOrgId() {} }) },
    '@/integrations/supabase/client': { supabase: {} },
  };
  new Function('require', 'exports', shell)((name: string) => stubs[name] ?? require(name), shellExports);
  return renderToStaticMarkup(createElement(shellExports.AdminAppShell));
}
test('owners and admins see Budget in desktop and mobile navigation; existing owner-only items stay restricted', () => {
  const owner = renderAdminNavigation('owner');
  const admin = renderAdminNavigation('admin');
  for (const html of [owner, admin]) assert.equal((html.match(/href="\/budget"/g) ?? []).length, 2);
  for (const route of ['/inventory', '/upload', '/invoices']) {
    assert.equal((owner.match(new RegExp(`href="${route}"`, 'g')) ?? []).length, 2, route);
    assert.equal(admin.includes(`href="${route}"`), false, route);
  }
  const staffNav = readFileSync(new URL('../src/components/staff/StaffBottomNav.tsx', import.meta.url), 'utf8');
  assert.doesNotMatch(staffNav, /\/budget/);
});

test('additive migration replaces only budget role authorization and preserves exact accounting SQL', () => {
  const foundation = readFileSync(new URL('../supabase/migrations/20260909110000_phase6a1_budget_foundation.sql', import.meta.url), 'utf8');
  const migration = readFileSync(new URL('../supabase/migrations/20260909120000_phase6a1_budget_admin_access.sql', import.meta.url), 'utf8');
  for (const kind of ['select', 'insert', 'update']) {
    assert.ok(migration.includes(`DROP POLICY organization_budgets_owner_${kind} ON public.organization_budgets;`));
    assert.ok(migration.includes(`CREATE POLICY organization_budgets_admin_${kind}`));
  }
  assert.match(migration, /FOR SELECT TO authenticated\s+USING \(public\.is_org_admin\(organization_id, auth\.uid\(\)\)\)/);
  assert.match(migration, /FOR INSERT TO authenticated\s+WITH CHECK \(public\.is_org_admin\(organization_id, auth\.uid\(\)\)\)/);
  assert.match(migration, /FOR UPDATE TO authenticated\s+USING \(public\.is_org_admin\(organization_id, auth\.uid\(\)\)\)\s+WITH CHECK \(public\.is_org_admin\(organization_id, auth\.uid\(\)\)\)/);
  const functionStart = 'CREATE OR REPLACE FUNCTION public.get_budget_summary(';
  const originalFunction = foundation.slice(foundation.indexOf(functionStart));
  const expected = originalFunction.replace(
    /IF NOT public\.has_org_role\([\s\S]*?END IF;/,
    "IF NOT public.is_org_admin(_organization_id, auth.uid()) THEN\n    RAISE EXCEPTION 'Forbidden: owner or admin access required';\n  END IF;",
  );
  assert.equal(migration.slice(migration.indexOf(functionStart)).replace(/\nCOMMIT;\s*$/, ''), expected);
  assert.doesNotMatch(migration, /FOR DELETE|GRANT DELETE|DISABLE ROW LEVEL SECURITY|TO staff/);
});
