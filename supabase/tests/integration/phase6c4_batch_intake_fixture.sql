-- Fixture for tests/phase6c4-batch-invoice-intake-integration.test.ts. Local disposable
-- database only; this file commits its rows. Run as postgres after every migration.
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('6c4e0000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated', 'itest-6c4-' || n || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM unnest(ARRAY[1, 2, 3, 4]) n;
INSERT INTO public.organizations (id, name, created_by) VALUES
  ('6c4e0000-0000-4000-8000-000000000101', 'Packet Athletics', '6c4e0000-0000-4000-8000-000000000001'),
  ('6c4e0000-0000-4000-8000-000000000102', 'Other Athletics', '6c4e0000-0000-4000-8000-000000000004');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('6c4e0000-0000-4000-8000-000000000101', '6c4e0000-0000-4000-8000-000000000001', 'owner', true),
  ('6c4e0000-0000-4000-8000-000000000101', '6c4e0000-0000-4000-8000-000000000002', 'admin', true),
  ('6c4e0000-0000-4000-8000-000000000101', '6c4e0000-0000-4000-8000-000000000003', 'staff', true),
  ('6c4e0000-0000-4000-8000-000000000102', '6c4e0000-0000-4000-8000-000000000004', 'owner', true);
INSERT INTO public.vendors (id, organization_id, name, normalized_name, active) VALUES
  ('6c4e0000-0000-4000-8000-000000000301', '6c4e0000-0000-4000-8000-000000000101', 'Henry Schein', 'henry schein', true);
