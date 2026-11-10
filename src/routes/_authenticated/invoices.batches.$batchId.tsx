import { createFileRoute } from "@tanstack/react-router";
import { InvoiceBatchPage } from "@/components/invoices/InvoiceBatchPage";

export const Route = createFileRoute("/_authenticated/invoices/batches/$batchId")({
  head: () => ({
    meta: [{ title: "Invoice Packet — MedSpend" }, { name: "robots", content: "noindex" }],
  }),
  component: InvoiceBatchRoute,
});

function InvoiceBatchRoute() {
  const { batchId } = Route.useParams();
  return <InvoiceBatchPage batchId={batchId} />;
}
