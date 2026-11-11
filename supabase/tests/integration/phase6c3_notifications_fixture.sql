-- Fixture for tests/phase6c3-request-notifications-integration.test.ts. Local disposable
-- database only; this file commits its rows. Run as postgres after every migration.
--
-- Organization 101 (New York): 1 owner, 2 admin, 3 staff, 4 staff, 5 inactive admin, 6 admin.
-- Organization 102 (Los Angeles): 7 owner, 8 staff.
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('6c3e0000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated', 'itest-6c3-' || n || '@example.invalid', '', now(), '{}',
  jsonb_build_object('full_name', 'Itest User ' || n), now(), now()
FROM generate_series(1, 8) n;
INSERT INTO public.organizations (id, name, created_by) VALUES
  ('6c3e0000-0000-4000-8000-000000000101', 'Notify Athletics', '6c3e0000-0000-4000-8000-000000000001'),
  ('6c3e0000-0000-4000-8000-000000000102', 'Notify West', '6c3e0000-0000-4000-8000-000000000007');
INSERT INTO public.teams (id, organization_id, name, active) VALUES
  ('6c3e0000-0000-4000-8000-000000000201', '6c3e0000-0000-4000-8000-000000000101', 'Football', true),
  ('6c3e0000-0000-4000-8000-000000000202', '6c3e0000-0000-4000-8000-000000000102', 'West Team', true);
INSERT INTO public.locations (id, organization_id, name, active) VALUES
  ('6c3e0000-0000-4000-8000-000000000211', '6c3e0000-0000-4000-8000-000000000101', 'Training Room', true),
  ('6c3e0000-0000-4000-8000-000000000212', '6c3e0000-0000-4000-8000-000000000102', 'West Room', true);
INSERT INTO public.organization_memberships (organization_id, user_id, role, active, default_team_id, default_location_id) VALUES
  ('6c3e0000-0000-4000-8000-000000000101', '6c3e0000-0000-4000-8000-000000000001', 'owner', true, '6c3e0000-0000-4000-8000-000000000201', '6c3e0000-0000-4000-8000-000000000211'),
  ('6c3e0000-0000-4000-8000-000000000101', '6c3e0000-0000-4000-8000-000000000002', 'admin', true, '6c3e0000-0000-4000-8000-000000000201', '6c3e0000-0000-4000-8000-000000000211'),
  ('6c3e0000-0000-4000-8000-000000000101', '6c3e0000-0000-4000-8000-000000000003', 'staff', true, '6c3e0000-0000-4000-8000-000000000201', '6c3e0000-0000-4000-8000-000000000211'),
  ('6c3e0000-0000-4000-8000-000000000101', '6c3e0000-0000-4000-8000-000000000004', 'staff', true, '6c3e0000-0000-4000-8000-000000000201', '6c3e0000-0000-4000-8000-000000000211'),
  ('6c3e0000-0000-4000-8000-000000000101', '6c3e0000-0000-4000-8000-000000000005', 'admin', false, NULL, NULL),
  ('6c3e0000-0000-4000-8000-000000000101', '6c3e0000-0000-4000-8000-000000000006', 'admin', true, NULL, NULL),
  ('6c3e0000-0000-4000-8000-000000000102', '6c3e0000-0000-4000-8000-000000000007', 'owner', true, '6c3e0000-0000-4000-8000-000000000202', '6c3e0000-0000-4000-8000-000000000212'),
  ('6c3e0000-0000-4000-8000-000000000102', '6c3e0000-0000-4000-8000-000000000008', 'staff', true, '6c3e0000-0000-4000-8000-000000000202', '6c3e0000-0000-4000-8000-000000000212');
INSERT INTO public.products (id, organization_id, name, normalized_name, unit_of_measure, active, staff_requestable)
VALUES ('6c3e0000-0000-4000-8000-000000000601', '6c3e0000-0000-4000-8000-000000000101', 'Athletic Tape', 'athletic tape', 'roll', true, true);
