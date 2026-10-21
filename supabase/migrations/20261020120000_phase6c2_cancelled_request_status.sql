-- Phase 6C.2: staff request cancellation, step 1 of 2.
--
-- Adds the 'cancelled' lifecycle status. It is appended to the enum, so no existing
-- value, row, or ordering-dependent comparison changes, and no row is remapped.
--
-- PostgreSQL does not allow a newly added enum value to be used in the transaction that
-- adds it, so this statement is its own migration. Everything that uses 'cancelled'
-- (the cancellation RPC, the audit constraint) is in
-- 20261020120100_phase6c2_staff_request_cancellation.sql, which runs after this commits.

ALTER TYPE public.supply_request_status ADD VALUE IF NOT EXISTS 'cancelled';
