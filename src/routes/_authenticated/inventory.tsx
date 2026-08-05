import { createFileRoute } from '@tanstack/react-router';
import { InventoryPage } from '@/components/inventory/InventoryPage';

export const Route = createFileRoute('/_authenticated/inventory')({
  head: () => ({ meta: [{ title: 'Inventory — MedSpend' }, { name: 'robots', content: 'noindex' }] }),
  component: InventoryPage,
});
