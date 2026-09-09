-- Phase 6A.1: allow organization owners and admins to manage budgets.
-- Preserve the applied foundation and all posted-invoice accounting semantics.

BEGIN;

DROP POLICY organization_budgets_owner_select ON public.organization_budgets;
CREATE POLICY organization_budgets_admin_select
  ON public.organization_budgets
  FOR SELECT TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()));

DROP POLICY organization_budgets_owner_insert ON public.organization_budgets;
CREATE POLICY organization_budgets_admin_insert
  ON public.organization_budgets
  FOR INSERT TO authenticated
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

DROP POLICY organization_budgets_owner_update ON public.organization_budgets;
CREATE POLICY organization_budgets_admin_update
  ON public.organization_budgets
  FOR UPDATE TO authenticated
  USING (public.is_org_admin(organization_id, auth.uid()))
  WITH CHECK (public.is_org_admin(organization_id, auth.uid()));

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
  remaining_amount numeric,
  posted_invoice_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_org_admin(_organization_id, auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden: owner or admin access required';
  END IF;

  RETURN QUERY
  WITH posted_invoices AS (
    SELECT
      invoice.id,
      invoice.organization_id,
      COALESCE(
        invoice.invoice_total,
        invoice.total_amount,
        invoice.total,
        (
          SELECT SUM(item.total_price)
          FROM public.invoice_items item
          WHERE item.invoice_id = invoice.id
            AND item.organization_id = invoice.organization_id
        ),
        0
      )::numeric AS resolved_total,
      COALESCE(invoice.invoice_date, invoice.posted_at::date) AS spend_date
    FROM public.invoices invoice
    WHERE invoice.organization_id = _organization_id
      AND invoice.posted_at IS NOT NULL
  )
  SELECT
    budget.id,
    budget.name,
    budget.period_start,
    budget.period_end,
    budget.amount,
    COALESCE(SUM(invoice.resolved_total), 0)::numeric AS actual_spend,
    (
      budget.amount - COALESCE(SUM(invoice.resolved_total), 0)
    )::numeric AS remaining_amount,
    COUNT(invoice.id)::bigint AS posted_invoice_count
  FROM public.organization_budgets budget
  LEFT JOIN posted_invoices invoice
    ON invoice.organization_id = budget.organization_id
   AND invoice.spend_date BETWEEN budget.period_start AND budget.period_end
  WHERE budget.organization_id = _organization_id
    AND budget.id = _budget_id
  GROUP BY
    budget.id,
    budget.name,
    budget.period_start,
    budget.period_end,
    budget.amount;
END;
$$;

REVOKE ALL ON FUNCTION public.get_budget_summary(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_budget_summary(uuid, uuid) TO authenticated;

COMMIT;
