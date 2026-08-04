import { createFileRoute, useNavigate, useSearch } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useState } from "react";
import { z } from "zod";
import { useActiveOrg } from "@/hooks/use-active-org";
import { searchProductsFn, submitSupplyRequestFn } from "@/lib/supply-requests.functions";
import { listOrgStructureFn } from "@/lib/org-structure.functions";

const search = z.object({
  type: z.enum(["reorder", "low_stock", "out_of_stock", "new_item"]).optional(),
});

export const Route = createFileRoute("/_authenticated/staff/request")({
  validateSearch: (s) => search.parse(s),
  head: () => ({ meta: [{ title: "Request supplies — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: RequestPage,
});

function RequestPage() {
  const { active } = useActiveOrg();
  const s = useSearch({ from: "/_authenticated/staff/request" });
  const navigate = useNavigate();
  const [type, setType] = useState<"reorder" | "low_stock" | "out_of_stock" | "new_item">(s.type ?? "reorder");
  const [q, setQ] = useState("");
  const [productId, setProductId] = useState<string | null>(null);
  const [productName, setProductName] = useState<string>("");
  const [freeText, setFreeText] = useState("");
  const [qty, setQty] = useState<string>("");
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [teamId, setTeamId] = useState<string>("");
  const [locationId, setLocationId] = useState<string>("");

  const searchFn = useServerFn(searchProductsFn);
  const submitFn = useServerFn(submitSupplyRequestFn);
  const listStructure = useServerFn(listOrgStructureFn);
  const qc = useQueryClient();

  const structure = useQuery({
    queryKey: ["org", active?.organizationId, "structure", "active"],
    queryFn: () => listStructure({ data: { organizationId: active!.organizationId, includeArchived: false } }),
    enabled: !!active,
  });
  const teams = structure.data?.teams ?? [];
  const locations = structure.data?.locations ?? [];

  const products = useQuery({
    queryKey: ["products", active?.organizationId, q],
    queryFn: () => searchFn({ data: { organizationId: active!.organizationId, q } }),
    enabled: !!active && q.length >= 2,
  });

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    setBusy(true);
    try {
      await submitFn({
        data: {
          organizationId: active!.organizationId,
          requestType: type,
          productId: productId ?? null,
          freeTextItem: productId ? null : freeText || null,
          quantity: qty ? Number(qty) : null,
          teamId: teamId || active!.defaultTeamId || null,
          locationId: locationId || active!.defaultLocationId || null,
          notes: notes || null,
        },
      });
      await qc.invalidateQueries({ queryKey: ["me", active?.organizationId, "requests"] });
      navigate({ to: "/staff/requests" });
    } catch (e) {
      setErr(e instanceof Error ? e.message : "Failed to submit");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div>
      <h1 className="text-2xl font-semibold">Request supplies</h1>
      <form onSubmit={submit} className="mt-6 space-y-4">
        <div>
          <label className="text-xs text-muted-foreground">Type</label>
          <div className="mt-1 grid grid-cols-2 gap-2">
            {(["reorder", "low_stock", "out_of_stock", "new_item"] as const).map((t) => (
              <button
                type="button"
                key={t}
                data-type={t}
                onClick={() => setType(t)}
                className={
                  "rounded-md border px-3 py-2 text-sm " +
                  (type === t ? "bg-primary text-primary-foreground border-primary" : "hover:bg-muted")
                }
              >
                {t.replaceAll("_", " ")}
              </button>
            ))}
          </div>
        </div>

        <div>
          <label className="text-xs text-muted-foreground">Item</label>
          {productId ? (
            <div className="mt-1 flex items-center justify-between rounded-md border bg-muted px-3 py-2 text-sm">
              <span>{productName}</span>
              <button
                type="button"
                className="text-xs underline"
                onClick={() => {
                  setProductId(null);
                  setProductName("");
                }}
              >
                Change
              </button>
            </div>
          ) : (
            <>
              <input
                className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
                placeholder="Search products…"
                value={q}
                onChange={(e) => setQ(e.target.value)}
              />
              {(products.data ?? []).length > 0 && (
                <ul className="mt-1 rounded-md border bg-card divide-y max-h-48 overflow-auto">
                  {(products.data ?? []).map((p: { id: string; name: string; unit: string | null }) => (
                    <li key={p.id}>
                      <button
                        type="button"
                        onClick={() => {
                          setProductId(p.id);
                          setProductName(p.name);
                        }}
                        className="w-full text-left px-3 py-2 text-sm hover:bg-muted"
                      >
                        {p.name}
                        {p.unit && <span className="text-xs text-muted-foreground"> · {p.unit}</span>}
                      </button>
                    </li>
                  ))}
                </ul>
              )}
              <div className="mt-3">
                <label className="text-xs text-muted-foreground">Or enter a custom item</label>
                <input
                  className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
                  placeholder="Item name"
                  value={freeText}
                  onChange={(e) => setFreeText(e.target.value)}
                />
              </div>
            </>
          )}
        </div>

        <div>
          <label className="text-xs text-muted-foreground">Quantity</label>
          <input
            type="number"
            min={0}
            className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
            value={qty}
            onChange={(e) => setQty(e.target.value)}
          />
        </div>

        {(teams.length > 0 || locations.length > 0) && (
          <div className="grid grid-cols-2 gap-2">
            {teams.length > 0 && (
              <div>
                <label className="text-xs text-muted-foreground">Team (optional)</label>
                <select
                  data-field="team"
                  className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
                  value={teamId || (active?.defaultTeamId ?? "")}
                  onChange={(e) => setTeamId(e.target.value)}
                >
                  <option value="">—</option>
                  {teams.map((t) => (
                    <option key={t.id} value={t.id}>
                      {t.name}
                    </option>
                  ))}
                </select>
              </div>
            )}
            {locations.length > 0 && (
              <div>
                <label className="text-xs text-muted-foreground">Location (optional)</label>
                <select
                  data-field="location"
                  className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
                  value={locationId || (active?.defaultLocationId ?? "")}
                  onChange={(e) => setLocationId(e.target.value)}
                >
                  <option value="">—</option>
                  {locations.map((l) => (
                    <option key={l.id} value={l.id}>
                      {l.name}
                    </option>
                  ))}
                </select>
              </div>
            )}
          </div>
        )}

        <div>
          <label className="text-xs text-muted-foreground">Notes</label>
          <textarea
            rows={3}
            className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
          />
        </div>

        {err && <div className="text-xs text-destructive">{err}</div>}
        <button
          type="submit"
          disabled={busy || (!productId && !freeText.trim())}
          className="w-full rounded-md bg-primary text-primary-foreground px-3 py-3 text-sm font-medium disabled:opacity-60"
        >
          {busy ? "Submitting…" : "Submit request"}
        </button>
      </form>
    </div>
  );
}
