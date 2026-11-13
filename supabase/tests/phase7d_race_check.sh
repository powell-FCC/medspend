#!/usr/bin/env bash
# Phase 7D race check: replenishment rule writes in two real database sessions at once (a
# rollback-only suite runs in one transaction and cannot show this). Boots its own disposable
# Postgres with every migration (container logs capped). Never reads .env files or talks to a
# hosted project.
#
#   1. Two creates of the same item x location at once: one commits, the other waits on the
#      unique key and is refused (23505); exactly one rule, with the first values.
#   2. Two creates of the same item at different locations at once: both succeed.
#   3. Two edits from the same screen version at once: the first commits, the second waits for
#      the row lock, sees a newer updated_at and is refused (55000, never 40001); the rule keeps
#      the first edit.
#   4. A disable and an edit from the same version at once: one wins, the other is refused.
#   5. A create in flight holds its location: archiving that location waits until the create
#      commits, then succeeds (no stock); the rule is kept and reads as inactive.
#
# Requires Docker and public.ecr.aws/supabase/postgres:17.6.1.167.
# Usage: supabase/tests/phase7d_race_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
container="medspend_7d_race_$$"
port="${MEDSPEND_7D_RACE_PORT:-55765}"
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

org=7d1e0000-0000-4000-8000-000000000101
owner=7d1e0000-0000-4000-8000-000000000001
item=7d1e0000-0000-4000-8000-000000000501
first=7d1e0000-0000-4000-8000-000000000301
academy=7d1e0000-0000-4000-8000-000000000302
cage=7d1e0000-0000-4000-8000-000000000303
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES ('$owner', 'authenticated', 'authenticated', 'race-owner@example.invalid', '', now(), '{}', '{}', now(), now());
INSERT INTO public.organizations (id, name, created_by) VALUES ('$org', 'Phase 7D Race', '$owner');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES ('$org', '$owner', 'owner', true);
INSERT INTO public.inventory_locations (id, organization_id, name, kind, active) VALUES
  ('$first', '$org', 'First Team ATR', 'storage', true),
  ('$academy', '$org', 'Academy ATR', 'storage', true),
  ('$cage', '$org', 'Temporary Cage', 'storage', true);
INSERT INTO public.inventory_items (id, organization_id, name, unit, quantity, active)
VALUES ('$item', '$org', 'Race Tape', 'roll', 0, true);
SQL
session() {  # <sql> : runs as the owner in one transaction
  psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d postgres <<SQL
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$owner', false);
BEGIN;
$1
COMMIT;
SQL
}
version() { q "SELECT updated_at FROM public.inventory_replenishment_rules WHERE inventory_item_id = '$item' AND inventory_location_id = '$1'"; }
values_of() { q "SELECT count(*) || ':' || coalesce(string_agg(minimum_quantity || '/' || target_quantity || '/' || enabled, ','), '') FROM public.inventory_replenishment_rules WHERE inventory_item_id = '$item' AND inventory_location_id = '$1'"; }

# 1. Same item x location, twice at once.
session "SELECT public.set_inventory_replenishment_rule('$org', '$item', '$first', 5, 10); SELECT pg_sleep(2);" > "$work/a.out" 2>&1 &
a=$!
sleep 0.7
if session "SELECT public.set_inventory_replenishment_rule('$org', '$item', '$first', 7, 14);" > "$work/b.out" 2>&1; then
  fail "the second simultaneous create succeeded"
fi
wait "$a" || fail "the first create failed: $(cat "$work/a.out")"
grep -q "already has a replenishment rule at First Team ATR" "$work/b.out" || fail "unexpected refusal: $(cat "$work/b.out")"
[ "$(values_of "$first")" = "1:5/10/true" ] || fail "expected one rule 5/10, got $(values_of "$first")"
echo "ok - simultaneous creates: one rule, the second refused (already has a rule), first values kept"

# 2. Same item, different locations, at once.
session "SELECT public.set_inventory_replenishment_rule('$org', '$item', '$academy', 1, 2); SELECT pg_sleep(1.5);" > "$work/a.out" 2>&1 &
a=$!
sleep 0.5
session "SELECT public.set_inventory_replenishment_rule('$org', '$item', '$cage', 3, 4);" > "$work/b.out" 2>&1 || fail "create at another location failed: $(cat "$work/b.out")"
wait "$a" || fail "create at Academy failed"
[ "$(values_of "$academy")" = "1:1/2/true" ] && [ "$(values_of "$cage")" = "1:3/4/true" ] || fail "parallel creates at different locations"
echo "ok - simultaneous creates at different locations both succeed"

# 3. Two edits from the same version.
v="$(version "$first")"
session "SELECT public.set_inventory_replenishment_rule('$org', '$item', '$first', 6, 12, '$v'); SELECT pg_sleep(2);" > "$work/a.out" 2>&1 &
a=$!
sleep 0.7
start=$(date +%s)
if psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d postgres -c "SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub', '$owner', false); SELECT public.set_inventory_replenishment_rule('$org', '$item', '$first', 9, 18, '$v');" > "$work/b.out" 2>&1; then
  fail "the stale simultaneous edit succeeded"
fi
elapsed=$(( $(date +%s) - start ))
wait "$a" || fail "the first edit failed: $(cat "$work/a.out")"
grep -q "changed since you opened it" "$work/b.out" || fail "unexpected stale refusal: $(cat "$work/b.out")"
grep -q "40001" "$work/b.out" && fail "a stale edit raised 40001"
[ "$elapsed" -le 10 ] || fail "the stale edit took ${elapsed}s (a retried serialization failure?)"
[ "$(values_of "$first")" = "1:6/12/true" ] || fail "expected the first edit 6/12, got $(values_of "$first")"
q "SELECT 1 FROM pg_stat_activity WHERE query LIKE '%set_inventory_replenishment_rule%' AND pid <> pg_backend_pid() AND state = 'active'" | grep -q 1 \
  && fail "a refused edit is still running"
echo "ok - simultaneous edits: the second waits, is refused as stale (not 40001) within ${elapsed}s; the first edit stands"

# 4. Disable and edit from the same version.
v="$(version "$first")"
rule="$(q "SELECT id FROM public.inventory_replenishment_rules WHERE inventory_item_id = '$item' AND inventory_location_id = '$first'")"
session "SELECT public.set_inventory_replenishment_rule_enabled('$org', '$rule', false, '$v'); SELECT pg_sleep(2);" > "$work/a.out" 2>&1 &
a=$!
sleep 0.7
if session "SELECT public.set_inventory_replenishment_rule('$org', '$item', '$first', 1, 2, '$v');" > "$work/b.out" 2>&1; then
  fail "the edit raced past the disable"
fi
wait "$a" || fail "the disable failed"
grep -q "changed since you opened it" "$work/b.out" || fail "unexpected refusal: $(cat "$work/b.out")"
[ "$(values_of "$first")" = "1:6/12/false" ] || fail "expected the disabled 6/12 rule, got $(values_of "$first")"
echo "ok - a disable and an edit from the same version: the disable wins, the edit is refused as stale"

# 5. Archiving a location while a rule is being created there.
psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres -c "DELETE FROM public.inventory_replenishment_rules WHERE inventory_location_id = '$cage'" >/dev/null
session "SELECT public.set_inventory_replenishment_rule('$org', '$item', '$cage', 2, 4); SELECT pg_sleep(2);" > "$work/a.out" 2>&1 &
a=$!
sleep 0.7
session "SELECT public.set_inventory_location_active('$org', '$cage', false);" > "$work/b.out" 2>&1 || fail "archiving failed: $(cat "$work/b.out")"
wait "$a" || fail "the create failed: $(cat "$work/a.out")"
[ "$(q "SELECT active FROM public.inventory_locations WHERE id = '$cage'")" = "f" ] || fail "the location was not archived"
[ "$(values_of "$cage")" = "1:2/4/true" ] || fail "the rule was not kept"
[ "$(q "SELECT category || '/' || inactive_reason FROM public.inventory_replenishment_rows('$org') WHERE inventory_location_id = '$cage'")" = "inactive/location_archived" ] \
  || fail "the rule at the archived location is not inactive"
echo "ok - archiving waits for an in-flight create, then succeeds; the rule is kept and inactive"
echo "phase7d_race_check: all checks passed"
