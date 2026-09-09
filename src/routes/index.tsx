import { createFileRoute } from "@tanstack/react-router";
import {
  InternalBetaLanding,
  internalBetaLandingHead,
} from "@/components/landing/InternalBetaLanding";

// To restore the commercial page, use CommercialLanding and commercialLandingHead
// from @/components/landing/CommercialLanding here. No auth or route changes needed.
export const Route = createFileRoute("/")({
  head: internalBetaLandingHead,
  component: InternalBetaLanding,
});
