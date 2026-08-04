import { createFileRoute, Link } from "@tanstack/react-router";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "MedSpend — Sports medicine purchasing & supply requests" },
      {
        name: "description",
        content:
          "MedSpend helps athletic training and sports medicine teams manage supply requests, purchasing, and vendor invoices in one place.",
      },
      { property: "og:title", content: "MedSpend" },
      { property: "og:description", content: "Sports medicine purchasing & supply requests." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: Landing,
});

function Landing() {
  return (
    <div className="min-h-screen bg-background text-foreground">
      <header className="max-w-5xl mx-auto px-6 py-5 flex items-center justify-between">
        <div className="font-semibold tracking-tight">MedSpend</div>
        <Link
          to="/auth"
          className="text-sm rounded-md bg-primary text-primary-foreground px-4 py-2 hover:opacity-90"
        >
          Sign in
        </Link>
      </header>
      <section className="max-w-5xl mx-auto px-6 pt-16 pb-24">
        <h1 className="text-4xl md:text-6xl font-semibold tracking-tight max-w-3xl">
          Supply requests and purchasing for sports medicine, in one place.
        </h1>
        <p className="mt-6 text-lg text-muted-foreground max-w-2xl">
          MedSpend gives athletic training staff a fast way to request supplies, and
          gives owners and admins a clean workflow for approving purchases and tracking
          invoices — with strict role separation between staff and administrators.
        </p>
        <div className="mt-8 flex gap-3">
          <Link
            to="/auth"
            className="rounded-md bg-primary text-primary-foreground px-5 py-3 text-sm font-medium hover:opacity-90"
          >
            Get started
          </Link>
        </div>
      </section>
    </div>
  );
}
