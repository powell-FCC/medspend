import { createFileRoute } from "@tanstack/react-router";
export const Route = createFileRoute("/_authenticated/products")({
  head: () => ({ meta: [{ title: "Products — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: () => (
    <div className="max-w-4xl mx-auto px-6 py-16 text-center">
      <h1 className="text-2xl font-semibold">Products</h1>
      <p className="mt-2 text-sm text-muted-foreground">Product management UI coming in Phase 2.</p>
    </div>
  ),
});