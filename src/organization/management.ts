import { z } from "zod";

export const structureNameSchema = z.string().trim().min(1, "Enter a name").max(120);

export const memberUpdateSchema = z
  .object({
    organizationId: z.string().uuid(),
    id: z.string().uuid(),
    changes: z
      .object({
        role: z.enum(["owner", "admin", "staff"]).optional(),
        active: z.boolean().optional(),
        default_team_id: z.string().uuid().nullable().optional(),
        default_location_id: z.string().uuid().nullable().optional(),
      })
      .strict()
      .refine((changes) => Object.keys(changes).length > 0, "Choose a change"),
  })
  .strict();

export type OrganizationMember = {
  id: string;
  userId: string;
  fullName: string;
  email: string | null;
  role: "owner" | "admin" | "staff";
  active: boolean;
  defaultTeamId: string | null;
  defaultLocationId: string | null;
};

export type StructureRecord = { id: string; name: string; active: boolean };

// UI guidance only; the database enforces these restrictions independently.
export function memberRestrictions(
  actor: { id: string; role: "owner" | "admin" | "staff" },
  member: OrganizationMember,
  activeOwnerCount: number,
) {
  const admin = actor.role === "owner" || actor.role === "admin";
  const self = actor.id === member.id;
  const lastOwner = member.active && member.role === "owner" && activeOwnerCount <= 1;
  const canEdit = admin && (member.role !== "owner" || actor.role === "owner");
  return {
    canEdit,
    canChangeRole: canEdit && !self && !lastOwner,
    canChangeActive: canEdit && !self && !lastOwner,
    reason: !canEdit
      ? "Only owners can manage owners."
      : lastOwner
        ? "Keep at least one active owner."
        : self
          ? "You cannot change your own role or deactivate yourself."
          : null,
  };
}
