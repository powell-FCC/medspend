-- Fixture for tests/phase7c0-request-workflow-integration.test.ts. Local disposable database only;
-- this file commits its rows. Run as postgres after every migration.
--
-- Organization 101: 1 owner, 2 admin, 3 staff, 4 staff. Organization 102: 5 owner, 6 staff.
-- No workflow settings rows (both organizations start Detailed); notification sending OFF.
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7c0f0000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated', 'itest-7c0-' || n || '@example.invalid', '', now(), '{}',
  jsonb_build_object('full_name', 'Itest Workflow ' || n), now(), now()
FROM generate_series(1, 6) n;
INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7c0f0000-0000-4000-8000-000000000101', 'Workflow Athletics', '7c0f0000-0000-4000-8000-000000000001'),
  ('7c0f0000-0000-4000-8000-000000000102', 'Workflow West', '7c0f0000-0000-4000-8000-000000000005');
INSERT INTO public.teams (id, organization_id, name, active) VALUES
  ('7c0f0000-0000-4000-8000-000000000201', '7c0f0000-0000-4000-8000-000000000101', 'Football', true),
  ('7c0f0000-0000-4000-8000-000000000202', '7c0f0000-0000-4000-8000-000000000102', 'West Team', true);
INSERT INTO public.locations (id, organization_id, name, active) VALUES
  ('7c0f0000-0000-4000-8000-000000000211', '7c0f0000-0000-4000-8000-000000000101', 'Training Room', true),
  ('7c0f0000-0000-4000-8000-000000000212', '7c0f0000-0000-4000-8000-000000000102', 'West Room', true);
INSERT INTO public.organization_memberships (organization_id, user_id, role, active, default_team_id, default_location_id) VALUES
  ('7c0f0000-0000-4000-8000-000000000101', '7c0f0000-0000-4000-8000-000000000001', 'owner', true, NULL, NULL),
  ('7c0f0000-0000-4000-8000-000000000101', '7c0f0000-0000-4000-8000-000000000002', 'admin', true, NULL, NULL),
  ('7c0f0000-0000-4000-8000-000000000101', '7c0f0000-0000-4000-8000-000000000003', 'staff', true, '7c0f0000-0000-4000-8000-000000000201', '7c0f0000-0000-4000-8000-000000000211'),
  ('7c0f0000-0000-4000-8000-000000000101', '7c0f0000-0000-4000-8000-000000000004', 'staff', true, '7c0f0000-0000-4000-8000-000000000201', '7c0f0000-0000-4000-8000-000000000211'),
  ('7c0f0000-0000-4000-8000-000000000102', '7c0f0000-0000-4000-8000-000000000005', 'owner', true, NULL, NULL),
  ('7c0f0000-0000-4000-8000-000000000102', '7c0f0000-0000-4000-8000-000000000006', 'staff', true, '7c0f0000-0000-4000-8000-000000000202', '7c0f0000-0000-4000-8000-000000000212');
