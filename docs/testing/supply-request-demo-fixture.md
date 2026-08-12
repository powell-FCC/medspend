# Supply request demo fixture

The representative queue fixture lives at `tests/fixtures/supply-request-demo.ts`. It covers Needs Review, Awaiting Order, Awaiting Delivery, Ready for Staff, and Completed with requester, team, location, notes, staff communication, internal context, and representative transition history.

This fixture is intentionally application-independent and does not write to Supabase. Use it in component tests, Storybook-like harnesses, or screenshot tooling. Never import it into production server functions or seed a real organization with it.

For authenticated end-to-end validation, create disposable owner and staff users in an isolated local/test Supabase project, create a disposable organization, then submit and transition requests through the real server functions. Delete the organization after validation. Do not run fixture setup against a production Supabase URL.
