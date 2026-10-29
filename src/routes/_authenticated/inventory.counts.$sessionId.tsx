import { createFileRoute } from "@tanstack/react-router";
import { CountSessionPage } from "@/components/inventory/workspace/CountSessionPage";

export const Route = createFileRoute("/_authenticated/inventory/counts/$sessionId")({
  head: () => ({
    meta: [{ title: "Physical count — MedSpend" }, { name: "robots", content: "noindex" }],
  }),
  component: CountRoute,
});

function CountRoute() {
  const { sessionId } = Route.useParams();
  return <CountSessionPage key={sessionId} sessionId={sessionId} />;
}
