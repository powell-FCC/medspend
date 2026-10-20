# Phase 6C.2 release checks

Read-only SQL for applying the Phase 6C.2 migrations to production. These scripts do not migrate anything themselves.

## Order

1. `precheck.sql`: save the output as `phase6c2_pre.txt`. Stop if any assertion fails.
2. Apply `supabase/migrations/20261020120000_phase6c2_cancelled_request_status.sql`.
3. Apply `supabase/migrations/20261020120100_phase6c2_staff_request_cancellation.sql`. Its own preflight refuses to run if step 2 has not committed.
4. `postcheck.sql`: save the output as `phase6c2_post.txt`. Stop if any assertion fails.
5. `diff phase6c2_pre.txt phase6c2_post.txt`.
6. Only then merge and deploy the application.

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase6c2/precheck.sql > phase6c2_pre.txt
```

Run each script from the repository root; they include `fingerprint.sql` with `\ir`.

## Expected diff

Besides the `precheck_at` / `postcheck_at` and assertion lines, exactly these fingerprint lines change:

```
enum | supply_request_status | …,denied            ->  …,denied,cancelled
function | cancel_submitted_supply_request | absent ->  f2bcba7dc4c6656a1eb2b69f9ea7c288 secdef=true authenticated=true anon=false
function | update_submitted_supply_request | 44e7e039… ->  6da72bb6… (grants unchanged)
overloads | cancel_submitted_supply_request         (new line: 1)
constraint | supply_request_updates_event_kind_check | c094b8e7… -> 529f020a…
count | public functions | N                        ->  N + 1
```

Everything else must be identical:

- the other lifecycle, budget and staff-projection function hashes;
- table, index, policy, trigger, constraint and enum-type counts;
- policy and trigger definitions on the four request tables;
- request status counts and status hash;
- line counts and line hash;
- audit-row counts and hash;
- commitment counts and hash.

A data line can still differ if users submit, edit or decide requests between the two runs. Run both during a quiet window. If a data line differs, compare the `supply_request_updates` rows created after `precheck_at`.

## Provenance

The expected hashes were taken from a disposable Postgres (`public.ecr.aws/supabase/postgres:17.6.1.167`), migrated from `main` at `5ddfe8a`, with seeded requests, lines, edits, a decision and a commitment. On that database both scripts pass and the pre/post diff is exactly the list above.
