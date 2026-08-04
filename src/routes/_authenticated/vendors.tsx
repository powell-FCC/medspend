import { createFileRoute } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useState } from "react";
import { useActiveOrg } from "@/hooks/use-active-org";
import { listCatalogFn, saveVendorFn, setVendorActiveFn } from "@/lib/catalog.functions";

export const Route = createFileRoute("/_authenticated/vendors")({
  head: () => ({ meta: [{ title: "Vendors — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: VendorsPage,
});

const field = "w-full rounded-md border bg-background px-3 py-2 text-sm";

function VendorsPage() {
  const { active } = useActiveOrg(); const qc = useQueryClient();
  const list = useServerFn(listCatalogFn); const save = useServerFn(saveVendorFn); const setActive = useServerFn(setVendorActiveFn);
  const [q, setQ] = useState(""); const [editing, setEditing] = useState<any>(null); const [message, setMessage] = useState("");
  const empty = { name: "", accountNumber: "", contactName: "", email: "", phone: "", website: "", notes: "" };
  const [form, setForm] = useState<any>(empty); const update = (key: string, value: string) => setForm((old: any) => ({ ...old, [key]: value }));
  const query = useQuery({ queryKey: ["catalog", active?.organizationId, q], queryFn: () => list({ data: { organizationId: active!.organizationId, q, includeArchived: true } }), enabled: !!active });
  async function submit(e: React.FormEvent) {
    e.preventDefault(); if (!active) return; setMessage("");
    try { const result = await save({ data: { organizationId: active.organizationId, id: editing?.id, ...form } }); setMessage(result.warnings.length ? `Saved. Possible duplicate: ${result.warnings.map((w: any) => w.name).join(", ")}. No records were merged.` : "Saved vendor"); setForm(empty); setEditing(null); await qc.invalidateQueries({ queryKey: ["catalog", active.organizationId] }); }
    catch (error) { setMessage(error instanceof Error ? error.message : "Unable to save vendor"); }
  }
  function edit(row: any) { setEditing(row); setForm({ name: row.name, accountNumber: row.account_number ?? "", contactName: row.contact_name ?? "", email: row.email ?? "", phone: row.phone ?? "", website: row.website ?? "", notes: row.notes ?? "" }); }
  return <div className="mx-auto max-w-6xl px-6 py-8" data-page="catalog-vendors">
    <div className="flex flex-wrap items-center justify-between gap-3"><div><h1 className="text-2xl font-semibold">Vendors</h1><p className="text-sm text-muted-foreground">Organization contacts and supplier accounts. Staff cannot access this page.</p></div><input aria-label="Search vendors" className={`${field} max-w-xs`} placeholder="Search vendors…" value={q} onChange={(e) => setQ(e.target.value)} /></div>
    <form onSubmit={submit} className="mt-6 rounded-lg border bg-card p-4"><h2 className="font-medium">{editing ? "Edit vendor" : "New vendor"}</h2><div className="mt-3 grid gap-3 md:grid-cols-2 lg:grid-cols-3">
      <input aria-label="Vendor name" className={field} placeholder="Vendor name" required value={form.name} onChange={(e) => update("name", e.target.value)} />
      <input aria-label="Account number" className={field} placeholder="Account number" value={form.accountNumber} onChange={(e) => update("accountNumber", e.target.value)} />
      <input aria-label="Contact name" className={field} placeholder="Contact name" value={form.contactName} onChange={(e) => update("contactName", e.target.value)} />
      <input aria-label="Vendor email" type="email" className={field} placeholder="Email" value={form.email} onChange={(e) => update("email", e.target.value)} />
      <input aria-label="Vendor phone" className={field} placeholder="Phone" value={form.phone} onChange={(e) => update("phone", e.target.value)} />
      <input aria-label="Vendor website" className={field} placeholder="Website" value={form.website} onChange={(e) => update("website", e.target.value)} />
      <textarea aria-label="Vendor notes" className={`${field} md:col-span-2 lg:col-span-3`} placeholder="Notes" value={form.notes} onChange={(e) => update("notes", e.target.value)} />
    </div>{message && <p role="status" className="mt-3 text-xs">{message}</p>}<div className="mt-3 flex gap-2"><button className="rounded-md bg-primary px-3 py-2 text-sm font-medium text-primary-foreground">Save vendor</button>{editing && <button type="button" className="text-sm underline" onClick={() => { setEditing(null); setForm(empty); }}>Cancel</button>}</div></form>
    {query.error && <p className="mt-4 text-sm text-destructive">{query.error.message}</p>}
    <div className="mt-6 grid gap-3">{(query.data?.vendors as any[] | undefined)?.map((row) => <article key={row.id} data-vendor={row.name} className="rounded-lg border bg-card p-4"><div className="flex flex-wrap items-start justify-between gap-3"><div><h3 className="font-medium">{row.name}</h3><p className="text-xs text-muted-foreground">{row.active ? "Active" : "Archived"}{row.account_number ? ` · Account ${row.account_number}` : ""}</p><p className="mt-1 text-sm">{[row.contact_name, row.email, row.phone].filter(Boolean).join(" · ") || "No contact details"}</p></div><div className="flex gap-2"><button className="text-sm underline" onClick={() => edit(row)}>Edit</button><button className="text-sm underline" onClick={async () => { if (!active) return; try { await setActive({ data: { organizationId: active.organizationId, id: row.id, active: !row.active } }); await qc.invalidateQueries({ queryKey: ["catalog", active.organizationId] }); } catch (e) { setMessage(e instanceof Error ? e.message : "Unable to update vendor"); } }}>{row.active ? "Archive" : "Restore"}</button></div></div></article>)}</div>
  </div>;
}
