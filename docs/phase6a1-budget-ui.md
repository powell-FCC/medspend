# Phase 6A.1 budget UI

Route: `/budget`, inside the existing authenticated admin shell. Budget appears after Dashboard in desktop and mobile navigation for owners and admins.

Owners and admins can access and manage Budget; staff cannot. `/budget` remains an admin route in the authenticated shell. Staff direct visits redirect to `/staff` without mounting the budget page. Each server operation verifies an active owner or admin membership in the requested organization and uses the existing authenticated Supabase client, preserving RLS. Inventory, Upload Invoice, and Invoices remain owner-only navigation items.

The additive migration `20260909120000_phase6a1_budget_admin_access.sql` replaces the budget SELECT, INSERT, and UPDATE policies and summary RPC guard with `public.is_org_admin`. UPDATE checks both the existing and proposed row organization. The RPC retains the exact foundation accounting query and organization/budget scoping. No DELETE permission is added, and the applied foundation migration is unchanged. The new migration is prepared locally only: admin database access requires it to be applied separately; it has not been applied remotely.

The page lists active organization budgets only. Its initial selection prefers a period containing the browser's local calendar date (inclusive). Ties use latest period start, then latest period end, then ascending ID. If no active period contains today, the same ordering selects the latest starting period and the page explicitly states that it does not cover today. Multiple active budgets get a labeled selector with names and full periods. Inactive budgets never appear. Changing organizations resets selection and editor state; query cache keys include organization and budget IDs.

No active budget shows the setup action. Creation has no default name, amount, or dates. Both client and server validate nonnegative finite amounts, real calendar dates, and chronological periods. Editing updates the existing active row using both organization and row ID. Duplicate exact active periods receive a useful save error. Successful saves invalidate scoped list and summary queries and show a toast.

The three metrics and posted invoice count come directly from `get_budget_summary`. The client does not calculate invoice totals or remaining spend. USD uses two decimal places; calendar dates render in UTC to avoid date-only timezone shifts. Negative remaining stays negative and has a restrained overage message. No percentage or progress bar is shown, including for zero budgets.

Tests: `node --test tests/budget.test.ts`. Tests render the real overview components through React server rendering, exercise validation and selection, and mock the Supabase boundary for role enforcement, RPC arguments/error propagation, and scoped updates. Navigation/server middleware wiring also has focused assertions. These are local tests, not a live Supabase RLS or authenticated browser test.
