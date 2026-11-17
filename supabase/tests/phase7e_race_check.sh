#!/usr/bin/env bash
# Phase 7E race check: budget saves, posting and removal in two real database sessions at once (a
# rollback-only suite runs in one transaction and cannot show this). Boots its own disposable
# Postgres with every migration (container logs capped). Never reads .env files or talks to a
# hosted project.
#
#   1. Two overlapping active budgets saved at once: the first commits, the second waits on the
#      organization's budget lock and is refused (23P01); exactly one active budget.
#   2. Two non-overlapping budgets saved at once: both succeed.
#   3. Two removals of the same posted document at once: one removes it and records one removal;
#      the other waits for the source row, then finds nothing to remove. Stock is reversed once.
#   4. Posting and deleting the same draft at once: the delete waits for the posting, then sees
#      a posted document and is refused (it must be removed with a reason). Nothing is lost.
#
# Requires Docker and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7e_race_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7e_race_$$"
port="${MEDSPEND_7E_RACE_PORT:-55805}"
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

org=7e5e0000-0000-4000-8000-000000000101
owner=7e5e0000-0000-4000-8000-000000000001
vendor=7e5e0000-0000-4000-8000-000000000301
product=7e5e0000-0000-4000-8000-000000000401
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES ('$owner', 'authenticated', 'authenticated', 'race-owner@example.invalid', '', now(), '{}', '{}', now(), now());
INSERT INTO public.organizations (id, name, created_by) VALUES ('$org', 'Phase 7E Race', '$owner');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES ('$org', '$owner', 'owner', true);
INSERT INTO public.vendors (id, organization_id, name, active) VALUES ('$vendor', '$org', 'Race Vendor', true);
INSERT INTO public.products (id, organization_id, name, approved, active, staff_requestable) VALUES ('$product', '$org', 'Race Tape', true, true, true);
SQL
draft() {  # <n> : an unposted invoice with one line, source file $org/race-<n>.pdf
  psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
INSERT INTO public.vendor_invoices (id, organization_id, uploaded_by, storage_path, original_filename, file_size, mime_type)
VALUES ('7e5e0000-0000-4000-8000-00000000a00$1', '$org', '$owner', '$org/race-$1.pdf', 'race-$1.pdf', 10, 'application/pdf');
INSERT INTO public.invoices (id, organization_id, source_file_id, vendor_id, vendor_name, document_type, invoice_number, invoice_date, processing_status, invoice_total, total_amount, total)
VALUES ('7e5e0000-0000-4000-8000-00000000b00$1', '$org', '7e5e0000-0000-4000-8000-00000000a00$1', '$vendor', 'Race Vendor', 'INVOICE', 'RACE-$1', '2026-06-01', 'review_required', 40, 40, 40);
INSERT INTO public.invoice_items (invoice_id, organization_id, line_number, description, quantity, unit_of_measure, unit_price, total_price, product_id)
VALUES ('7e5e0000-0000-4000-8000-00000000b00$1', '$org', 1, 'Race tape', 4, 'roll', 10, 40, '$product');
SQL
}
session() {  # <sql> : runs as the owner in one transaction
  psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d postgres <<SQL
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$owner', false);
BEGIN;
$1
COMMIT;
SQL
}
budget() {  # <name> <start> <end>
  echo "INSERT INTO public.organization_budgets (organization_id, name, period_start, period_end, amount, active) VALUES ('$org', '$1', '$2', '$3', 100, true);"
}

# 1. Overlapping budgets at once.
session "$(budget 'Race A' 2026-01-01 2026-12-31) SELECT pg_sleep(2);" > "$work/a.out" 2>&1 &
a=$!
sleep 0.7
if session "$(budget 'Race B' 2026-06-01 2027-05-31)" > "$work/b.out" 2>&1; then
  fail "the overlapping budget saved at the same time succeeded"
fi
wait "$a" || fail "the first budget failed: $(cat "$work/a.out")"
grep -q 'overlaps the active budget "Race A"' "$work/b.out" || fail "unexpected refusal: $(cat "$work/b.out")"
[ "$(q "SELECT count(*) FROM public.organization_budgets WHERE organization_id = '$org' AND active")" = "1" ] || fail "expected one active budget"
echo "ok - overlapping budgets saved at once: the second waits and is refused (23P01); one active budget"

# 2. Non-overlapping budgets at once.
session "$(budget 'Race 2027' 2027-01-01 2027-12-31) SELECT pg_sleep(1.5);" > "$work/a.out" 2>&1 &
a=$!
sleep 0.5
session "$(budget 'Race 2028' 2028-01-01 2028-12-31)" > "$work/b.out" 2>&1 || fail "a non-overlapping budget was refused: $(cat "$work/b.out")"
wait "$a" || fail "the 2027 budget failed: $(cat "$work/a.out")"
[ "$(q "SELECT count(*) FROM public.organization_budgets WHERE organization_id = '$org' AND active")" = "3" ] || fail "expected three active budgets"
echo "ok - non-overlapping budgets saved at once both succeed"

# 3. Two removals of the same posted document at once.
draft 1
session "SELECT public.post_reviewed_invoice('$org', '7e5e0000-0000-4000-8000-00000000a001');" >/dev/null
posted_at="$(q "SELECT posted_at FROM public.invoices WHERE id = '7e5e0000-0000-4000-8000-00000000b001'")"
[ "$(q "SELECT quantity FROM public.inventory_items WHERE product_id = '$product'")" = "4" ] || fail "posting did not receive stock"
remove="SELECT public.remove_posted_financial_document('$org', '7e5e0000-0000-4000-8000-00000000a001', '$posted_at', 'RACE-1', 'Duplicate upload removed in a race test');"
session "$remove SELECT pg_sleep(2);" > "$work/a.out" 2>&1 &
a=$!
sleep 0.7
if session "$remove" > "$work/b.out" 2>&1; then
  fail "the second simultaneous removal succeeded"
fi
wait "$a" || fail "the first removal failed: $(cat "$work/a.out")"
grep -q "Document not found" "$work/b.out" || fail "unexpected refusal: $(cat "$work/b.out")"
[ "$(q "SELECT count(*) FROM public.financial_document_removals WHERE organization_id = '$org'")" = "1" ] || fail "expected exactly one removal record"
[ "$(q "SELECT quantity FROM public.inventory_items WHERE product_id = '$product'")" = "0" ] || fail "stock was not reversed exactly once"
echo "ok - simultaneous removals: one removes and records it, the other finds nothing; stock reversed once"

# 4. Posting and deleting the same draft at once.
draft 2
session "SELECT public.post_reviewed_invoice('$org', '7e5e0000-0000-4000-8000-00000000a002'); SELECT pg_sleep(2);" > "$work/a.out" 2>&1 &
a=$!
sleep 0.7
if session "SELECT public.delete_invoice_permanently('$org', '7e5e0000-0000-4000-8000-00000000a002');" > "$work/b.out" 2>&1; then
  fail "the draft was deleted while it was being posted"
fi
wait "$a" || fail "the posting failed: $(cat "$work/a.out")"
grep -q "Posted documents must be removed with a recorded reason" "$work/b.out" || fail "unexpected refusal: $(cat "$work/b.out")"
[ "$(q "SELECT posted_at IS NOT NULL FROM public.invoices WHERE id = '7e5e0000-0000-4000-8000-00000000b002'")" = "t" ] || fail "the posted invoice is missing"
[ "$(q "SELECT quantity FROM public.inventory_items WHERE product_id = '$product'")" = "4" ] || fail "stock does not match the posting"
echo "ok - posting and deleting a draft at once: the delete waits, sees it posted and is refused"
echo "phase7e_race_check: all checks passed"
