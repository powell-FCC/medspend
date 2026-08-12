import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { ArrowLeft, MessageCircle } from "lucide-react";
import { useActiveOrg } from "@/hooks/use-active-org";
import { getStaffRequestDetailFn } from "@/lib/supply-requests.functions";
import { RequestDetailHeader } from "@/components/staff/RequestDetailHeader";
import { RequestDetailTimeline } from "@/components/staff/RequestDetailTimeline";

export const Route = createFileRoute("/_authenticated/staff/requests/$id")({
  head: () => ({ meta: [{ title: "Request details — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: StaffRequestDetail,
});

function StaffRequestDetail() {
  const { id } = Route.useParams();
  const { active } = useActiveOrg();
  const fetchDetail = useServerFn(getStaffRequestDetailFn);
  const request = useQuery({
    queryKey: ["me", active?.organizationId, "requests", id],
    queryFn: () => fetchDetail({ data: { organizationId: active!.organizationId, requestId: id } }),
    enabled: !!active,
  });

  return <div className="space-y-6">
    <Link to="/staff/requests" className="inline-flex min-h-11 items-center gap-2 py-2 text-sm font-semibold text-[#526174]"><ArrowLeft className="size-4" /> My Requests</Link>
    {request.isLoading && <div className="rounded-2xl bg-white p-6 text-sm text-[#697687]">Loading request…</div>}
    {request.isError && <div role="alert" className="rounded-2xl bg-[#fff0f1] p-5 text-sm text-[#a83340]">This request isn't available.</div>}
    {request.data && <>
      <RequestDetailHeader request={request.data} />
      {request.data.staffMessage && <section className="rounded-2xl border border-[#e1e6ec] bg-white p-5">
        <div className="flex items-center gap-2 text-sm font-semibold"><MessageCircle className="size-4 text-[#f56600]" /> Latest Update</div>
        <p className="mt-3 text-sm leading-6 text-[#526174]">{request.data.staffMessage}</p>
      </section>}
      <section className="rounded-2xl border border-[#e1e6ec] bg-white p-5">
        <h2 className="mb-6 text-sm font-semibold text-[#34445a]">Timeline</h2>
        <RequestDetailTimeline items={request.data.timeline} />
      </section>
    </>}
  </div>;
}
