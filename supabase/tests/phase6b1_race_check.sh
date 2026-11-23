#!/usr/bin/env bash
# Phase 6B.1 race check: Price Intelligence reads in real database sessions while documents are
# posted and removed (a rollback-only suite runs in one transaction and cannot show this).
# Boots its own disposable Postgres with every migration (container logs capped). Never reads
# .env files or talks to a hosted project.
#
#   1. Keyset pages read while documents are posted between pages: no product appears twice and
#      no product whose last purchase did not change is skipped. (A product whose last purchase
#      becomes newer than the cursor moves ahead of it, by design; it appears on a fresh list.)
#   2. A read in a REPEATABLE READ transaction while a document is posted: the read is not
#      blocked, sees one consistent snapshot, and a fresh read sees the new purchase.
#   3. A product's history read while the 7E owner removal deletes one of its documents: the
#      reading transaction keeps its snapshot; afterwards the observation is gone with no orphan
#      price-history, line or source reference, and every RPC still answers.
#   4. Every 6B.1 read leaves all business rows unchanged.
#
# Requires Docker and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase6b1_race_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_6b1_race_$$"
port="${MEDSPEND_6B1_RACE_PORT:-55845}"
work="$(mktemp -d)"
export PGPASSWORD=postgres PGHOST=127.0.0.1 PGPORT="$port" PGOPTIONS="-c client_min_messages=warning"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$1"; }

docker run -d --log-opt max-size=10m --log-opt max-file=1 --name "$container" -e POSTGRES_PASSWORD=postgres -p "127.0.0.1:$port:5432" \
  public.ecr.aws/supabase/postgres:17.6.1.167 >/dev/null
for _ in $(seq 1 60); do
  if psql -U supabase_admin -d postgres -Atc "select 1 from pg_roles where rolname = 'authenticator'" 2>/dev/null | grep -q 1; then break; fi
  sleep 2
done
sleep 5
cd "$root"
psql -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -f supabase/tests/integration/local_stack_setup.sql >/dev/null
for migration in supabase/migrations/*.sql; do
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -f "$migration" >/dev/null
done

org=6b1e0000-0000-4000-8000-000000000101
owner=6b1e0000-0000-4000-8000-000000000001
vendor=6b1e0000-0000-4000-8000-000000000301
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES ('$owner', 'authenticated', 'authenticated', 'race-6b1@example.invalid', '', now(), '{}', '{}', now(), now());
INSERT INTO public.organizations (id, name, created_by) VALUES ('$org', 'Phase 6B.1 Race', '$owner');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES ('$org', '$owner', 'owner', true);
INSERT INTO public.vendors (id, organization_id, name, active) VALUES ('$vendor', '$org', 'Race Vendor', true);
INSERT INTO public.products (id, organization_id, name, approved, active, staff_requestable)
SELECT ('6b1e0000-0000-4000-8000-0000000004' || lpad(n::text, 2, '0'))::uuid, '$org', 'Race Product ' || lpad(n::text, 2, '0'), true, true, true
FROM generate_series(1, 13) n;
SQL
product() { echo "6b1e0000-0000-4000-8000-0000000004$(printf %02d "$1")"; }
# Post a one-line invoice through the real review posting: <n> <product n> <days ago>
post() {
  local id; id=$(printf %03d "$1")
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
VALUES ('6b1e0000-0000-4000-8000-00000000a$id', '$org', '$owner', '$org/race-$id.pdf', 'race-$id.pdf', 10, 'application/pdf');
INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, document_type, invoice_number, invoice_date, processing_status, invoice_total, total_amount, total)
VALUES ('6b1e0000-0000-4000-8000-00000000b$id', '$org', '6b1e0000-0000-4000-8000-00000000a$id', '$vendor', 'Race Vendor', 'INVOICE', 'RACE-$id',
  (now() AT TIME ZONE 'UTC')::date - $3, 'review_required', 10, 10, 10);
INSERT INTO public.invoice_items (invoice_id, organization_id, line_number, description, sku, quantity, unit_of_measure, unit_price, total_price, product_id)
VALUES ('6b1e0000-0000-4000-8000-00000000b$id', '$org', 1, 'Race line', 'SKU-$2', 1, 'ea', 10 + $1, 10 + $1, '$(product "$2")');
SQL
  session "SELECT public.post_reviewed_invoice('$org', '6b1e0000-0000-4000-8000-00000000a$id');" >/dev/null
}
session() {  # <sql> : runs as the owner in one transaction
  psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d postgres <<SQL
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$owner', false);
BEGIN ISOLATION LEVEL REPEATABLE READ;
$1
COMMIT;
SQL
}
fingerprint() {
  q "SELECT md5(string_agg(t, '|' ORDER BY t)) FROM (
      SELECT 'i' || md5(coalesce(string_agg(to_jsonb(x)::text, ',' ORDER BY x.id), '')) t FROM public.invoices x
      UNION ALL SELECT 'l' || md5(coalesce(string_agg(to_jsonb(x)::text, ',' ORDER BY x.id), '')) FROM public.invoice_items x
      UNION ALL SELECT 'h' || md5(coalesce(string_agg(to_jsonb(x)::text, ',' ORDER BY x.id), '')) FROM public.inventory_price_history x
      UNION ALL SELECT 'm' || md5(coalesce(string_agg(to_jsonb(x)::text, ',' ORDER BY x.id), '')) FROM public.vendor_products x
      UNION ALL SELECT 'p' || md5(coalesce(string_agg(to_jsonb(x)::text, ',' ORDER BY x.id), '')) FROM public.products x
      UNION ALL SELECT 'v' || md5(coalesce(string_agg(to_jsonb(x)::text, ',' ORDER BY x.id), '')) FROM public.inventory_items x
      UNION ALL SELECT 'a' || md5(coalesce(string_agg(to_jsonb(x)::text, ',' ORDER BY x.id), '')) FROM public.inventory_adjustments x) s"
}

# Twelve products, one purchase each, 12..1 weeks ago; product 1 is bought twice.
for n in $(seq 1 12); do post "$n" "$n" $((7 * (13 - n))); done
post 21 1 100

# 1. Keyset pages with postings between them.
page() { session "SELECT public.list_price_intelligence_products('$org', 'recent', 'all', NULL, $1, 4);" | tail -1; }
page NULL > "$work/p1.json"
cursor="$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))['nextCursor']))" "$work/p1.json")"
post 31 2 0          # product 2 (on a later page) is bought today: it moves ahead of the cursor
post 32 13 0         # a brand-new product, also today
pages="$work/p1.json"
n=2
while :; do
  page "'$cursor'::jsonb" > "$work/p$n.json"
  pages="$pages $work/p$n.json"
  done_="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['exhausted'])" "$work/p$n.json")"
  [ "$done_" = "True" ] && break
  cursor="$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))['nextCursor']))" "$work/p$n.json")"
  n=$((n + 1)); [ "$n" -lt 20 ] || fail "pagination did not terminate"
done
python3 - "$(product 2)" "$(product 13)" $pages <<'PY' || fail "keyset pages under concurrent posting"
import json, sys
moved, new, *paths = sys.argv[1:]
ids = [r["productId"] for p in paths for r in json.load(open(p))["rows"]]
assert len(ids) == len(set(ids)), f"duplicate rows: {ids}"
expected = {f"6b1e0000-0000-4000-8000-0000000004{n:02d}" for n in range(1, 13)} - {moved}
missing = expected - set(ids)
assert not missing, f"skipped products: {missing}"
assert new not in ids, "a product posted after the first page appeared behind the cursor"
PY
[ "$(session "SELECT jsonb_array_length(public.list_price_intelligence_products('$org', 'recent', 'all', NULL, NULL, 50) -> 'rows');" | tail -1)" = "13" ] \
  || fail "a fresh list does not show all 13 products"
echo "ok - keyset pages while documents post: no duplicates, no unchanged product skipped; a fresh list shows the moved and new products"

# 2. A snapshot read while a document posts.
session "SELECT public.get_price_intelligence_summary('$org') ->> 'observationCount'; SELECT pg_sleep(2); SELECT public.get_price_intelligence_summary('$org') ->> 'observationCount';" > "$work/snap.out" 2>&1 &
a=$!
sleep 0.7
start=$(date +%s)
post 41 3 0
[ $(( $(date +%s) - start )) -lt 2 ] || fail "posting waited for the Price Intelligence read"
wait "$a" || fail "the snapshot read failed: $(cat "$work/snap.out")"
[ "$(sed -n 2p "$work/snap.out")" = "$(sed -n 4p "$work/snap.out")" ] || fail "the read transaction saw the concurrent posting: $(cat "$work/snap.out")"
[ "$(session "SELECT public.get_price_intelligence_summary('$org') ->> 'observationCount';" | tail -1)" = "$(( $(sed -n 2p "$work/snap.out") + 1 ))" ] \
  || fail "a fresh read does not see the new purchase"
echo "ok - a read during posting is not blocked, keeps one snapshot, and a fresh read sees the purchase"

# 3. Removal while the product's history is read.
before="$(session "SELECT public.get_product_vendor_price_history('$org', '$(product 1)') ->> 'observationCount';" | tail -1)"
[ "$before" = "2" ] || fail "product 1 should have two observations, has $before"
posted_at="$(q "SELECT posted_at FROM public.invoices WHERE id = '6b1e0000-0000-4000-8000-00000000b021'")"
session "SELECT public.get_product_vendor_price_history('$org', '$(product 1)') ->> 'observationCount'; SELECT pg_sleep(2); SELECT public.get_product_vendor_price_history('$org', '$(product 1)') ->> 'observationCount';" > "$work/detail.out" 2>&1 &
a=$!
sleep 0.7
session "SELECT public.remove_posted_financial_document('$org', '6b1e0000-0000-4000-8000-00000000a021', '$posted_at', 'RACE-021', 'Duplicate upload removed in a 6B.1 race test');" >/dev/null \
  || fail "the owner removal failed while history was being read"
wait "$a" || fail "the history read failed: $(cat "$work/detail.out")"
[ "$(sed -n 2p "$work/detail.out")" = "2" ] && [ "$(sed -n 4p "$work/detail.out")" = "2" ] || fail "the reading transaction lost its snapshot: $(cat "$work/detail.out")"
[ "$(session "SELECT public.get_product_vendor_price_history('$org', '$(product 1)') ->> 'observationCount';" | tail -1)" = "1" ] || fail "the removed observation is still shown"
[ "$(q "SELECT count(*) FROM public.inventory_price_history h LEFT JOIN public.invoices i ON i.id = h.invoice_id LEFT JOIN public.invoice_items l ON l.id = h.invoice_item_id WHERE i.id IS NULL OR l.id IS NULL")" = "0" ] \
  || fail "orphan price history after removal"
[ "$(q "SELECT count(*) FROM public.inventory_price_history WHERE invoice_id = '6b1e0000-0000-4000-8000-00000000b021'")" = "0" ] || fail "the removed document's observation remains"
[ "$(q "SELECT (inventory_reversal ->> 'removedPriceHistoryCount')::int FROM public.financial_document_removals WHERE invoice_id = '6b1e0000-0000-4000-8000-00000000b021'")" = "1" ] \
  || fail "the removal record does not count the removed observation"
session "SELECT public.list_price_intelligence_products('$org'); SELECT public.get_price_intelligence_summary('$org'); SELECT public.get_price_intelligence_overview('$org'); SELECT public.get_product_price_intelligence('$org', '$(product 1)');" >/dev/null \
  || fail "a read failed after the removal"
echo "ok - removal during a history read: the reader keeps its snapshot; afterwards the observation is gone with no orphan rows; every read answers"

# 4. Reads are read-only.
fp="$(fingerprint)"
session "SELECT public.list_price_intelligence_products('$org', 'product', 'single_vendor', NULL, NULL, 2, 2);
         SELECT public.get_price_intelligence_summary('$org');
         SELECT public.get_product_vendor_price_history('$org', '$(product 2)');
         SELECT public.get_price_intelligence_overview('$org');" >/dev/null
[ "$(fingerprint)" = "$fp" ] || fail "a 6B.1 read changed business rows"
echo "ok - every read left invoices, lines, price history, mappings, products, inventory and adjustments unchanged"
echo "phase6b1_race_check: all checks passed"
