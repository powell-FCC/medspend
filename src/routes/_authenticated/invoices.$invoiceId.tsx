import { createFileRoute } from '@tanstack/react-router';
import { InvoiceReviewPage } from '@/components/invoice-processing/InvoiceReviewPage';

export const Route = createFileRoute('/_authenticated/invoices/$invoiceId')({
  head: () => ({ meta: [{ title: 'Invoice Review — MedSpend' }, { name: 'robots', content: 'noindex' }] }),
  component: InvoiceReviewRoute,
});

function InvoiceReviewRoute() {
  const { invoiceId } = Route.useParams();
  return <InvoiceReviewPage sourceFileId={invoiceId} />;
}
