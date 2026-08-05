import { createFileRoute } from "@tanstack/react-router";
import { InvoiceUploadPage } from "@/components/invoices/InvoiceUploadPage";

export const Route = createFileRoute("/_authenticated/upload")({
  head: () => ({ meta: [{ title: "Upload Invoice — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: InvoiceUploadPage,
});
