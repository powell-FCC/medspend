import { createFileRoute } from '@tanstack/react-router';
import { VendorHistoryPage } from '@/components/invoice-history/VendorHistoryPage';

export const Route = createFileRoute('/_authenticated/vendors')({
  head: () => ({ meta: [{ title: 'Vendors — MedSpend' }, { name: 'robots', content: 'noindex' }] }),
  component: VendorHistoryPage,
});
