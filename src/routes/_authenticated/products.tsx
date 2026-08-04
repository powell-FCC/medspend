import { createFileRoute } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useState } from "react";
import { useActiveOrg } from "@/hooks/use-active-org";
import { deleteAliasFn, listCatalogFn, saveAliasFn, saveCategoryFn, saveProductFn, setCategoryActiveFn, setProductActiveFn } from "@/lib/catalog.functions";

export const Route = createFileRoute("/_authenticated/products")({
  head: () => ({ meta: [{ title: "Products — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: ProductsPage,
});

const field = "w-full rounded-md border bg-background px-3 py-2 text-sm";
const button = "rounded-md bg-primary px-3 py-2 text-sm font-medium text-primary-foreground disabled:opacity-50";

function ProductsPage() {
  const { active } = useActiveOrg();
  const [tab, setTab] = useState<"products" | "categories">("products");
  const [q, setQ] = useState("");
  const list = useServerFn(listCatalogFn);
  const query = useQuery({
    queryKey: ["catalog", active?.organizationId, q],
    queryFn: () => list({ data: { organizationId: active!.organizationId, q, includeArchived: true } }),
    enabled: !!active,
  });
  return (
    <div className="mx-auto max-w-6xl px-6 py-8" data-page="catalog-products">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div><h1 className="text-2xl font-semibold">Product catalog</h1><p className="text-sm text-muted-foreground">Manage requestable products, aliases, and categories.</p></div>
        <input aria-label="Search catalog" className={`${field} max-w-xs`} placeholder="Search catalog…" value={q} onChange={(e) => setQ(e.target.value)} />
      </div>
      <div className="mt-6 flex gap-2">
        {(["products", "categories"] as const).map((value) => <button key={value} onClick={() => setTab(value)} className={`rounded-md border px-4 py-2 text-sm ${tab === value ? "bg-primary text-primary-foreground" : ""}`}>{value === "products" ? "Products" : "Categories"}</button>)}
      </div>
      {query.isLoading && <p className="mt-6 text-sm text-muted-foreground">Loading…</p>}
      {query.error && <p className="mt-6 text-sm text-destructive">{String(query.error.message)}</p>}
      {active && query.data && (tab === "categories"
        ? <Categories organizationId={active.organizationId} rows={query.data.categories as any[]} />
        : <Products organizationId={active.organizationId} rows={query.data.products as any[]} categories={query.data.categories as any[]} vendors={query.data.vendors as any[]} />)}
    </div>
  );
}

function Categories({ organizationId, rows }: { organizationId: string; rows: any[] }) {
  const qc = useQueryClient(); const save = useServerFn(saveCategoryFn); const setActive = useServerFn(setCategoryActiveFn);
  const [editing, setEditing] = useState<any>(null); const [name, setName] = useState(""); const [parent, setParent] = useState(""); const [message, setMessage] = useState("");
  async function submit(e: React.FormEvent) {
    e.preventDefault(); setMessage("");
    try { await save({ data: { organizationId, id: editing?.id, name, parentCategoryId: parent || null } }); setName(""); setParent(""); setEditing(null); await qc.invalidateQueries({ queryKey: ["catalog", organizationId] }); }
    catch (error) { setMessage(error instanceof Error ? error.message : "Unable to save category"); }
  }
  return <section className="mt-6 grid gap-6 lg:grid-cols-[320px_1fr]" data-section="categories">
    <form onSubmit={submit} className="h-fit space-y-3 rounded-lg border bg-card p-4">
      <h2 className="font-medium">{editing ? "Edit category" : "New category"}</h2>
      <input aria-label="Category name" className={field} placeholder="Category name" value={name} onChange={(e) => setName(e.target.value)} required />
      <select aria-label="Parent category" className={field} value={parent} onChange={(e) => setParent(e.target.value)}><option value="">No parent</option>{rows.filter((r) => r.id !== editing?.id).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select>
      {message && <p role="alert" className="text-xs text-destructive">{message}</p>}
      <div className="flex gap-2"><button className={button}>Save category</button>{editing && <button type="button" className="text-sm underline" onClick={() => { setEditing(null); setName(""); setParent(""); }}>Cancel</button>}</div>
    </form>
    <div className="space-y-2">{rows.map((row) => <div key={row.id} data-category={row.name} className="flex items-center justify-between rounded-lg border bg-card p-3"><div><div className="font-medium">{row.name}</div><div className="text-xs text-muted-foreground">{row.active ? "Active" : "Archived"}</div></div><div className="flex gap-2"><button className="text-sm underline" onClick={() => { setEditing(row); setName(row.name); setParent(row.parent_category_id ?? ""); }}>Edit</button><button className="text-sm underline" onClick={async () => { try { await setActive({ data: { organizationId, id: row.id, active: !row.active } }); await qc.invalidateQueries({ queryKey: ["catalog", organizationId] }); } catch (e) { setMessage(e instanceof Error ? e.message : "Unable to update category"); } }}>{row.active ? "Archive" : "Restore"}</button></div></div>)}</div>
  </section>;
}

function Products({ organizationId, rows, categories, vendors }: { organizationId: string; rows: any[]; categories: any[]; vendors: any[] }) {
  const qc = useQueryClient(); const save = useServerFn(saveProductFn); const setActive = useServerFn(setProductActiveFn); const saveAlias = useServerFn(saveAliasFn); const removeAlias = useServerFn(deleteAliasFn);
  const empty = { name: "", description: "", categoryId: "", preferredVendorId: "", manufacturer: "", vendorItemNumber: "", internalItemCode: "", unitOfMeasure: "", packSize: "", staffRequestable: true };
  const [form, setForm] = useState<any>(empty); const [editing, setEditing] = useState<any>(null); const [aliasProduct, setAliasProduct] = useState<any>(null); const [alias, setAlias] = useState(""); const [message, setMessage] = useState("");
  const update = (key: string, value: any) => setForm((old: any) => ({ ...old, [key]: value }));
  async function submit(e: React.FormEvent) {
    e.preventDefault(); setMessage("");
    try { const result = await save({ data: { organizationId, id: editing?.id, ...form, categoryId: form.categoryId || null, preferredVendorId: form.preferredVendorId || null } }); setMessage(result.warnings.length ? `Saved. Possible duplicate: ${result.warnings.map((w: any) => w.name).join(", ")}. No records were merged.` : "Saved product"); setForm(empty); setEditing(null); await qc.invalidateQueries({ queryKey: ["catalog", organizationId] }); }
    catch (error) { setMessage(error instanceof Error ? error.message : "Unable to save product"); }
  }
  function edit(row: any) { setEditing(row); setForm({ name: row.name, description: row.description ?? "", categoryId: row.category_id ?? "", preferredVendorId: row.preferred_vendor_id ?? "", manufacturer: row.manufacturer ?? "", vendorItemNumber: row.vendor_item_number ?? "", internalItemCode: row.internal_item_code ?? "", unitOfMeasure: row.unit_of_measure ?? "", packSize: row.pack_size ?? "", staffRequestable: row.staff_requestable }); }
  return <section className="mt-6 space-y-6" data-section="products">
    <form onSubmit={submit} className="rounded-lg border bg-card p-4"><h2 className="font-medium">{editing ? "Edit product" : "New product"}</h2><div className="mt-3 grid gap-3 md:grid-cols-2 lg:grid-cols-3">
      <input aria-label="Product name" className={field} placeholder="Product name" required value={form.name} onChange={(e) => update("name", e.target.value)} />
      <input aria-label="Manufacturer" className={field} placeholder="Manufacturer" value={form.manufacturer} onChange={(e) => update("manufacturer", e.target.value)} />
      <input aria-label="Vendor item number" className={field} placeholder="Vendor item number" value={form.vendorItemNumber} onChange={(e) => update("vendorItemNumber", e.target.value)} />
      <input aria-label="Internal item code" className={field} placeholder="Internal item code" value={form.internalItemCode} onChange={(e) => update("internalItemCode", e.target.value)} />
      <input aria-label="Unit of measure" className={field} placeholder="Unit of measure" value={form.unitOfMeasure} onChange={(e) => update("unitOfMeasure", e.target.value)} />
      <input aria-label="Pack size" className={field} placeholder="Pack size" value={form.packSize} onChange={(e) => update("packSize", e.target.value)} />
      <select aria-label="Category" className={field} value={form.categoryId} onChange={(e) => update("categoryId", e.target.value)}><option value="">No category</option>{categories.filter((r) => r.active).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select>
      <select aria-label="Preferred vendor" className={field} value={form.preferredVendorId} onChange={(e) => update("preferredVendorId", e.target.value)}><option value="">No preferred vendor</option>{vendors.filter((r) => r.active).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select>
      <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={form.staffRequestable} onChange={(e) => update("staffRequestable", e.target.checked)} /> Staff requestable</label>
      <textarea aria-label="Product description" className={`${field} md:col-span-2 lg:col-span-3`} placeholder="Description" value={form.description} onChange={(e) => update("description", e.target.value)} />
    </div>{message && <p role="status" className="mt-3 text-xs">{message}</p>}<div className="mt-3 flex gap-2"><button className={button}>Save product</button>{editing && <button type="button" className="text-sm underline" onClick={() => { setEditing(null); setForm(empty); }}>Cancel</button>}</div></form>
    <div className="grid gap-3">{rows.map((row) => <article key={row.id} data-product={row.name} className="rounded-lg border bg-card p-4"><div className="flex flex-wrap justify-between gap-3"><div><h3 className="font-medium">{row.name}</h3><p className="text-xs text-muted-foreground">{row.manufacturer || "No manufacturer"} · {row.active ? "Active" : "Archived"} · {row.staff_requestable ? "Staff requestable" : "Admin only"}</p>{row.product_aliases?.length > 0 && <p className="mt-1 text-xs">Aliases: {row.product_aliases.map((a: any) => a.alias).join(", ")}</p>}</div><div className="flex gap-2"><button className="text-sm underline" onClick={() => edit(row)}>Edit</button><button className="text-sm underline" onClick={() => setAliasProduct(row)}>Aliases</button><button className="text-sm underline" onClick={async () => { await setActive({ data: { organizationId, id: row.id, active: !row.active } }); await qc.invalidateQueries({ queryKey: ["catalog", organizationId] }); }}>{row.active ? "Archive" : "Restore"}</button></div></div>
      {aliasProduct?.id === row.id && <form className="mt-3 flex flex-wrap gap-2 border-t pt-3" onSubmit={async (e) => { e.preventDefault(); await saveAlias({ data: { organizationId, productId: row.id, alias } }); setAlias(""); await qc.invalidateQueries({ queryKey: ["catalog", organizationId] }); }}><input aria-label="Product alias" className={`${field} max-w-xs`} placeholder="Add alias" value={alias} onChange={(e) => setAlias(e.target.value)} required /><button className={button}>Add alias</button>{row.product_aliases?.map((a: any) => <button type="button" key={a.id} className="rounded border px-2 text-xs" title="Remove alias" onClick={async () => { await removeAlias({ data: { organizationId, id: a.id } }); await qc.invalidateQueries({ queryKey: ["catalog", organizationId] }); }}>{a.alias} ×</button>)}</form>}
    </article>)}</div>
  </section>;
}
