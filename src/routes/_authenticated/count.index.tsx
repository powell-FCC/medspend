import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useCallback } from "react";
import { useActiveOrg } from "@/hooks/use-active-org";
import { listCountableLocationsFn } from "@/lib/inventory-count.functions";
import { CountLocationPicker } from "@/components/count/CountLocationPicker";
import { QrScannerView } from "@/components/count/QrScanner";
import { useQrScanner } from "@/count/use-qr-scanner";

export const Route = createFileRoute("/_authenticated/count/")({
  head: () => ({
    meta: [{ title: "Scan Inventory QR — MedSpend" }, { name: "robots", content: "noindex" }],
  }),
  component: CountHome,
});

// Scan Inventory QR. The scanner opens a label's count inside the app; if the camera can't
// run, the phone's own camera or the location list gets there just the same.
function CountHome() {
  const navigate = useNavigate();
  const { active } = useActiveOrg();
  const onToken = useCallback(
    (token: string) => navigate({ to: "/count/$token", params: { token } }),
    [navigate],
  );
  const scanner = useQrScanner(onToken);
  const list = useServerFn(listCountableLocationsFn);
  const locations = useQuery({
    queryKey: ["count-locations", active?.organizationId],
    queryFn: () => list({ data: { organizationId: active!.organizationId } }),
    enabled: !!active,
  });

  return (
    <div className="space-y-6">
      <header className="pr-16">
        <p className="text-[0.7rem] font-semibold uppercase tracking-[0.18em] text-[#5c6878]">
          Physical inventory count
        </p>
        <h1 className="mt-1 text-[1.6rem] font-semibold tracking-[-0.03em] text-[#071d38]">
          Scan Inventory QR
        </h1>
        <p className="mt-0.5 text-sm text-[#697687]">
          Scan the label on a cabinet, closet or cart to count what's there.
        </p>
      </header>
      <QrScannerView
        state={scanner.state}
        videoRef={scanner.videoRef}
        notice={scanner.notice}
        onStart={() => void scanner.start()}
      />
      <CountLocationPicker
        locations={locations.data}
        loading={locations.isLoading}
        error={locations.error ? "Couldn't load locations." : null}
        onRetry={() => void locations.refetch()}
        onSelect={(locationId) =>
          navigate({ to: "/count/location/$locationId", params: { locationId } })
        }
      />
    </div>
  );
}
