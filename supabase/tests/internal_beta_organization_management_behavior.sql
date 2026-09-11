-- Run against a disposable database with all migrations applied. Always rolls back.
BEGIN;
CREATE TEMP TABLE management_checks (name text);
GRANT ALL ON management_checks TO authenticated, anon;
CREATE FUNCTION pg_temp.fixture_id(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('61000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;
CREATE FUNCTION pg_temp.check_result(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Failed: %', label; END IF;
  INSERT INTO management_checks VALUES (label);
END;
$$;
CREATE FUNCTION pg_temp.expect_error(statement text, expected_state text, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE statement;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> expected_state THEN RAISE; END IF;
    INSERT INTO management_checks VALUES (label);
    RETURN;
  END;
  RAISE EXCEPTION 'Unexpected success: %', label;
END;
$$;

INSERT INTO auth.users(id, email, raw_user_meta_data)
SELECT pg_temp.fixture_id(n), 'management-' || n || '@example.test', jsonb_build_object('full_name', 'Management User ' || n)
FROM generate_series(1, 7) n;
INSERT INTO public.organizations(id, name) VALUES
  (pg_temp.fixture_id(11), 'Management test'), (pg_temp.fixture_id(12), 'Other organization');
INSERT INTO public.teams(id, organization_id, name) VALUES
  (pg_temp.fixture_id(21), pg_temp.fixture_id(11), 'Original team'),
  (pg_temp.fixture_id(22), pg_temp.fixture_id(12), 'Other team');
INSERT INTO public.locations(id, organization_id, name) VALUES
  (pg_temp.fixture_id(31), pg_temp.fixture_id(11), 'Original location'),
  (pg_temp.fixture_id(32), pg_temp.fixture_id(12), 'Other location');
INSERT INTO public.organization_memberships(id, organization_id, user_id, role, active, default_team_id, default_location_id) VALUES
  (pg_temp.fixture_id(101), pg_temp.fixture_id(11), pg_temp.fixture_id(1), 'owner', true, NULL, NULL),
  (pg_temp.fixture_id(102), pg_temp.fixture_id(11), pg_temp.fixture_id(2), 'admin', true, NULL, NULL),
  (pg_temp.fixture_id(103), pg_temp.fixture_id(11), pg_temp.fixture_id(3), 'staff', true, pg_temp.fixture_id(21), pg_temp.fixture_id(31)),
  (pg_temp.fixture_id(104), pg_temp.fixture_id(12), pg_temp.fixture_id(4), 'owner', true, NULL, NULL),
  (pg_temp.fixture_id(105), pg_temp.fixture_id(11), pg_temp.fixture_id(5), 'staff', true, NULL, NULL),
  (pg_temp.fixture_id(106), pg_temp.fixture_id(11), pg_temp.fixture_id(6), 'admin', false, NULL, NULL);
INSERT INTO public.organization_invites(id, organization_id, invited_email, invited_role, token_hash, default_team_id, default_location_id, expires_at)
VALUES (pg_temp.fixture_id(201), pg_temp.fixture_id(11), 'management-3@example.test', 'staff', encode(extensions.digest('management-old-invite-token', 'sha256'), 'hex'), pg_temp.fixture_id(21), pg_temp.fixture_id(31), now() + interval '1 day');
INSERT INTO public.supply_requests(id, organization_id, requested_by, request_type, free_text_item, quantity, team_id, location_id)
VALUES (pg_temp.fixture_id(301), pg_temp.fixture_id(11), pg_temp.fixture_id(3), 'new_item', 'Historical supply', 1, pg_temp.fixture_id(21), pg_temp.fixture_id(31));
INSERT INTO public.supply_request_items(id, organization_id, supply_request_id, free_text_item, quantity)
VALUES (pg_temp.fixture_id(302), pg_temp.fixture_id(11), pg_temp.fixture_id(301), 'Historical supply', 1);
INSERT INTO public.supply_request_updates(id, organization_id, supply_request_id, author_id, staff_visible_note)
VALUES (pg_temp.fixture_id(303), pg_temp.fixture_id(11), pg_temp.fixture_id(301), pg_temp.fixture_id(3), 'Original attribution');
INSERT INTO public.invoices(id, organization_id, invoice_number, invoice_total, posted_at, processing_status)
VALUES (pg_temp.fixture_id(401), pg_temp.fixture_id(11), 'HISTORICAL', 125, now(), 'completed');
INSERT INTO public.organization_budgets(id, organization_id, name, period_start, period_end, amount)
VALUES (pg_temp.fixture_id(501), pg_temp.fixture_id(11), 'Budget', '2026-01-01', '2026-12-31', 1000);
CREATE TEMP TABLE historical_snapshot AS
SELECT 'request' AS kind, to_jsonb(r) AS value FROM public.supply_requests r WHERE id = pg_temp.fixture_id(301)
UNION ALL SELECT 'items', to_jsonb(r) FROM public.supply_request_items r WHERE id = pg_temp.fixture_id(302)
UNION ALL SELECT 'audit', to_jsonb(r) FROM public.supply_request_updates r WHERE id = pg_temp.fixture_id(303)
UNION ALL SELECT 'invoice', to_jsonb(r) FROM public.invoices r WHERE id = pg_temp.fixture_id(401)
UNION ALL SELECT 'budget', to_jsonb(r) FROM public.organization_budgets r WHERE id = pg_temp.fixture_id(501);
GRANT SELECT ON historical_snapshot TO authenticated;

SET LOCAL ROLE anon;
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(103), '{"active":false}')$q$, '42501', 'anonymous mutation denied');
RESET ROLE;
SET LOCAL ROLE authenticated;

-- Staff, a foreign owner, an inactive admin, and a nonmember cannot manage this org.
DO $$
DECLARE actor integer;
BEGIN
  FOREACH actor IN ARRAY ARRAY[3,4,6,7] LOOP
    PERFORM set_config('request.jwt.claim.sub', pg_temp.fixture_id(actor)::text, true);
    PERFORM pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(103), '{"role":"admin"}')$q$, '42501', 'unauthorized member edit denied: ' || actor);
    PERFORM pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(103), '{"active":false}')$q$, '42501', 'unauthorized member deactivation denied: ' || actor);
    UPDATE public.teams SET name = 'Forbidden', active = false WHERE id = pg_temp.fixture_id(21);
    PERFORM pg_temp.check_result(NOT FOUND, 'unauthorized team edit/archive denied: ' || actor);
    UPDATE public.locations SET name = 'Forbidden', active = false WHERE id = pg_temp.fixture_id(31);
    PERFORM pg_temp.check_result(NOT FOUND, 'unauthorized location edit/archive denied: ' || actor);
    PERFORM pg_temp.check_result(NOT EXISTS(SELECT 1 FROM public.list_organization_member_identities(pg_temp.fixture_id(11))), 'identity read denied: ' || actor);
  END LOOP;
END;
$$;
SELECT set_config('request.jwt.claim.sub', pg_temp.fixture_id(2)::text, true);
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(104), '{"active":false}')$q$, '22023', 'foreign membership id rejected');
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(101), '{"active":false}')$q$, '42501', 'admin cannot deactivate owner');
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(103), '{"role":"owner"}')$q$, '42501', 'admin cannot grant ownership');
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(102), '{"active":false}')$q$, '22023', 'admin cannot deactivate self');
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(102), '{"role":"staff"}')$q$, '22023', 'admin cannot demote self');
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(103), '{"default_team_id":"61000000-0000-4000-8000-000000000022"}')$q$, '22023', 'foreign team default rejected');
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(103), '{"default_location_id":"61000000-0000-4000-8000-000000000032"}')$q$, '22023', 'foreign location default rejected');
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(103), '{"user_id":null}')$q$, '22023', 'unsupported identity mutation rejected');
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(103), '{"role":null}')$q$, '22023', 'null role rejected');
SELECT pg_temp.expect_error($q$UPDATE public.teams SET organization_id = pg_temp.fixture_id(12) WHERE id = pg_temp.fixture_id(21)$q$, '42501', 'structure cannot move organization');

SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(105), jsonb_build_object('role', 'admin', 'default_team_id', pg_temp.fixture_id(21), 'default_location_id', pg_temp.fixture_id(31)));
SELECT pg_temp.check_result((SELECT role = 'admin' AND default_team_id = pg_temp.fixture_id(21) AND default_location_id = pg_temp.fixture_id(31) FROM public.organization_memberships WHERE id = pg_temp.fixture_id(105)), 'admin edits role and defaults');
SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(103), '{"active":false}');
SELECT pg_temp.check_result((SELECT NOT active FROM public.organization_memberships WHERE id = pg_temp.fixture_id(103)), 'admin deactivates membership without deletion');
SELECT pg_temp.check_result((SELECT revoked_at IS NOT NULL FROM public.organization_invites WHERE id = pg_temp.fixture_id(201)), 'deactivation revokes pending invitation');
SELECT pg_temp.check_result((SELECT display_name = 'Management User 3' FROM public.list_organization_member_identities(pg_temp.fixture_id(11)) WHERE user_id = pg_temp.fixture_id(3)), 'inactive historical identity still displayable');
SELECT set_config('request.jwt.claim.sub', pg_temp.fixture_id(3)::text, true);
SELECT pg_temp.check_result(NOT public.is_org_member(pg_temp.fixture_id(11), auth.uid()), 'deactivated member loses organization access');
SELECT pg_temp.check_result(NOT EXISTS(SELECT 1 FROM public.supply_requests WHERE id = pg_temp.fixture_id(301)), 'deactivated member cannot read old request directly');
SELECT pg_temp.check_result(NOT EXISTS(SELECT 1 FROM public.supply_request_items WHERE id = pg_temp.fixture_id(302)), 'deactivated member cannot read old request items directly');
SELECT pg_temp.check_result(NOT EXISTS(SELECT 1 FROM public.supply_request_updates WHERE id = pg_temp.fixture_id(303)), 'deactivated member cannot read old request updates directly');
SELECT pg_temp.expect_error($q$SELECT public.accept_invitation('management-old-invite-token')$q$, 'P0001', 'old invitation cannot undo deactivation');

SELECT set_config('request.jwt.claim.sub', pg_temp.fixture_id(1)::text, true);
SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(103), '{"active":true}');
SELECT pg_temp.check_result(public.is_org_member(pg_temp.fixture_id(11), pg_temp.fixture_id(3)), 'owner reactivates preserved membership');
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(101), '{"active":false}')$q$, '22023', 'last owner deactivation rejected');
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(101), '{"role":"admin"}')$q$, '22023', 'last owner demotion rejected');
SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(105), '{"role":"owner"}');
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(101), '{"active":false}')$q$, '22023', 'self deactivation rejected even with another owner');
SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(105), '{"active":false}');
SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(105), '{"active":true}');
SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(105), '{"role":"staff"}');
SELECT pg_temp.check_result((SELECT role = 'staff' AND active FROM public.organization_memberships WHERE id = pg_temp.fixture_id(105)), 'owner may deactivate reactivate and demote another owner safely');

-- The trigger also prevents lockout through legacy security-definer upserts/deletes.
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT pg_temp.expect_error($q$DELETE FROM public.organization_memberships WHERE id = pg_temp.fixture_id(101)$q$, '22023', 'last owner deletion blocked at database trigger');
SELECT pg_temp.expect_error($q$UPDATE public.organization_memberships SET role = 'staff' WHERE id = pg_temp.fixture_id(101)$q$, '22023', 'last owner demotion blocked outside RPC');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', pg_temp.fixture_id(2)::text, true);
UPDATE public.teams SET name = 'Renamed team' WHERE id = pg_temp.fixture_id(21);
UPDATE public.locations SET name = 'Renamed location' WHERE id = pg_temp.fixture_id(31);
UPDATE public.teams SET active = false WHERE id = pg_temp.fixture_id(21);
UPDATE public.locations SET active = false WHERE id = pg_temp.fixture_id(31);
SELECT pg_temp.check_result(NOT EXISTS(SELECT 1 FROM public.teams WHERE organization_id = pg_temp.fixture_id(11) AND active), 'archived teams excluded from active selection');
SELECT pg_temp.check_result(NOT EXISTS(SELECT 1 FROM public.locations WHERE organization_id = pg_temp.fixture_id(11) AND active), 'archived locations excluded from active selection');
SELECT pg_temp.check_result((SELECT t.name = 'Renamed team' AND l.name = 'Renamed location' FROM public.supply_requests r JOIN public.teams t ON t.id = r.team_id JOIN public.locations l ON l.id = r.location_id WHERE r.id = pg_temp.fixture_id(301)), 'historical request still joins archived team and location');
SELECT pg_temp.check_result(NOT EXISTS(SELECT 1 FROM public.organization_memberships WHERE organization_id = pg_temp.fixture_id(11) AND (default_team_id IS NOT NULL OR default_location_id IS NOT NULL)), 'archive clears only workflow membership defaults');
SELECT pg_temp.check_result((SELECT default_team_id IS NULL AND default_location_id IS NULL FROM public.organization_invites WHERE id = pg_temp.fixture_id(201)), 'archive clears invitation defaults');
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(103), '{"default_team_id":"61000000-0000-4000-8000-000000000021"}')$q$, '22023', 'new archived team default rejected');
SELECT pg_temp.expect_error($q$SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(103), '{"default_location_id":"61000000-0000-4000-8000-000000000031"}')$q$, '22023', 'new archived location default rejected');
SELECT pg_temp.expect_error($q$DELETE FROM public.teams WHERE id = pg_temp.fixture_id(21)$q$, '42501', 'team hard delete denied');
SELECT pg_temp.expect_error($q$DELETE FROM public.locations WHERE id = pg_temp.fixture_id(31)$q$, '42501', 'location hard delete denied');
SELECT pg_temp.expect_error($q$DELETE FROM public.organization_memberships WHERE id = pg_temp.fixture_id(103)$q$, '42501', 'member hard delete denied');
SELECT set_config('request.jwt.claim.sub', pg_temp.fixture_id(3)::text, true);
SELECT pg_temp.check_result(NOT EXISTS(SELECT 1 FROM public.teams WHERE id = pg_temp.fixture_id(21)), 'active staff cannot select archived team');
SELECT pg_temp.check_result(NOT EXISTS(SELECT 1 FROM public.locations WHERE id = pg_temp.fixture_id(31)), 'active staff cannot select archived location');
SELECT pg_temp.check_result(EXISTS(SELECT 1 FROM public.supply_requests WHERE id = pg_temp.fixture_id(301)), 'active staff historical request access preserved');
SELECT set_config('request.jwt.claim.sub', pg_temp.fixture_id(1)::text, true);
UPDATE public.teams SET active = true WHERE id = pg_temp.fixture_id(21);
UPDATE public.locations SET active = true WHERE id = pg_temp.fixture_id(31);
SELECT pg_temp.check_result((SELECT active FROM public.teams WHERE id = pg_temp.fixture_id(21)) AND (SELECT active FROM public.locations WHERE id = pg_temp.fixture_id(31)), 'owner reactivates structure');
SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(103), jsonb_build_object('default_team_id', pg_temp.fixture_id(21), 'default_location_id', pg_temp.fixture_id(31)));
SELECT public.update_organization_member(pg_temp.fixture_id(11), pg_temp.fixture_id(103), '{"default_team_id":null,"default_location_id":null}');
SELECT pg_temp.check_result((SELECT default_team_id IS NULL AND default_location_id IS NULL FROM public.organization_memberships WHERE id = pg_temp.fixture_id(103)), 'member defaults may be cleared explicitly');

SELECT pg_temp.check_result((SELECT value FROM historical_snapshot WHERE kind = 'request') = (SELECT to_jsonb(r) FROM public.supply_requests r WHERE id = pg_temp.fixture_id(301)), 'request row and lifecycle unchanged');
SELECT pg_temp.check_result((SELECT value FROM historical_snapshot WHERE kind = 'items') = (SELECT to_jsonb(r) FROM public.supply_request_items r WHERE id = pg_temp.fixture_id(302)), 'request lines unchanged');
SELECT pg_temp.check_result((SELECT value FROM historical_snapshot WHERE kind = 'audit') = (SELECT to_jsonb(r) FROM public.supply_request_updates r WHERE id = pg_temp.fixture_id(303)), 'audit row and attribution unchanged');
SELECT pg_temp.check_result((SELECT value FROM historical_snapshot WHERE kind = 'invoice') = (SELECT to_jsonb(r) FROM public.invoices r WHERE id = pg_temp.fixture_id(401)), 'posted invoice unchanged');
SELECT pg_temp.check_result((SELECT value FROM historical_snapshot WHERE kind = 'budget') = (SELECT to_jsonb(r) FROM public.organization_budgets r WHERE id = pg_temp.fixture_id(501)), 'budget unchanged');
RESET ROLE;
SELECT pg_temp.check_result((SELECT name = 'Other team' AND active FROM public.teams WHERE id = pg_temp.fixture_id(22)) AND (SELECT name = 'Other location' AND active FROM public.locations WHERE id = pg_temp.fixture_id(32)), 'other organization unchanged');
SELECT count(*) AS checks_passed, 0 AS checks_failed FROM management_checks;
SELECT name AS passed_check FROM management_checks ORDER BY name;
ROLLBACK;
