#!/usr/bin/env bash
# Phase 7E mutation check. Proves the behaviour suites fail when a critical rule in the 7E
# migration is removed. Disposable databases only: never point this at production.
#
# Usage:
#   supabase/tests/phase7e_mutation_check.sh <database>
#
# <database> must have every migration applied, through
# 20261117120000_phase7e_budget_analytics.sql. Each mutant re-creates the 7E functions (with one
# rule broken) inside one transaction, runs a suite there, and rolls everything back. Tables,
# triggers and policies are not re-created: trigger functions are, so guard mutants take effect.
#
# Equivalent, deliberately not listed:
#   * the financial_document_removals reason CHECK: the function refuses the same reasons first;
#   * financial_assert_range's ten-year cap: no read can reach it in a suite without a fixture
#     that is itself meaningless; the cap only bounds generate_series.
# Covered elsewhere: concurrent budget saves and removals (supabase/tests/phase7e_race_check.sh).
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261117120000_phase7e_budget_analytics.sql"
suites=(
  "$root/supabase/tests/phase7e_budget_analytics_behavior.sql"
  "$root/supabase/tests/phase6b_price_intelligence_behavior.sql"
  "$root/supabase/tests/phase7a1_location_aware_inventory_behavior.sql"
)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
# Every occurrence of a target is replaced. Specs split on the pipe character, so no mutant uses
# SQL's string concatenation operator, and none contains a dollar-quote (bash would expand it).
mutants=(
  # Actual Spend
  "credit memos counted|        WHEN document.document_type = 'CREDIT_MEMO' THEN 'credit_memo'
|"
  "statements counted|        WHEN document.document_type = 'STATEMENT' THEN 'statement'
|"
  "non-USD counted|        WHEN document.currency_basis_value = 'other' THEN 'non_usd'
|"
  "NULL currency excluded|    WHEN _currency_code IS NULL OR btrim(_currency_code) = '' THEN 'legacy_usd'|    WHEN _currency_code IS NULL OR btrim(_currency_code) = '' THEN 'other'"
  "spend date in local time|COALESCE(invoice.invoice_date, (invoice.posted_at AT TIME ZONE 'UTC')::date) AS spend_date_value|COALESCE(invoice.invoice_date, (invoice.posted_at AT TIME ZONE 'America/New_York')::date) AS spend_date_value"
  "posting day preferred over invoice date|COALESCE(invoice.invoice_date, (invoice.posted_at AT TIME ZONE 'UTC')::date) AS spend_date_value|COALESCE((invoice.posted_at AT TIME ZONE 'UTC')::date, invoice.invoice_date) AS spend_date_value"
  "amount from lines first|      COALESCE(document.invoice_total, document.total_amount, document.total,|      COALESCE(line.lines_total, document.invoice_total, document.total_amount, document.total,"
  "drafts counted|      AND invoice.posted_at IS NOT NULL
      AND (_invoice_id IS NULL OR invoice.id = _invoice_id)|      AND (_invoice_id IS NULL OR invoice.id = _invoice_id)"
  "product lines include uncounted documents|    ON item.invoice_id = document.invoice_id AND item.organization_id = _organization_id
  WHERE document.counted|    ON item.invoice_id = document.invoice_id AND item.organization_id = _organization_id"
  "legacy budget reads include uncounted documents|    FROM public.financial_spend_rows(_organization_id, _budget.period_start, _budget.period_end) document
    WHERE document.counted|    FROM public.financial_spend_rows(_organization_id, _budget.period_start, _budget.period_end) document"
  "vendor table includes uncounted documents|      SELECT * FROM public.financial_spend_rows(_organization_id, _from, _to) WHERE counted
    ),
    vendors AS (|      SELECT * FROM public.financial_spend_rows(_organization_id, _from, _to)
    ),
    vendors AS ("
  "series includes uncounted documents|      FROM public.financial_spend_rows(_organization_id, _from, _to)
      WHERE counted
    ),
    daily AS (|      FROM public.financial_spend_rows(_organization_id, _from, _to)
    ),
    daily AS ("
  # Remaining, commitments, pace, burn, signals
  "Remaining subtracts open commitments|    _remaining := _budget.amount - _a.spent;|    _remaining := _budget.amount - _a.spent - _a.open_priced_amount;"
  "approx subtracts received commitments|      _approx := _remaining - _a.open_priced_amount;|      _approx := _remaining - _a.open_priced_amount - _a.rns_priced_amount;"
  "received counted as open|      WHEN request.status IN ('approved', 'ordered') THEN 'open'|      WHEN request.status IN ('approved', 'ordered', 'received') THEN 'open'"
  "pace signal at exactly 10|    IF _gap IS NOT NULL AND _gap > 10 THEN|    IF _gap IS NOT NULL AND _gap >= 10 THEN"
  "pace band edge|      _band := CASE WHEN _gap > 5 THEN 'ahead'|      _band := CASE WHEN _gap >= 5 THEN 'ahead'"
  "elapsed off by one day|      ELSE (LEAST(_today, _budget.period_end) - _budget.period_start + 1)::numeric|      ELSE (LEAST(_today, _budget.period_end) - _budget.period_start)::numeric"
  "near-limit threshold 80%|    ELSIF _budget.amount > 0 AND _a.spent / _budget.amount >= 0.9 THEN|    ELSIF _budget.amount > 0 AND _a.spent / _budget.amount >= 0.8 THEN"
  "stale after 90 days|commitment_date < _today - 30) AS open_stale|commitment_date < _today - 90) AS open_stale"
  "duplicates only on the same day|   AND b.spend_date BETWEEN a.spend_date - 30 AND a.spend_date + 30|   AND b.spend_date = a.spend_date"
  "inactive budgets cover spend|        AND budget.active
        AND document.spend_date BETWEEN budget.period_start AND budget.period_end|        AND document.spend_date BETWEEN budget.period_start AND budget.period_end"
  "average with fewer than 6 months|    IF _a.complete_month_count >= 6 AND _a.months_with_spend >= 6 THEN|    IF _a.complete_month_count >= 1 THEN"
  # Access
  "admins drill into documents|  PERFORM public.financial_assert_access(_organization_id, true);|  PERFORM public.financial_assert_access(_organization_id, false);"
  "staff read analytics|  IF NOT _owner_only AND NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN|  IF NOT _owner_only AND NOT COALESCE(public.is_org_member(_organization_id, auth.uid()), false) THEN"
  "admins remove posted documents|    _organization_id, auth.uid(), ARRAY['owner']::public.org_role[]
  ), false) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _reason IS NULL|    _organization_id, auth.uid(), ARRAY['owner', 'admin']::public.org_role[]
  ), false) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _reason IS NULL"
  # Budget overlap
  "overlap guard off|  IF FOUND THEN
    RAISE EXCEPTION 'This period overlaps|  IF false THEN
    RAISE EXCEPTION 'This period overlaps"
  "adjacent-day overlap allowed|    AND other.period_start <= NEW.period_end
    AND NEW.period_start <= other.period_end|    AND other.period_start < NEW.period_end
    AND NEW.period_start < other.period_end"
  "inactive budgets checked for overlap|  IF NOT NEW.active THEN
    RETURN NEW;
  END IF;
  -- Serialize|  IF false THEN
    RETURN NEW;
  END IF;
  -- Serialize"
  # Posted-document integrity
  "posted header editable|  IF (to_jsonb(NEW) - 'updated_at' - 'reviewed_by') IS DISTINCT FROM (to_jsonb(OLD) - 'updated_at' - 'reviewed_by')|  IF false"
  "reviewer reassignable|     OR (NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by AND NEW.reviewed_by IS NOT NULL) THEN|     THEN"
  "posted documents deletable|    RAISE EXCEPTION 'Posted documents can''t be deleted. The owner can remove one with a recorded reason.'|    RETURN OLD;
    RAISE EXCEPTION 'Posted documents can''t be deleted. The owner can remove one with a recorded reason.'"
  "direct posting allowed|  IF OLD.posted_at IS NULL THEN
    RAISE EXCEPTION 'Documents can only be posted|  IF false THEN
    RAISE EXCEPTION 'Documents can only be posted"
  "posted lines editable|  IF COALESCE(_posted, false) THEN|  IF false THEN"
  "context always granted|  SELECT COALESCE(current_setting('sportspend.financial_context', true), '') = _context|  SELECT true"
  "credit memos post|  IF _invoice.document_type = 'CREDIT_MEMO' THEN|  IF false THEN"
  "statements post|  ELSIF _invoice.document_type = 'STATEMENT' THEN|  ELSIF false THEN"
  "posting leaves its context set|  PERFORM set_config('sportspend.financial_context', '', true);

  RETURN jsonb_build_object('invoiceId', _invoice.id, 'createdInventoryItems', _created,|
  RETURN jsonb_build_object('invoiceId', _invoice.id, 'createdInventoryItems', _created,"
  # Audited removal
  "posted documents delete silently|  IF FOUND AND (_invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed') THEN|  IF false THEN"
  "removal without a reason|  IF _reason IS NULL OR char_length(btrim(_reason)) < 10 OR char_length(btrim(_reason)) > 1000 THEN|  IF false THEN"
  "removal without confirmation|  IF lower(btrim(COALESCE(_confirmation, ''))) <> lower(_expected_confirmation) THEN|  IF false THEN"
  "removal ignores the screen version|  IF _expected_posted_at IS DISTINCT FROM _invoice.posted_at THEN|  IF false THEN"
  "removal drafts allowed|  IF NOT FOUND OR (_invoice.posted_at IS NULL AND _invoice.processing_status <> 'completed') THEN
    RAISE EXCEPTION 'This document isn''t posted. Delete it instead.'|  IF NOT FOUND THEN
    RAISE EXCEPTION 'This document isn''t posted. Delete it instead.'"
  "line snapshot dropped|  SELECT COALESCE(jsonb_agg(to_jsonb(item) ORDER BY item.line_number NULLS LAST, item.created_at, item.id), '[]'::jsonb)|  SELECT '[]'::jsonb"
  "removal leaves its context set|  _reversal := public.delete_invoice_internal(_organization_id, _source_file_id);
  PERFORM set_config('sportspend.financial_context', '', true);|  _reversal := public.delete_invoice_internal(_organization_id, _source_file_id);"
  "removal records editable|  RAISE EXCEPTION 'Removal records are permanent' USING ERRCODE = '55000';|  RETURN COALESCE(NEW, OLD);"
  "removed PDF deletable|  SELECT NOT EXISTS (
      SELECT 1 FROM public.financial_document_removals removal
      WHERE removal.storage_path = _object_name
    )
    AND NOT EXISTS (|  SELECT NOT EXISTS ("
  "posted PDF deletable|        AND (invoice.posted_at IS NOT NULL OR invoice.processing_status = 'completed')
    )|        AND false
    )"
  # Price Intelligence: Phase 6B.1 replaced both functions; its own check
  # (phase6b1_mutation_check.sh) now mutates the NULL-currency and non-USD rules.
)

# The migration's functions only (tables, triggers and data already exist in <database>).
python3 - "$migration" "$work/functions.sql" "$root/supabase/migrations/20261123120000_phase6b1_multi_vendor_intelligence.sql" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
found = re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS (\$\$|\$function\$)\n.*?\n\2;)", text, re.S)
if len(found) != 34:
    sys.exit(f"expected the migration's 34 functions, found {len(found)}")
blocks = [block for block, _ in found]
# Phase 6B.1 later replaced the two Price Intelligence functions. On a database that has it,
# re-apply its functions after 7E's so every suite runs against the current definitions.
later = sys.argv[3]
import os
if os.path.exists(later):
    blocks += [b for b, _ in re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS (\$\$|\$function\$)\n.*?\n\2;)", open(later).read(), re.S)]
open(sys.argv[2], "w").write("\n".join(blocks))
PY

build() {  # <spec or empty> <target> <suite>
  python3 - "$work/functions.sql" "$3" "$2" "$1" <<'PY'
import sys
functions, suite, target, spec = sys.argv[1:5]
text = open(functions).read()
if spec:
    parts = spec.split("|")
    if len(parts) % 2:
        sys.exit(f"mutation needs text|replacement pairs: {spec!r}")
    for needle, replacement in zip(parts[::2], parts[1::2]):
        if needle not in text:
            sys.exit(f"mutation target not found: {needle!r}")
        text = text.replace(needle, replacement)
text = text.replace("CREATE FUNCTION", "CREATE OR REPLACE FUNCTION")
body = open(suite).read().replace("BEGIN;\n", "", 1).replace("\nROLLBACK;\n", "\n")
open(target, "w").write("BEGIN;\n" + text + "\n" + body + "\nROLLBACK;\n")
PY
}

survived=0
for entry in "${mutants[@]}"; do
  name="${entry%%|*}"
  killed=""
  for suite in "${suites[@]}"; do
    build "${entry#*|}" "$work/mutant.sql" "$suite"
    if ! psql -q -v ON_ERROR_STOP=1 -d "$database" -f "$work/mutant.sql" >/dev/null 2>"$work/err"; then
      killed="$(basename "$suite" .sql): $(grep -m1 -o 'ERROR: .*' "$work/err" | head -c 110)"
      break
    fi
  done
  if [ -z "$killed" ]; then
    echo "SURVIVED - $name"
    survived=$((survived + 1))
  else
    echo "KILLED - $name: $killed"
  fi
done

# Control: the unmutated functions pass every suite.
for suite in "${suites[@]}"; do
  build "" "$work/control.sql" "$suite"
  psql -q -v ON_ERROR_STOP=1 -d "$database" -f "$work/control.sql" >/dev/null || { echo "control run failed: $suite"; exit 1; }
done

if [ "$survived" -ne 0 ]; then
  echo "$survived mutant(s) survived"
  exit 1
fi
echo "all ${#mutants[@]} mutants killed; control passed"
