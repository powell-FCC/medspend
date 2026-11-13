import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { assertInventoryOwner } from "@/inventory/owner-access";
import {
  getReplenishmentSummary,
  listLocationReplenishmentRules,
  listReplenishmentPage,
  setReplenishmentRule,
  setReplenishmentRuleEnabled,
} from "@/inventory/replenishment-reads";

// Phase 7D Replenishment. Reads are for owners and admins (the database functions check the
// role); rule writes are owner-only here and again in the database. Nothing here creates or
// prepares a supply request, a purchase or a stock move: moves go through the existing Move
// Stock action, which the owner confirms.

const uuid = z.string().uuid();
// A rule version is passed back exactly as the database returned it.
const version = z.string().min(1).max(64);
const quantity = z.number().finite();

export const listReplenishmentFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({
        organizationId: uuid,
        view: z.enum(["attention", "ok", "inactive", "all"]).default("attention"),
        locationId: uuid.nullable().default(null),
        cursor: z
          .object({
            rank: z.number().int().min(0).max(3),
            item: z.string().max(300),
            location: z.string().max(300),
            id: uuid,
          })
          .nullable()
          .default(null),
        limit: z.number().int().min(1).max(500).default(100),
      })
      .parse(value),
  )
  .handler(({ data, context }) => listReplenishmentPage(context.supabase, data));

export const getReplenishmentSummaryFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: uuid }).parse(value))
  .handler(({ data, context }) => getReplenishmentSummary(context.supabase, data.organizationId));

export const listLocationReplenishmentRulesFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z.object({ organizationId: uuid, locationId: uuid }).parse(value),
  )
  .handler(async ({ data, context }) => ({
    rules: await listLocationReplenishmentRules(
      context.supabase,
      data.organizationId,
      data.locationId,
    ),
  }));

export const setReplenishmentRuleFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({
        organizationId: uuid,
        inventoryItemId: uuid,
        locationId: uuid,
        minimumQuantity: quantity.min(0),
        targetQuantity: quantity.positive(),
        expectedUpdatedAt: version.nullable(),
      })
      .refine((input) => input.targetQuantity >= input.minimumQuantity, {
        message: "Target must be at least the Minimum",
      })
      .parse(value),
  )
  .handler(async ({ data, context }) => {
    await assertInventoryOwner(context.supabase, context.userId, data.organizationId);
    return setReplenishmentRule(context.supabase, data);
  });

export const setReplenishmentRuleEnabledFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({
        organizationId: uuid,
        ruleId: uuid,
        enabled: z.boolean(),
        expectedUpdatedAt: version,
      })
      .parse(value),
  )
  .handler(async ({ data, context }) => {
    await assertInventoryOwner(context.supabase, context.userId, data.organizationId);
    return setReplenishmentRuleEnabled(context.supabase, data);
  });
