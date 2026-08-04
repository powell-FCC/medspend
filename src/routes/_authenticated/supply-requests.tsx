import { createFileRoute } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useState } from "react";
import { useActiveOrg } from "@/hooks/use-active-org";
import { listOrgRequestsFn, updateRequestStatusFn } from "@/lib/supply-requests.functions";

export const Route = createFileRoute("/_authenticated/supply-requests")({
  head: () => ({ meta: [{ title: "Supply Requests — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: Page,
});

type TabKey = "open" | "urgent" | "new" | "oos" | "total";

const STATUSES = ["submitted", "under_review", "approved", "ordered", "received", "completed", "denied"] as const;

function Page() {
  const { active } = useActiveOrg();
  const fetcher = useServerFn(listOrgRequestsFn);
  const update = useServerFn(updateRequestStatusFn);
  const qc = useQueryClient();
  const [tab, setTab] = useState<TabKey>("open");
  const [openId, setOpenId] = useState<string | null>(null);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);

  const q = useQuery({
    queryKey: ["org", active?.organizationId, "requests"],
    queryFn: () => fetcher({ data: { organizationId: active!.organizationId } }),
    enabled: !!active,
  });

  const all = q.data ?? [];
  const filtered = all.filter((r) => {
    if (tab === "open") return !["completed", "denied", "received"].includes(r.status);
    if (tab === "urgent") return r.requestType === "out_of_stock" && !["completed", "denied"].includes(r.status);
    if (tab === "new") return r.requestType === "new_item";
    if (tab === "oos") return r.requestType === "out_of_stock";
    return true;
  });

  const counts = {
    open: all.filter((r) => !["completed", "denied", "received"].includes(r.status)).length,
    urgent: all.filter((r) => r.requestType === "out_of_stock" && !["completed", "denied"].includes(r.status)).length,
    new: all.filter((r) => r.requestType === "new_item").length,
    oos: all.filter((r) => r.requestType === "out_of_stock").length,
    total: all.length,
  };

  const openRow = all.find((r) => r.id === openId) ?? null;

  async function setStatus(id: string, status: (typeof STATUSES)[number]) {
    setBusy(true);
    try {
      await update({
        data: {
          id,
          status,
          staffVisibleNote: note.trim() || null,
          orderedAt: status === "ordered" ? new Date().toISOString() : null,
          receivedAt: status === "received" ? new Date().toISOString() : null,
        },
      });
      setNote("");
      await qc.invalidateQueries({ queryKey: ["org", active?.organizationId, "requests"] });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="max-w-6xl mx-auto px-6 py-8">
      <h1 className="text-2xl font-semibold">Supply Requests</h1>
      <div className="mt-4 flex gap-2 flex-wrap">
        {(["open", "urgent", "new", "oos", "total"] as TabKey[]).map((k) => (
          <button
            key={k}
            onClick={() => setTab(k)}
            className={
              "rounded-full border px-3 py-1 text-xs " +
              (tab === k ? "bg-primary text-primary-foreground border-primary" : "hover:bg-muted")
            }
          >
            {labelFor(k)} <span className="opacity-70">· {counts[k]}</span>
          </button>
        ))}
      </div>
      <div className="mt-4 rounded-xl border bg-card overflow-hidden">
        <table className="w-full text-sm">
          <thead className="bg-muted text-xs uppercase tracking-wider text-muted-foreground">
            <tr>
              <th className="text-left px-3 py-2">Item</th>
              <th className="text-left px-3 py-2">Type</th>
              <th className="text-left px-3 py-2">Qty</th>
              <th className="text-left px-3 py-2">Requester</th>
              <th className="text-left px-3 py-2">Status</th>
              <th className="text-left px-3 py-2">Submitted</th>
              <th className="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((r) => (
              <tr key={r.id} className="border-t">
                <td className="px-3 py-2">{r.itemName}</td>
                <td className="px-3 py-2 text-xs">{r.requestType}</td>
                <td className="px-3 py-2">{r.quantity ?? "—"}</td>
                <td className="px-3 py-2 text-xs">{r.requestedBy}</td>
                <td className="px-3 py-2 text-xs">{r.status}</td>
                <td className="px-3 py-2 text-xs text-muted-foreground">{new Date(r.createdAt).toLocaleDateString()}</td>
                <td className="px-3 py-2">
                  <button onClick={() => setOpenId(r.id)} className="text-xs underline">
                    Review
                  </button>
                </td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr>
                <td colSpan={7} className="px-3 py-8 text-center text-sm text-muted-foreground">
                  No requests.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {openRow && (
        <div
          className="fixed inset-0 bg-black/40 flex items-end md:items-center justify-center p-4"
          onClick={() => setOpenId(null)}
        >
          <div className="bg-card rounded-xl w-full max-w-md p-5" onClick={(e) => e.stopPropagation()}>
            <div className="text-xs text-muted-foreground">Request</div>
            <div className="text-lg font-semibold">{openRow.itemName}</div>
            <div className="mt-1 text-xs text-muted-foreground">
              {openRow.requestType} · qty {openRow.quantity ?? "—"} · by {openRow.requestedBy}
            </div>
            {openRow.notes && <div className="mt-3 text-sm">{openRow.notes}</div>}
            <label className="mt-4 block text-xs text-muted-foreground">Staff-visible note (optional)</label>
            <textarea
              value={note}
              onChange={(e) => setNote(e.target.value)}
              className="mt-1 w-full rounded-md border bg-background px-2 py-1 text-sm"
              rows={3}
            />
            <div className="mt-3 flex flex-wrap gap-2">
              {STATUSES.map((s) => (
                <button
                  key={s}
                  disabled={busy}
                  onClick={() => setStatus(openRow.id, s)}
                  className={
                    "rounded-md border px-2 py-1 text-xs " +
                    (openRow.status === s ? "bg-primary text-primary-foreground border-primary" : "hover:bg-muted")
                  }
                >
                  {s}
                </button>
              ))}
            </div>
            <button onClick={() => setOpenId(null)} className="mt-4 text-xs text-muted-foreground">
              Close
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

function labelFor(k: TabKey) {
  return { open: "Open", urgent: "Urgent", new: "New Items", oos: "Out of Stock", total: "Total" }[k];
}