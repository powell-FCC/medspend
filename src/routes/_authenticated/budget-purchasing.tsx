import { createFileRoute } from '@tanstack/react-router';
import { BudgetPurchasingPage } from '@/components/budget-purchasing/BudgetPurchasingPage';

export const Route = createFileRoute('/_authenticated/budget-purchasing')({
  head: () => ({ meta: [{ title: 'Budget & Purchasing — SportSpend' }, { name: 'robots', content: 'noindex' }] }),
  component: BudgetPurchasingPage,
});
