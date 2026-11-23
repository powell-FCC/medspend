import { createFileRoute } from "@tanstack/react-router";
import { BudgetPurchasingPage } from "@/components/budget-purchasing/BudgetPurchasingPage";
import { priceSearchSchema } from "@/price-intelligence/vendor-intelligence";

export const Route = createFileRoute("/_authenticated/budget-purchasing")({
  head: () => ({
    meta: [{ title: "Budget & Purchasing — SportSpend" }, { name: "robots", content: "noindex" }],
  }),
  // Phase 6B.1: a malformed UUID is dropped, never passed to the server.
  validateSearch: priceSearchSchema,
  component: BudgetPurchasingPage,
});
