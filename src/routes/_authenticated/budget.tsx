import { createFileRoute } from '@tanstack/react-router';
import { BudgetPage } from '@/components/budget/BudgetPage';

export const Route = createFileRoute('/_authenticated/budget')({
  head: () => ({ meta: [{ title: 'Budget — SportSpend' }, { name: 'robots', content: 'noindex' }] }),
  component: BudgetPage,
});
