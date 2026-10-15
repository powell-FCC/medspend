import { createFileRoute, redirect } from "@tanstack/react-router";

// The Budget page became Budget & Purchasing; keep old links and bookmarks working.
export const Route = createFileRoute("/_authenticated/budget")({
  beforeLoad: () => {
    throw redirect({ to: "/budget-purchasing", replace: true });
  },
});
