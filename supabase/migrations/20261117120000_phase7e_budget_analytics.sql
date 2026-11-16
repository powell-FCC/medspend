-- Phase 7E: Budget Analytics & Financial Intelligence V1.
--
-- Product rules (locked 2026-11-16):
--   * A budget is one organization-wide spending budget for a period. Active budget periods may
--     not overlap (organization_budgets_no_overlap). Existing rows are audited by the preflight
--     and never altered. Owner/admin budget editing (6A.1) is unchanged.
--   * Actual Spend = posted documents except CREDIT_MEMO and STATEMENT, in USD or with no
--     currency recorded (legacy, treated as USD), dated by invoice_date or, without one, by the
--     UTC calendar day of posted_at. Amount = invoice_total, total_amount, total, the line sum,
--     or 0, in that order (tax and shipping included). UNKNOWN (and a missing) document type is
--     counted and disclosed. Explicit non-USD is excluded and disclosed; nothing is converted.
--   * CREDIT_MEMO and STATEMENT can no longer be posted (post_reviewed_invoice).
--   * Remaining = Budget - Spent. Commitments are reported separately: open (approved/ordered)
--     and received, not settled (received/completed). Nothing about commitments changes.
--   * Posted documents are immutable through ordinary writes (guard triggers on invoices and
--     invoice_items, for every role). A posted document can only be removed by its owner
--     through remove_posted_financial_document, which keeps a durable snapshot in
--     financial_document_removals, reuses the canonical inventory reversal, and keeps the source
--     PDF (the storage delete policy refuses it). Drafts keep today's deletion.
--   * Every figure, list and chart reads financial_spend_rows / financial_spend_line_rows /
--     financial_commitment_rows (internal, no client EXECUTE).
--   * All financial dates are UTC calendar days. A document posted near midnight UTC can fall on
--     a different reporting day than the organization's local calendar; organization financial
--     time zones are Phase 9A.
--
-- Sanctioned writes: post_reviewed_invoice and remove_posted_financial_document set the
-- transaction-local setting sportspend.financial_context ('post' | 'remove') for their own
-- writes and clear it before returning. API roles cannot set it: PostgREST exposes no
-- set_config, and every other function leaves it unset. Anything that can run arbitrary SQL
-- (the SQL Editor) is outside this model by design.

BEGIN;

DO $preflight$
DECLARE
  _conflicts text;
BEGIN
  IF pg_catalog.to_regclass('public.financial_document_removals') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname IN (
                  'financial_spend_rows', 'financial_spend_line_rows', 'financial_commitment_rows',
                  'financial_currency_basis', 'financial_context_is', 'delete_invoice_internal',
                  'remove_posted_financial_document', 'get_financial_spend_summary',
                  'tg_guard_posted_invoice', 'tg_guard_posted_invoice_item',
                  'tg_guard_organization_budget_overlap', 'vendor_invoice_storage_deletable')) THEN
    RAISE EXCEPTION 'Phase 7E budget analytics objects already exist unexpectedly';
  END IF;

  IF pg_catalog.to_regclass('public.inventory_replenishment_rules') IS NULL THEN
    RAISE EXCEPTION 'Phase 7E requires Phase 7D (inventory_replenishment_rules is missing)';
  END IF;

  IF current_setting('TimeZone') NOT IN ('UTC', 'Etc/UTC') THEN
    RAISE EXCEPTION 'Phase 7E expects the database TimeZone to be UTC (found %)', current_setting('TimeZone');
  END IF;

  -- Audit existing budgets; never alter them.
  SELECT string_agg(format('%s / %s (%s..%s overlaps %s..%s)', a.name, b.name,
           a.period_start, a.period_end, b.period_start, b.period_end), '; ')
  INTO _conflicts
  FROM public.organization_budgets a
  JOIN public.organization_budgets b
    ON b.organization_id = a.organization_id AND b.id > a.id
   AND a.active AND b.active
   AND a.period_start <= b.period_end AND b.period_start <= a.period_end;
  IF _conflicts IS NOT NULL THEN
    RAISE EXCEPTION 'Active budgets overlap; resolve before applying Phase 7E: %', _conflicts;
  END IF;

  IF EXISTS (SELECT 1 FROM public.invoices
             WHERE posted_at IS NOT NULL AND document_type IN ('CREDIT_MEMO', 'STATEMENT')) THEN
    RAISE EXCEPTION 'Posted credit memos or statements exist; Phase 7E would exclude them from spend. Review before applying.';
  END IF;
END
$preflight$;

-- ---------------------------------------------------------------------------------------
-- Durable evidence of removed posted documents.
-- ---------------------------------------------------------------------------------------
CREATE TABLE public.financial_document_removals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  invoice_id uuid NOT NULL,
  source_file_id uuid NOT NULL,
  storage_path text,
  original_filename text,
  source_file_retained boolean NOT NULL,
  vendor_id uuid,
  vendor_name text,
  document_type text,
  document_number text,
  invoice_date date,
  posted_at timestamptz,
  spend_date date,
  spend_amount numeric NOT NULL,
  counted_as_spend boolean NOT NULL,
  header jsonb NOT NULL,
  lines jsonb NOT NULL,
  inventory_reversal jsonb NOT NULL,
  reason text NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 10 AND 1000),
  removed_by uuid NOT NULL,
  removed_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX financial_document_removals_org_removed_idx
  ON public.financial_document_removals (organization_id, removed_at DESC, id DESC);
CREATE INDEX financial_document_removals_storage_path_idx
  ON public.financial_document_removals (storage_path);
ALTER TABLE public.financial_document_removals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.financial_document_removals FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.financial_document_removals TO service_role;
COMMENT ON TABLE public.financial_document_removals IS
  'Append-only evidence of posted financial documents removed through remove_posted_financial_document: header and line snapshot, spend amount, inventory reversal summary, reason, who and when. The source PDF is retained at storage_path. RLS on, no policies; read through list_financial_document_removals (owner).';

CREATE FUNCTION public.tg_financial_document_removals_append_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Removing the whole organization cascades here; that is the only permitted delete.
  IF TG_OP = 'DELETE' AND NOT EXISTS (
    SELECT 1 FROM public.organizations WHERE id = OLD.organization_id
  ) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'Removal records are permanent' USING ERRCODE = '55000';
END;
$$;
REVOKE ALL ON FUNCTION public.tg_financial_document_removals_append_only() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER financial_document_removals_append_only
  BEFORE UPDATE OR DELETE ON public.financial_document_removals
  FOR EACH ROW EXECUTE FUNCTION public.tg_financial_document_removals_append_only();

-- Posted spend by organization and canonical spend date (the exact expression used by
-- financial_spend_rows).
CREATE INDEX invoices_org_posted_spend_idx
  ON public.invoices (organization_id, (COALESCE(invoice_date, (posted_at AT TIME ZONE 'UTC')::date)))
  WHERE posted_at IS NOT NULL;

-- ---------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.financial_currency_basis(_currency_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN _currency_code IS NULL OR btrim(_currency_code) = '' THEN 'legacy_usd'
    WHEN upper(btrim(_currency_code)) = 'USD' THEN 'usd'
    ELSE 'other'
  END
$$;
REVOKE ALL ON FUNCTION public.financial_currency_basis(text) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.financial_currency_basis(text) IS
  'usd | legacy_usd (no currency recorded; treated as USD in 7E) | other (excluded from USD figures, never converted).';

CREATE FUNCTION public.financial_context_is(_context text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(current_setting('sportspend.financial_context', true), '') = _context
$$;
REVOKE ALL ON FUNCTION public.financial_context_is(text) FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------
-- Active budget overlap guard
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.tg_guard_organization_budget_overlap()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _other public.organization_budgets%ROWTYPE;
BEGIN
  IF NOT NEW.active THEN
    RETURN NEW;
  END IF;
  -- Serialize active-budget writes per organization so two overlapping saves cannot both pass.
  PERFORM pg_advisory_xact_lock(hashtextextended('organization_budgets:' || NEW.organization_id::text, 0));
  SELECT * INTO _other
  FROM public.organization_budgets other
  WHERE other.organization_id = NEW.organization_id
    AND other.active
    AND other.id <> NEW.id
    AND other.period_start <= NEW.period_end
    AND NEW.period_start <= other.period_end
  ORDER BY other.period_start, other.id
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'This period overlaps the active budget "%" (% to %). Active budgets can''t overlap.',
      _other.name, _other.period_start, _other.period_end
      USING ERRCODE = '23P01';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.tg_guard_organization_budget_overlap() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER organization_budgets_no_overlap
  BEFORE INSERT OR UPDATE ON public.organization_budgets
  FOR EACH ROW EXECUTE FUNCTION public.tg_guard_organization_budget_overlap();

-- ---------------------------------------------------------------------------------------
-- Posted-document guards
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.tg_guard_posted_invoice()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.posted_at IS NULL OR public.financial_context_is('remove') THEN
      RETURN OLD;
    END IF;
    -- Deleting the whole organization cascades here.
    IF NOT EXISTS (SELECT 1 FROM public.organizations WHERE id = OLD.organization_id) THEN
      RETURN OLD;
    END IF;
    RAISE EXCEPTION 'Posted documents can''t be deleted. The owner can remove one with a recorded reason.'
      USING ERRCODE = '55000';
  END IF;

  -- UPDATE
  IF OLD.posted_at IS NULL AND NEW.posted_at IS NULL THEN
    RETURN NEW;
  END IF;
  IF public.financial_context_is('post') THEN
    RETURN NEW;
  END IF;
  IF OLD.posted_at IS NULL THEN
    RAISE EXCEPTION 'Documents can only be posted through invoice review.' USING ERRCODE = '55000';
  END IF;
  -- Posted: nothing may change except updated_at and a reviewer reference cleared by user deletion.
  IF (to_jsonb(NEW) - 'updated_at' - 'reviewed_by') IS DISTINCT FROM (to_jsonb(OLD) - 'updated_at' - 'reviewed_by')
     OR (NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by AND NEW.reviewed_by IS NOT NULL) THEN
    RAISE EXCEPTION 'Posted documents can''t be changed. The owner can remove one with a recorded reason and post a corrected document.'
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.tg_guard_posted_invoice() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER invoices_posted_guard
  BEFORE UPDATE OR DELETE ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public.tg_guard_posted_invoice();

CREATE FUNCTION public.tg_guard_posted_invoice_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _posted boolean;
BEGIN
  IF public.financial_context_is('post') OR public.financial_context_is('remove') THEN
    RETURN COALESCE(NEW, OLD);
  END IF;
  -- A missing parent means the invoice (or organization) is being deleted by a permitted path.
  SELECT bool_or(invoice.posted_at IS NOT NULL) INTO _posted
  FROM public.invoices invoice
  WHERE invoice.id IN (
    CASE WHEN TG_OP <> 'INSERT' THEN OLD.invoice_id END,
    CASE WHEN TG_OP <> 'DELETE' THEN NEW.invoice_id END
  );
  IF COALESCE(_posted, false) THEN
    RAISE EXCEPTION 'Lines on a posted document can''t be changed.' USING ERRCODE = '55000';
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;
REVOKE ALL ON FUNCTION public.tg_guard_posted_invoice_item() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER invoice_items_posted_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.invoice_items
  FOR EACH ROW EXECUTE FUNCTION public.tg_guard_posted_invoice_item();

-- ---------------------------------------------------------------------------------------
-- post_reviewed_invoice: the Phase 7A.1 body plus the document-type refusal and the posting
-- context for the posted-document guards.
-- ---------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_reviewed_invoice(_organization_id uuid, _source_file_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public
AS $function$
DECLARE
  _invoice public.invoices%ROWTYPE;
  _line public.invoice_items%ROWTYPE;
  _vendor_id uuid;
  _vendor_name text;
  _product_id uuid;
  _vendor_product_id uuid;
  _mapping public.vendor_products%ROWTYPE;
  _inventory public.inventory_items%ROWTYPE;
  _inventory_sku text;
  _candidate_sku text;
  _created integer := 0;
  _updated integer := 0;
  _line_count integer;
  _unresolved integer;
BEGIN
  IF NOT public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;

  SELECT * INTO _invoice
  FROM public.invoices
  WHERE organization_id = _organization_id AND source_file_id = _source_file_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice review not found'; END IF;
  IF _invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed' THEN
    RETURN jsonb_build_object('invoiceId', _invoice.id, 'createdInventoryItems', 0,
      'updatedInventoryItems', 0, 'alreadyCompleted', true);
  END IF;

  -- Phase 7E: credits and statements never post through the positive-spend path.
  IF _invoice.document_type = 'CREDIT_MEMO' THEN
    RAISE EXCEPTION 'Credit memos can''t be posted yet: SportSpend can''t record credits accurately.'
      USING ERRCODE = '22023';
  ELSIF _invoice.document_type = 'STATEMENT' THEN
    RAISE EXCEPTION 'Statements are reference documents and never count as spend, so they can''t be posted.'
      USING ERRCODE = '22023';
  END IF;

  -- Phase 7E: the posted-document guards accept this function's own writes only.
  PERFORM set_config('sportspend.financial_context', 'post', true);

  -- Identity gate, before any write. Lock every line first so a concurrent direct API
  -- edit cannot unlink a line between this check and the posting loop.
  PERFORM 1 FROM public.invoice_items
  WHERE invoice_id = _invoice.id AND organization_id = _organization_id
  FOR UPDATE;
  SELECT count(*) INTO _unresolved FROM public.invoice_items
  WHERE invoice_id = _invoice.id AND organization_id = _organization_id AND product_id IS NULL;
  IF _unresolved > 0 THEN
    RAISE EXCEPTION 'Match or create a product for every invoice line before approval (% unresolved)', _unresolved
      USING ERRCODE = '23502';
  END IF;

  _vendor_id := _invoice.vendor_id;
  _vendor_name := nullif(btrim(_invoice.vendor_name), '');
  IF _vendor_id IS NOT NULL THEN
    SELECT name INTO _vendor_name FROM public.vendors
      WHERE id = _vendor_id AND organization_id = _organization_id AND active = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Selected vendor is unavailable'; END IF;
  ELSIF _vendor_name IS NOT NULL THEN
    SELECT id INTO _vendor_id FROM public.vendors
      WHERE organization_id = _organization_id
        AND normalized_name = public.normalize_catalog_text(_vendor_name) AND active = true
      LIMIT 1;
    IF _vendor_id IS NULL THEN
      INSERT INTO public.vendors (organization_id, name, normalized_name)
      VALUES (_organization_id, _vendor_name, public.normalize_catalog_text(_vendor_name))
      RETURNING id INTO _vendor_id;
    END IF;
  ELSE
    RAISE EXCEPTION 'Vendor is required before approval';
  END IF;

  SELECT count(*) INTO _line_count FROM public.invoice_items
    WHERE invoice_id = _invoice.id AND organization_id = _organization_id;
  IF _line_count = 0 THEN RAISE EXCEPTION 'Add at least one line item before approval'; END IF;

  FOR _line IN
    SELECT * FROM public.invoice_items
    WHERE invoice_id = _invoice.id AND organization_id = _organization_id
    ORDER BY line_number NULLS LAST, created_at
    FOR UPDATE
  LOOP
    _product_id := _line.product_id;
    _vendor_product_id := _line.vendor_product_id;
    IF _product_id IS NULL THEN
      RAISE EXCEPTION 'Match or create a product for every invoice line before approval' USING ERRCODE = '23502';
    END IF;

    -- A reviewed mapping must belong to this organization and invoice vendor, be active,
    -- and name the same product as the line. It never replaces the line's product.
    IF _vendor_product_id IS NOT NULL THEN
      SELECT * INTO _mapping FROM public.vendor_products
        WHERE id = _vendor_product_id AND organization_id = _organization_id
          AND vendor_id = _vendor_id AND active = true;
      IF NOT FOUND THEN RAISE EXCEPTION 'A selected vendor product is unavailable'; END IF;
      IF _mapping.product_id IS DISTINCT FROM _product_id THEN
        RAISE EXCEPTION 'A selected vendor product maps to a different product than the invoice line';
      END IF;

      UPDATE public.vendor_products SET
        product_id = _product_id,
        package_size = coalesce(nullif(btrim(_line.package_size), ''), package_size),
        unit_of_measure = coalesce(nullif(btrim(_line.unit_of_measure), ''), unit_of_measure),
        active = true
      WHERE id = _vendor_product_id AND organization_id = _organization_id AND vendor_id = _vendor_id;
    END IF;

    SELECT * INTO _inventory FROM public.inventory_items
    WHERE organization_id = _organization_id AND product_id = _product_id
    LIMIT 1 FOR UPDATE;

    -- The SKU on an inventory item is a label; one item per vendor may carry a given SKU.
    -- This product's item takes the line's SKU, or keeps its own, whichever no other
    -- product's item already carries for this vendor. Otherwise it carries none. The other
    -- item is never touched, and the receipt is recorded against this line's product.
    _inventory_sku := NULL;
    FOREACH _candidate_sku IN ARRAY ARRAY[nullif(btrim(_line.sku), ''), _inventory.sku] LOOP
      IF _candidate_sku IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.inventory_items other
        WHERE other.organization_id = _organization_id
          AND lower(other.vendor_name) = lower(_vendor_name)
          AND lower(other.sku) = lower(_candidate_sku)
          AND other.id IS DISTINCT FROM _inventory.id
      ) THEN
        _inventory_sku := _candidate_sku;
        EXIT;
      END IF;
    END LOOP;

    IF _inventory.id IS NULL THEN
      INSERT INTO public.inventory_items
        (organization_id, product_id, sku, name, description, category, manufacturer,
         unit, quantity, vendor_name, last_purchase_price, last_purchase_date, active)
      VALUES
        (_organization_id, _product_id, _inventory_sku, btrim(_line.description),
         btrim(_line.description), nullif(btrim(_line.category), ''),
         nullif(btrim(_line.manufacturer), ''), coalesce(nullif(btrim(_line.unit_of_measure), ''), 'each'),
         0, _vendor_name, _line.unit_price, coalesce(_invoice.invoice_date, current_date), true)
      RETURNING * INTO _inventory;
      _created := _created + 1;
    ELSE
      _updated := _updated + 1;
    END IF;

    UPDATE public.inventory_items SET
      sku = _inventory_sku,
      category = coalesce(nullif(btrim(_line.category), ''), category),
      manufacturer = coalesce(nullif(btrim(_line.manufacturer), ''), manufacturer),
      vendor_name = _vendor_name,
      last_purchase_price = coalesce(_line.unit_price, last_purchase_price),
      last_purchase_date = coalesce(_invoice.invoice_date, current_date),
      active = true
    WHERE id = _inventory.id;

    -- Phase 7A.1: every receipt lands in Unassigned through the canonical mutation, which
    -- writes the same 'Invoice received' row with the same provenance and idempotency key.
    PERFORM public.apply_inventory_location_delta(
      _organization_id, _inventory.id, NULL, _line.quantity, 'Invoice received', 'invoice',
      _invoice.id, _line.id, 'invoice-item:' || _line.id::text);

    INSERT INTO public.inventory_price_history
      (organization_id, product_id, vendor_id, vendor_product_id, invoice_id, invoice_item_id,
       purchase_date, quantity, package_size, unit_of_measure, unit_price, extended_price)
    VALUES
      (_organization_id, _product_id, _vendor_id, _vendor_product_id, _invoice.id, _line.id,
       coalesce(_invoice.invoice_date, current_date), _line.quantity, nullif(btrim(_line.package_size), ''),
       nullif(btrim(_line.unit_of_measure), ''), _line.unit_price, _line.total_price);

    UPDATE public.invoice_items SET product_id = _product_id,
      vendor_product_id = _vendor_product_id, review_status = 'approved'
    WHERE id = _line.id;
  END LOOP;

  UPDATE public.invoices SET vendor_id = _vendor_id, vendor_name = _vendor_name,
    invoice_total = coalesce(invoice_total, total_amount, total),
    total_amount = coalesce(total_amount, invoice_total, total),
    total = coalesce(total, total_amount, invoice_total),
    processing_status = 'completed', reviewed_by = auth.uid(), reviewed_at = now(), posted_at = now()
  WHERE id = _invoice.id;

  UPDATE public.invoice_processing_jobs SET status = 'completed'
  WHERE invoice_id = _source_file_id AND organization_id = _organization_id;

  PERFORM set_config('sportspend.financial_context', '', true);

  RETURN jsonb_build_object('invoiceId', _invoice.id, 'createdInventoryItems', _created,
    'updatedInventoryItems', _updated, 'alreadyCompleted', false);
END;
$function$;
REVOKE ALL ON FUNCTION public.post_reviewed_invoice(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_reviewed_invoice(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- delete_invoice_internal: the Phase 7A.1 delete_invoice_permanently body, unchanged except
-- that callers check the owner. No client EXECUTE.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.delete_invoice_internal(_organization_id uuid, _source_file_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public
AS $function$
DECLARE
  _source public.vendor_invoices%ROWTYPE;
  _invoice public.invoices%ROWTYPE;
  _invoice_found boolean;
  _job_status text;
  _inventory public.inventory_items%ROWTYPE;
  _adjustment public.inventory_adjustments%ROWTYPE;
  _latest_price numeric;
  _latest_date date;
  _latest_vendor_name text;
  _receipt_quantity numeric;
  _remaining_adjustments numeric;
  _reconstructed_quantity numeric;
  _running_quantity numeric;
  _unassigned_location_id uuid;
  _unassigned_quantity numeric;
  _price_records integer := 0;
  _adjustment_records integer := 0;
BEGIN
  -- Callers (delete_invoice_permanently, remove_posted_financial_document) check the owner.
  -- The source row serializes two deletion attempts for the same upload.
  SELECT * INTO _source
  FROM public.vendor_invoices
  WHERE id = _source_file_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Document not found'; END IF;

  IF _source.storage_path IS NULL
    OR split_part(_source.storage_path, '/', 1) <> _organization_id::text THEN
    RAISE EXCEPTION 'Document source file ownership could not be verified';
  END IF;

  -- Posting locks the invoice before its inventory records. Preserve that order here.
  SELECT * INTO _invoice
  FROM public.invoices
  WHERE source_file_id = _source_file_id AND organization_id = _organization_id
  FOR UPDATE;
  _invoice_found := FOUND;

  SELECT status INTO _job_status
  FROM public.invoice_processing_jobs
  WHERE invoice_id = _source_file_id AND organization_id = _organization_id;

  IF _job_status = 'processing' OR EXISTS (
    SELECT 1 FROM public.invoice_extraction_runs
    WHERE vendor_invoice_id = _source_file_id
      AND organization_id = _organization_id
      AND status IN ('queued', 'processing')
  ) THEN
    RAISE EXCEPTION 'This document is currently being processed. Try again when processing is complete.';
  END IF;

  IF _invoice_found THEN
    -- Prevent review/posting changes and establish a stable set of line identities.
    PERFORM 1 FROM public.invoice_items
    WHERE invoice_id = _invoice.id AND organization_id = _organization_id
    ORDER BY id FOR UPDATE;

    -- Completed invoices must have the exact provenance written by post_reviewed_invoice.
    -- Historical or externally-mutated rows without complete provenance cannot be reversed safely.
    IF (_invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed') AND (
      NOT EXISTS (
        SELECT 1 FROM public.invoice_items item
        WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
      ) OR EXISTS (
        SELECT 1 FROM public.invoice_items item
        WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
          AND (
            (SELECT count(*) FROM public.inventory_adjustments adjustment
             WHERE adjustment.organization_id = _organization_id
               AND adjustment.source_invoice_id = _invoice.id
               AND adjustment.source_invoice_item_id = item.id
               AND adjustment.source_type = 'invoice'
               AND adjustment.adjustment_amount = item.quantity) <> 1
            OR
            (SELECT count(*) FROM public.inventory_price_history history
             WHERE history.organization_id = _organization_id
               AND history.invoice_id = _invoice.id
               AND history.invoice_item_id = item.id) <> 1
          )
      )
    ) THEN
      RAISE EXCEPTION 'This posted invoice cannot be deleted safely because its inventory provenance is incomplete. No changes were made.';
    END IF;

    -- Lock every affected stock record deterministically before calculating any reversal.
    PERFORM 1 FROM public.inventory_items inventory
    WHERE inventory.organization_id = _organization_id
      AND EXISTS (
        SELECT 1 FROM public.inventory_adjustments adjustment
        WHERE adjustment.organization_id = _organization_id
          AND adjustment.inventory_item_id = inventory.id
          AND (
            adjustment.source_invoice_id = _invoice.id
            OR adjustment.source_invoice_item_id IN (
              SELECT item.id FROM public.invoice_items item
              WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
            )
          )
      )
    ORDER BY inventory.id FOR UPDATE;

    FOR _inventory IN
      SELECT inventory.* FROM public.inventory_items inventory
      WHERE inventory.organization_id = _organization_id
        AND EXISTS (
          SELECT 1 FROM public.inventory_adjustments adjustment
          WHERE adjustment.organization_id = _organization_id
            AND adjustment.inventory_item_id = inventory.id
            AND (
              adjustment.source_invoice_id = _invoice.id
              OR adjustment.source_invoice_item_id IN (
                SELECT item.id FROM public.invoice_items item
                WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
              )
            )
        )
      ORDER BY inventory.id
    LOOP
      SELECT coalesce(sum(adjustment.adjustment_amount), 0)
      INTO _receipt_quantity
      FROM public.inventory_adjustments adjustment
      WHERE adjustment.organization_id = _organization_id
        AND adjustment.inventory_item_id = _inventory.id
        AND (
          adjustment.source_invoice_id = _invoice.id
          OR adjustment.source_invoice_item_id IN (
            SELECT item.id FROM public.invoice_items item
            WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
          )
        );

      _reconstructed_quantity := _inventory.quantity - _receipt_quantity;
      IF _receipt_quantity < 0 OR _reconstructed_quantity < 0 THEN
        RAISE EXCEPTION 'This invoice cannot be deleted safely because removing its inventory receipts would make % inventory negative. Correct the affected inventory first, then try again.', _inventory.name;
      END IF;

      -- Phase 7A.1: a physical count is an absolute checkpoint. Replaying relative history
      -- across one would corrupt stock, so a receipt counted over cannot be deleted.
      IF EXISTS (
        SELECT 1 FROM public.inventory_adjustments counted
        WHERE counted.organization_id = _organization_id
          AND counted.inventory_item_id = _inventory.id
          AND counted.source_type = 'physical_count'
          AND counted.created_at >= (
            SELECT min(receipt.created_at) FROM public.inventory_adjustments receipt
            WHERE receipt.organization_id = _organization_id
              AND receipt.inventory_item_id = _inventory.id
              AND (
                receipt.source_invoice_id = _invoice.id
                OR receipt.source_invoice_item_id IN (
                  SELECT item.id FROM public.invoice_items item
                  WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
                )
              )
          )
      ) THEN
        RAISE EXCEPTION 'This invoice cannot be deleted because % was physically counted after it was received. Correct the inventory with an adjustment instead.', _inventory.name
          USING ERRCODE = '55000';
      END IF;

      -- Phase 7A.1: receipts always land in Unassigned, so the reversal comes only from
      -- Unassigned. Stock already moved to a physical location is never pulled back silently.
      _unassigned_location_id := public.ensure_inventory_unassigned_location(_organization_id);
      SELECT balance.quantity INTO _unassigned_quantity
      FROM public.inventory_location_balances balance
      WHERE balance.inventory_item_id = _inventory.id
        AND balance.inventory_location_id = _unassigned_location_id
      FOR UPDATE;
      _unassigned_quantity := coalesce(_unassigned_quantity, 0);
      IF _unassigned_quantity < _receipt_quantity THEN
        RAISE EXCEPTION 'Move % % of % back to Unassigned before deleting this invoice.',
          trim_scale(_receipt_quantity - _unassigned_quantity), _inventory.unit, _inventory.name
          USING ERRCODE = '55000';
      END IF;

      -- Rebuild balance snapshots for all surviving adjustments. The baseline captures stock
      -- that predates the adjustment ledger; adjustment amounts and ordering never change.
      SELECT coalesce(sum(adjustment.adjustment_amount), 0)
      INTO _remaining_adjustments
      FROM public.inventory_adjustments adjustment
      WHERE adjustment.organization_id = _organization_id
        AND adjustment.inventory_item_id = _inventory.id
        AND NOT (
          coalesce(adjustment.source_invoice_id = _invoice.id, false)
          OR coalesce(adjustment.source_invoice_item_id IN (
            SELECT item.id FROM public.invoice_items item
            WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
          ), false)
        );

      _running_quantity := _reconstructed_quantity - _remaining_adjustments;
      IF _running_quantity < 0 THEN
        RAISE EXCEPTION 'This invoice cannot be deleted safely because the remaining inventory history for % would begin below zero. Correct the affected inventory first, then try again.', _inventory.name;
      END IF;

      FOR _adjustment IN
        SELECT adjustment.* FROM public.inventory_adjustments adjustment
        WHERE adjustment.organization_id = _organization_id
          AND adjustment.inventory_item_id = _inventory.id
          AND NOT (
            coalesce(adjustment.source_invoice_id = _invoice.id, false)
            OR coalesce(adjustment.source_invoice_item_id IN (
              SELECT item.id FROM public.invoice_items item
              WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
            ), false)
          )
        ORDER BY adjustment.created_at, adjustment.id
        FOR UPDATE
      LOOP
        IF _running_quantity + _adjustment.adjustment_amount < 0 THEN
          RAISE EXCEPTION 'This invoice cannot be deleted safely because the remaining inventory history for % would become negative. Correct the affected inventory first, then try again.', _inventory.name;
        END IF;
        UPDATE public.inventory_adjustments SET
          previous_quantity = _running_quantity,
          new_quantity = _running_quantity + _adjustment.adjustment_amount
        WHERE id = _adjustment.id AND organization_id = _organization_id;
        _running_quantity := _running_quantity + _adjustment.adjustment_amount;
      END LOOP;

      IF _running_quantity <> _reconstructed_quantity THEN
        RAISE EXCEPTION 'Invoice deletion could not reconstruct inventory history safely. No changes were made.';
      END IF;

      -- Remove the receipt from Unassigned and the organization total together. Deletion
      -- removes the receipt rows below rather than writing a reversing row.
      PERFORM public.inventory_apply_balance_delta(
        _organization_id, _inventory.id, _unassigned_location_id, -_receipt_quantity);
      IF (SELECT quantity FROM public.inventory_items WHERE id = _inventory.id) <> _reconstructed_quantity THEN
        RAISE EXCEPTION 'Invoice deletion could not reconstruct inventory history safely. No changes were made.';
      END IF;
    END LOOP;

    SELECT count(*) INTO _adjustment_records
    FROM public.inventory_adjustments adjustment
    WHERE adjustment.organization_id = _organization_id
      AND (adjustment.source_invoice_id = _invoice.id OR adjustment.source_invoice_item_id IN (
        SELECT item.id FROM public.invoice_items item
        WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
      ));

    SELECT count(*) INTO _price_records
    FROM public.inventory_price_history history
    WHERE history.organization_id = _organization_id
      AND (history.invoice_id = _invoice.id OR history.invoice_item_id IN (
        SELECT item.id FROM public.invoice_items item
        WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
      ));

    -- Provenance rows must be explicitly removed before their non-cascading invoice FKs.
    DELETE FROM public.inventory_adjustments adjustment
    WHERE adjustment.organization_id = _organization_id
      AND (adjustment.source_invoice_id = _invoice.id OR adjustment.source_invoice_item_id IN (
        SELECT item.id FROM public.invoice_items item
        WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
      ));

    DELETE FROM public.inventory_price_history history
    WHERE history.organization_id = _organization_id
      AND (history.invoice_id = _invoice.id OR history.invoice_item_id IN (
        SELECT item.id FROM public.invoice_items item
        WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
      ));

    -- Rebuild denormalized purchase fields only for stock touched by the deleted invoice.
    FOR _inventory IN
      SELECT inventory.* FROM public.inventory_items inventory
      WHERE inventory.organization_id = _organization_id
        AND inventory.product_id IN (
          SELECT DISTINCT item.product_id FROM public.invoice_items item
          WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id
            AND item.product_id IS NOT NULL
        )
      ORDER BY inventory.id FOR UPDATE
    LOOP
      SELECT history.unit_price, history.purchase_date, vendor.name
      INTO _latest_price, _latest_date, _latest_vendor_name
      FROM public.inventory_price_history history
      JOIN public.vendors vendor
        ON vendor.id = history.vendor_id AND vendor.organization_id = history.organization_id
      WHERE history.organization_id = _organization_id
        AND history.product_id = _inventory.product_id
      ORDER BY history.purchase_date DESC, history.created_at DESC, history.id DESC
      LIMIT 1;

      UPDATE public.inventory_items SET
        last_purchase_price = _latest_price,
        last_purchase_date = _latest_date,
        vendor_name = _latest_vendor_name
      WHERE id = _inventory.id AND organization_id = _organization_id;
    END LOOP;

    -- Canonical products, vendors, mappings, signatures, and inventory items are preserved.
    -- invoice_items and legacy invoice_line_items cascade from this invoice-owned row.
    DELETE FROM public.invoices
    WHERE id = _invoice.id AND organization_id = _organization_id;
  END IF;

  -- Processing jobs, extraction runs, and candidates cascade from the source upload.
  DELETE FROM public.vendor_invoices
  WHERE id = _source_file_id AND organization_id = _organization_id;

  RETURN jsonb_build_object(
    'sourceFileId', _source.id,
    'storagePath', _source.storage_path,
    'filename', _source.original_filename,
    'documentType', CASE WHEN _invoice_found THEN _invoice.document_type ELSE 'UNKNOWN' END,
    'posted', CASE WHEN _invoice_found THEN (_invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed') ELSE false END,
    'removedAdjustmentCount', _adjustment_records,
    'removedPriceHistoryCount', _price_records
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.delete_invoice_internal(uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;

-- delete_invoice_permanently: same signature, same result for drafts and unposted uploads.
-- A posted document is refused: it can only leave through remove_posted_financial_document.
CREATE OR REPLACE FUNCTION public.delete_invoice_permanently(_organization_id uuid, _source_file_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public
AS $function$
DECLARE
  _invoice public.invoices%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(
    _organization_id, auth.uid(), ARRAY['owner']::public.org_role[]
  ) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;

  -- Same lock order as the deletion itself: source upload, then its invoice.
  PERFORM 1 FROM public.vendor_invoices
  WHERE id = _source_file_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Document not found'; END IF;

  SELECT * INTO _invoice FROM public.invoices
  WHERE source_file_id = _source_file_id AND organization_id = _organization_id
  FOR UPDATE;
  IF FOUND AND (_invoice.posted_at IS NOT NULL OR _invoice.processing_status = 'completed') THEN
    RAISE EXCEPTION 'Posted documents must be removed with a recorded reason.' USING ERRCODE = '55000';
  END IF;

  RETURN public.delete_invoice_internal(_organization_id, _source_file_id);
END;
$function$;
REVOKE ALL ON FUNCTION public.delete_invoice_permanently(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_invoice_permanently(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Authoritative spend rows (internal). Every Phase 7E figure, list and chart reads these.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.financial_spend_rows(
  _organization_id uuid,
  _from date,
  _to date,
  _invoice_id uuid DEFAULT NULL
)
RETURNS TABLE (
  invoice_id uuid,
  source_file_id uuid,
  vendor_id uuid,
  vendor_name text,
  document_type text,
  type_status text,
  document_number text,
  invoice_number text,
  invoice_date date,
  posted_at timestamptz,
  spend_date date,
  date_basis text,
  amount numeric,
  amount_basis text,
  subtotal numeric,
  tax_amount numeric,
  shipping_amount numeric,
  lines_total numeric,
  line_count integer,
  component_difference numeric,
  currency_code text,
  currency_basis text,
  counted boolean,
  exclusion_reason text
)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  WITH documents AS (
    SELECT
      invoice.*,
      COALESCE(invoice.invoice_date, (invoice.posted_at AT TIME ZONE 'UTC')::date) AS spend_date_value,
      public.financial_currency_basis(invoice.currency_code) AS currency_basis_value
    FROM public.invoices invoice
    WHERE invoice.organization_id = _organization_id
      AND invoice.posted_at IS NOT NULL
      AND (_invoice_id IS NULL OR invoice.id = _invoice_id)
      AND (_from IS NULL OR COALESCE(invoice.invoice_date, (invoice.posted_at AT TIME ZONE 'UTC')::date) >= _from)
      AND (_to IS NULL OR COALESCE(invoice.invoice_date, (invoice.posted_at AT TIME ZONE 'UTC')::date) <= _to)
  ),
  lines AS (
    SELECT item.invoice_id, sum(item.total_price) AS lines_total, count(*)::integer AS line_count
    FROM public.invoice_items item
    JOIN documents document ON document.id = item.invoice_id
    WHERE item.organization_id = _organization_id
    GROUP BY item.invoice_id
  ),
  resolved AS (
    SELECT
      document.*,
      line.lines_total AS lines_total_value,
      COALESCE(line.line_count, 0) AS line_count_value,
      COALESCE(document.invoice_total, document.total_amount, document.total, line.lines_total, 0)::numeric AS amount_value,
      CASE
        WHEN document.invoice_total IS NOT NULL THEN 'invoice_total'
        WHEN document.total_amount IS NOT NULL THEN 'total_amount'
        WHEN document.total IS NOT NULL THEN 'total'
        WHEN line.lines_total IS NOT NULL THEN 'lines'
        ELSE 'zero'
      END AS amount_basis_value,
      CASE
        WHEN document.document_type = 'CREDIT_MEMO' THEN 'credit_memo'
        WHEN document.document_type = 'STATEMENT' THEN 'statement'
        WHEN document.currency_basis_value = 'other' THEN 'non_usd'
      END AS exclusion_value
    FROM documents document
    LEFT JOIN lines line ON line.invoice_id = document.id
  )
  SELECT
    resolved.id,
    resolved.source_file_id,
    resolved.vendor_id,
    COALESCE(vendor.name, resolved.vendor_name),
    resolved.document_type,
    CASE
      WHEN resolved.document_type IS NULL OR btrim(resolved.document_type) = '' THEN 'missing'
      WHEN resolved.document_type = 'UNKNOWN' THEN 'unknown'
      ELSE 'classified'
    END,
    CASE WHEN resolved.document_type IN ('ORDER_CONFIRMATION', 'PURCHASE_ORDER')
      THEN COALESCE(NULLIF(btrim(resolved.order_number), ''), NULLIF(btrim(resolved.invoice_number), ''))
      ELSE COALESCE(NULLIF(btrim(resolved.invoice_number), ''), NULLIF(btrim(resolved.order_number), ''))
    END,
    resolved.invoice_number,
    resolved.invoice_date,
    resolved.posted_at,
    resolved.spend_date_value,
    CASE WHEN resolved.invoice_date IS NOT NULL THEN 'invoice_date' ELSE 'posted_at_utc' END,
    resolved.amount_value,
    resolved.amount_basis_value,
    resolved.subtotal,
    resolved.tax_amount,
    resolved.shipping_amount,
    resolved.lines_total_value,
    resolved.line_count_value,
    resolved.amount_value - (COALESCE(resolved.lines_total_value, 0)
      + COALESCE(resolved.tax_amount, 0) + COALESCE(resolved.shipping_amount, 0)),
    resolved.currency_code,
    resolved.currency_basis_value,
    resolved.exclusion_value IS NULL,
    resolved.exclusion_value
  FROM resolved
  LEFT JOIN public.vendors vendor
    ON vendor.id = resolved.vendor_id AND vendor.organization_id = resolved.organization_id
$$;
REVOKE ALL ON FUNCTION public.financial_spend_rows(uuid, date, date, uuid) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.financial_spend_rows(uuid, date, date, uuid) IS
  'Internal. One row per posted document whose UTC spend date is in [_from, _to] (NULL = unbounded). counted = not CREDIT_MEMO/STATEMENT and USD or no currency. The single definition of Actual Spend.';

CREATE FUNCTION public.financial_spend_line_rows(_organization_id uuid, _from date, _to date)
RETURNS TABLE (
  invoice_id uuid,
  invoice_item_id uuid,
  spend_date date,
  vendor_id uuid,
  vendor_name text,
  document_number text,
  product_id uuid,
  description text,
  quantity numeric,
  unit_price numeric,
  total_price numeric,
  unit_of_measure text,
  package_size text,
  uom_key text,
  package_key text,
  line_number integer
)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT
    document.invoice_id,
    item.id,
    document.spend_date,
    document.vendor_id,
    document.vendor_name,
    document.document_number,
    item.product_id,
    item.description,
    item.quantity,
    item.unit_price,
    item.total_price,
    item.unit_of_measure,
    item.package_size,
    NULLIF(lower(regexp_replace(btrim(COALESCE(item.unit_of_measure, '')), '\s+', ' ', 'g')), ''),
    NULLIF(lower(regexp_replace(btrim(COALESCE(item.package_size, '')), '\s+', ' ', 'g')), ''),
    item.line_number
  FROM public.financial_spend_rows(_organization_id, _from, _to) document
  JOIN public.invoice_items item
    ON item.invoice_id = document.invoice_id AND item.organization_id = _organization_id
  WHERE document.counted
$$;
REVOKE ALL ON FUNCTION public.financial_spend_line_rows(uuid, date, date) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.financial_spend_line_rows(uuid, date, date) IS
  'Internal. The lines of counted documents from financial_spend_rows (line totals exclude tax and shipping).';

CREATE FUNCTION public.financial_commitment_rows(_organization_id uuid, _from date, _to date)
RETURNS TABLE (
  commitment_id uuid,
  supply_request_id uuid,
  committed_at timestamptz,
  commitment_date date,
  amount numeric,
  pricing_status text,
  total_item_count integer,
  priced_item_count integer,
  request_status public.supply_request_status,
  bucket text
)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT
    commitment.id,
    commitment.supply_request_id,
    commitment.committed_at,
    (commitment.committed_at AT TIME ZONE 'UTC')::date,
    commitment.amount,
    commitment.pricing_status,
    commitment.total_item_count,
    commitment.priced_item_count,
    request.status,
    CASE
      WHEN request.status IN ('approved', 'ordered') THEN 'open'
      WHEN request.status IN ('received', 'completed') THEN 'received_not_settled'
      ELSE 'unexpected'
    END
  FROM public.supply_request_commitments commitment
  JOIN public.supply_requests request
    ON request.id = commitment.supply_request_id
   AND request.organization_id = commitment.organization_id
  WHERE commitment.organization_id = _organization_id
    AND commitment.status = 'active'
    AND (_from IS NULL OR (commitment.committed_at AT TIME ZONE 'UTC')::date >= _from)
    AND (_to IS NULL OR (commitment.committed_at AT TIME ZONE 'UTC')::date <= _to)
$$;
REVOKE ALL ON FUNCTION public.financial_commitment_rows(uuid, date, date) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.financial_commitment_rows(uuid, date, date) IS
  'Internal. Active commitments by UTC commitment date: open (approved/ordered), received_not_settled (received/completed), unexpected (asserted absent).';

-- ---------------------------------------------------------------------------------------
-- Audited removal of a posted document (owner only)
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.remove_posted_financial_document(
  _organization_id uuid,
  _source_file_id uuid,
  _expected_posted_at timestamptz,
  _confirmation text,
  _reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _source public.vendor_invoices%ROWTYPE;
  _invoice public.invoices%ROWTYPE;
  _spend record;
  _lines jsonb;
  _document_number text;
  _expected_confirmation text;
  _reversal jsonb;
  _removal_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT COALESCE(public.has_org_role(
    _organization_id, auth.uid(), ARRAY['owner']::public.org_role[]
  ), false) THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF _reason IS NULL OR char_length(btrim(_reason)) < 10 OR char_length(btrim(_reason)) > 1000 THEN
    RAISE EXCEPTION 'Give a reason of 10 to 1000 characters for removing this posted document.'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO _source FROM public.vendor_invoices
  WHERE id = _source_file_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Document not found' USING ERRCODE = 'P0002'; END IF;

  SELECT * INTO _invoice FROM public.invoices
  WHERE source_file_id = _source_file_id AND organization_id = _organization_id
  FOR UPDATE;
  IF NOT FOUND OR (_invoice.posted_at IS NULL AND _invoice.processing_status <> 'completed') THEN
    RAISE EXCEPTION 'This document isn''t posted. Delete it instead.' USING ERRCODE = '55000';
  END IF;
  IF _expected_posted_at IS DISTINCT FROM _invoice.posted_at THEN
    RAISE EXCEPTION 'This document changed since you opened it. Reload and try again.' USING ERRCODE = '55000';
  END IF;

  _document_number := CASE WHEN _invoice.document_type IN ('ORDER_CONFIRMATION', 'PURCHASE_ORDER')
    THEN COALESCE(NULLIF(btrim(_invoice.order_number), ''), NULLIF(btrim(_invoice.invoice_number), ''))
    ELSE COALESCE(NULLIF(btrim(_invoice.invoice_number), ''), NULLIF(btrim(_invoice.order_number), ''))
  END;
  _expected_confirmation := COALESCE(_document_number, 'REMOVE');
  IF lower(btrim(COALESCE(_confirmation, ''))) <> lower(_expected_confirmation) THEN
    RAISE EXCEPTION 'Type % to confirm the removal.', _expected_confirmation USING ERRCODE = '22023';
  END IF;

  -- Snapshot before anything changes.
  SELECT * INTO _spend FROM public.financial_spend_rows(_organization_id, NULL, NULL, _invoice.id);
  SELECT COALESCE(jsonb_agg(to_jsonb(item) ORDER BY item.line_number NULLS LAST, item.created_at, item.id), '[]'::jsonb)
  INTO _lines
  FROM public.invoice_items item
  WHERE item.invoice_id = _invoice.id AND item.organization_id = _organization_id;

  PERFORM set_config('sportspend.financial_context', 'remove', true);
  _reversal := public.delete_invoice_internal(_organization_id, _source_file_id);
  PERFORM set_config('sportspend.financial_context', '', true);

  INSERT INTO public.financial_document_removals (
    organization_id, invoice_id, source_file_id, storage_path, original_filename,
    source_file_retained, vendor_id, vendor_name, document_type, document_number, invoice_date,
    posted_at, spend_date, spend_amount, counted_as_spend, header, lines, inventory_reversal,
    reason, removed_by
  ) VALUES (
    _organization_id, _invoice.id, _source_file_id, _source.storage_path, _source.original_filename,
    true, _invoice.vendor_id, COALESCE(_spend.vendor_name, _invoice.vendor_name), _invoice.document_type,
    _document_number, _invoice.invoice_date, _invoice.posted_at, _spend.spend_date,
    COALESCE(_spend.amount, 0), COALESCE(_spend.counted, false), to_jsonb(_invoice), _lines,
    jsonb_build_object(
      'removedAdjustmentCount', _reversal -> 'removedAdjustmentCount',
      'removedPriceHistoryCount', _reversal -> 'removedPriceHistoryCount'
    ),
    btrim(_reason), auth.uid()
  )
  RETURNING id INTO _removal_id;

  RETURN jsonb_build_object(
    'removalId', _removal_id,
    'sourceFileId', _source_file_id,
    'documentNumber', _document_number,
    'spendAmount', COALESCE(_spend.amount, 0),
    'countedAsSpend', COALESCE(_spend.counted, false),
    'removedAdjustmentCount', _reversal -> 'removedAdjustmentCount',
    'removedPriceHistoryCount', _reversal -> 'removedPriceHistoryCount',
    'sourceFileRetained', true
  );
END;
$$;
REVOKE ALL ON FUNCTION public.remove_posted_financial_document(uuid, uuid, timestamptz, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.remove_posted_financial_document(uuid, uuid, timestamptz, text, text) TO authenticated;
COMMENT ON FUNCTION public.remove_posted_financial_document(uuid, uuid, timestamptz, text, text) IS
  'Owner only. Removes a posted document with explicit confirmation and a reason, reversing inventory exactly as delete_invoice_permanently did, and records a durable snapshot. The source PDF is kept.';

-- ---------------------------------------------------------------------------------------
-- Source PDFs of posted or removed documents are retained: the owner storage delete policy
-- no longer matches them. Drafts and failed uploads are deletable as before.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.vendor_invoice_storage_deletable(_object_name text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NOT EXISTS (
      SELECT 1 FROM public.financial_document_removals removal
      WHERE removal.storage_path = _object_name
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.vendor_invoices source
      JOIN public.invoices invoice ON invoice.source_file_id = source.id
      WHERE source.storage_path = _object_name
        AND (invoice.posted_at IS NOT NULL OR invoice.processing_status = 'completed')
    )
$$;
REVOKE ALL ON FUNCTION public.vendor_invoice_storage_deletable(text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.vendor_invoice_storage_deletable(text) TO authenticated;
COMMENT ON FUNCTION public.vendor_invoice_storage_deletable(text) IS
  'Used by the vendor-invoices storage delete policy: false for the source file of a posted or removed financial document.';

DROP POLICY vendor_invoices_storage_owner_delete ON storage.objects;
CREATE POLICY vendor_invoices_storage_owner_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'vendor-invoices'
    AND EXISTS (
      SELECT 1
      FROM public.organization_memberships membership
      WHERE membership.organization_id::text = (storage.foldername(name))[1]
        AND membership.user_id = auth.uid()
        AND membership.role = 'owner'
        AND membership.active = true
    )
    AND public.vendor_invoice_storage_deletable(name)
  );


-- ---------------------------------------------------------------------------------------
-- Shared signal definitions (internal)
-- ---------------------------------------------------------------------------------------
-- Possible duplicates among counted documents in [_from, _to]: same vendor and the same
-- document number, or same vendor and the same amount within 30 days.
CREATE FUNCTION public.financial_possible_duplicate_ids(_organization_id uuid, _from date, _to date)
RETURNS TABLE (invoice_id uuid)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  WITH docs AS MATERIALIZED (
    SELECT * FROM public.financial_spend_rows(_organization_id, _from, _to) WHERE counted
  )
  SELECT a.invoice_id
  FROM docs a
  JOIN docs b
    ON b.vendor_id = a.vendor_id
   AND lower(b.document_number) = lower(a.document_number)
   AND b.invoice_id <> a.invoice_id
  UNION
  SELECT a.invoice_id
  FROM docs a
  JOIN docs b
    ON b.vendor_id = a.vendor_id
   AND b.amount = a.amount
   AND b.invoice_id <> a.invoice_id
   AND b.spend_date BETWEEN a.spend_date - 30 AND a.spend_date + 30
$$;
REVOKE ALL ON FUNCTION public.financial_possible_duplicate_ids(uuid, date, date) FROM PUBLIC, anon, authenticated, service_role;

-- Counted documents (any date) that no active budget period covers.
CREATE FUNCTION public.financial_outside_budget_ids(_organization_id uuid)
RETURNS TABLE (invoice_id uuid)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT document.invoice_id
  FROM public.financial_spend_rows(_organization_id, NULL, NULL) document
  WHERE document.counted
    AND NOT EXISTS (
      SELECT 1 FROM public.organization_budgets budget
      WHERE budget.organization_id = _organization_id
        AND budget.active
        AND document.spend_date BETWEEN budget.period_start AND budget.period_end
    )
$$;
REVOKE ALL ON FUNCTION public.financial_outside_budget_ids(uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.financial_assert_range(_from date, _to date)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
BEGIN
  IF _from IS NULL OR _to IS NULL THEN
    RAISE EXCEPTION 'from and to dates are required' USING ERRCODE = '22004';
  END IF;
  IF _from > _to THEN
    RAISE EXCEPTION 'from must be on or before to' USING ERRCODE = '22023';
  END IF;
  IF _to - _from > 3700 THEN
    RAISE EXCEPTION 'Date range is limited to ten years' USING ERRCODE = '22023';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.financial_assert_range(date, date) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.financial_assert_access(_organization_id uuid, _owner_only boolean)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _is_owner boolean;
BEGIN
  IF _organization_id IS NULL THEN
    RAISE EXCEPTION 'organization_id is required' USING ERRCODE = '22004';
  END IF;
  _is_owner := COALESCE(public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]), false);
  IF _owner_only AND NOT _is_owner THEN
    RAISE EXCEPTION 'Forbidden: owner access required' USING ERRCODE = '42501';
  END IF;
  IF NOT _owner_only AND NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  RETURN _is_owner;
END;
$$;
REVOKE ALL ON FUNCTION public.financial_assert_access(uuid, boolean) FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------
-- Spend summary (owner + admin): headline, commitments, pace, burn, coverage, signals.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.get_financial_spend_summary(
  _organization_id uuid,
  _budget_id uuid DEFAULT NULL,
  _as_of date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _today date := COALESCE(_as_of, (now() AT TIME ZONE 'UTC')::date);
  _is_owner boolean;
  _budget public.organization_budgets%ROWTYPE;
  _has_budget boolean;
  _from date;
  _to date;
  _month_start date := date_trunc('month', COALESCE(_as_of, (now() AT TIME ZONE 'UTC')::date))::date;
  _a record;
  _remaining numeric;
  _approx numeric;
  _state text;
  _elapsed numeric;
  _spent_ratio numeric;
  _gap numeric;
  _band text;
  _average numeric;
  _signals jsonb := '[]'::jsonb;
BEGIN
  _is_owner := public.financial_assert_access(_organization_id, false);

  IF _budget_id IS NOT NULL THEN
    SELECT * INTO _budget FROM public.organization_budgets
    WHERE id = _budget_id AND organization_id = _organization_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Budget not found' USING ERRCODE = 'P0002'; END IF;
  ELSE
    SELECT * INTO _budget FROM public.organization_budgets budget
    WHERE budget.organization_id = _organization_id AND budget.active
    ORDER BY (_today BETWEEN budget.period_start AND budget.period_end) DESC,
      budget.period_start DESC, budget.period_end DESC, budget.id
    LIMIT 1;
  END IF;
  _has_budget := _budget.id IS NOT NULL;
  IF _has_budget THEN
    _from := _budget.period_start;
    _to := _budget.period_end;
  ELSE
    _from := date_trunc('year', _today)::date;
    _to := _today;
  END IF;

  WITH docs AS MATERIALIZED (
    SELECT * FROM public.financial_spend_rows(_organization_id, _from, _to)
  ),
  burn_docs AS MATERIALIZED (
    SELECT spend_date, amount
    FROM public.financial_spend_rows(_organization_id, LEAST(_month_start, _today - 89), _today)
    WHERE counted
  ),
  commitments AS MATERIALIZED (
    SELECT * FROM public.financial_commitment_rows(_organization_id, _from, _to)
  ),
  lines AS (
    SELECT line.product_id, product.category_id
    FROM public.financial_spend_line_rows(_organization_id, _from, _to) line
    LEFT JOIN public.products product
      ON product.id = line.product_id AND product.organization_id = _organization_id
  ),
  outside AS (
    SELECT document.invoice_id, document.amount
    FROM public.financial_spend_rows(_organization_id, NULL, NULL) document
    JOIN public.financial_outside_budget_ids(_organization_id) outside_id
      ON outside_id.invoice_id = document.invoice_id
  ),
  duplicates AS (
    SELECT DISTINCT duplicate.invoice_id FROM public.financial_possible_duplicate_ids(_organization_id, _from, _to) duplicate
  ),
  removed AS (
    SELECT * FROM public.financial_document_removals removal
    WHERE removal.organization_id = _organization_id
      AND removal.spend_date BETWEEN _from AND _to
  ),
  complete_months AS (
    SELECT month_start::date AS month_start, (month_start + interval '1 month - 1 day')::date AS month_end
    FROM generate_series(date_trunc('month', _from), date_trunc('month', _to), interval '1 month') month_start
    WHERE month_start::date >= _from
      AND (month_start + interval '1 month - 1 day')::date <= _to
      AND (month_start + interval '1 month - 1 day')::date < _today
  )
  SELECT
    COALESCE(sum(d.amount) FILTER (WHERE d.counted), 0) AS spent,
    count(*) FILTER (WHERE d.counted) AS counted_count,
    count(*) FILTER (WHERE d.counted AND d.date_basis = 'posted_at_utc') AS posting_count,
    COALESCE(sum(d.amount) FILTER (WHERE d.counted AND d.date_basis = 'posted_at_utc'), 0) AS posting_amount,
    count(*) FILTER (WHERE d.counted AND d.document_type = 'ORDER_CONFIRMATION') AS oc_count,
    COALESCE(sum(d.amount) FILTER (WHERE d.counted AND d.document_type = 'ORDER_CONFIRMATION'), 0) AS oc_amount,
    count(*) FILTER (WHERE d.counted AND d.type_status = 'unknown') AS unknown_count,
    COALESCE(sum(d.amount) FILTER (WHERE d.counted AND d.type_status = 'unknown'), 0) AS unknown_amount,
    count(*) FILTER (WHERE d.counted AND d.type_status = 'missing') AS missing_count,
    COALESCE(sum(d.amount) FILTER (WHERE d.counted AND d.type_status = 'missing'), 0) AS missing_amount,
    count(*) FILTER (WHERE d.exclusion_reason = 'credit_memo') AS credit_count,
    COALESCE(sum(d.amount) FILTER (WHERE d.exclusion_reason = 'credit_memo'), 0) AS credit_amount,
    count(*) FILTER (WHERE d.exclusion_reason = 'statement') AS statement_count,
    COALESCE(sum(d.amount) FILTER (WHERE d.exclusion_reason = 'statement'), 0) AS statement_amount,
    count(*) FILTER (WHERE d.exclusion_reason = 'non_usd') AS non_usd_count,
    count(*) FILTER (WHERE d.counted AND d.currency_basis = 'legacy_usd') AS legacy_count,
    COALESCE(sum(d.amount) FILTER (WHERE d.counted AND d.currency_basis = 'legacy_usd'), 0) AS legacy_amount,
    count(*) FILTER (WHERE d.counted AND d.component_difference <> 0) AS diff_count,
    COALESCE(sum(d.component_difference) FILTER (WHERE d.counted), 0) AS diff_amount,
    COALESCE(sum(d.lines_total) FILTER (WHERE d.counted), 0) AS lines_total,
    COALESCE(sum(d.tax_amount) FILTER (WHERE d.counted), 0) AS tax_total,
    COALESCE(sum(d.shipping_amount) FILTER (WHERE d.counted), 0) AS shipping_total,
    (SELECT count(*) FROM duplicates) AS duplicate_count,
    (SELECT COALESCE(sum(x.amount), 0) FROM docs x JOIN duplicates y ON y.invoice_id = x.invoice_id) AS duplicate_amount,
    (SELECT count(*) FROM outside) AS outside_count,
    (SELECT COALESCE(sum(amount), 0) FROM outside) AS outside_amount,
    (SELECT count(*) FROM removed) AS removed_count,
    (SELECT COALESCE(sum(spend_amount) FILTER (WHERE counted_as_spend), 0) FROM removed) AS removed_amount,
    (SELECT count(*) FROM lines) AS line_count,
    (SELECT count(*) FROM lines WHERE category_id IS NOT NULL) AS categorized_line_count,
    (SELECT COALESCE(sum(amount), 0) FROM burn_docs WHERE spend_date BETWEEN _month_start AND _today) AS month_spent,
    (SELECT COALESCE(sum(amount), 0) FROM burn_docs WHERE spend_date BETWEEN _today - 89 AND _today) AS trailing_spent,
    (SELECT count(*) FROM complete_months) AS complete_month_count,
    (SELECT count(DISTINCT m.month_start) FROM complete_months m JOIN docs x
       ON x.counted AND x.spend_date BETWEEN m.month_start AND m.month_end) AS months_with_spend,
    (SELECT COALESCE(sum(x.amount), 0) FROM complete_months m JOIN docs x
       ON x.counted AND x.spend_date BETWEEN m.month_start AND m.month_end) AS complete_month_spent,
    (SELECT count(*) FROM commitments WHERE bucket = 'open') AS open_count,
    (SELECT COALESCE(sum(amount) FILTER (WHERE pricing_status <> 'unpriced'), 0) FROM commitments WHERE bucket = 'open') AS open_priced_amount,
    (SELECT count(*) FROM commitments WHERE bucket = 'open' AND pricing_status = 'fully_priced') AS open_fully,
    (SELECT count(*) FROM commitments WHERE bucket = 'open' AND pricing_status = 'partially_priced') AS open_partly,
    (SELECT count(*) FROM commitments WHERE bucket = 'open' AND pricing_status = 'unpriced') AS open_unpriced,
    (SELECT count(*) FROM commitments WHERE bucket = 'open' AND commitment_date < _today - 30) AS open_stale,
    (SELECT count(*) FROM commitments WHERE bucket = 'received_not_settled') AS rns_count,
    (SELECT COALESCE(sum(amount) FILTER (WHERE pricing_status <> 'unpriced'), 0) FROM commitments WHERE bucket = 'received_not_settled') AS rns_priced_amount,
    (SELECT count(*) FROM commitments WHERE bucket = 'received_not_settled' AND pricing_status = 'fully_priced') AS rns_fully,
    (SELECT count(*) FROM commitments WHERE bucket = 'received_not_settled' AND pricing_status = 'partially_priced') AS rns_partly,
    (SELECT count(*) FROM commitments WHERE bucket = 'received_not_settled' AND pricing_status = 'unpriced') AS rns_unpriced,
    (SELECT count(*) FROM commitments WHERE bucket = 'unexpected') AS unexpected_count
  INTO _a
  FROM docs d;

  IF _has_budget THEN
    _remaining := _budget.amount - _a.spent;
    IF _a.open_count > 0 THEN
      _approx := _remaining - _a.open_priced_amount;
    END IF;
    _state := CASE
      WHEN _today < _budget.period_start THEN 'not_started'
      WHEN _today > _budget.period_end THEN 'ended'
      WHEN _budget.amount = 0 THEN 'no_amount'
      ELSE 'in_progress'
    END;
    _elapsed := CASE
      WHEN _today < _budget.period_start THEN 0
      ELSE (LEAST(_today, _budget.period_end) - _budget.period_start + 1)::numeric
        / (_budget.period_end - _budget.period_start + 1)
    END;
    IF _budget.amount > 0 THEN
      _spent_ratio := _a.spent / _budget.amount;
    END IF;
    IF _state = 'in_progress' THEN
      _gap := (_spent_ratio - _elapsed) * 100;
      _band := CASE WHEN _gap > 5 THEN 'ahead' WHEN _gap < -5 THEN 'behind' ELSE 'even' END;
    END IF;
    IF _a.complete_month_count >= 6 AND _a.months_with_spend >= 6 THEN
      _average := round(_a.complete_month_spent / _a.complete_month_count, 2);
    END IF;

    IF _gap IS NOT NULL AND _gap > 10 THEN
      _signals := _signals || jsonb_build_object('code', 'pace_ahead', 'severity', 'warning',
        'gapPoints', round(_gap, 2), 'count', NULL, 'amount', NULL);
    END IF;
    IF _budget.amount >= 0 AND _a.spent > _budget.amount THEN
      _signals := _signals || jsonb_build_object('code', 'budget_over', 'severity', 'critical',
        'count', NULL, 'amount', _a.spent - _budget.amount);
    ELSIF _budget.amount > 0 AND _a.spent / _budget.amount >= 0.9 THEN
      _signals := _signals || jsonb_build_object('code', 'budget_near_limit', 'severity', 'warning',
        'count', NULL, 'amount', _remaining, 'usedPercent', round(_a.spent / _budget.amount * 100, 2));
    END IF;
  END IF;

  IF _a.open_partly + _a.open_unpriced > 0 THEN
    _signals := _signals || jsonb_build_object('code', 'open_commitments_unpriced', 'severity', 'info',
      'count', _a.open_partly + _a.open_unpriced, 'amount', NULL);
  END IF;
  IF _a.rns_count > 0 THEN
    _signals := _signals || jsonb_build_object('code', 'received_not_settled', 'severity', 'info',
      'count', _a.rns_count, 'amount', _a.rns_priced_amount);
  END IF;
  IF _a.open_stale > 0 THEN
    _signals := _signals || jsonb_build_object('code', 'open_commitment_stale', 'severity', 'warning',
      'count', _a.open_stale, 'amount', NULL);
  END IF;
  IF _a.outside_count > 0 THEN
    _signals := _signals || jsonb_build_object('code', 'spend_outside_budgets', 'severity', 'warning',
      'count', _a.outside_count, 'amount', _a.outside_amount);
  END IF;
  IF _a.posting_count > 0 THEN
    _signals := _signals || jsonb_build_object('code', 'dated_by_posting', 'severity', 'info',
      'count', _a.posting_count, 'amount', _a.posting_amount);
  END IF;
  IF _a.oc_count > 0 THEN
    _signals := _signals || jsonb_build_object('code', 'order_confirmations_counted', 'severity', 'info',
      'count', _a.oc_count, 'amount', _a.oc_amount);
  END IF;
  IF _a.duplicate_count > 0 THEN
    _signals := _signals || jsonb_build_object('code', 'possible_duplicates', 'severity', 'warning',
      'count', _a.duplicate_count, 'amount', _a.duplicate_amount);
  END IF;
  IF _a.non_usd_count > 0 THEN
    _signals := _signals || jsonb_build_object('code', 'non_usd_excluded', 'severity', 'warning',
      'count', _a.non_usd_count, 'amount', NULL);
  END IF;

  RETURN jsonb_build_object(
    'organizationId', _organization_id,
    'asOf', _today,
    'viewerIsOwner', _is_owner,
    'scope', jsonb_build_object(
      'kind', CASE WHEN _has_budget THEN 'budget' ELSE 'calendar_year_to_date' END,
      'budgetId', _budget.id,
      'budgetName', _budget.name,
      'budgetActive', _budget.active,
      'from', _from,
      'to', _to,
      'budgetAmount', _budget.amount
    ),
    'budgets', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('budgetId', budget.id, 'budgetName', budget.name,
        'periodStart', budget.period_start, 'periodEnd', budget.period_end, 'budgetAmount', budget.amount)
        ORDER BY budget.period_start DESC, budget.period_end DESC, budget.id)
      FROM public.organization_budgets budget
      WHERE budget.organization_id = _organization_id AND budget.active
    ), '[]'::jsonb),
    'spent', _a.spent,
    'countedDocumentCount', _a.counted_count,
    'remaining', _remaining,
    'commitments', jsonb_build_object(
      'open', jsonb_build_object('count', _a.open_count, 'pricedAmount', _a.open_priced_amount,
        'fullyPriced', _a.open_fully, 'partiallyPriced', _a.open_partly, 'unpriced', _a.open_unpriced,
        'staleCount', _a.open_stale),
      'receivedNotSettled', jsonb_build_object('count', _a.rns_count, 'pricedAmount', _a.rns_priced_amount,
        'fullyPriced', _a.rns_fully, 'partiallyPriced', _a.rns_partly, 'unpriced', _a.rns_unpriced),
      'unexpectedCount', _a.unexpected_count
    ),
    'approxRemainingAfterOpenCommitments', _approx,
    'pace', CASE WHEN _has_budget THEN jsonb_build_object(
      'state', _state,
      'elapsedPercent', round(_elapsed * 100, 2),
      'spentPercent', CASE WHEN _spent_ratio IS NULL THEN NULL ELSE round(_spent_ratio * 100, 2) END,
      'gapPoints', CASE WHEN _gap IS NULL THEN NULL ELSE round(_gap, 2) END,
      'band', _band
    ) END,
    'burn', jsonb_build_object(
      'monthStart', _month_start,
      'spentThisMonth', _a.month_spent,
      'trailingFrom', _today - 89,
      'trailing90Days', _a.trailing_spent,
      'completeMonths', _a.complete_month_count,
      'monthsWithSpend', _a.months_with_spend,
      'averagePerCompleteMonth', _average
    ),
    'coverage', jsonb_build_object(
      'countedDocuments', jsonb_build_object('count', _a.counted_count, 'amount', _a.spent),
      'datedByPosting', jsonb_build_object('count', _a.posting_count, 'amount', _a.posting_amount),
      'orderConfirmations', jsonb_build_object('count', _a.oc_count, 'amount', _a.oc_amount),
      'typeUnknown', jsonb_build_object('count', _a.unknown_count, 'amount', _a.unknown_amount),
      'typeMissing', jsonb_build_object('count', _a.missing_count, 'amount', _a.missing_amount),
      'excludedCreditMemos', jsonb_build_object('count', _a.credit_count, 'amount', _a.credit_amount),
      'excludedStatements', jsonb_build_object('count', _a.statement_count, 'amount', _a.statement_amount),
      'excludedNonUsd', jsonb_build_object('count', _a.non_usd_count),
      'legacyNoCurrency', jsonb_build_object('count', _a.legacy_count, 'amount', _a.legacy_amount),
      'componentDifferences', jsonb_build_object('count', _a.diff_count, 'amount', _a.diff_amount),
      'components', jsonb_build_object('linesTotal', _a.lines_total, 'taxTotal', _a.tax_total,
        'shippingTotal', _a.shipping_total, 'difference', _a.diff_amount),
      'linesCategorized', jsonb_build_object('categorized', _a.categorized_line_count, 'total', _a.line_count),
      'possibleDuplicates', jsonb_build_object('count', _a.duplicate_count, 'amount', _a.duplicate_amount),
      'removedAfterPosting', jsonb_build_object('count', _a.removed_count, 'amount', _a.removed_amount),
      'spendOutsideBudgets', jsonb_build_object('count', _a.outside_count, 'amount', _a.outside_amount)
    ),
    'signals', _signals
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_financial_spend_summary(uuid, uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_financial_spend_summary(uuid, uuid, date) TO authenticated;
COMMENT ON FUNCTION public.get_financial_spend_summary(uuid, uuid, date) IS
  'Owner + admin. Organization-wide spend for one budget period (default: the active budget covering today, UTC) or calendar year to date: Spent, Remaining = Budget - Spent, open and received-not-settled commitments with price coverage, pace, burn, coverage and attention signals.';

-- ---------------------------------------------------------------------------------------
-- Chart data (owner + admin)
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.get_financial_spend_series(_organization_id uuid, _from date, _to date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.financial_assert_access(_organization_id, false);
  PERFORM public.financial_assert_range(_from, _to);
  RETURN (
    WITH docs AS MATERIALIZED (
      SELECT spend_date, amount
      FROM public.financial_spend_rows(_organization_id, _from, _to)
      WHERE counted
    ),
    daily AS (
      SELECT spend_date, sum(amount) AS amount, count(*) AS document_count
      FROM docs GROUP BY spend_date
    ),
    months AS (
      SELECT month_start::date AS month_start
      FROM generate_series(date_trunc('month', _from), date_trunc('month', _to), interval '1 month') month_start
    )
    SELECT jsonb_build_object(
      'from', _from,
      'to', _to,
      'total', (SELECT COALESCE(sum(amount), 0) FROM docs),
      'cumulative', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('date', point.spend_date, 'amount', point.amount,
          'documentCount', point.document_count, 'cumulative', point.running) ORDER BY point.spend_date)
        FROM (
          SELECT spend_date, amount, document_count,
            sum(amount) OVER (ORDER BY spend_date) AS running
          FROM daily
        ) point
      ), '[]'::jsonb),
      'months', (
        SELECT jsonb_agg(jsonb_build_object(
          'month', to_char(month.month_start, 'YYYY-MM'),
          'monthStart', month.month_start,
          'amount', COALESCE((SELECT sum(amount) FROM docs WHERE date_trunc('month', spend_date) = month.month_start), 0),
          'documentCount', (SELECT count(*) FROM docs WHERE date_trunc('month', spend_date) = month.month_start)
        ) ORDER BY month.month_start)
        FROM months month
      )
    )
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_financial_spend_series(uuid, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_financial_spend_series(uuid, date, date) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Vendor analytics (owner + admin)
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.list_financial_vendor_spend(
  _organization_id uuid,
  _from date,
  _to date,
  _limit integer DEFAULT 100,
  _offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.financial_assert_access(_organization_id, false);
  PERFORM public.financial_assert_range(_from, _to);
  IF _limit IS NULL OR _limit < 1 OR _limit > 500 OR _offset IS NULL OR _offset < 0 THEN
    RAISE EXCEPTION 'limit must be 1 to 500 and offset at least 0' USING ERRCODE = '22023';
  END IF;
  RETURN (
    WITH docs AS MATERIALIZED (
      SELECT * FROM public.financial_spend_rows(_organization_id, _from, _to) WHERE counted
    ),
    vendors AS (
      SELECT
        vendor_id,
        max(vendor_name) AS vendor_name,
        sum(amount) AS spend,
        count(*) AS document_count,
        max(amount) AS largest,
        min(spend_date) AS first_date,
        max(spend_date) AS last_date,
        count(*) FILTER (WHERE document_type = 'ORDER_CONFIRMATION') AS oc_count
      FROM docs
      GROUP BY vendor_id
    ),
    total AS (SELECT COALESCE(sum(amount), 0) AS spend FROM docs)
    SELECT jsonb_build_object(
      'totalSpend', total.spend,
      'vendorCount', (SELECT count(*) FROM vendors),
      'rows', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'vendorId', page.vendor_id,
          'vendorName', page.vendor_name,
          'spend', page.spend,
          'sharePercent', CASE WHEN total.spend = 0 THEN NULL ELSE round(page.spend / total.spend * 100, 2) END,
          'documentCount', page.document_count,
          'averageDocument', round(page.spend / page.document_count, 2),
          'largestDocument', page.largest,
          'firstSpendDate', page.first_date,
          'lastSpendDate', page.last_date,
          'orderConfirmationCount', page.oc_count
        ) ORDER BY page.spend DESC, page.vendor_name, page.vendor_id)
        FROM (
          SELECT * FROM vendors
          ORDER BY spend DESC, vendor_name, vendor_id
          LIMIT _limit OFFSET _offset
        ) page
      ), '[]'::jsonb)
    )
    FROM total
  );
END;
$$;
REVOKE ALL ON FUNCTION public.list_financial_vendor_spend(uuid, date, date, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_financial_vendor_spend(uuid, date, date, integer, integer) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Product analytics (owner + admin). Line totals exclude tax and shipping; unit prices are
-- compared only within the same normalized unit of measure and package size.
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.list_financial_product_spend(
  _organization_id uuid,
  _from date,
  _to date,
  _sort text DEFAULT 'spend',
  _limit integer DEFAULT 50,
  _offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.financial_assert_access(_organization_id, false);
  PERFORM public.financial_assert_range(_from, _to);
  IF _sort IS NULL OR _sort NOT IN ('spend', 'documents', 'recent', 'name') THEN
    RAISE EXCEPTION 'sort must be spend, documents, recent or name' USING ERRCODE = '22023';
  END IF;
  IF _limit IS NULL OR _limit < 1 OR _limit > 200 OR _offset IS NULL OR _offset < 0 THEN
    RAISE EXCEPTION 'limit must be 1 to 200 and offset at least 0' USING ERRCODE = '22023';
  END IF;
  RETURN (
    WITH docs AS MATERIALIZED (
      SELECT * FROM public.financial_spend_rows(_organization_id, _from, _to) WHERE counted
    ),
    lines AS MATERIALIZED (
      SELECT line.*,
        COALESCE(line.unit_price, line.total_price / NULLIF(line.quantity, 0)) AS effective_unit_price
      FROM public.financial_spend_line_rows(_organization_id, _from, _to) line
    ),
    unit_groups AS (
      SELECT
        product_id, uom_key, package_key,
        max(unit_of_measure) AS unit_of_measure,
        max(package_size) AS package_size,
        sum(quantity) AS quantity,
        count(*) AS line_count,
        min(effective_unit_price) AS min_unit_price,
        max(effective_unit_price) AS max_unit_price,
        (array_agg(effective_unit_price ORDER BY spend_date DESC, invoice_id DESC, invoice_item_id DESC))[1] AS latest_unit_price
      FROM lines
      GROUP BY product_id, uom_key, package_key
    ),
    products AS (
      SELECT
        line.product_id,
        sum(line.total_price) AS spend,
        count(*) AS line_count,
        count(DISTINCT line.invoice_id) AS document_count,
        count(DISTINCT line.vendor_id) AS vendor_count,
        max(line.spend_date) AS last_date
      FROM lines line
      GROUP BY line.product_id
    ),
    named AS (
      SELECT products.*, COALESCE(product.name, 'Lines without a product') AS product_name
      FROM products
      LEFT JOIN public.products product
        ON product.id = products.product_id AND product.organization_id = _organization_id
    ),
    page AS (
      SELECT * FROM named
      ORDER BY
        CASE WHEN _sort = 'spend' THEN spend END DESC NULLS LAST,
        CASE WHEN _sort = 'documents' THEN document_count END DESC NULLS LAST,
        CASE WHEN _sort = 'recent' THEN last_date END DESC NULLS LAST,
        product_name, product_id
      LIMIT _limit OFFSET _offset
    ),
    totals AS (
      SELECT
        COALESCE(sum(amount), 0) AS spent,
        COALESCE(sum(lines_total), 0) AS lines_total,
        COALESCE(sum(tax_amount), 0) AS tax_total,
        COALESCE(sum(shipping_amount), 0) AS shipping_total,
        COALESCE(sum(component_difference), 0) AS difference
      FROM docs
    )
    SELECT jsonb_build_object(
      'sort', _sort,
      'productCount', (SELECT count(*) FROM named),
      'reconciliation', jsonb_build_object(
        'linesTotal', totals.lines_total, 'taxTotal', totals.tax_total,
        'shippingTotal', totals.shipping_total, 'difference', totals.difference,
        'spent', totals.spent),
      'rows', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'productId', page.product_id,
          'productName', page.product_name,
          'lineSpend', page.spend,
          'sharePercent', CASE WHEN totals.lines_total = 0 THEN NULL ELSE round(page.spend / totals.lines_total * 100, 2) END,
          'lineCount', page.line_count,
          'documentCount', page.document_count,
          'vendorCount', page.vendor_count,
          'lastSpendDate', page.last_date,
          'unitGroups', (
            SELECT jsonb_agg(jsonb_build_object(
              'unitOfMeasure', grp.unit_of_measure,
              'packageSize', grp.package_size,
              'quantity', grp.quantity,
              'lineCount', grp.line_count,
              'minUnitPrice', grp.min_unit_price,
              'maxUnitPrice', grp.max_unit_price,
              'latestUnitPrice', grp.latest_unit_price
            ) ORDER BY grp.quantity DESC, grp.uom_key NULLS LAST, grp.package_key NULLS LAST)
            FROM unit_groups grp
            WHERE grp.product_id IS NOT DISTINCT FROM page.product_id
          )
        ) ORDER BY
          CASE WHEN _sort = 'spend' THEN page.spend END DESC NULLS LAST,
          CASE WHEN _sort = 'documents' THEN page.document_count END DESC NULLS LAST,
          CASE WHEN _sort = 'recent' THEN page.last_date END DESC NULLS LAST,
          page.product_name, page.product_id)
        FROM page
      ), '[]'::jsonb)
    )
    FROM totals
  );
END;
$$;
REVOKE ALL ON FUNCTION public.list_financial_product_spend(uuid, date, date, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_financial_product_spend(uuid, date, date, text, integer, integer) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Commitments list (owner + admin; request level only)
-- ---------------------------------------------------------------------------------------
CREATE FUNCTION public.list_financial_commitments(
  _organization_id uuid,
  _from date,
  _to date,
  _bucket text DEFAULT 'all',
  _limit integer DEFAULT 50,
  _offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.financial_assert_access(_organization_id, false);
  PERFORM public.financial_assert_range(_from, _to);
  IF _bucket IS NULL OR _bucket NOT IN ('all', 'open', 'received_not_settled') THEN
    RAISE EXCEPTION 'bucket must be all, open or received_not_settled' USING ERRCODE = '22023';
  END IF;
  IF _limit IS NULL OR _limit < 1 OR _limit > 200 OR _offset IS NULL OR _offset < 0 THEN
    RAISE EXCEPTION 'limit must be 1 to 200 and offset at least 0' USING ERRCODE = '22023';
  END IF;
  RETURN (
    WITH rows AS MATERIALIZED (
      SELECT * FROM public.financial_commitment_rows(_organization_id, _from, _to)
      WHERE _bucket = 'all' OR bucket = _bucket
    )
    SELECT jsonb_build_object(
      'bucket', _bucket,
      'totalCount', (SELECT count(*) FROM rows),
      'pricedAmount', (SELECT COALESCE(sum(amount) FILTER (WHERE pricing_status <> 'unpriced'), 0) FROM rows),
      'rows', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'commitmentId', page.commitment_id,
          'requestId', page.supply_request_id,
          'requestStatus', page.request_status,
          'bucket', page.bucket,
          'committedAt', page.committed_at,
          'commitmentDate', page.commitment_date,
          'amount', CASE WHEN page.pricing_status = 'unpriced' THEN NULL ELSE page.amount END,
          'pricingStatus', page.pricing_status,
          'itemCount', page.total_item_count,
          'pricedItemCount', page.priced_item_count,
          'teamName', (
            SELECT team.name FROM public.supply_requests request
            JOIN public.teams team ON team.id = request.team_id
            WHERE request.id = page.supply_request_id
          ),
          'itemLabel', (
            SELECT COALESCE(product.name, NULLIF(btrim(item.free_text_item), ''), 'Catalog item')
            FROM public.supply_request_items item
            LEFT JOIN public.products product
              ON product.id = item.product_id AND product.organization_id = item.organization_id
            WHERE item.supply_request_id = page.supply_request_id
              AND item.organization_id = _organization_id
            ORDER BY item.created_at, item.id
            LIMIT 1
          )
        ) ORDER BY page.committed_at, page.commitment_id)
        FROM (
          SELECT * FROM rows ORDER BY committed_at, commitment_id LIMIT _limit OFFSET _offset
        ) page
      ), '[]'::jsonb)
    )
  );
END;
$$;
REVOKE ALL ON FUNCTION public.list_financial_commitments(uuid, date, date, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_financial_commitments(uuid, date, date, text, integer, integer) TO authenticated;

-- ---------------------------------------------------------------------------------------
-- Document drill-down (owner only)
-- ---------------------------------------------------------------------------------------
-- Client JSON for one financial_spend_rows row (passed as to_jsonb(row)).
CREATE FUNCTION public.financial_spend_row_json(_row jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'invoiceId', _row -> 'invoice_id',
    'sourceFileId', _row -> 'source_file_id',
    'vendorId', _row -> 'vendor_id',
    'vendorName', _row -> 'vendor_name',
    'documentType', _row -> 'document_type',
    'typeStatus', _row -> 'type_status',
    'documentNumber', _row -> 'document_number',
    'invoiceDate', _row -> 'invoice_date',
    'postedAt', _row -> 'posted_at',
    'spendDate', _row -> 'spend_date',
    'dateBasis', _row -> 'date_basis',
    'amount', _row -> 'amount',
    'amountBasis', _row -> 'amount_basis',
    'subtotal', _row -> 'subtotal',
    'taxAmount', _row -> 'tax_amount',
    'shippingAmount', _row -> 'shipping_amount',
    'linesTotal', _row -> 'lines_total',
    'lineCount', _row -> 'line_count',
    'componentDifference', _row -> 'component_difference',
    'currencyCode', _row -> 'currency_code',
    'currencyBasis', _row -> 'currency_basis',
    'counted', _row -> 'counted',
    'exclusionReason', _row -> 'exclusion_reason'
  )
$$;
REVOKE ALL ON FUNCTION public.financial_spend_row_json(jsonb) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.list_financial_spend_documents(
  _organization_id uuid,
  _from date,
  _to date,
  _filter text DEFAULT 'all',
  _value text DEFAULT NULL,
  _limit integer DEFAULT 50,
  _cursor_spend_date date DEFAULT NULL,
  _cursor_invoice_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _month date;
  _vendor uuid;
  _range_from date := _from;
  _range_to date := _to;
BEGIN
  PERFORM public.financial_assert_access(_organization_id, true);
  IF _filter IS NULL OR _filter NOT IN ('all', 'month', 'vendor', 'dated_by_posting', 'order_confirmations',
      'type_unclassified', 'legacy_currency', 'component_difference', 'possible_duplicates',
      'outside_budgets', 'excluded') THEN
    RAISE EXCEPTION 'Unknown document filter' USING ERRCODE = '22023';
  END IF;
  IF _filter = 'outside_budgets' THEN
    -- Organization-wide by definition; the range is ignored.
    _range_from := NULL;
    _range_to := NULL;
  ELSE
    PERFORM public.financial_assert_range(_from, _to);
  END IF;
  IF _filter = 'month' THEN
    IF _value IS NULL OR _value !~ '^\d{4}-(0[1-9]|1[0-2])$' THEN
      RAISE EXCEPTION 'month filter needs YYYY-MM' USING ERRCODE = '22023';
    END IF;
    _month := (_value || '-01')::date;
  ELSIF _filter = 'vendor' THEN
    IF _value IS NULL OR _value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'vendor filter needs a vendor id' USING ERRCODE = '22023';
    END IF;
    _vendor := _value::uuid;
  END IF;
  IF _limit IS NULL OR _limit < 1 OR _limit > 200 THEN
    RAISE EXCEPTION 'limit must be 1 to 200' USING ERRCODE = '22023';
  END IF;
  IF (_cursor_spend_date IS NULL) <> (_cursor_invoice_id IS NULL) THEN
    RAISE EXCEPTION 'cursor needs both spend date and invoice id' USING ERRCODE = '22023';
  END IF;

  RETURN (
    WITH filtered AS MATERIALIZED (
      SELECT document.*
      FROM public.financial_spend_rows(_organization_id, _range_from, _range_to) document
      WHERE CASE _filter
        WHEN 'excluded' THEN NOT document.counted
        WHEN 'all' THEN document.counted
        WHEN 'month' THEN document.counted AND date_trunc('month', document.spend_date)::date = _month
        WHEN 'vendor' THEN document.counted AND document.vendor_id = _vendor
        WHEN 'dated_by_posting' THEN document.counted AND document.date_basis = 'posted_at_utc'
        WHEN 'order_confirmations' THEN document.counted AND document.document_type = 'ORDER_CONFIRMATION'
        WHEN 'type_unclassified' THEN document.counted AND document.type_status <> 'classified'
        WHEN 'legacy_currency' THEN document.counted AND document.currency_basis = 'legacy_usd'
        WHEN 'component_difference' THEN document.counted AND document.component_difference <> 0
        WHEN 'possible_duplicates' THEN document.counted AND document.invoice_id IN (
          SELECT duplicate.invoice_id FROM public.financial_possible_duplicate_ids(_organization_id, _from, _to) duplicate)
        WHEN 'outside_budgets' THEN document.invoice_id IN (
          SELECT outside.invoice_id FROM public.financial_outside_budget_ids(_organization_id) outside)
      END
    ),
    page AS (
      SELECT * FROM filtered
      WHERE _cursor_spend_date IS NULL
         OR (spend_date, invoice_id) < (_cursor_spend_date, _cursor_invoice_id)
      ORDER BY spend_date DESC, invoice_id DESC
      LIMIT _limit + 1
    ),
    shown AS (
      SELECT * FROM page ORDER BY spend_date DESC, invoice_id DESC LIMIT _limit
    )
    SELECT jsonb_build_object(
      'filter', _filter,
      'value', _value,
      'countsTowardSpent', _filter <> 'excluded',
      'totalCount', (SELECT count(*) FROM filtered),
      'totalAmount', (SELECT COALESCE(sum(amount), 0) FROM filtered),
      'rows', COALESCE((
        SELECT jsonb_agg(public.financial_spend_row_json(to_jsonb(shown)) ORDER BY shown.spend_date DESC, shown.invoice_id DESC)
        FROM shown
      ), '[]'::jsonb),
      'nextCursor', CASE WHEN (SELECT count(*) FROM page) > _limit THEN (
        SELECT jsonb_build_object('spendDate', last_row.spend_date, 'invoiceId', last_row.invoice_id)
        FROM (SELECT * FROM shown ORDER BY spend_date, invoice_id LIMIT 1) last_row
      ) END
    )
  );
END;
$$;
REVOKE ALL ON FUNCTION public.list_financial_spend_documents(uuid, date, date, text, text, integer, date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_financial_spend_documents(uuid, date, date, text, text, integer, date, uuid) TO authenticated;

CREATE FUNCTION public.get_financial_document_detail(_organization_id uuid, _invoice_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _row record;
BEGIN
  PERFORM public.financial_assert_access(_organization_id, true);
  IF _invoice_id IS NULL THEN
    RAISE EXCEPTION 'invoice_id is required' USING ERRCODE = '22004';
  END IF;
  SELECT * INTO _row FROM public.financial_spend_rows(_organization_id, NULL, NULL, _invoice_id);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Posted document not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object(
    'document', public.financial_spend_row_json(to_jsonb(_row)),
    'lines', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'invoiceItemId', item.id,
        'lineNumber', item.line_number,
        'productId', item.product_id,
        'productName', product.name,
        'description', item.description,
        'sku', item.sku,
        'quantity', item.quantity,
        'unitOfMeasure', item.unit_of_measure,
        'packageSize', item.package_size,
        'unitPrice', item.unit_price,
        'totalPrice', item.total_price
      ) ORDER BY item.line_number NULLS LAST, item.created_at, item.id)
      FROM public.invoice_items item
      LEFT JOIN public.products product
        ON product.id = item.product_id AND product.organization_id = item.organization_id
      WHERE item.invoice_id = _invoice_id AND item.organization_id = _organization_id
    ), '[]'::jsonb),
    'flags', jsonb_build_object(
      'orderConfirmation', _row.document_type = 'ORDER_CONFIRMATION',
      'datedByPosting', _row.date_basis = 'posted_at_utc',
      'typeUnclassified', _row.type_status <> 'classified',
      'legacyCurrency', _row.currency_basis = 'legacy_usd',
      'componentDifference', _row.component_difference <> 0,
      'possibleDuplicate', _row.counted AND EXISTS (
        SELECT 1 FROM public.financial_possible_duplicate_ids(_organization_id, _row.spend_date - 30, _row.spend_date + 30) duplicate
        WHERE duplicate.invoice_id = _invoice_id
      ),
      'outsideBudgets', _row.counted AND NOT EXISTS (
        SELECT 1 FROM public.organization_budgets budget
        WHERE budget.organization_id = _organization_id AND budget.active
          AND _row.spend_date BETWEEN budget.period_start AND budget.period_end
      )
    )
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_financial_document_detail(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_financial_document_detail(uuid, uuid) TO authenticated;

CREATE FUNCTION public.list_financial_product_lines(
  _organization_id uuid,
  _product_id uuid,
  _from date,
  _to date,
  _limit integer DEFAULT 50,
  _cursor_spend_date date DEFAULT NULL,
  _cursor_item_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.financial_assert_access(_organization_id, true);
  PERFORM public.financial_assert_range(_from, _to);
  IF _limit IS NULL OR _limit < 1 OR _limit > 200 THEN
    RAISE EXCEPTION 'limit must be 1 to 200' USING ERRCODE = '22023';
  END IF;
  IF (_cursor_spend_date IS NULL) <> (_cursor_item_id IS NULL) THEN
    RAISE EXCEPTION 'cursor needs both spend date and line id' USING ERRCODE = '22023';
  END IF;
  RETURN (
    WITH filtered AS MATERIALIZED (
      SELECT * FROM public.financial_spend_line_rows(_organization_id, _from, _to)
      WHERE product_id IS NOT DISTINCT FROM _product_id
    ),
    page AS (
      SELECT * FROM filtered
      WHERE _cursor_spend_date IS NULL
         OR (spend_date, invoice_item_id) < (_cursor_spend_date, _cursor_item_id)
      ORDER BY spend_date DESC, invoice_item_id DESC
      LIMIT _limit + 1
    ),
    shown AS (SELECT * FROM page ORDER BY spend_date DESC, invoice_item_id DESC LIMIT _limit)
    SELECT jsonb_build_object(
      'productId', _product_id,
      'totalCount', (SELECT count(*) FROM filtered),
      'totalLineSpend', (SELECT COALESCE(sum(total_price), 0) FROM filtered),
      'rows', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'invoiceId', shown.invoice_id,
          'invoiceItemId', shown.invoice_item_id,
          'spendDate', shown.spend_date,
          'vendorId', shown.vendor_id,
          'vendorName', shown.vendor_name,
          'documentNumber', shown.document_number,
          'description', shown.description,
          'quantity', shown.quantity,
          'unitOfMeasure', shown.unit_of_measure,
          'packageSize', shown.package_size,
          'unitPrice', shown.unit_price,
          'totalPrice', shown.total_price
        ) ORDER BY shown.spend_date DESC, shown.invoice_item_id DESC)
        FROM shown
      ), '[]'::jsonb),
      'nextCursor', CASE WHEN (SELECT count(*) FROM page) > _limit THEN (
        SELECT jsonb_build_object('spendDate', last_row.spend_date, 'invoiceItemId', last_row.invoice_item_id)
        FROM (SELECT * FROM shown ORDER BY spend_date, invoice_item_id LIMIT 1) last_row
      ) END
    )
  );
END;
$$;
REVOKE ALL ON FUNCTION public.list_financial_product_lines(uuid, uuid, date, date, integer, date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_financial_product_lines(uuid, uuid, date, date, integer, date, uuid) TO authenticated;

CREATE FUNCTION public.list_financial_document_removals(
  _organization_id uuid,
  _limit integer DEFAULT 50,
  _cursor_removed_at timestamptz DEFAULT NULL,
  _cursor_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.financial_assert_access(_organization_id, true);
  IF _limit IS NULL OR _limit < 1 OR _limit > 200 THEN
    RAISE EXCEPTION 'limit must be 1 to 200' USING ERRCODE = '22023';
  END IF;
  IF (_cursor_removed_at IS NULL) <> (_cursor_id IS NULL) THEN
    RAISE EXCEPTION 'cursor needs both removed_at and id' USING ERRCODE = '22023';
  END IF;
  RETURN (
    WITH page AS (
      SELECT removal.*
      FROM public.financial_document_removals removal
      WHERE removal.organization_id = _organization_id
        AND (_cursor_removed_at IS NULL OR (removal.removed_at, removal.id) < (_cursor_removed_at, _cursor_id))
      ORDER BY removal.removed_at DESC, removal.id DESC
      LIMIT _limit + 1
    ),
    shown AS (SELECT * FROM page ORDER BY removed_at DESC, id DESC LIMIT _limit)
    SELECT jsonb_build_object(
      'totalCount', (SELECT count(*) FROM public.financial_document_removals WHERE organization_id = _organization_id),
      'rows', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'removalId', shown.id,
          'removedAt', shown.removed_at,
          'removedByName', COALESCE(NULLIF(btrim(profile.full_name), ''), profile.email),
          'reason', shown.reason,
          'vendorName', shown.vendor_name,
          'documentType', shown.document_type,
          'documentNumber', shown.document_number,
          'spendDate', shown.spend_date,
          'spendAmount', shown.spend_amount,
          'countedAsSpend', shown.counted_as_spend,
          'lineCount', jsonb_array_length(shown.lines),
          'sourceFileRetained', shown.source_file_retained,
          'originalFilename', shown.original_filename
        ) ORDER BY shown.removed_at DESC, shown.id DESC)
        FROM shown
        LEFT JOIN public.profiles profile ON profile.id = shown.removed_by
      ), '[]'::jsonb),
      'nextCursor', CASE WHEN (SELECT count(*) FROM page) > _limit THEN (
        SELECT jsonb_build_object('removedAt', last_row.removed_at, 'id', last_row.id)
        FROM (SELECT * FROM shown ORDER BY removed_at, id LIMIT 1) last_row
      ) END
    )
  );
END;
$$;
REVOKE ALL ON FUNCTION public.list_financial_document_removals(uuid, integer, timestamptz, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_financial_document_removals(uuid, integer, timestamptz, uuid) TO authenticated;


-- ---------------------------------------------------------------------------------------
-- Existing budget reads, rebased on financial_spend_rows / financial_commitment_rows so the
-- Command Center, request approval panel and Spend tab agree. Same signatures and exactly the
-- same JSON keys: the deployed app parses these with strict schemas during the window between
-- the migration and the deploy.
-- ---------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_budget_summary(
  _organization_id uuid,
  _budget_id uuid
)
RETURNS TABLE (
  budget_id uuid,
  budget_name text,
  period_start date,
  period_end date,
  budget_amount numeric,
  actual_spend numeric,
  committed_spend numeric,
  available_amount numeric,
  remaining_amount numeric,
  posted_invoice_count bigint,
  active_commitment_count bigint,
  incomplete_commitment_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _budget public.organization_budgets%ROWTYPE;
BEGIN
  IF NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required';
  END IF;

  SELECT * INTO _budget FROM public.organization_budgets budget
  WHERE budget.organization_id = _organization_id AND budget.id = _budget_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH spend AS (
    SELECT COALESCE(sum(document.amount), 0)::numeric AS actual, count(*)::bigint AS documents
    FROM public.financial_spend_rows(_organization_id, _budget.period_start, _budget.period_end) document
    WHERE document.counted
  ),
  commitments AS (
    SELECT
      COALESCE(sum(commitment.amount), 0)::numeric AS committed,
      count(*)::bigint AS active_count,
      count(*) FILTER (WHERE commitment.pricing_status <> 'fully_priced')::bigint AS incomplete_count
    FROM public.financial_commitment_rows(_organization_id, _budget.period_start, _budget.period_end) commitment
  )
  SELECT
    _budget.id,
    _budget.name,
    _budget.period_start,
    _budget.period_end,
    _budget.amount,
    spend.actual,
    commitments.committed,
    -- Kept for older clients only; Phase 7E screens show Remaining = Budget - Spent.
    (_budget.amount - spend.actual - commitments.committed)::numeric,
    (_budget.amount - spend.actual)::numeric,
    spend.documents,
    commitments.active_count,
    commitments.incomplete_count
  FROM spend CROSS JOIN commitments;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_supply_request_budget_impact(
  _organization_id uuid,
  _request_id uuid
)
RETURNS TABLE (
  request_id uuid,
  request_status public.supply_request_status,
  estimated_amount numeric,
  pricing_status text,
  total_item_count integer,
  priced_item_count integer,
  commitment_status text,
  commitment_release_reason text,
  budget_id uuid,
  budget_name text,
  budget_amount numeric,
  actual_spend numeric,
  committed_spend numeric,
  available_amount numeric,
  projected_available_after_approval numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _today date := (now() AT TIME ZONE 'UTC')::date;
BEGIN
  IF NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: administrator access required' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.supply_requests request
    WHERE request.id = _request_id AND request.organization_id = _organization_id
  ) THEN
    RAISE EXCEPTION 'Supply request not found' USING ERRCODE = 'P0002';
  END IF;

  RETURN QUERY
  WITH live_estimates AS MATERIALIZED (
    SELECT * FROM public.resolve_supply_request_item_costs(_organization_id, _request_id)
  ),
  live_total AS (
    SELECT
      COUNT(*)::integer AS total_item_count,
      COUNT(unit_cost)::integer AS priced_item_count,
      COALESCE(SUM(line_amount), 0)::numeric AS amount
    FROM live_estimates
  ),
  request_cost AS (
    SELECT
      request.id,
      request.status AS lifecycle_status,
      COALESCE(commitment.amount, live.amount) AS amount,
      COALESCE(commitment.total_item_count, live.total_item_count) AS total_item_count,
      COALESCE(commitment.priced_item_count, live.priced_item_count) AS priced_item_count,
      COALESCE(commitment.pricing_status, CASE
        WHEN live.priced_item_count = 0 THEN 'unpriced'
        WHEN live.priced_item_count = live.total_item_count THEN 'fully_priced'
        ELSE 'partially_priced'
      END) AS pricing_status,
      commitment.status AS commitment_status,
      commitment.release_reason
    FROM public.supply_requests request
    CROSS JOIN live_total live
    LEFT JOIN public.supply_request_commitments commitment
      ON commitment.supply_request_id = request.id
     AND commitment.organization_id = request.organization_id
    WHERE request.id = _request_id AND request.organization_id = _organization_id
  ),
  selected_budget AS (
    SELECT budget.*
    FROM public.organization_budgets budget
    WHERE budget.organization_id = _organization_id
      AND budget.active = true
      AND _today BETWEEN budget.period_start AND budget.period_end
    ORDER BY budget.period_start DESC, budget.period_end DESC, budget.id
    LIMIT 1
  ),
  budget_values AS (
    SELECT
      budget.*,
      COALESCE((
        SELECT SUM(document.amount)
        FROM public.financial_spend_rows(_organization_id, budget.period_start, budget.period_end) document
        WHERE document.counted
      ), 0)::numeric AS actual_spend,
      COALESCE((
        SELECT SUM(commitment.amount)
        FROM public.financial_commitment_rows(_organization_id, budget.period_start, budget.period_end) commitment
      ), 0)::numeric AS committed_spend
    FROM selected_budget budget
  )
  SELECT
    cost.id,
    cost.lifecycle_status,
    cost.amount,
    cost.pricing_status,
    cost.total_item_count,
    cost.priced_item_count,
    cost.commitment_status,
    cost.release_reason,
    budget.id,
    budget.name,
    budget.amount,
    budget.actual_spend,
    budget.committed_spend,
    CASE WHEN budget.id IS NULL THEN NULL
      ELSE budget.amount - budget.actual_spend - budget.committed_spend END,
    CASE
      WHEN budget.id IS NULL OR cost.pricing_status = 'unpriced' THEN NULL
      WHEN cost.commitment_status = 'active'
        THEN budget.amount - budget.actual_spend - budget.committed_spend
      WHEN cost.lifecycle_status IN ('submitted', 'under_review')
        THEN budget.amount - budget.actual_spend - budget.committed_spend - cost.amount
      ELSE NULL
    END
  FROM request_cost cost
  LEFT JOIN budget_values budget ON true;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_budget_purchasing_overview(_organization_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _is_owner boolean;
  _result jsonb;
BEGIN
  IF _organization_id IS NULL THEN
    RAISE EXCEPTION 'organization_id is required' USING ERRCODE = '22004';
  END IF;
  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  _is_owner := COALESCE(
    public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]),
    false
  );

  WITH budget_rows AS (
    SELECT summary.*
    FROM public.organization_budgets budget
    CROSS JOIN LATERAL public.get_budget_summary(_organization_id, budget.id) summary
    WHERE budget.organization_id = _organization_id
      AND budget.active = true
  ),
  -- Settlement candidates: active commitments whose request is received or completed
  -- (Phase 7E "received, not settled"). Surfaced for review only.
  active_commitments AS (
    SELECT
      commitment.commitment_id AS id,
      commitment.supply_request_id,
      commitment.amount,
      commitment.pricing_status,
      commitment.total_item_count,
      commitment.committed_at,
      commitment.commitment_date,
      commitment.request_status,
      commitment.bucket = 'received_not_settled' AS settlement_candidate
    FROM public.financial_commitment_rows(_organization_id, NULL, NULL) commitment
  ),
  recent_invoices AS (
    SELECT document.*
    FROM public.financial_spend_rows(_organization_id, NULL, NULL) document
    WHERE _is_owner AND document.counted
    ORDER BY document.spend_date DESC, document.posted_at DESC, document.invoice_id DESC
    LIMIT 8
  )
  SELECT jsonb_build_object(
    'organizationId', _organization_id,
    'viewerIsOwner', _is_owner,
    'budgets', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'budgetId', budget_row.budget_id,
        'budgetName', budget_row.budget_name,
        'periodStart', budget_row.period_start,
        'periodEnd', budget_row.period_end,
        'budgetAmount', budget_row.budget_amount,
        'actualSpend', budget_row.actual_spend,
        'committedSpend', budget_row.committed_spend,
        'availableAmount', budget_row.available_amount,
        'postedInvoiceCount', budget_row.posted_invoice_count,
        'activeCommitmentCount', budget_row.active_commitment_count,
        'incompleteCommitmentCount', budget_row.incomplete_commitment_count,
        'settlementCandidateCount', (
          SELECT count(*) FROM active_commitments candidate
          WHERE candidate.settlement_candidate
            AND candidate.commitment_date BETWEEN budget_row.period_start AND budget_row.period_end
        ),
        'settlementCandidateAmount', (
          SELECT COALESCE(SUM(candidate.amount), 0) FROM active_commitments candidate
          WHERE candidate.settlement_candidate
            AND candidate.commitment_date BETWEEN budget_row.period_start AND budget_row.period_end
        )
      ) ORDER BY budget_row.period_start DESC, budget_row.period_end DESC, budget_row.budget_id)
      FROM budget_rows budget_row
    ), '[]'::jsonb),
    'attention', jsonb_build_object(
      'awaitingApprovalCount', (
        SELECT count(*) FROM public.supply_requests request
        WHERE request.organization_id = _organization_id
          AND request.status IN ('submitted', 'under_review')
      ),
      'commitmentsToSettleCount', (
        SELECT count(*) FROM active_commitments WHERE settlement_candidate
      ),
      'commitmentsToSettleAmount', (
        SELECT COALESCE(SUM(amount), 0) FROM active_commitments WHERE settlement_candidate
      ),
      'unpricedCommitmentCount', (
        SELECT count(*) FROM active_commitments WHERE pricing_status <> 'fully_priced'
      ),
      'invoiceReviewCount', CASE WHEN _is_owner THEN (
        SELECT count(*) FROM public.invoice_processing_jobs job
        WHERE job.organization_id = _organization_id
          AND job.status = 'review_required'
      ) END
    ),
    'settlementCandidates', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'requestId', listed.supply_request_id,
        'requestStatus', listed.request_status,
        'committedAt', listed.committed_at,
        'amount', listed.amount,
        'pricingStatus', listed.pricing_status,
        'itemCount', listed.total_item_count,
        'itemLabel', (
          SELECT COALESCE(product.name, NULLIF(btrim(item.free_text_item), ''), 'Catalog item')
          FROM public.supply_request_items item
          LEFT JOIN public.products product
            ON product.id = item.product_id AND product.organization_id = item.organization_id
          WHERE item.supply_request_id = listed.supply_request_id
            AND item.organization_id = _organization_id
          ORDER BY item.created_at, item.id
          LIMIT 1
        )
      ) ORDER BY listed.committed_at, listed.id)
      FROM (
        SELECT * FROM active_commitments WHERE settlement_candidate
        ORDER BY committed_at, id
        LIMIT 25
      ) listed
    ), '[]'::jsonb),
    'settlementCandidateLimit', 25,
    'recentPurchases', CASE WHEN _is_owner THEN COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'invoiceId', recent.invoice_id,
        'sourceFileId', recent.source_file_id,
        'vendorName', recent.vendor_name,
        'invoiceNumber', recent.document_number,
        'spendDate', recent.spend_date,
        'amount', recent.amount
      ) ORDER BY recent.spend_date DESC, recent.posted_at DESC, recent.invoice_id DESC)
      FROM recent_invoices recent
    ), '[]'::jsonb) END
  ) INTO _result;

  RETURN _result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_budget_lineage(_organization_id uuid, _budget_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _budget public.organization_budgets%ROWTYPE;
  _is_owner boolean;
  _result jsonb;
BEGIN
  IF _organization_id IS NULL OR _budget_id IS NULL THEN
    RAISE EXCEPTION 'organization_id and budget_id are required' USING ERRCODE = '22004';
  END IF;
  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO _budget FROM public.organization_budgets budget
  WHERE budget.id = _budget_id AND budget.organization_id = _organization_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Budget not found' USING ERRCODE = 'P0002';
  END IF;
  _is_owner := COALESCE(
    public.has_org_role(_organization_id, auth.uid(), ARRAY['owner']::public.org_role[]),
    false
  );

  WITH commitments AS (
    SELECT
      commitment.commitment_id AS id,
      commitment.supply_request_id,
      commitment.committed_at,
      commitment.amount,
      commitment.pricing_status,
      commitment.total_item_count,
      commitment.request_status
    FROM public.financial_commitment_rows(_organization_id, _budget.period_start, _budget.period_end) commitment
  ),
  listed_commitments AS (
    SELECT * FROM commitments
    ORDER BY committed_at DESC, id DESC
    LIMIT 50
  ),
  posted AS (
    SELECT document.*
    FROM public.financial_spend_rows(_organization_id, _budget.period_start, _budget.period_end) document
    WHERE _is_owner AND document.counted
  ),
  listed_posted AS (
    SELECT * FROM posted ORDER BY spend_date DESC, invoice_id DESC LIMIT 50
  )
  SELECT jsonb_build_object(
    'budgetId', _budget.id,
    'commitmentCount', (SELECT count(*) FROM commitments),
    'commitmentTotal', (SELECT COALESCE(sum(amount), 0) FROM commitments),
    'settlementCandidateCount', (
      SELECT count(*) FROM commitments WHERE request_status IN ('received', 'completed')
    ),
    'settlementCandidateTotal', (
      SELECT COALESCE(sum(amount), 0) FROM commitments
      WHERE request_status IN ('received', 'completed')
    ),
    'commitments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'requestId', listed.supply_request_id,
        'requestStatus', listed.request_status,
        'committedAt', listed.committed_at,
        'amount', listed.amount,
        'pricingStatus', listed.pricing_status,
        'itemCount', listed.total_item_count,
        'settlementCandidate', listed.request_status IN ('received', 'completed'),
        'itemLabel', (
          SELECT COALESCE(product.name, NULLIF(btrim(item.free_text_item), ''), 'Catalog item')
          FROM public.supply_request_items item
          LEFT JOIN public.products product
            ON product.id = item.product_id AND product.organization_id = item.organization_id
          WHERE item.supply_request_id = listed.supply_request_id
            AND item.organization_id = _organization_id
          ORDER BY item.created_at, item.id
          LIMIT 1
        )
      ) ORDER BY listed.committed_at DESC, listed.id DESC)
      FROM listed_commitments listed
    ), '[]'::jsonb),
    'postedInvoiceCount', CASE WHEN _is_owner THEN (SELECT count(*) FROM posted) END,
    'postedTotal', CASE WHEN _is_owner THEN (SELECT COALESCE(sum(amount), 0) FROM posted) END,
    'postedInvoices', CASE WHEN _is_owner THEN COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'invoiceId', listed.invoice_id,
        'sourceFileId', listed.source_file_id,
        'vendorName', listed.vendor_name,
        'invoiceNumber', listed.document_number,
        'spendDate', listed.spend_date,
        'amount', listed.amount
      ) ORDER BY listed.spend_date DESC, listed.invoice_id DESC)
      FROM listed_posted listed
    ), '[]'::jsonb) END,
    'listLimit', 50
  ) INTO _result;

  RETURN _result;
END;
$$;

-- ---------------------------------------------------------------------------------------
-- Price Intelligence: NULL currency is legacy USD (Phase 7E). Otherwise unchanged.
-- ---------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_price_intelligence_overview(_organization_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _result jsonb;
BEGIN
  IF _organization_id IS NULL THEN
    RAISE EXCEPTION 'organization_id is required' USING ERRCODE = '22004';
  END IF;
  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;

  WITH valid AS MATERIALIZED (
    SELECT
      history.id,
      history.product_id,
      history.vendor_id,
      history.invoice_id,
      history.purchase_date,
      history.created_at,
      history.quantity,
      history.unit_of_measure,
      history.package_size,
      NULLIF(lower(regexp_replace(btrim(history.unit_of_measure), '\s+', ' ', 'g')), '')
        AS uom_key,
      NULLIF(lower(regexp_replace(btrim(history.package_size), '\s+', ' ', 'g')), '')
        AS package_key,
      COALESCE(
        history.unit_price,
        history.extended_price / NULLIF(history.quantity, 0)
      )::numeric AS price,
      invoice.invoice_number,
      vendor.name AS vendor_name
    FROM public.inventory_price_history history
    JOIN public.invoices invoice
      ON invoice.id = history.invoice_id
     AND invoice.organization_id = history.organization_id
     AND invoice.posted_at IS NOT NULL
    JOIN public.vendors vendor
      ON vendor.id = history.vendor_id
     AND vendor.organization_id = history.organization_id
    WHERE history.organization_id = _organization_id
      -- Phase 7E: no currency recorded is legacy USD; explicit non-USD stays excluded.
      AND public.financial_currency_basis(invoice.currency_code) <> 'other'
      AND COALESCE(history.unit_price, history.extended_price / NULLIF(history.quantity, 0))
        IS NOT NULL
  ),
  sequenced AS MATERIALIZED (
    SELECT
      valid.*,
      row_number() OVER (
        PARTITION BY product_id
        ORDER BY purchase_date DESC, created_at DESC, id DESC
      ) AS product_position,
      row_number() OVER (
        PARTITION BY product_id, vendor_id, uom_key, package_key
        ORDER BY purchase_date DESC, created_at DESC, id DESC
      ) AS unit_position,
      lag(price) OVER unit_history AS previous_price,
      lag(purchase_date) OVER unit_history AS previous_date,
      lag(invoice_id) OVER unit_history AS previous_invoice_id,
      lag(invoice_number) OVER unit_history AS previous_invoice_number,
      avg(price) OVER unit_window AS window_average,
      count(*) OVER unit_window AS window_count
    FROM valid
    WINDOW
      unit_history AS (
        PARTITION BY product_id, vendor_id, uom_key, package_key
        ORDER BY purchase_date, created_at, id
      ),
      unit_window AS (
        PARTITION BY product_id, vendor_id, uom_key, package_key
        ORDER BY purchase_date
        RANGE BETWEEN interval '89 days' PRECEDING AND CURRENT ROW
      )
  ),
  current_rows AS (
    SELECT * FROM sequenced WHERE product_position = 1
  ),
  bounded AS (
    SELECT * FROM current_rows
    ORDER BY purchase_date DESC, created_at DESC, id DESC
    LIMIT 500
  ),
  alternatives AS (
    SELECT DISTINCT ON (current_row.product_id)
      current_row.product_id,
      other.vendor_id,
      other.vendor_name,
      other.price,
      other.purchase_date,
      other.invoice_id,
      other.invoice_number,
      other.unit_of_measure,
      other.package_size,
      count(*) OVER (PARTITION BY current_row.product_id) AS comparable_vendor_count
    FROM bounded current_row
    JOIN sequenced other
      ON other.product_id = current_row.product_id
     AND other.vendor_id <> current_row.vendor_id
     AND other.unit_position = 1
     -- "=" never matches NULL, so an unrecorded unit or package has no alternative.
     AND other.uom_key = current_row.uom_key
     AND other.package_key = current_row.package_key
    ORDER BY current_row.product_id, other.price, other.purchase_date DESC, other.vendor_id
  )
  SELECT jsonb_build_object(
    'organizationId', _organization_id,
    'currencyCode', 'USD',
    'averageWindowDays', 90,
    'productLimit', 500,
    'productCount', (SELECT count(*) FROM current_rows),
    'rows', COALESCE(jsonb_agg(jsonb_build_object(
      'productId', cur.product_id,
      'productName', product.name,
      'comparability', CASE WHEN cur.uom_key IS NULL THEN 'missing_unit_of_measure' ELSE 'comparable' END,
      'current', jsonb_build_object(
        'observationId', cur.id,
        'vendorId', cur.vendor_id,
        'vendorName', cur.vendor_name,
        'price', cur.price,
        'purchaseDate', cur.purchase_date,
        'quantity', cur.quantity,
        'unitOfMeasure', cur.unit_of_measure,
        'packageSize', cur.package_size,
        'invoiceId', cur.invoice_id,
        'invoiceNumber', cur.invoice_number
      ),
      'previous', CASE WHEN cur.uom_key IS NOT NULL AND cur.previous_price IS NOT NULL THEN
        jsonb_build_object(
          'price', cur.previous_price,
          'purchaseDate', cur.previous_date,
          'invoiceId', cur.previous_invoice_id,
          'invoiceNumber', cur.previous_invoice_number
        ) END,
      'absoluteChange', CASE WHEN cur.uom_key IS NOT NULL AND cur.previous_price IS NOT NULL
        THEN cur.price - cur.previous_price END,
      'percentChange', CASE WHEN cur.uom_key IS NOT NULL AND cur.previous_price > 0
        THEN ((cur.price - cur.previous_price) / cur.previous_price) * 100 END,
      'recentAverage', CASE WHEN cur.uom_key IS NOT NULL THEN jsonb_build_object(
          'average', cur.window_average,
          'observationCount', cur.window_count,
          'windowStart', cur.purchase_date - 89,
          'windowEnd', cur.purchase_date
        ) END,
      'bestAlternative', CASE WHEN alternative.product_id IS NOT NULL THEN jsonb_build_object(
          'vendorId', alternative.vendor_id,
          'vendorName', alternative.vendor_name,
          'price', alternative.price,
          'purchaseDate', alternative.purchase_date,
          'invoiceId', alternative.invoice_id,
          'invoiceNumber', alternative.invoice_number,
          'unitOfMeasure', alternative.unit_of_measure,
          'packageSize', alternative.package_size,
          'comparableVendorCount', alternative.comparable_vendor_count
        ) END,
      'unitSavings', CASE WHEN alternative.price < cur.price
        THEN cur.price - alternative.price END
    ) ORDER BY cur.purchase_date DESC, cur.created_at DESC, cur.id DESC), '[]'::jsonb)
  ) INTO _result
  FROM bounded cur
  JOIN public.products product
    ON product.id = cur.product_id
   AND product.organization_id = _organization_id
  LEFT JOIN alternatives alternative ON alternative.product_id = cur.product_id;

  RETURN _result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_price_intelligence_overview(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_price_intelligence_overview(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_product_price_intelligence(
  _organization_id uuid,
  _product_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _product public.products%ROWTYPE;
  _result jsonb;
BEGIN
  IF _organization_id IS NULL OR _product_id IS NULL THEN
    RAISE EXCEPTION 'organization_id and product_id are required' USING ERRCODE = '22004';
  END IF;

  IF NOT COALESCE(public.is_org_admin(_organization_id, auth.uid()), false) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO _product
  FROM public.products product
  WHERE product.id = _product_id
    AND product.organization_id = _organization_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found' USING ERRCODE = 'P0002';
  END IF;

  WITH posted AS MATERIALIZED (
    SELECT
      history.id,
      history.organization_id,
      history.product_id,
      history.vendor_id,
      history.vendor_product_id,
      history.invoice_id,
      history.invoice_item_id,
      history.purchase_date,
      history.quantity,
      history.package_size,
      history.unit_of_measure,
      COALESCE(
        history.unit_price,
        history.extended_price / NULLIF(history.quantity, 0)
      )::numeric AS purchase_price,
      history.extended_price,
      history.created_at,
      invoice.invoice_number,
      invoice.currency_code,
      invoice.posted_at,
      vendor.name AS vendor_name,
      vendor_product.vendor_sku
    FROM public.inventory_price_history history
    JOIN public.invoices invoice
      ON invoice.id = history.invoice_id
     AND invoice.organization_id = history.organization_id
     AND invoice.posted_at IS NOT NULL
    JOIN public.vendors vendor
      ON vendor.id = history.vendor_id
     AND vendor.organization_id = history.organization_id
    LEFT JOIN public.vendor_products vendor_product
      ON vendor_product.id = history.vendor_product_id
     AND vendor_product.organization_id = history.organization_id
     AND vendor_product.product_id = history.product_id
    WHERE history.organization_id = _organization_id
      AND history.product_id = _product_id
  ),
  valid AS MATERIALIZED (
    SELECT
      posted.*,
      row_number() OVER (
        ORDER BY purchase_date DESC, created_at DESC, id DESC
      ) AS product_position,
      row_number() OVER (
        PARTITION BY vendor_id
        ORDER BY purchase_date DESC, created_at DESC, id DESC
      ) AS vendor_position
    FROM posted
    WHERE public.financial_currency_basis(currency_code) <> 'other'
      AND purchase_price IS NOT NULL
      AND purchase_price >= 0
  ),
  summary AS (
    SELECT
      count(*)::integer AS observation_count,
      min(purchase_price) AS historical_low,
      max(purchase_price) AS historical_high,
      max(purchase_price) FILTER (WHERE product_position = 1) AS latest_price,
      max(purchase_date) FILTER (WHERE product_position = 1) AS latest_price_date,
      max(purchase_price) FILTER (WHERE product_position = 2) AS previous_price
    FROM valid
  ),
  coverage AS (
    SELECT
      count(*)::integer AS posted_observation_count,
      count(*) FILTER (WHERE public.financial_currency_basis(currency_code) = 'other')::integer
        AS non_usd_count,
      count(*) FILTER (WHERE public.financial_currency_basis(currency_code) <> 'other' AND purchase_price IS NULL)::integer
        AS missing_price_count
    FROM posted
  ),
  recent AS (
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'observationId', observation.id,
        'purchaseDate', observation.purchase_date,
        'vendorId', observation.vendor_id,
        'vendorName', observation.vendor_name,
        'vendorProductId', observation.vendor_product_id,
        'vendorSku', observation.vendor_sku,
        'purchasePrice', observation.purchase_price,
        'currencyCode', 'USD',
        'quantity', observation.quantity,
        'packageDescription', observation.package_size,
        'unitOfMeasure', observation.unit_of_measure,
        'packageEvidenceStatus', 'unverified',
        'invoiceId', observation.invoice_id,
        'invoiceItemId', observation.invoice_item_id,
        'invoiceNumber', observation.invoice_number,
        'postedAt', observation.posted_at,
        'provenanceType', 'posted_invoice_purchase_history'
      ) ORDER BY observation.purchase_date DESC, observation.created_at DESC, observation.id DESC
    ), '[]'::jsonb) AS value
    FROM (
      SELECT * FROM valid
      ORDER BY purchase_date DESC, created_at DESC, id DESC
      LIMIT 20
    ) observation
  ),
  vendor_rollup AS (
    SELECT
      vendor_id,
      max(vendor_name) AS vendor_name,
      count(*)::integer AS observation_count,
      max(purchase_price) FILTER (WHERE vendor_position = 1) AS latest_price,
      max(purchase_date) FILTER (WHERE vendor_position = 1) AS latest_price_date,
      max(purchase_price) FILTER (WHERE vendor_position = 2) AS previous_price,
      min(purchase_price) AS historical_low,
      max(purchase_price) AS historical_high
    FROM valid
    GROUP BY vendor_id
  ),
  vendor_history AS (
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'vendorId', vendor_row.vendor_id,
        'vendorName', vendor_row.vendor_name,
        'latestPrice', vendor_row.latest_price,
        'latestPriceDate', vendor_row.latest_price_date,
        'previousPrice', vendor_row.previous_price,
        'historicalLow', vendor_row.historical_low,
        'historicalHigh', vendor_row.historical_high,
        'observationCount', vendor_row.observation_count
      ) ORDER BY vendor_row.latest_price_date DESC, vendor_row.vendor_id
    ), '[]'::jsonb) AS value
    FROM (
      SELECT * FROM vendor_rollup
      ORDER BY latest_price_date DESC, vendor_id
      LIMIT 12
    ) vendor_row
  )
  SELECT jsonb_build_object(
    'organizationId', _organization_id,
    'productId', _product_id,
    'productName', _product.name,
    'currencyCode', 'USD',
    'summary', jsonb_build_object(
      'latestPrice', summary.latest_price,
      'latestPriceDate', summary.latest_price_date,
      'previousPrice', summary.previous_price,
      'absoluteChange', CASE
        WHEN summary.latest_price IS NULL OR summary.previous_price IS NULL THEN NULL
        ELSE summary.latest_price - summary.previous_price
      END,
      'percentChange', CASE
        WHEN summary.latest_price IS NULL OR summary.previous_price IS NULL
          OR summary.previous_price = 0 THEN NULL
        ELSE ((summary.latest_price - summary.previous_price) / summary.previous_price) * 100
      END,
      'historicalLow', summary.historical_low,
      'historicalHigh', summary.historical_high,
      'observationCount', summary.observation_count
    ),
    'recentPurchases', recent.value,
    'vendorHistory', vendor_history.value,
    'packageComparability', jsonb_build_object(
      'status', 'not_verified',
      'normalizedUnitEconomicsAvailable', false,
      'reason', 'Historical purchases do not snapshot verified package quantity and unit metadata.'
    ),
    'coverage', jsonb_build_object(
      'postedObservationCount', coverage.posted_observation_count,
      'includedUsdObservationCount', summary.observation_count,
      -- Phase 7E: no currency recorded is included as legacy USD, so nothing is excluded for it.
      -- (Same keys as before: the deployed app parses this object strictly.)
      'excludedUnknownCurrencyCount', 0,
      'excludedNonUsdCount', coverage.non_usd_count,
      'excludedMissingPriceCount', coverage.missing_price_count
    ),
    'historyLimit', 20,
    'vendorLimit', 12
  ) INTO _result
  FROM summary
  CROSS JOIN coverage
  CROSS JOIN recent
  CROSS JOIN vendor_history;

  RETURN _result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_product_price_intelligence(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_price_intelligence(uuid, uuid)
  TO authenticated;

COMMIT;
