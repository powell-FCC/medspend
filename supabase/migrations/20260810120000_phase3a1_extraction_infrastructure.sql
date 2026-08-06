-- Phase 3A.1: provider-neutral extraction state. No network provider or business posting changes.
ALTER TABLE public.invoice_processing_jobs
  ADD COLUMN extraction_result jsonb,
  ADD COLUMN extraction_error text,
  ADD COLUMN ocr_provider text,
  ADD COLUMN extraction_provider text;

COMMENT ON COLUMN public.invoice_processing_jobs.extraction_result IS
  'Canonical provider-neutral extraction. Review data remains editable and authoritative.';

