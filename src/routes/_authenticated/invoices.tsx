import { createFileRoute, Outlet } from "@tanstack/react-router";
export const Route = createFileRoute("/_authenticated/invoices")({
  head: () => ({ meta: [{ title: "Invoices — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: Outlet,
});
