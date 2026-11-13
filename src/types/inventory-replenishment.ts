// Phase 7D Replenishment. Every value here comes from the database calculation
// (inventory_replenishment_rows); the application only displays it.

export type ReplenishmentCategory =
  | "move_available"
  | "partly_covered"
  | "needs_purchasing"
  | "ok"
  | "inactive";
export type ReplenishmentInactiveReason = "disabled" | "item_archived" | "location_archived";
export type ReplenishmentView = "attention" | "ok" | "inactive" | "all";
export type ReplenishmentCountState =
  | "not_applicable"
  | "nothing_to_count"
  | "never_counted"
  | "counted"
  | "current"
  | "due"
  | "overdue";

export interface ReplenishmentDonor {
  locationId: string;
  name: string;
  kind: "unassigned" | "storage";
  spareQuantity: number;
  // The part of the move this donor covers, in donor order (0 when earlier donors cover it).
  moveQuantity: number;
}

export interface ReplenishmentRow {
  ruleId: string;
  inventoryItemId: string;
  itemName: string;
  itemUnit: string;
  itemActive: boolean;
  inventoryLocationId: string;
  locationName: string;
  locationActive: boolean;
  minimumQuantity: number;
  targetQuantity: number;
  enabled: boolean;
  // The rule's version, exactly as the database returned it (microseconds included). It goes
  // back unchanged as the expected version of an edit; never round-trip it through Date.
  updatedAt: string;
  category: ReplenishmentCategory;
  inactiveReason: ReplenishmentInactiveReason | null;
  currentQuantity: number;
  notStockedHere: boolean;
  shortageQuantity: number;
  availableQuantity: number;
  moveQuantity: number;
  externalQuantity: number;
  organizationQuantity: number;
  unassignedQuantity: number;
  donors: ReplenishmentDonor[];
  otherShortLocationCount: number;
  lastCountedAt: string | null;
  locationCountState: ReplenishmentCountState | null;
  openRequestCount: number;
  openApprovedRequestCount: number;
  openOrderedRequestCount: number;
}

export interface ReplenishmentCursor {
  rank: number;
  item: string;
  location: string;
  id: string;
}

export interface ReplenishmentPage {
  rows: ReplenishmentRow[];
  nextCursor: ReplenishmentCursor | null;
}

export interface ReplenishmentSummary {
  rules: { total: number; active: number; inactive: number; disabled: number };
  categories: {
    moveAvailable: number;
    partlyCovered: number;
    needsPurchasing: number;
    ok: number;
    inactive: number;
  };
  notStockedHere: number;
  items: { active: number; withRule: number; withoutRule: number };
  locations: { activeStorage: number; withRule: number; withoutRule: number };
}

export interface ReplenishmentRuleResult {
  ruleId: string;
  inventoryItemId: string;
  inventoryLocationId: string;
  minimumQuantity: number;
  targetQuantity: number;
  enabled: boolean;
  updatedAt: string;
}

// What the Move Stock dialog is opened with from a recommendation: one donor per action.
export interface ReplenishmentMovePrefill {
  fromId: string;
  toId: string;
  quantity: number;
}

// The Minimum / Target dialog (Phase 7D): create for one storage location, or edit one rule.
export interface RuleDialogItem {
  id: string;
  name: string;
  unit: string;
}

export type RuleDialogState =
  | {
      mode: "create";
      locationId: string;
      locationName: string;
      // Active items the owner can choose from (stock here is not required).
      items: RuleDialogItem[];
    }
  | {
      mode: "edit";
      locationId: string;
      locationName: string;
      item: RuleDialogItem;
      minimum: number;
      target: number;
      // The rule's version as the screen loaded it; an edit from an older screen is refused.
      updatedAt: string;
    };

export interface RuleDialogSubmit {
  inventoryItemId: string;
  minimumQuantity: number;
  targetQuantity: number;
  expectedUpdatedAt: string | null;
}
