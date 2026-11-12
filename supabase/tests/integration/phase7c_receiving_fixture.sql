-- Fixture for tests/phase7c-receiving-destination-integration.test.ts. Local disposable database
-- only; this file commits its rows. Run as postgres after every migration.
--
-- Organization 101 (Lean): 1 owner, 2 admin, 3 staff, 4 staff; inventory locations First Team ATR
-- and Academy ATR (active), Old Cage (archived), plus the protected Unassigned holding 12 rolls of
-- tape. Organization 102: 5 owner, its own West Room. Notification sending ON for 101.
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7c2f0000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated', 'itest-7c-' || n || '@example.invalid', '', now(), '{}',
  jsonb_build_object('full_name', 'Itest Receiving ' || n), now(), now()
FROM generate_series(1, 5) n;
INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7c2f0000-0000-4000-8000-000000000101', 'Receiving Athletics', '7c2f0000-0000-4000-8000-000000000001'),
  ('7c2f0000-0000-4000-8000-000000000102', 'Receiving West', '7c2f0000-0000-4000-8000-000000000005');
INSERT INTO public.teams (id, organization_id, name, active) VALUES
  ('7c2f0000-0000-4000-8000-000000000201', '7c2f0000-0000-4000-8000-000000000101', 'First Team', true);
INSERT INTO public.locations (id, organization_id, name, active) VALUES
  ('7c2f0000-0000-4000-8000-000000000211', '7c2f0000-0000-4000-8000-000000000101', 'First Team ATR', true);
INSERT INTO public.organization_memberships (organization_id, user_id, role, active, default_team_id, default_location_id) VALUES
  ('7c2f0000-0000-4000-8000-000000000101', '7c2f0000-0000-4000-8000-000000000001', 'owner', true, NULL, NULL),
  ('7c2f0000-0000-4000-8000-000000000101', '7c2f0000-0000-4000-8000-000000000002', 'admin', true, NULL, NULL),
  ('7c2f0000-0000-4000-8000-000000000101', '7c2f0000-0000-4000-8000-000000000003', 'staff', true, '7c2f0000-0000-4000-8000-000000000201', '7c2f0000-0000-4000-8000-000000000211'),
  ('7c2f0000-0000-4000-8000-000000000101', '7c2f0000-0000-4000-8000-000000000004', 'staff', true, '7c2f0000-0000-4000-8000-000000000201', '7c2f0000-0000-4000-8000-000000000211'),
  ('7c2f0000-0000-4000-8000-000000000102', '7c2f0000-0000-4000-8000-000000000005', 'owner', true, NULL, NULL);
INSERT INTO public.inventory_locations (id, organization_id, name, kind, active) VALUES
  ('7c2f0000-0000-4000-8000-000000000301', '7c2f0000-0000-4000-8000-000000000101', 'First Team ATR', 'storage', true),
  ('7c2f0000-0000-4000-8000-000000000302', '7c2f0000-0000-4000-8000-000000000101', 'Academy ATR', 'storage', true),
  ('7c2f0000-0000-4000-8000-000000000303', '7c2f0000-0000-4000-8000-000000000101', 'Old Cage', 'storage', true),
  ('7c2f0000-0000-4000-8000-000000000304', '7c2f0000-0000-4000-8000-000000000102', 'West Room', 'storage', true);
UPDATE public.inventory_locations SET active = false WHERE id = '7c2f0000-0000-4000-8000-000000000303';
INSERT INTO public.inventory_items (id, organization_id, name, unit, quantity, active)
VALUES ('7c2f0000-0000-4000-8000-000000000401', '7c2f0000-0000-4000-8000-000000000101', 'Receiving Tape', 'roll', 0, true);
SELECT set_config('request.jwt.claim.sub', '7c2f0000-0000-4000-8000-000000000001', false);
SELECT public.adjust_inventory_location_quantity('7c2f0000-0000-4000-8000-000000000101', '7c2f0000-0000-4000-8000-000000000401',
  (SELECT id FROM public.inventory_locations WHERE organization_id = '7c2f0000-0000-4000-8000-000000000101' AND kind = 'unassigned'), 12, 'Correction');
SELECT public.update_organization_request_workflow_settings('7c2f0000-0000-4000-8000-000000000101', 'lean');
SELECT public.set_organization_notification_sending('7c2f0000-0000-4000-8000-000000000101', true);
