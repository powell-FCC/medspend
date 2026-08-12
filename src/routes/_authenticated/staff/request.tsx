import { createFileRoute, Link, useSearch } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Check, Minus, Plus, Search, X } from "lucide-react";
import { useState } from "react";
import { z } from "zod";
import { useActiveOrg } from "@/hooks/use-active-org";
import { listOrgStructureFn } from "@/lib/org-structure.functions";
import { searchProductsFn, submitSupplyRequestFn } from "@/lib/supply-requests.functions";

const search = z.object({
  type: z.enum(["reorder", "low_stock", "out_of_stock", "new_item"]).optional(),
});

export const Route = createFileRoute("/_authenticated/staff/request")({
  validateSearch: (value) => search.parse(value),
  head: () => ({ meta: [{ title: "Request supplies — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: RequestPage,
});

function RequestPage() {
  const { active } = useActiveOrg();
  const routeSearch = useSearch({ from: "/_authenticated/staff/request" });
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<{ id: string; name: string; unit: string | null } | null>(null);
  const [customItem, setCustomItem] = useState("");
  const [quantity, setQuantity] = useState(1);
  const [items, setItems] = useState<Array<{ key: string; productId: string | null; name: string; unit: string | null; quantity: number }>>([]);
  const [notes, setNotes] = useState("");
  const [teamId, setTeamId] = useState("");
  const [locationId, setLocationId] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [submitted, setSubmitted] = useState(false);
  const searchFn = useServerFn(searchProductsFn);
  const submitFn = useServerFn(submitSupplyRequestFn);
  const listStructure = useServerFn(listOrgStructureFn);
  const queryClient = useQueryClient();
  const products = useQuery({
    queryKey: ["products", active?.organizationId, query],
    queryFn: () => searchFn({ data: { organizationId: active!.organizationId, q: query } }),
    enabled: !!active && query.trim().length >= 2 && !selected,
  });
  const structure = useQuery({
    queryKey: ["org", active?.organizationId, "request-context"],
    queryFn: () => listStructure({ data: { organizationId: active!.organizationId, includeArchived: false } }),
    enabled: !!active,
  });
  const hasActiveDefaultTeam = !!active?.defaultTeamId && structure.data?.teams.some((team) => team.id === active.defaultTeamId);
  const hasActiveDefaultLocation = !!active?.defaultLocationId && structure.data?.locations.some((location) => location.id === active.defaultLocationId);

  function addItem() {
    const name = selected?.name ?? customItem.trim();
    if (!name || !Number.isInteger(quantity) || quantity <= 0) return;
    setItems((current) => [...current, { key: crypto.randomUUID(), productId: selected?.id ?? null, name, unit: selected?.unit ?? null, quantity }]);
    setSelected(null); setCustomItem(""); setQuery(""); setQuantity(1);
  }

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);
    setBusy(true);
    try {
      await submitFn({ data: {
        organizationId: active!.organizationId,
        requestType: routeSearch.type ?? (items.some((item) => !item.productId) ? "new_item" : "reorder"),
        items: items.map((item) => ({ productId: item.productId, freeTextItem: item.productId ? null : item.name, quantity: item.quantity })),
        teamId: hasActiveDefaultTeam ? active!.defaultTeamId : teamId || null,
        locationId: hasActiveDefaultLocation ? active!.defaultLocationId : locationId || null,
        notes: notes.trim() || null,
      } });
      await queryClient.invalidateQueries({ queryKey: ["me", active?.organizationId, "requests"] });
      setSubmitted(true);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "We couldn't submit your request.");
    } finally {
      setBusy(false);
    }
  }

  if (submitted) return (
    <div className="flex min-h-[65dvh] flex-col items-center justify-center text-center">
      <span className="flex size-16 items-center justify-center rounded-full bg-[#edf7f1] text-[#286443]"><Check className="size-8" /></span>
      <h1 className="mt-6 text-2xl font-semibold tracking-tight">Request Submitted</h1>
      <p className="mt-2 max-w-xs text-sm leading-6 text-[#667384]">We'll update you when it is ready.</p>
      <Link to="/staff/requests" className="mt-8 flex min-h-12 w-full items-center justify-center rounded-xl bg-[#071d38] px-5 font-semibold text-white">View My Requests</Link>
      <button type="button" onClick={() => { setSubmitted(false); setSelected(null); setItems([]); setCustomItem(""); setQuery(""); setQuantity(1); setNotes(""); }} className="mt-3 min-h-12 w-full text-sm font-semibold text-[#d95700]">Request another item</button>
    </div>
  );

  const hasItem = !!selected || !!customItem.trim();
  return (
    <div>
      <header>
        <p className="text-xs font-semibold uppercase tracking-[0.16em] text-[#697687]">New Request</p>
        <h1 className="mt-1 text-[1.7rem] font-semibold tracking-tight">What do you need?</h1>
      </header>
      <form onSubmit={submit} className="mt-7 space-y-7">
        {(!hasActiveDefaultTeam || !hasActiveDefaultLocation) && <section className="grid gap-4">
          {!hasActiveDefaultTeam && <label className="text-sm font-semibold">Team
            <select aria-label="Team" required value={teamId} onChange={(event) => setTeamId(event.target.value)} className="mt-2 min-h-12 w-full rounded-xl border border-[#dce2e8] bg-white px-3 font-normal">
              <option value="">Select team</option>
              {structure.data?.teams.map((team) => <option key={team.id} value={team.id}>{team.name}</option>)}
            </select>
          </label>}
          {!hasActiveDefaultLocation && <label className="text-sm font-semibold">Location
            <select aria-label="Location" required value={locationId} onChange={(event) => setLocationId(event.target.value)} className="mt-2 min-h-12 w-full rounded-xl border border-[#dce2e8] bg-white px-3 font-normal">
              <option value="">Select location</option>
              {structure.data?.locations.map((location) => <option key={location.id} value={location.id}>{location.name}</option>)}
            </select>
          </label>}
        </section>}
        <section>
          <label htmlFor="supply-search" className="text-sm font-semibold">Search supplies</label>
          {!selected ? <>
            <div className="relative mt-2">
              <Search className="absolute left-4 top-1/2 size-5 -translate-y-1/2 text-[#7b8693]" aria-hidden="true" />
              <input id="supply-search" value={query} onChange={(event) => { setQuery(event.target.value); setCustomItem(""); }} placeholder="Tape, gloves, gauze…" autoComplete="off" className="min-h-14 w-full rounded-2xl border border-[#dce2e8] bg-white pl-12 pr-4 text-base shadow-sm outline-none placeholder:text-[#9aa3ad] focus:border-[#f56600] focus:ring-4 focus:ring-[#f56600]/10" />
            </div>
            {(products.data?.length ?? 0) > 0 && <div className="mt-2 overflow-hidden rounded-2xl border border-[#dfe5eb] bg-white shadow-lg">
              {products.data?.map((product: { id: string; name: string; unit: string | null }) => <button key={product.id} type="button" onClick={() => { setSelected(product); setQuery(""); }} className="flex min-h-14 w-full items-center justify-between border-b border-[#edf0f3] px-4 text-left last:border-0 hover:bg-[#f7f8fa] focus-visible:bg-[#f7f8fa]">
                <span className="font-medium">{product.name}</span><span className="text-xs text-[#75808e]">{product.unit}</span>
              </button>)}
            </div>}
            <details className="mt-4 group">
              <summary className="min-h-11 cursor-pointer list-none py-3 text-sm font-semibold text-[#566477]">Can't find the item?</summary>
              <label htmlFor="custom-item" className="sr-only">Item name</label>
              <input id="custom-item" value={customItem} onChange={(event) => { setCustomItem(event.target.value); setQuery(""); }} placeholder="Enter the item name" className="min-h-14 w-full rounded-2xl border border-[#dce2e8] bg-white px-4 text-base outline-none focus:border-[#f56600] focus:ring-4 focus:ring-[#f56600]/10" />
            </details>
          </> : <div className="mt-2 flex min-h-20 items-center justify-between rounded-2xl border border-[#dce2e8] bg-white p-4 shadow-sm">
            <div><div className="font-semibold">{selected.name}</div>{selected.unit && <div className="mt-1 text-sm text-[#697687]">{selected.unit}</div>}</div>
            <button type="button" onClick={() => setSelected(null)} className="flex size-11 items-center justify-center rounded-full text-[#637080] hover:bg-[#f0f2f5]" aria-label="Change selected item"><X className="size-5" /></button>
          </div>}
        </section>

        {hasItem && <>
          <section>
            <div className="text-sm font-semibold">Quantity</div>
            <div className="mt-2 flex items-center justify-between rounded-2xl border border-[#dce2e8] bg-white p-2 shadow-sm">
              <button type="button" onClick={() => setQuantity((value) => Math.max(1, value - 1))} className="flex size-12 items-center justify-center rounded-xl bg-[#eef1f4]" aria-label="Decrease quantity"><Minus className="size-5" /></button>
              <span className="text-xl font-semibold tabular-nums" aria-live="polite">{quantity}</span>
              <button type="button" onClick={() => setQuantity((value) => value + 1)} className="flex size-12 items-center justify-center rounded-xl bg-[#071d38] text-white" aria-label="Increase quantity"><Plus className="size-5" /></button>
            </div>
          </section>
          <button type="button" onClick={addItem} className="min-h-12 w-full rounded-xl border border-[#f56600] font-semibold text-[#d95700]">Add to Request</button>
        </>}

        {items.length > 0 && <>
          <section className="rounded-2xl border border-[#dce2e8] bg-white p-4">
            <h2 className="font-semibold text-[#071d38]">Your Request</h2>
            <div className="mt-3 divide-y divide-[#edf0f3]">
              {items.map((item) => <div key={item.key} className="flex items-center gap-3 py-3">
                <div className="min-w-0 flex-1"><div className="truncate font-medium">{item.name}</div><div className="mt-1 text-sm text-[#697687]">{item.quantity}{item.unit ? ` ${item.unit}` : ""}</div></div>
                <button type="button" onClick={() => setItems((current) => current.map((candidate) => candidate.key === item.key ? { ...candidate, quantity: Math.max(1, candidate.quantity - 1) } : candidate))} aria-label={`Decrease ${item.name}`} className="flex size-10 items-center justify-center rounded-lg bg-[#eef1f4]"><Minus className="size-4" /></button>
                <button type="button" onClick={() => setItems((current) => current.map((candidate) => candidate.key === item.key ? { ...candidate, quantity: candidate.quantity + 1 } : candidate))} aria-label={`Increase ${item.name}`} className="flex size-10 items-center justify-center rounded-lg bg-[#071d38] text-white"><Plus className="size-4" /></button>
                <button type="button" onClick={() => setItems((current) => current.filter((candidate) => candidate.key !== item.key))} aria-label={`Remove ${item.name}`} className="flex size-10 items-center justify-center rounded-lg text-[#a83340]"><X className="size-4" /></button>
              </div>)}
            </div>
          </section>
          <section>
            <label htmlFor="request-note" className="text-sm font-semibold">Add a note <span className="font-normal text-[#7b8693]">(optional)</span></label>
            <textarea id="request-note" rows={3} value={notes} onChange={(event) => setNotes(event.target.value)} placeholder="Size, location, or anything helpful" className="mt-2 w-full resize-none rounded-2xl border border-[#dce2e8] bg-white p-4 text-base outline-none placeholder:text-[#9aa3ad] focus:border-[#f56600] focus:ring-4 focus:ring-[#f56600]/10" />
          </section>
          {error && <p role="alert" className="rounded-xl bg-[#fff0f1] p-3 text-sm text-[#a83340]">{error}</p>}
          <button type="submit" disabled={busy} className="min-h-14 w-full rounded-2xl bg-[#f56600] px-5 text-base font-semibold text-white shadow-[0_10px_25px_rgba(245,102,0,0.22)] disabled:opacity-60">{busy ? "Submitting…" : "Submit Request"}</button>
        </>}
      </form>
    </div>
  );
}
