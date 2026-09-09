# Landing page variants

The root route (`src/routes/index.tsx`) currently selects `InternalBetaLanding` and `internalBetaLandingHead`. This is a static component choice, with no feature flags, environment variables, or extra public routes.

`CommercialLanding.tsx` preserves the previous root page's complete commercial layout, helper components, copy, and metadata. Both variants reuse `SportSpendLogo`, the existing stadium image, and the existing public styles. `internal-beta.css` contains only styles scoped to `.sp-internal-beta`; it does not restyle the commercial page or authentication.

To restore the commercial experience, change the import in `src/routes/index.tsx` to `CommercialLanding` and `commercialLandingHead` from `@/components/landing/CommercialLanding`, then use them for `component` and `head`. No other files or routing changes are needed.

Both beta Sign in links use the existing `/auth` route. Authentication, signup, redirects, authenticated shells, and product functionality are unchanged.
