import { z } from "zod";

export const commitmentReleaseKinds = ["settled", "cancelled", "adjustment", "other"] as const;
export type CommitmentReleaseKind = (typeof commitmentReleaseKinds)[number];
export type RequestPricingStatus = "fully_priced" | "partially_priced" | "unpriced";
export type RequestCommitmentStatus = "active" | "released" | null;

export type RequestBudgetImpact = {
  requestId: string;
  requestStatus: string;
  estimatedAmount: number;
  pricingStatus: RequestPricingStatus;
  totalItemCount: number;
  pricedItemCount: number;
  commitmentStatus: RequestCommitmentStatus;
  commitmentReleaseReason: string | null;
  budgetId: string | null;
  budgetName: string | null;
  budgetAmount: number | null;
  actualSpend: number | null;
  committedSpend: number | null;
  availableAmount: number | null;
  projectedAvailableAfterApproval: number | null;
};

export const releaseCommitmentSchema = z.object({
  organizationId: z.string().uuid(),
  requestId: z.string().uuid(),
  releaseKind: z.enum(commitmentReleaseKinds),
  releaseReason: z.string().trim().min(1, "Explain why this commitment can be released.").max(1000),
});

export function pricingDescription(impact: RequestBudgetImpact): string {
  if (impact.pricingStatus === "fully_priced") return "All requested items are priced.";
  if (impact.pricingStatus === "partially_priced") {
    return `${impact.pricedItemCount} of ${impact.totalItemCount} requested items are priced. Totals include known costs only.`;
  }
  return "No reliable USD price is available for this request.";
}
