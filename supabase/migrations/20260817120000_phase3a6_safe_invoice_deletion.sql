-- Phase 3A.6: owner-only hard deletion of uploaded documents.
-- Installing this function does not mutate historical invoices. An explicit owner action is required.

CREATE OR REPLACE FUNCTION public.delete_invoice_permanently(
  _organization_id uuid,
  _source_file_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
  _price_records integer := 0;
  _adjustment_records integer := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_org_role(
    _organization_id, auth.uid(), ARRAY['owner']::public.org_role[]
  ) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
  END IF;

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

      UPDATE public.inventory_items
      SET quantity = _reconstructed_quantity
      WHERE id = _inventory.id AND organization_id = _organization_id;
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
$$;

REVOKE ALL ON FUNCTION public.delete_invoice_permanently(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_invoice_permanently(uuid, uuid) TO authenticated;
