-- Phase 3A.2: raw embedded PDF text metadata on the existing one-per-upload job.
ALTER TABLE public.invoice_processing_jobs
  ADD COLUMN document_text_status text NOT NULL DEFAULT 'pending'
    CHECK (document_text_status IN ('pending', 'success', 'ocr_required', 'failed')),
  ADD COLUMN raw_extracted_text text,
  ADD COLUMN document_page_count integer CHECK (document_page_count IS NULL OR document_page_count > 0),
  ADD COLUMN document_processing_duration_ms integer
    CHECK (document_processing_duration_ms IS NULL OR document_processing_duration_ms >= 0),
  ADD COLUMN ocr_required boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.invoice_processing_jobs.raw_extracted_text IS
  'Normalized embedded PDF text scoped by the processing job organization. Not structured invoice data.';
