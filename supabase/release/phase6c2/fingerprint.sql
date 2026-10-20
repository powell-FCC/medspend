-- Phase 6C.2 release fingerprint. Read-only; included by precheck.sql and postcheck.sql.
-- Every row is (section, key, value) so the two outputs can be diffed line by line.

SELECT section, key, value FROM (
  -- Lifecycle enum, in declaration order.
  SELECT 1 AS ord, 'enum' AS section, 'supply_request_status' AS key,
    string_agg(enumlabel, ',' ORDER BY enumsortorder) AS value
  FROM pg_enum WHERE enumtypid = 'public.supply_request_status'::regtype

  -- Request-lifecycle, budget, and staff projection functions: existence and body hash.
  UNION ALL
  SELECT 2, 'function', fn.name,
    coalesce((
      SELECT md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = fn.name
      ORDER BY p.oid LIMIT 1
    ), 'absent')
  FROM (VALUES
    ('apply_supply_request_transition'),
    ('cancel_submitted_supply_request'),
    ('create_supply_request_commitment'),
    ('decide_supply_request'),
    ('get_budget_purchasing_overview'),
    ('get_budget_summary'),
    ('get_supply_request_budget_impact'),
    ('guard_supply_request_lifecycle'),
    ('list_staff_supply_request_updates'),
    ('release_supply_request_commitment'),
    ('replace_supply_request_items'),
    ('resolve_supply_request_context'),
    ('submit_supply_request'),
    ('transition_supply_request'),
    ('update_submitted_supply_request')
  ) AS fn(name)

  -- Overload counts (a recreated function must not leave a second signature behind).
  UNION ALL
  SELECT 3, 'overloads', p.proname, count(*)::text
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname IN (
    'cancel_submitted_supply_request', 'update_submitted_supply_request',
    'list_staff_supply_request_updates', 'decide_supply_request', 'transition_supply_request'
  )
  GROUP BY p.proname

  -- The audit event constraint.
  UNION ALL
  SELECT 4, 'constraint', 'supply_request_updates_event_kind_check',
    coalesce((
      SELECT md5(pg_get_constraintdef(c.oid)) || ' validated=' || c.convalidated
      FROM pg_constraint c
      WHERE c.conrelid = 'public.supply_request_updates'::regclass
        AND c.conname = 'supply_request_updates_event_kind_check'
    ), 'absent')

  -- Schema object counts in public.
  UNION ALL
  SELECT 5, 'count', 'public functions', count(*)::text
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public'
  UNION ALL
  SELECT 5, 'count', 'public tables', count(*)::text
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
  UNION ALL
  SELECT 5, 'count', 'public indexes', count(*)::text
  FROM pg_indexes WHERE schemaname = 'public'
  UNION ALL
  SELECT 5, 'count', 'public policies', count(*)::text
  FROM pg_policies WHERE schemaname = 'public'
  UNION ALL
  SELECT 5, 'count', 'public triggers', count(*)::text
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT t.tgisinternal
  UNION ALL
  SELECT 5, 'count', 'public constraints', count(*)::text
  FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = 'public'
  UNION ALL
  SELECT 5, 'count', 'public enum types', count(*)::text
  FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public' AND t.typtype = 'e'

  -- Policy and trigger fingerprints on the request tables (definitions, not just counts).
  UNION ALL
  SELECT 6, 'policies', tablename,
    md5(string_agg(policyname || ':' || cmd || ':' || coalesce(qual, '') || ':' || coalesce(with_check, ''),
      '|' ORDER BY policyname))
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename IN ('supply_requests', 'supply_request_items', 'supply_request_updates', 'supply_request_commitments')
  GROUP BY tablename
  UNION ALL
  SELECT 6, 'triggers', c.relname,
    md5(string_agg(t.tgname || ':' || pg_get_triggerdef(t.oid), '|' ORDER BY t.tgname))
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT t.tgisinternal
    AND c.relname IN ('supply_requests', 'supply_request_items', 'supply_request_updates', 'supply_request_commitments')
  GROUP BY c.relname

  -- Data: row counts and content hashes. A status hash proves no request changed status;
  -- a line hash proves no line was deleted or rewritten.
  UNION ALL
  SELECT 7, 'rows', 'supply_requests by status',
    coalesce(string_agg(status::text || '=' || n, ',' ORDER BY status), 'none')
  FROM (SELECT status, count(*) AS n FROM public.supply_requests GROUP BY status) s
  UNION ALL
  SELECT 7, 'rows', 'supply_requests status hash',
    coalesce(md5(string_agg(id::text || ':' || status::text, ',' ORDER BY id)), 'empty')
  FROM public.supply_requests
  UNION ALL
  SELECT 7, 'rows', 'supply_request_items count', count(*)::text FROM public.supply_request_items
  UNION ALL
  SELECT 7, 'rows', 'supply_request_items hash',
    coalesce(md5(string_agg(id::text || ':' || supply_request_id::text || ':' || quantity::text, ',' ORDER BY id)), 'empty')
  FROM public.supply_request_items
  UNION ALL
  SELECT 7, 'rows', 'supply_request_updates by event_kind',
    coalesce(string_agg(kind || '=' || n, ',' ORDER BY kind), 'none')
  FROM (SELECT coalesce(event_kind, '(status/note)') AS kind, count(*) AS n
        FROM public.supply_request_updates GROUP BY 1) u
  UNION ALL
  SELECT 7, 'rows', 'supply_request_updates hash',
    coalesce(md5(string_agg(id::text, ',' ORDER BY id)), 'empty')
  FROM public.supply_request_updates
  UNION ALL
  SELECT 7, 'rows', 'supply_request_commitments by status',
    coalesce(string_agg(status || '=' || n, ',' ORDER BY status), 'none')
  FROM (SELECT status::text AS status, count(*) AS n FROM public.supply_request_commitments GROUP BY 1) c
  UNION ALL
  SELECT 7, 'rows', 'supply_request_commitments hash',
    coalesce(md5(string_agg(id::text || ':' || status::text, ',' ORDER BY id)), 'empty')
  FROM public.supply_request_commitments
) fingerprint
ORDER BY ord, section, key;
