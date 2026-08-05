import { createFileRoute } from "@tanstack/react-router";
import { InvoiceListPage } from "@/components/invoice-history/InvoiceListPage";
export const Route = createFileRoute("/_authenticated/invoices")({
  head: () => ({ meta: [{ title: "Invoices — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: InvoiceListPage,
});
