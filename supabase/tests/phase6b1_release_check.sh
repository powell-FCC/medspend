#!/usr/bin/env bash
# Phase 6B.1 release check: proves the release files and the migration behave in the Supabase
# SQL Editor exactly as README.md says, on a seeded copy of FC Cincinnati's Price Intelligence
# shape (one vendor; Ammex glove sizes and Eco-Flex colors under one product; Leukotape bought
# twice at one price; Mediproxen by invoice then order confirmation; Protex invoiced as "EA)";
# a product with two mapped SKUs bought once; single purchases), and replays the deployed app's
# Price Intelligence reads through main's strict schemas. Boots its own disposable Postgres.
# Never reads .env files or talks to a hosted project.
#
# Requires Docker and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase6b1_release_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_6b1_release_$$"
port="${MEDSPEND_6B1_RELEASE_PORT:-55865}"
work="$(mktemp -d)"
# Outside node_modules (Node will not strip types there) but inside the repo so "zod" resolves.
compat="$root/.phase6b1-release-compat-$$"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
migration="20261123120000_phase6b1_multi_vendor_intelligence.sql"
rewrite="$root/supabase/tests/support/studio_sql_editor_rewrite.mjs"
release="$root/supabase/release/phase6b1"
baseline=18ab8baf9372e1b9c1231911ed7e762bf37ebf8a

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work" "$compat"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cd "$root"

for file in "supabase/migrations/$migration" "$release"/*.sql; do
  [ -z "$(node "$rewrite" "$file" --tables)" ] || fail "the SQL Editor would append RLS statements to $file"
  cmp -s "$file" <(node "$rewrite" "$file") || fail "the SQL Editor would rewrite $file"
done
grep -qi "create[[:space:]]\+temp" "supabase/migrations/$migration" && fail "the 6B.1 migration creates temp tables"
python3 - "supabase/migrations/$migration" <<'PY2'
import re, sys
text = open(sys.argv[1]).read()
tail = text[text.rindex("\nCOMMIT;") + len("\nCOMMIT;"):]
sys.exit(0 if re.sub(r"--[^\n]*", "", tail).strip() == "" else 1)
PY2
echo "ok - the SQL Editor sends the 6B.1 migration and release files unchanged; nothing follows COMMIT"

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

org=6b1f0000-0000-4000-8000-000000000101
owner=6b1f0000-0000-4000-8000-000000000001
admin=6b1f0000-0000-4000-8000-000000000002
staff=6b1f0000-0000-4000-8000-000000000003
vendor=6b1f0000-0000-4000-8000-000000000301
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT u, 'authenticated', 'authenticated', 'release6b1-' || right(u::text, 3) || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM unnest(ARRAY['$owner', '$admin', '$staff']::uuid[]) u;
INSERT INTO public.organizations (id, name, created_by) VALUES ('$org', 'Release FC', '$owner');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('$org', '$owner', 'owner', true), ('$org', '$admin', 'admin', true), ('$org', '$staff', 'staff', true);
INSERT INTO public.vendors (id, organization_id, name, active) VALUES ('$vendor', '$org', 'Henry Schein', true);
INSERT INTO public.products (organization_id, name, approved, active, staff_requestable)
SELECT '$org', n, true, true, true FROM unnest(ARRAY['Ammex Black PF Nitrile Glove X-Large', 'Eco-Flex Stretch Cohesive Tape',
  'Leukotape P', 'Mediproxen', 'Disinfectant Spray Protex', 'Athletic Tape 950', 'APS Dry Needling Needles',
  'Single 1', 'Single 2', 'Single 3', 'Single 4', 'Single 5', 'Single 6', 'Single 7', 'Single 8']) n;
-- Posted before 6B.1, as post_reviewed_invoice writes them: one document per line here.
SELECT set_config('sportspend.financial_context', 'post', false);
CREATE FUNCTION pg_temp.seed(_product text, _sku text, _unit text, _price numeric, _quantity numeric, _day date,
  _order integer, _type text DEFAULT 'INVOICE', _number text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS \$\$
DECLARE _invoice uuid := gen_random_uuid(); _item uuid := gen_random_uuid(); _mapping uuid; _p uuid;
BEGIN
  SELECT id INTO _p FROM public.products WHERE organization_id = '$org' AND name = _product;
  SELECT id INTO _mapping FROM public.vendor_products WHERE organization_id = '$org' AND vendor_sku = _sku;
  IF _mapping IS NULL THEN
    INSERT INTO public.vendor_products (organization_id, vendor_id, product_id, vendor_sku) VALUES ('$org', '$vendor', _p, _sku) RETURNING id INTO _mapping;
  END IF;
  INSERT INTO public.invoices (id, organization_id, vendor_id, vendor_name, document_type, invoice_number, order_number, invoice_date,
    posted_at, processing_status, currency_code, invoice_total, total_amount, total)
  VALUES (_invoice, '$org', '$vendor', 'Henry Schein', _type, CASE WHEN _type = 'INVOICE' THEN COALESCE(_number, 'INV-' || left(_invoice::text, 6)) END,
    CASE WHEN _type = 'ORDER_CONFIRMATION' THEN COALESCE(_number, 'OC-' || left(_invoice::text, 6)) END,
    CASE WHEN _type = 'INVOICE' THEN _day END, _day::timestamp AT TIME ZONE 'UTC' + interval '12 hours', 'completed', NULL,
    _price * _quantity, _price * _quantity, _price * _quantity);
  INSERT INTO public.invoice_items (id, invoice_id, organization_id, line_number, description, sku, quantity, unit_of_measure, unit_price, total_price,
    product_id, vendor_product_id, review_status)
  VALUES (_item, _invoice, '$org', 1, _product, _sku, _quantity, _unit, _price, _price * _quantity, _p, _mapping, 'approved');
  INSERT INTO public.inventory_price_history (organization_id, product_id, vendor_id, vendor_product_id, invoice_id, invoice_item_id,
    purchase_date, quantity, package_size, unit_of_measure, unit_price, extended_price, created_at)
  VALUES ('$org', _p, '$vendor', _mapping, _invoice, _item, _day, _quantity, NULL, _unit, _price, _price * _quantity,
    now() + make_interval(secs => _order));
END \$\$;
SELECT pg_temp.seed('Ammex Black PF Nitrile Glove X-Large', '398-0144', 'BX', 6.08, 3, '2026-01-15', 1);
SELECT pg_temp.seed('Ammex Black PF Nitrile Glove X-Large', '398-0145', 'BX', 6.23, 3, '2026-01-15', 2);
SELECT pg_temp.seed('Eco-Flex Stretch Cohesive Tape', '134-4998', 'CA', 39.62, 2, '2026-01-15', 3);
SELECT pg_temp.seed('Eco-Flex Stretch Cohesive Tape', '735-0022', 'CA', 35.44, 2, '2026-01-15', 4);
SELECT pg_temp.seed('Eco-Flex Stretch Cohesive Tape', '135-0459', 'CA', 39.64, 2, '2026-01-19', 5);
SELECT pg_temp.seed('Leukotape P', '911-3665', 'RL', 7.29, 5, '2026-01-15', 6);
SELECT pg_temp.seed('Leukotape P', '911-3665', 'RL', 7.29, 8, '2026-06-22', 7);
SELECT pg_temp.seed('Mediproxen', '151-9200', 'BX', 16.85, 3, '2026-05-07', 8);
SELECT pg_temp.seed('Mediproxen', '151-9200', 'Bx', 16.85, 2, '2026-10-12', 9, 'ORDER_CONFIRMATION', 'SO-42');
SELECT pg_temp.seed('Disinfectant Spray Protex', '124-6100', 'EA', 13.49, 2, '2026-01-15', 10);
SELECT pg_temp.seed('Disinfectant Spray Protex', '124-6100', 'EA)', 167.88, 1, '2026-07-08', 11);
INSERT INTO public.vendor_products (organization_id, vendor_id, product_id, vendor_sku)
SELECT '$org', '$vendor', id, '124-6101' FROM public.products WHERE name = 'Disinfectant Spray Protex';
INSERT INTO public.vendor_products (organization_id, vendor_id, product_id, vendor_sku)
SELECT '$org', '$vendor', id, '134-8647' FROM public.products WHERE name = 'Athletic Tape 950';
SELECT pg_temp.seed('Athletic Tape 950', '134-8646', 'BX', 63.23, 1, '2026-02-01', 12);
SELECT pg_temp.seed('APS Dry Needling Needles', '127-2586', 'BX', 16.32, 2, '2026-01-19', 13);
SELECT pg_temp.seed('APS Dry Needling Needles', '127-2587', 'BX', 16.32, 2, '2026-01-19', 14);
SELECT pg_temp.seed('Single ' || n, 'S-' || n, 'EA', n, 1, ('2026-11-0' || n)::date, 20 + n) FROM generate_series(1, 8) n;
SELECT set_config('sportspend.financial_context', '', false);
SQL
q() { psql -X -U postgres -d postgres -Atc "$1"; }
editor() { psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At -F ' | ' -c "$(node "$rewrite" "$1")"; }
readonly_editor() { PGOPTIONS="$PGOPTIONS -c default_transaction_read_only=on" editor "$@"; }
fingerprint() { readonly_editor "$release/fingerprint.sql"; }
expect_failure() {  # <label> <expected message> <command...>
  local label="$1" expected="$2"; shift 2
  if out="$("$@" 2>&1)"; then fail "$label unexpectedly succeeded"; fi
  echo "$out" | grep -qF "$expected" || fail "$label: unexpected error: $out"
  echo "ok - $label refused: $expected"
}
as_user() {  # <user> <sql> : prints only the statement's own result
  psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres -At \
    -c "SET ROLE authenticated" -c "DO 'BEGIN PERFORM set_config(''request.jwt.claim.sub'', ''$1'', false); END'" -c "$2"
}
ammex="$(q "SELECT id FROM public.products WHERE name = 'Ammex Black PF Nitrile Glove X-Large'")"
leuko="$(q "SELECT id FROM public.products WHERE name = 'Leukotape P'")"

# The deployed app's reads before the release.
as_user "$owner" "SELECT public.get_price_intelligence_overview('$org')" > "$work/old_overview.json"
as_user "$owner" "SELECT public.get_product_price_intelligence('$org', '$ammex')" > "$work/old_ammex.json"
as_user "$owner" "SELECT public.get_budget_purchasing_overview('$org')" > "$work/old_budget.json"
python3 - "$work/old_overview.json" <<'PY2' || fail "the seeded copy does not reproduce production's two false increases"
import json, sys
rows = json.load(open(sys.argv[1]))["rows"]
increases = sorted(r["productName"] for r in rows if (r["absoluteChange"] or 0) > 0)
assert increases == ["Ammex Black PF Nitrile Glove X-Large", "Eco-Flex Stretch Cohesive Tape"], increases
PY2
echo "ok - before the release the seeded copy shows production's two false increases (Ammex, Eco-Flex)"

readonly_editor "$release/precheck.sql" > "$work/pre.txt"
cmp -s "$work/pre.txt" <(fingerprint) || fail "precheck output is not exactly the fingerprint"
grep -q '^count | public functions | 208$' "$work/pre.txt" && grep -q '^count | public tables | 55$' "$work/pre.txt" \
  && grep -q '^count | public indexes | 207$' "$work/pre.txt" && grep -q '^count | public triggers | 89$' "$work/pre.txt" \
  && grep -q '^count | public policies | 58$' "$work/pre.txt" || fail "pre counts are not the 7E production baseline"
grep -q "^price | $org | absent\$" "$work/pre.txt" || fail "the price line should be absent before the migration"
echo "ok - precheck passed on the 7E baseline (208/55/207/58/89)"

python3 - "supabase/migrations/$migration" "$work/broken.sql" <<'PY2'
import sys
text = open(sys.argv[1]).read()
marker = "\nCOMMIT;\n"
assert text.count(marker) == 1
open(sys.argv[2], "w").write(text.replace(marker, "\nDO $induced$ BEGIN RAISE EXCEPTION 'induced failure before COMMIT'; END $induced$;\nCOMMIT;\n"))
PY2
expect_failure "induced failure before COMMIT" "induced failure before COMMIT" editor "$work/broken.sql"
[ "$(q "SELECT count(*) FROM pg_proc WHERE proname LIKE 'price\_%' AND pronamespace = 'public'::regnamespace")" = "0" ] || fail "partial 6B.1 objects survived"
cmp -s "$work/pre.txt" <(fingerprint) || fail "the failed migration left changes behind"
echo "ok - induced failure rolled back completely; the fingerprint is unchanged"

out="$(editor "supabase/migrations/$migration" 2>&1)" || fail "the migration failed: $out"
[ -z "$out" ] || fail "the migration printed output: $out"
echo "ok - migration (as the SQL Editor sends it) returned success with no output"

readonly_editor "$release/postcheck.sql" > "$work/post.txt"
cmp -s "$work/post.txt" <(fingerprint) || fail "postcheck output is not exactly the fingerprint"
echo "ok - postcheck passed (including the deployed app's read shapes, as the seeded owner)"
node supabase/tests/support/phase6b1_release_generate.mjs --pre "$work/pre.txt" --post "$work/post.txt" --check >/dev/null \
  || fail "precheck.sql / postcheck.sql are not what the generator produces from fingerprint.sql on this database"
echo "ok - precheck.sql and postcheck.sql are exactly what the generator produces from fingerprint.sql"

expect_failure "second application" "Phase 6B.1 multi-vendor intelligence objects already exist unexpectedly" editor "supabase/migrations/$migration"
expect_failure "precheck after the migration" "precheck: Phase 6B.1 objects already exist" readonly_editor "$release/precheck.sql"
cmp -s "$work/post.txt" <(fingerprint) || fail "the refused reapplication changed something"

new_functions='price_unit_key|price_unit_is_valid|price_recency|price_catalog_unit_agrees|price_package_agreement|price_row_is_valid|price_observation_rows|price_recent_anchors|price_name_anchors|price_observation_evidence|price_product_state|price_catalog_package_agreement|price_summary_flagged_invoices|price_summary_groups|price_summary_product_states|list_price_intelligence_products|get_price_intelligence_summary|get_product_vendor_price_history|get_supply_request_price_context'
changed_functions='get_price_intelligence_overview|get_product_price_intelligence'
strip() { grep -v -E "^(function|overloads) \| ($new_functions|$changed_functions) \| " "$1" \
  | grep -v -E "^index \| (inventory_price_history_product_vendor_order_idx|inventory_price_history_org_recent_idx) \| " \
  | grep -v -E "^price \| " \
  | grep -v -E '^count \| public (functions|indexes) \| '; }
diff <(strip "$work/pre.txt") <(strip "$work/post.txt") || fail "precheck/postcheck differ outside the documented lines"
delta() { echo $(( $(grep -F "count | public $1 |" "$work/post.txt" | awk -F' [|] ' '{print $3}') - $(grep -F "count | public $1 |" "$work/pre.txt" | awk -F' [|] ' '{print $3}') )); }
[ "$(delta functions)" = "19" ] && [ "$(delta tables)" = "0" ] && [ "$(delta indexes)" = "2" ] \
  && [ "$(delta policies)" = "0" ] && [ "$(delta triggers)" = "0" ] \
  || fail "unexpected object deltas: functions $(delta functions) tables $(delta tables) indexes $(delta indexes) policies $(delta policies) triggers $(delta triggers)"
for table in inventory_price_history invoices invoice_items vendor_products products supply_requests supply_request_items inventory_items; do
  [ "$(grep -F "rows | $table hash |" "$work/pre.txt")" = "$(grep -F "rows | $table hash |" "$work/post.txt")" ] || fail "$table changed"
done
echo "ok - pre/post differ only in documented lines: +19 functions, 2 changed, +2 indexes, the price line; no row changed"

expected_price="products=15 | observations=22 | insufficient_identity=5 | multiple_skus=5 | one_purchase=8 | single_vendor=2 | comparable=0 | missing_package_details=0 | incompatible_units=0 | same_sku_increases=0 | lower_comparable=0"
grep -qF "price | $org | $expected_price" "$work/post.txt" || fail "price line: $(grep "^price | $org" "$work/post.txt")"
echo "ok - FC Cincinnati-like copy: $expected_price"

# Compatibility window: the deployed app (main $baseline) keeps working against the migrated
# schema. Its strict schemas parse the new payloads; the false increases are gone.
as_user "$owner" "SELECT public.get_price_intelligence_overview('$org')" > "$work/new_overview.json"
as_user "$owner" "SELECT public.get_product_price_intelligence('$org', '$ammex')" > "$work/new_ammex.json"
as_user "$owner" "SELECT public.get_product_price_intelligence('$org', '$leuko')" > "$work/new_leuko.json"
as_user "$owner" "SELECT public.get_budget_purchasing_overview('$org')" > "$work/new_budget.json"
cmp -s "$work/old_budget.json" "$work/new_budget.json" || fail "get_budget_purchasing_overview changed"
mkdir -p "$compat"
git show "$baseline:src/budget-purchasing/command-center.ts" > "$compat/command-center.ts"
git show "$baseline:src/lib/price-intelligence.functions.ts" | python3 -c "
import sys
text = sys.stdin.read()
schema = text[text.index('const priceIntelligenceSchema'):text.index('export const getProductPriceIntelligenceFn')]
sys.stdout.write('import { z } from \"zod\";\nconst uuid = z.string().uuid();\nconst nullableMoney = z.number().nullable();\nexport ' + schema)
" > "$compat/price-intelligence-schema.ts"
cat > "$compat/replay.ts" <<'TS'
import { readFileSync } from "node:fs";
import { priceOverviewSchema } from "./command-center.ts";
import { priceIntelligenceSchema } from "./price-intelligence-schema.ts";
const [overviewFile, ammexFile, leukoFile] = process.argv.slice(2);
const overview = priceOverviewSchema.parse(JSON.parse(readFileSync(overviewFile, "utf8")));
const ammex = priceIntelligenceSchema.parse(JSON.parse(readFileSync(ammexFile, "utf8")));
const leuko = priceIntelligenceSchema.parse(JSON.parse(readFileSync(leukoFile, "utf8")));
const increases = overview.rows.filter((r) => (r.absoluteChange ?? 0) > 0).map((r) => r.productName);
if (increases.length) throw new Error(`false increases remain: ${increases}`);
if (overview.rows.some((r) => r.unitSavings !== null || r.recentAverage !== null)) throw new Error("savings or averages returned");
if (ammex.summary.previousPrice !== null || ammex.summary.absoluteChange !== null) throw new Error("Ammex detail still compares SKUs");
if (leuko.summary.previousPrice !== 7.29 || leuko.summary.absoluteChange !== 0) throw new Error("Leukotape same-SKU history lost");
console.log(`parsed ${overview.rows.length} overview rows and two product details with main's schemas`);
TS
node "$compat/replay.ts" "$work/new_overview.json" "$work/new_ammex.json" "$work/new_leuko.json" >/dev/null \
  || fail "the deployed app's strict schemas reject the migrated payloads"
echo "ok - compatibility: main's strict schemas parse the migrated Price Intelligence payloads; no false increase, no savings; budget overview identical"

# The new reads on the FC-like copy.
as_user "$admin" "SELECT public.get_price_intelligence_summary('$org')" > "$work/summary.json"
python3 - "$work/summary.json" <<'PY2' || fail "summary on the FC-like copy"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["productCount"] == 15 and s["observationCount"] == 22, s
assert s["states"] == {"insufficient_identity": 5, "one_purchase": 8, "single_vendor": 2, "comparable": 0,
                       "missing_package_details": 0, "incompatible_units": 0}, s["states"]
assert s["signals"]["same_sku_price_increased"] == 0 and s["signals"]["lower_comparable_price_other_vendor"] == 0
assert s["coverage"]["orderConfirmationCount"] == 1 and s["coverage"]["datedByPostingCount"] == 1
assert s["coverage"]["missingOrMalformedUnitCount"] == 1
PY2
expect_failure "staff summary" "Forbidden" as_user "$staff" "SELECT public.get_price_intelligence_summary('$org')"
echo "ok - summary on the FC-like copy (admin): 15 products, 22 observations, 5 / 8 / 2 / 0 / 0 / 0, no increase; staff refused"
echo "phase6b1_release_check: all checks passed"
