import { createFileRoute } from "@tanstack/react-router";
import { useAuth } from "@/hooks/use-auth";
import { useActiveOrg } from "@/hooks/use-active-org";

export const Route = createFileRoute("/_authenticated/profile")({
  head: () => ({ meta: [{ title: "Profile — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: Profile,
});

function Profile() {
  const { user } = useAuth();
  const { active } = useActiveOrg();
  return (
    <div>
      <h1 className="text-2xl font-semibold">Profile</h1>
      <dl className="mt-6 space-y-3 text-sm">
        <Row label="Name" value={user?.user_metadata?.full_name ?? "—"} />
        <Row label="Email" value={user?.email ?? "—"} />
        <Row label="Organization" value={active?.organizationName ?? "—"} />
        <Row label="Role" value={active?.role ?? "—"} />
      </dl>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between border-b pb-2">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="font-medium">{value}</dd>
    </div>
  );
}