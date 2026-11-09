#!/usr/bin/env bash
# Phase 6C.4 mutation check. Proves phase6c4_batch_invoice_intake_behavior.sql fails when a
# critical rule in the 6C.4 migration is removed. Disposable databases only: never point this
# at production.
#
# Usage:
#   supabase/tests/phase6c4_mutation_check.sh <database>
#
# <database> must have every migration applied, through
# 20261109120000_phase6c4_batch_invoice_intake.sql. Each mutant re-creates the 6C.4 functions
# (with one rule broken), or prepends one schema change, inside one transaction, runs the suite
# there, and rolls everything back. The segmentation rules themselves (TypeScript) have their
# own check: supabase/tests/phase6c4_segmentation_mutation_check.mjs.
#
# Equivalent changes, deliberately not listed: dropping the auth.uid() IS NULL tests
# (has_org_role with a NULL user is false), and dropping "_end > _page_count" (segments are
# contiguous from page 1, so any overrun already fails the final every-page-once check).
set -euo pipefail

database="${1:?usage: $0 <database>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
migration="$root/supabase/migrations/20261109120000_phase6c4_batch_invoice_intake.sql"
suite="$root/supabase/tests/phase6c4_batch_invoice_intake_behavior.sql"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | exact text in the migration | replacement [| more text | replacement ...]
# name | PREPEND | SQL run before the suite (schema mutants)
# Every occurrence of a target is replaced. No mutant uses SQL's string concatenation
# operator: specs split on the pipe character.
mutants=(
  "every member may use batch intake|public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[])|public.is_org_member(_organization_id, auth.uid())"
  "admins may use batch intake|public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[])|public.is_org_admin(_organization_id, auth.uid())"
  "segment lookup ignores the organization (cross-org register)|  SELECT * INTO _segment FROM public.invoice_upload_batch_segments
  WHERE id = _segment_id AND organization_id = _organization_id;|  SELECT * INTO _segment FROM public.invoice_upload_batch_segments
  WHERE id = _segment_id;|  WHERE id = _segment_id AND organization_id = _organization_id FOR UPDATE;

  IF _segment.status = 'created'|  WHERE id = _segment_id FOR UPDATE;

  IF _segment.status = 'created'"
  "release ignores the organization|  WHERE id = _segment_id AND organization_id = _organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice packet segment not found'; END IF;
  IF _segment.status <> 'held'|  WHERE id = _segment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice packet segment not found'; END IF;
  IF _segment.status <> 'held'"
  "fail ignores the organization|  WHERE id = _segment_id AND organization_id = _organization_id AND status IN ('pending', 'failed');|  WHERE id = _segment_id AND status IN ('pending', 'failed');"
  "packet read ignores the organization|WHERE id = _batch_id AND organization_id = _organization_id;|WHERE id = _batch_id;"
  "packet list ignores the organization|      WHERE batch.organization_id = _organization_id|      WHERE true"
  "provenance ignores the organization|    WHERE segment.source_file_id = _source_file_id AND segment.organization_id = _organization_id|    WHERE segment.source_file_id = _source_file_id"
  "a page gap is accepted|    IF _start IS DISTINCT FROM _expected_start OR _end IS NULL|    IF _start < 1 OR _end IS NULL"
  "overlapping pages are accepted|    _expected_start := _end + 1;|    _expected_start := _start + 1;"
  "trailing pages may stay unassigned|  IF _expected_start IS DISTINCT FROM _page_count + 1 THEN|  IF false THEN"
  "segments may arrive out of order|(_segment->>'index')::integer IS DISTINCT FROM _position THEN|(_segment->>'index')::integer < 1 THEN"
  "a single invoice becomes a packet|  IF _invoices < 2 THEN|  IF _invoices < 1 THEN"
  "unknown reasons accepted|    IF EXISTS (SELECT 1 FROM unnest(_reasons) reason WHERE reason NOT IN (|    IF EXISTS (SELECT 1 FROM unnest(_reasons) reason WHERE false AND reason NOT IN ("
  "flagged invoice ranges are prepared without review|      WHEN cardinality(_reasons) > 0 THEN 'held'|      WHEN false THEN 'held'"
  "unresolved pages are prepared without review|      WHEN _kind = 'unresolved' THEN 'held'|      WHEN _kind = 'unresolved' THEN 'pending'"
  "an in-packet copy is created|      WHEN 'DUPLICATE_IN_PACKET' = ANY (_reasons) THEN 'duplicate'|      WHEN false THEN 'duplicate'"
  "the same bytes create a second packet|  IF FOUND THEN
    RETURN jsonb_build_object('batchId', _batch_id, 'existing', true);|  IF false THEN
    RETURN jsonb_build_object('batchId', _batch_id, 'existing', true);"
  "a packet path from another organization is accepted|  IF _storage_path IS NULL OR _storage_path !~* ('^'|  IF _storage_path IS NULL OR false AND _storage_path !~* ('^'"
  "duplicate protection across packets bypassed|      AND status = 'created' AND source_file_id IS NOT NULL AND id <> _segment.id|      AND false"
  "invoices uploaded on their own are not checked|    IF _duplicate IS NULL AND _batch.vendor_name IS NOT NULL THEN|    IF false THEN"
  "the vendor is ignored when matching an existing invoice|        AND (
          strpos(|        AND (true OR
          strpos("
  "another organization's invoice counts as a duplicate|      WHERE invoice.organization_id = _organization_id
        AND invoice.source_file_id IS NOT NULL|      WHERE invoice.source_file_id IS NOT NULL"
  "retry registers a second invoice|  IF _segment.status = 'created' AND _segment.source_file_id IS NOT NULL THEN|  IF false THEN"
  "held and ignored ranges can be registered|  IF _segment.status NOT IN ('pending', 'failed') OR _segment.kind = 'non_invoice' THEN|  IF _segment.status NOT IN ('pending', 'failed', 'held', 'ignored') THEN"
  "a child may reuse the packet file|     OR _storage_path = _batch.storage_path THEN|     THEN"
  "a created invoice can be marked failed|  WHERE id = _segment_id AND organization_id = _organization_id AND status IN ('pending', 'failed');|  WHERE id = _segment_id AND organization_id = _organization_id;"
  "any segment can be released|  IF _segment.status <> 'held' THEN|  IF false THEN"
  "invoice numbers keep separators in the identity|'[^a-z0-9]+', '', 'g'|'[^a-z0-9-]+', '', 'g'"
  "anon may read packets|PREPEND|GRANT EXECUTE ON FUNCTION public.get_invoice_upload_batch(uuid, uuid) TO anon;"
  "clients read segments directly|PREPEND|GRANT SELECT ON public.invoice_upload_batch_segments TO authenticated;"
  "clients write packets directly|PREPEND|GRANT INSERT ON public.invoice_upload_batches TO authenticated;"
  "clients call the identity helper|PREPEND|GRANT EXECUTE ON FUNCTION public.invoice_batch_identity_key(text, text) TO authenticated;"
  "the identity index is dropped|PREPEND|DROP INDEX public.invoice_upload_batch_segments_identity_uq;"
  "RLS off on segments|PREPEND|ALTER TABLE public.invoice_upload_batch_segments DISABLE ROW LEVEL SECURITY;"
)

# The migration's functions only (tables, triggers and data already exist in <database>).
python3 - "$migration" "$work/functions.sql" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
found = re.findall(r"(CREATE (?:OR REPLACE )?FUNCTION .*?\nAS (\$\$|\$function\$)\n.*?\n\2;)", text, re.S)
if len(found) != 9:
    sys.exit(f"expected the migration's functions, found {len(found)}")
open(sys.argv[2], "w").write("\n".join(block for block, _ in found))
PY

build() {  # <spec or empty> <target>
  python3 - "$work/functions.sql" "$suite" "$2" "$1" <<'PY'
import sys
functions, suite, target, spec = sys.argv[1:5]
text = open(functions).read()
prepend = ""
if spec:
    parts = spec.split("|")
    if parts[0] == "PREPEND":
        prepend = parts[1]
    else:
        if len(parts) % 2:
            sys.exit(f"mutation needs text|replacement pairs: {spec!r}")
        for needle, replacement in zip(parts[::2], parts[1::2]):
            if needle not in text:
                sys.exit(f"mutation target not found: {needle!r}")
            text = text.replace(needle, replacement)
text = text.replace("CREATE FUNCTION", "CREATE OR REPLACE FUNCTION")
body = open(suite).read().replace("BEGIN;\n", "", 1).replace("\nROLLBACK;\n", "\n")
open(target, "w").write("BEGIN;\n" + prepend + "\n" + text + "\n" + body + "\nROLLBACK;\n")
PY
}

survived=0
for entry in "${mutants[@]}"; do
  name="${entry%%|*}"
  build "${entry#*|}" "$work/mutant.sql"
  if psql -q -v ON_ERROR_STOP=1 -d "$database" -f "$work/mutant.sql" >/dev/null 2>"$work/err"; then
    echo "SURVIVED - $name"
    survived=$((survived + 1))
  else
    echo "KILLED - $name: $(grep -m1 -o 'ERROR: .*' "$work/err" | head -c 120)"
  fi
done

# Control: the unmutated functions pass.
build "" "$work/control.sql"
psql -q -v ON_ERROR_STOP=1 -d "$database" -f "$work/control.sql" >/dev/null || { echo "control run failed"; exit 1; }

if [ "$survived" -ne 0 ]; then
  echo "$survived mutant(s) survived"
  exit 1
fi
echo "all ${#mutants[@]} mutants killed; control passed"
