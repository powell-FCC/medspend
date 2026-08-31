# Henry Schein Phase 5A.4B dry-run transformer

This directory contains the offline, standard-library-only transformer for the
reviewed Henry Schein v28 QA workbook and immutable v25 source archive. It does
not connect to Supabase and contains no database mutation code.

Run from the repository root:

```sh
python3 scripts/catalog/henry-schein/transform.py \
  --v28 inputs/catalog/henry-schein/Henry_Schein_Product_Registry_Master_v28_QA_Final.xlsx \
  --v25 inputs/catalog/henry-schein/Henry_Schein_Product_Registry_Master_v25.xlsx \
  --output-dir outputs/catalog/henry-schein/v28
```

The transformer pins the reviewed filenames and SHA-256 digests. A different
file fails before transformation.

Source ordinals follow v28 `Category Metrics` catalog-page order and then the
original row order of the corresponding v25 occurrence sheet. This is stable
and avoids the non-page-ordered diagnostic tabs in v25.

Canonical products use one conservative product per promoted Henry Schein SKU.
No fuzzy matching, cross-vendor merging, or source-category-to-global-taxonomy
mapping occurs. `catalog_category_key` therefore remains null.

Package quantity/unit are emitted only when one consistent interpretation is
supported by structured v25 fields, a simple explicit source package, or a
verified override. Other identities remain `source_only` or `unknown`; all 346
package-review identities are retained. No source/list price is inferred.

The 9,268 keyed SKU occurrences become source-record candidates with ordinals
1–9,268. The 53 unkeyed listings are preserved in a separate artifact without
invented SKUs or ordinals. Dry-run records use deterministic logical keys and
omit database UUIDs and lifecycle timestamps; a future, separately approved
promotion workflow must translate those keys and add lifecycle timestamps.

## Phase 5A.4C production importer

`import.ts` consumes only the generated v28 directory. It never reads the XLSX
workbooks. Its default mode validates the pinned manifest and every artifact,
maps deterministic database IDs, appends ordinals 9,269–9,321 to the 53
unkeyed rows in their preserved artifact order, and writes an import plan
without opening a database connection:

```sh
npm run catalog:henry-schein:import
```

An optional live preflight is read-only and requires the server-side Supabase
environment variables:

```sh
npm run catalog:henry-schein:import -- --preflight-live
```

The production mutation path is deliberately awkward to invoke:

```sh
npm run catalog:henry-schein:import -- \
  --execute \
  --confirm-production-import
```

An existing `pending`, `processing`, `failed`, or `cancelled` batch is refused
unless `--resume-incomplete` is also supplied. Resume re-reads every expected
deterministic row, adopts only exact semantic matches, and inserts only missing
rows. It never updates or deletes immutable source records. A completed batch
is reconciled and returned as already imported without mutation.

Supabase REST requests are not a shared database transaction. The importer
therefore uses deterministic UUIDv5 identities, small ordered chunks, exact
post-phase reads, explicit failed/incomplete batch state, and opt-in recovery.
It targets only the six platform catalog tables and never organization-scoped
catalog, inventory, invoice, or pricing tables.

All IDs use RFC 4122 UUIDv5 under the namespace derived from URL namespace
`6ba7b811-9dad-11d1-80b4-00c04fd430c8` and
`https://medspend.app/global-catalog/import-identities/v1`. Natural names are:

- vendor: normalized vendor name;
- batch: normalized vendor name + source artifact SHA-256 + manifest SHA-256;
- canonical product: normalized vendor name + authoritative normalized SKU;
- vendor product: normalized vendor name + authoritative normalized SKU;
- source record: deterministic batch ID + source ordinal;
- override: normalized vendor name + deterministic batch ID + stable dry-run
  `override_key`.

Canonical IDs deliberately remain stable across catalog versions. If a later
artifact reuses an authoritative SKU with different semantic product
attributes, the importer stops for manual reconciliation rather than creating
a versioned duplicate or overwriting the existing identity.

After a successful execute-mode reconciliation, the importer writes these files
to `outputs/catalog/henry-schein/v28/import-plan/`:

- `execution_report.json`
- `execution_report.md`
- `post_import_reconciliation.json`

The timestamped execution report records inserted versus adopted rows, chunk
outcomes, batch lifecycle and recovery state, mutation-call counts, final live
counts for all seven global catalog tables, and the completed batch identity.
The reconciliation artifact contains every post-import assertion, including the
special-SKU checks. A failed insert or reconciliation throws before these
success artifacts are written and leaves a non-zero process exit status.
