# Cloudflare deployment preparation

MedSpend is a full-stack TanStack Start application. Deploy it as a Cloudflare
Worker with static assets, not as a static-only Pages project. The build already
uses Nitro's `cloudflare-module` preset through
`@lovable.dev/vite-tanstack-config`; `wrangler.jsonc` commits the generated
runtime contract at the repository root.

## Local validation

The ignored `.env` belongs to the original Lovable project and must not be used
for Cloudflare preparation. The preview command explicitly loads the owned
development project from `.env.test.local` for both build-time and Worker
runtime variables:

```sh
npm run cf:preview
```

This builds the application and starts Wrangler locally at
`http://localhost:8787`. It does not authenticate to Cloudflare or deploy.

## Environment variables

Configure these as Cloudflare **build variables** before a production build:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`

The `VITE_` prefix makes these values public in the browser bundle. The
publishable key is designed for browser use and is protected by Supabase RLS.
`VITE_SUPABASE_PROJECT_ID` is optional operational metadata; current application
code does not read it.

Configure these as Worker **runtime text variables**:

- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_KEY`

`SUPABASE_PROJECT_ID` is optional operational metadata; current server code does
not read it. With `nodejs_compat` and the configured compatibility date,
Cloudflare exposes runtime bindings through `process.env` inside request-time
middleware.

No application runtime secret is currently required. In particular, do not add
`SUPABASE_SERVICE_ROLE_KEY` to Cloudflare: production server functions use the
caller's access token and RLS, and the service-role client has no production
call sites. The service-role key and
`LOVABLE_BROWSER_SUPABASE_STORAGE_KEY` remain local acceptance-test variables.

Cloudflare credentials such as `CLOUDFLARE_API_TOKEN` belong in the deployment
operator's shell or CI secret store. They are not Worker environment variables.

## Supabase Auth after a domain is assigned

Keep the existing localhost entries for development. Add the final Worker or
custom origin in Supabase Authentication URL Configuration:

- Site URL: `https://<production-origin>`
- Allowed redirect URL: `https://<production-origin>/**`
- Keep: `http://localhost:8080/**`

Signup confirmation uses `window.location.origin`. Invitation links are also
created from `window.location.origin`, so both automatically use the deployed
domain. Email/password sign-in and sign-out navigate internally and require no
additional provider callback. Password recovery is not implemented; add its
future recovery route to the allowlist when that feature is built. Google OAuth
remains unverified and out of scope.

## Manual deployment checklist

1. Choose the final `workers.dev` name or custom domain.
2. Configure Cloudflare build variables and Worker runtime text variables.
3. Run typecheck, build, local Wrangler preview, and acceptance tests.
4. Add the production origin to Supabase Auth without removing localhost.
5. Authenticate Wrangler or configure a scoped CI API token.
6. Review `wrangler deploy --dry-run` output.
7. Deploy manually only after approval.

There is intentionally no `deploy` package script in this preparation change.
