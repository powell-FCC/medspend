-- Phase 6A.1: organization-level budget tracking foundation.
-- Actual spend is derived only from posted invoices.
-- No request commitments, forecasting, team allocation, or purchasing workflows yet.

CREATE TABLE public.organization_budgets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name text NOT NULL,
  period_start date NOT NULL,
  period_end date NOT NULL,
  amount numeric NOT NULL CHECK (amount >= 0),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT organization_budgets_period_check
    CHECK (period_end >= period_start)
);

CREATE INDEX organization_budgets_org_period_idx
  ON public.organization_budgets (organization_id, period_start, period_end);

CREATE UNIQUE INDEX organization_budgets_org_active_period_uq
  ON public.organization_budgets (organization_id, period_start, period_end)
  WHERE active = true;

CREATE TRIGGER organization_budgets_updated_at
  BEFORE UPDATE ON public.organization_budgets
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

ALTER TABLE public.organization_budgets ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE ON public.organization_budgets TO authenticated;
GRANT ALL ON public.organization_budgets TO service_role;

CREATE POLICY organization_budgets_owner_select
  ON public.organization_budgets
  FOR SELECT TO authenticated
  USING (
    public.has_org_role(
      organization_id,
      auth.uid(),
      ARRAY['owner']::public.org_role[]
    )
  );

CREATE POLICY organization_budgets_owner_insert
  ON public.organization_budgets
  FOR INSERT TO authenticated
  WITH CHECK (
    public.has_org_role(
      organization_id,
      auth.uid(),
      ARRAY['owner']::public.org_role[]
    )
  );

CREATE POLICY organization_budgets_owner_update
  ON public.organization_budgets
  FOR UPDATE TO authenticated
  USING (
    public.has_org_role(
      organization_id,
      auth.uid(),
      ARRAY['owner']::public.org_role[]
    )
  )
  WITH CHECK (
    public.has_org_role(
      organization_id,
      auth.uid(),
      ARRAY['owner']::public.org_role[]
    )
  );

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
  IF NOT public.has_org_role(
    _organization_id,
    auth.uid(),
    ARRAY['owner']::public.org_role[]
  ) THEN
    RAISE EXCEPTION 'Forbidden: owner access required';
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
