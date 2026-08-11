export type ProductMatchState = "EXACT" | "SUGGESTED" | "UNRESOLVED" | "CONFIRMED";

export interface IdentityLine {
  sku: string;
  description: string;
  manufacturer?: string;
  unitOfMeasure?: string | null;
  packageSize?: string | null;
  productId?: string | null;
  vendorProductId?: string | null;
}

export interface IdentityProduct {
  organizationId: string;
  id: string;
  name: string;
  description?: string | null;
  manufacturer?: string | null;
  internalItemCode?: string | null;
  vendorItemNumber?: string | null;
  preferredVendorId?: string | null;
  unitOfMeasure?: string | null;
  packSize?: string | null;
}

export interface IdentityVendorMapping {
  organizationId: string;
  id: string;
  vendorId: string;
  productId: string;
  vendorSku: string;
  unitOfMeasure?: string | null;
  packageSize?: string | null;
}

export interface ProductMatchResult {
  state: ProductMatchState;
  productId: string | null;
  vendorProductId: string | null;
  score?: number;
  reasons: string[];
}

export const normalizeIdentifier = (value: string) =>
  value
    .trim()
    .toUpperCase()
    .replace(/[\s._-]+/g, "");

export function normalizeUom(value?: string | null) {
  const normalized = normalizeWords(value ?? "");
  const aliases: Record<string, string> = {
    bx: "box",
    boxes: "box",
    box: "box",
    ea: "each",
    each: "each",
    rl: "roll",
    rolls: "roll",
    roll: "roll",
    cs: "case",
    cases: "case",
    case: "case",
    pk: "pack",
    pkg: "pack",
    packs: "pack",
    pack: "pack",
  };
  return aliases[normalized] ?? normalized;
}

export function normalizePackageSize(value?: string | null) {
  const normalized = normalizeWords(value ?? "").replace(/\s*\/\s*/g, "/");
  const match = normalized.match(/^(\d+(?:\.\d+)?)\s*\/\s*(.+)$/);
  return match ? `${match[1]}/${normalizeUom(match[2])}` : normalized;
}

export function normalizeDescription(value: string) {
  return value
    .toLowerCase()
    .normalize("NFKC")
    .replace(/[“”″]/g, " inch ")
    .replace(/[‘’′]/g, " foot ")
    .replace(/\b(inches|inch|in\.)\b/g, " inch ")
    .replace(/\b(yards|yard|yds|yd\.)\b/g, " yd ")
    .replace(/\b(millimeters|millimeter|mm\.)\b/g, " mm ")
    .replace(/[^a-z0-9.]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

const normalizeWords = (value: string) =>
  value
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9./]+/g, " ")
    .replace(/\s+/g, " ");
const tokens = (value: string) => new Set(normalizeDescription(value).split(" ").filter(Boolean));
const dimensions = (value: string) =>
  normalizeDescription(value).match(/\b\d+(?:\.\d+)?\s*(?:inch|yd|mm|cm|gauge|ga)\b/g) ?? [];
const sameOptional = (left?: string | null, right?: string | null, normalizer = normalizeWords) =>
  !left || !right || normalizer(left) === normalizer(right);

function descriptionScore(left: string, right: string) {
  const a = tokens(left);
  const b = tokens(right);
  const intersection = [...a].filter((token) => b.has(token)).length;
  const union = new Set([...a, ...b]).size;
  return union ? intersection / union : 0;
}

function compatible(line: IdentityLine, product: IdentityProduct) {
  const leftDimensions = dimensions(line.description);
  const rightDimensions = dimensions(`${product.name} ${product.description ?? ""}`);
  if (
    leftDimensions.length &&
    rightDimensions.length &&
    leftDimensions.sort().join("|") !== rightDimensions.sort().join("|")
  )
    return false;
  if (!sameOptional(line.unitOfMeasure, product.unitOfMeasure, normalizeUom)) return false;
  if (!sameOptional(line.packageSize, product.packSize, normalizePackageSize)) return false;
  return true;
}

export function matchInvoiceProduct(
  line: IdentityLine,
  organizationId: string,
  vendorId: string | null,
  products: IdentityProduct[],
  mappings: IdentityVendorMapping[],
): ProductMatchResult {
  if (line.productId)
    return {
      state: "CONFIRMED",
      productId: line.productId,
      vendorProductId: line.vendorProductId ?? null,
      reasons: ["OWNER_CONFIRMED"],
    };
  const sku = normalizeIdentifier(line.sku);
  if (vendorId && sku) {
    const remembered = mappings.find(
      (mapping) =>
        mapping.organizationId === organizationId &&
        mapping.vendorId === vendorId &&
        normalizeIdentifier(mapping.vendorSku) === sku,
    );
    const rememberedProduct =
      remembered &&
      products.find(
        (product) =>
          product.organizationId === organizationId && product.id === remembered.productId,
      );
    const mappingCompatible =
      remembered &&
      sameOptional(line.unitOfMeasure, remembered.unitOfMeasure, normalizeUom) &&
      sameOptional(line.packageSize, remembered.packageSize, normalizePackageSize);
    if (
      remembered &&
      rememberedProduct &&
      mappingCompatible &&
      compatible(line, rememberedProduct)
    ) {
      return {
        state: "EXACT",
        productId: remembered.productId,
        vendorProductId: remembered.id,
        score: 100,
        reasons: ["REMEMBERED_VENDOR_SKU"],
      };
    }
  }
  if (sku) {
    const trusted = products.filter(
      (product) =>
        product.organizationId === organizationId &&
        (normalizeIdentifier(product.internalItemCode ?? "") === sku ||
          (vendorId &&
            product.preferredVendorId === vendorId &&
            normalizeIdentifier(product.vendorItemNumber ?? "") === sku)),
    );
    if (trusted.length === 1 && compatible(line, trusted[0]))
      return {
        state: "EXACT",
        productId: trusted[0].id,
        vendorProductId: null,
        score: 100,
        reasons: ["TRUSTED_EXACT_IDENTIFIER"],
      };
  }
  const suggestions = products
    .filter((product) => product.organizationId === organizationId)
    .map((product) => {
      if (!compatible(line, product)) return null;
      const score = descriptionScore(
        line.description,
        `${product.name} ${product.description ?? ""}`,
      );
      const manufacturerMatches = Boolean(
        line.manufacturer &&
        product.manufacturer &&
        normalizeWords(line.manufacturer) === normalizeWords(product.manufacturer),
      );
      return {
        product,
        score: Math.min(99, Math.round(score * 85 + (manufacturerMatches ? 10 : 0))),
      };
    })
    .filter((candidate): candidate is NonNullable<typeof candidate> =>
      Boolean(candidate && candidate.score >= 72),
    )
    .sort((left, right) => right.score - left.score);
  if (
    suggestions.length === 1 ||
    (suggestions[0] && suggestions[1] && suggestions[0].score - suggestions[1].score >= 12)
  ) {
    return {
      state: "SUGGESTED",
      productId: suggestions[0].product.id,
      vendorProductId: null,
      score: suggestions[0].score,
      reasons: ["STRONG_DESCRIPTION_COMPATIBILITY", "OWNER_CONFIRMATION_REQUIRED"],
    };
  }
  return {
    state: "UNRESOLVED",
    productId: null,
    vendorProductId: null,
    reasons: suggestions.length > 1 ? ["AMBIGUOUS_CANDIDATES"] : ["INSUFFICIENT_EVIDENCE"],
  };
}
