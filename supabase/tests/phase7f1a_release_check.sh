#!/usr/bin/env bash
# Phase 7F.1A release check: proves the release files and the migration behave in the Supabase
# SQL Editor exactly as README.md says, on a seeded production-shaped copy: one global catalog
# ("Henry Schein") with an import batch and source records; FC Cincinnati-like organization
# linked to it with adopted products (including a name twin), SKU mappings, requests, a posted
# invoice and price history; three organizations with no vendor at all. Boots its own
# disposable Postgres. Never reads .env files or talks to a hosted project.
#
# Requires Docker and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7f1a_release_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7f1a_release_$$"
port="${MEDSPEND_7F1A_RELEASE_PORT:-55935}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
migration="20261125120000_phase7f1a_core_catalog_foundation.sql"
rewrite="$root/supabase/tests/support/studio_sql_editor_rewrite.mjs"
release="$root/supabase/release/phase7f1a"

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cd "$root"

for file in "supabase/migrations/$migration" "$release"/*.sql; do
  [ -z "$(node "$rewrite" "$file" --tables)" ] || fail "the SQL Editor would offer 'Run and enable RLS' for $file"
  cmp -s "$file" <(node "$rewrite" "$file") || fail "the SQL Editor would rewrite $file"
done
echo "ok - the SQL Editor sends the 7F.1A migration and release files unchanged (no RLS modal)"

docker run -d --log-opt max-size=10m --log-opt max-file=1 --name "$container" -e POSTGRES_PASSWORD=postgres \
  -p "127.0.0.1:$port:5432" public.ecr.aws/supabase/postgres:17.6.1.167 >/dev/null
for _ in $(seq 1 60); do
  if psql -U supabase_admin -d postgres -Atc "select 1 from pg_roles where rolname = 'authenticator'" 2>/dev/null | grep -q 1; then break; fi
  sleep 2
done
sleep 5
psql -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -f supabase/tests/integration/local_stack_setup.sql >/dev/null
for file in supabase/migrations/*.sql; do
  [[ "$(basename "$file")" < "$migration" ]] || continue
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$file" >/dev/null
done

fcc=7f1ac000-0000-4000-8000-000000000101
owner=7f1ac000-0000-4000-8000-000000000001
staff=7f1ac000-0000-4000-8000-000000000003
cv=7f1ac000-0000-4000-8000-000000000201
vendor=7f1ac000-0000-4000-8000-000000000301
batch=7f1ac000-0000-4000-8000-000000000701
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7f1ac000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated', 'release7f1a-' || n || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM generate_series(1, 6) n;
INSERT INTO public.organizations (id, name, created_by) VALUES
  ('$fcc', 'Release FC', '$owner'),
  ('7f1ac000-0000-4000-8000-000000000102', 'Release Demo 1', '7f1ac000-0000-4000-8000-000000000004'),
  ('7f1ac000-0000-4000-8000-000000000103', 'Release Demo 2', '7f1ac000-0000-4000-8000-000000000005'),
  ('7f1ac000-0000-4000-8000-000000000104', 'Release Demo 3', '7f1ac000-0000-4000-8000-000000000006');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('$fcc', '$owner', 'owner', true), ('$fcc', '7f1ac000-0000-4000-8000-000000000002', 'admin', true), ('$fcc', '$staff', 'staff', true),
  ('7f1ac000-0000-4000-8000-000000000102', '7f1ac000-0000-4000-8000-000000000004', 'owner', true),
  ('7f1ac000-0000-4000-8000-000000000103', '7f1ac000-0000-4000-8000-000000000005', 'owner', true),
  ('7f1ac000-0000-4000-8000-000000000104', '7f1ac000-0000-4000-8000-000000000006', 'owner', true);

-- One global catalog of 300 listings; products 1-40 share 20 names (name twins).
INSERT INTO public.catalog_vendors (id, name, normalized_name, website, domain, active)
VALUES ('$cv', 'Henry Schein', 'x', 'https://www.henryschein.com', 'henryschein.com', true);
INSERT INTO public.catalog_import_batches (id, catalog_vendor_id, source_name, source_version, artifact_name, artifact_sha256, status, raw_record_count, started_at, completed_at)
VALUES ('$batch', '$cv', 'Release guide', 'v28', 'release.xlsx', repeat('a', 64), 'completed', 300, now(), now());
INSERT INTO public.catalog_products (id, name, normalized_name, description, manufacturer, active, verification_status)
SELECT ('7f1ac001-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  CASE WHEN n <= 40 THEN 'Twin Item ' || ((n + 1) / 2) ELSE (ARRAY['Athletic Tape', 'Prewrap', 'Gauze Sponge', 'Nitrile Gloves', 'Cold Pack'])[1 + n % 5] || ' ' || n END,
  'x', CASE WHEN n % 3 = 0 THEN 'Size ' || n END, NULL, true, 'verified'
FROM generate_series(1, 300) n;
INSERT INTO public.catalog_vendor_products (id, catalog_product_id, catalog_vendor_id, vendor_sku, normalized_vendor_sku,
  package_quantity, package_unit, package_description, package_status, active, discontinued, verification_status)
SELECT ('7f1ac002-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, ('7f1ac001-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, '$cv',
  lpad((100 + n)::text, 3, '0') || '-' || lpad(n::text, 4, '0'), 'x',
  CASE WHEN n % 4 = 0 THEN NULL ELSE 12 END, CASE WHEN n % 4 = 0 THEN NULL ELSE 'roll' END,
  CASE WHEN n % 4 = 0 THEN '12/cs' END, CASE WHEN n % 4 = 0 THEN 'source_only' ELSE 'verified' END,
  n <> 300, n = 300, 'verified'
FROM generate_series(1, 300) n;
INSERT INTO public.catalog_source_records (import_batch_id, catalog_vendor_id, source_ordinal, raw_vendor_sku, raw_product_name,
  raw_variant, raw_data, matched_catalog_vendor_product_id, resolution_status, resolved_at)
SELECT '$batch', '$cv', n, lpad((100 + n)::text, 3, '0') || '-' || lpad(n::text, 4, '0'), 'Raw ' || n,
  CASE WHEN n % 2 = 0 THEN '2" x 15 yd' END, jsonb_build_object('row', n),
  ('7f1ac002-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, 'verified_match', now()
FROM generate_series(1, 300) n;

-- FC Cincinnati-like organization: linked vendor, adopted products (one name twin), a local
-- product with two SKUs, requests on both, a posted invoice with price history.
INSERT INTO public.vendors (id, organization_id, name, active, catalog_vendor_id) VALUES ('$vendor', '$fcc', 'Henry Schein', true, '$cv');
SELECT set_config('request.jwt.claim.sub', '$owner', false);
SELECT public.adopt_catalog_vendor_product('$fcc', ('7f1ac002-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid)
FROM generate_series(1, 2) n;
SELECT public.adopt_catalog_vendor_product('$fcc', ('7f1ac002-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid)
FROM generate_series(41, 60) n;
SELECT set_config('request.jwt.claim.sub', '', false);
INSERT INTO public.products (id, organization_id, name, approved, active, staff_requestable, preferred_vendor_id)
VALUES ('7f1ac000-0000-4000-8000-000000000601', '$fcc', 'Local Mixed Tape', true, true, true, '$vendor');
INSERT INTO public.vendor_products (organization_id, product_id, vendor_id, vendor_sku, active) VALUES
  ('$fcc', '7f1ac000-0000-4000-8000-000000000601', '$vendor', 'LOCAL-1', true),
  ('$fcc', '7f1ac000-0000-4000-8000-000000000601', '$vendor', 'LOCAL-2', true);
INSERT INTO public.supply_requests (id, organization_id, requested_by, request_type, status)
VALUES ('7f1ac000-0000-4000-8000-000000000801', '$fcc', '$staff', 'reorder', 'submitted');
INSERT INTO public.supply_request_items (organization_id, supply_request_id, catalog_vendor_product_id, quantity) VALUES
  ('$fcc', '7f1ac000-0000-4000-8000-000000000801', '7f1ac002-0000-4000-8000-000000000099', 2);
INSERT INTO public.supply_request_items (organization_id, supply_request_id, product_id, quantity) VALUES
  ('$fcc', '7f1ac000-0000-4000-8000-000000000801', '7f1ac000-0000-4000-8000-000000000601', 1);
SELECT set_config('sportspend.financial_context', 'post', false);
INSERT INTO public.invoices (id, organization_id, invoice_number, invoice_date, posted_at, processing_status, document_type, vendor_id)
VALUES ('7f1ac000-0000-4000-8000-000000000901', '$fcc', 'R-1', current_date - 5, now() - interval '4 days', 'completed', 'INVOICE', '$vendor');
INSERT INTO public.invoice_items (id, invoice_id, organization_id, description, sku, quantity, unit_price, total_price, unit_of_measure, product_id, vendor_product_id)
SELECT '7f1ac000-0000-4000-8000-000000000911', '7f1ac000-0000-4000-8000-000000000901', '$fcc', 'Local Mixed Tape', 'LOCAL-1', 2, 5, 10, 'RL',
  '7f1ac000-0000-4000-8000-000000000601', id FROM public.vendor_products WHERE vendor_sku = 'LOCAL-1';
INSERT INTO public.inventory_price_history (organization_id, product_id, vendor_id, vendor_product_id, invoice_id, invoice_item_id, purchase_date, unit_price, quantity, extended_price, unit_of_measure)
SELECT '$fcc', '7f1ac000-0000-4000-8000-000000000601', '$vendor', id, '7f1ac000-0000-4000-8000-000000000901',
  '7f1ac000-0000-4000-8000-000000000911', current_date - 5, 5, 2, 10, 'RL' FROM public.vendor_products WHERE vendor_sku = 'LOCAL-1';
SELECT set_config('sportspend.financial_context', '', false);
SQL
echo "seeded: $(psql -U postgres -d postgres -Atc "select (select count(*) from products)||' products, '||(select count(*) from vendor_products)||' mappings, '||(select count(*) from catalog_vendor_products)||' listings, '||(select count(*) from organizations)||' organizations'")"

send() { # file -> run it the way the SQL Editor sends it, as one query, capturing the grid
  node "$rewrite" "$1" > "$work/sent.sql"
  psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At -F ' | ' -f "$work/sent.sql"
}

search_snapshot() { # -> every organization's staff-search rows for a few queries
  for query in tape twin "101-0001" "LOCAL-1" gauze "Twin Item 1"; do
    for org in "$fcc" 7f1ac000-0000-4000-8000-000000000102; do
      member="$(psql -U postgres -d postgres -Atc "select user_id from organization_memberships where organization_id = '$org' order by role limit 1")"
      psql -X -q -U postgres -d postgres -At \
        -c "SELECT set_config('request.jwt.claim.sub', '$member', false)" -c "SET ROLE authenticated" \
        -c "SELECT '$org $query', s::text FROM public.search_supply_request_products_with_signals('$org', \$q\$$query\$q\$, 50) s"
    done
  done
}

send "$release/precheck.sql" > "$work/pre.txt" || fail "precheck failed on the seeded main schema"
search_snapshot > "$work/search_pre.txt"
echo "ok - precheck passes on the seeded main schema ($(wc -l < "$work/pre.txt" | tr -d ' ') fingerprint rows)"
if send "$release/postcheck.sql" > /dev/null 2> "$work/err"; then fail "postcheck passed before the migration"; fi
echo "ok - postcheck refuses the unmigrated schema: $(grep -o 'ERROR: .*' "$work/err" | head -1 | cut -c1-110)"

send "supabase/migrations/$migration" > /dev/null || fail "the migration failed"
echo "ok - migration applied in one SQL Editor submission"
if send "supabase/migrations/$migration" > /dev/null 2> "$work/err"; then fail "the migration ran twice"; fi
grep -q 'Phase 7F.1A objects already exist unexpectedly' "$work/err" || fail "second application refused for the wrong reason: $(cat "$work/err")"
echo "ok - a second application is refused by the preflight"
if send "$release/precheck.sql" > /dev/null 2> "$work/err"; then fail "precheck passed after the migration"; fi
grep -q 'precheck: Phase 7F.1A objects already exist' "$work/err" || fail "precheck refused for the wrong reason"
echo "ok - precheck refuses after the migration"

send "$release/postcheck.sql" > "$work/post.txt" || fail "postcheck failed after the migration"
echo "ok - postcheck passes ($(wc -l < "$work/post.txt" | tr -d ' ') fingerprint rows)"

# Only the documented lines differ.
python3 - "$work/pre.txt" "$work/post.txt" <<'PY'
import sys
def load(path):
    rows = {}
    for line in open(path):
        line = line.rstrip("\n")
        if not line or " | " not in line:
            continue
        section, key, value = (line.split(" | ", 2) + [""])[:3]
        rows[(section, key)] = value
    return rows
pre, post = load(sys.argv[1]), load(sys.argv[2])
new_tables = {"catalog_brands", "catalog_bundle_components", "catalog_certification_types", "catalog_concept_synonyms",
              "catalog_concepts", "catalog_product_certifications", "catalog_product_concepts", "catalog_product_families"}
allowed_functions = {"supply_request_product_search", "supply_request_product_identities"}
altered = {"catalog_products", "catalog_vendor_products", "catalog_import_batches"}
bad = []
for key in sorted(set(pre) | set(post)):
    a, b = pre.get(key, "(none)"), post.get(key, "(none)")
    if a == b:
        continue
    section, name = key
    ok = (
        (section == "function" and name in allowed_functions)
        or (section == "table" and (name in altered or name in new_tables))
        or (section in ("policies", "grants") and name in new_tables)
        or (section in ("index", "constraint", "trigger") and a == "(none)" and (
            any(name.startswith(t) for t in new_tables) or name.startswith(("catalog_products", "catalog_vendor_products", "catalog_import_batches"))))
        or (section == "count" and name != "public functions")
        or (section == "catalog" and name == "new metadata")
    )
    if not ok:
        bad.append(f"{section} | {name}: {a} -> {b}")
if bad:
    print("\n".join(bad))
    sys.exit(1)
rows = [k for k in pre if k[0] == "rows"]
print(f"ok - precheck -> postcheck differs only in documented lines; all {len(rows)} data hashes and the catalog scope lines are identical")
PY

search_snapshot > "$work/search_post.txt"
if diff <(grep "^$fcc" "$work/search_pre.txt") <(grep "^$fcc" "$work/search_post.txt") > "$work/search_diff"; then
  echo "ok - the linked organization's staff search returns identical rows ($(grep -c "^$fcc" "$work/search_pre.txt") rows)"
else
  cat "$work/search_diff" | head; fail "the linked organization's search changed"
fi
before="$(grep -c '^7f1ac000-0000-4000-8000-000000000102.*global_catalog' "$work/search_pre.txt" || true)"
after="$(grep -c '^7f1ac000-0000-4000-8000-000000000102.*global_catalog' "$work/search_post.txt" || true)"
[ "$before" -gt 0 ] && [ "$after" = 0 ] || fail "an unlinked organization's global rows: before $before, after $after"
echo "ok - an organization with no linked vendor saw $before global listings before and 0 after (documented scope change)"
