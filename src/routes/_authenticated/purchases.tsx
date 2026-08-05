import { createFileRoute } from "@tanstack/react-router";
import { PurchaseHistoryPage } from "@/components/invoice-history/PurchaseHistoryPage";
export const Route = createFileRoute("/_authenticated/purchases")({
  head: () => ({ meta: [{ title: "Purchases — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: PurchaseHistoryPage,
});
