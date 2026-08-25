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
