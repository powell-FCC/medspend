import { createFileRoute, Outlet } from "@tanstack/react-router";

export const Route = createFileRoute("/_authenticated/inventory")({
  head: () => ({
    meta: [{ title: "Inventory — MedSpend" }, { name: "robots", content: "noindex" }],
  }),
  component: Outlet,
});
