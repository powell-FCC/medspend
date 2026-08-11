export type DocumentType =
  | "INVOICE"
  | "ORDER_CONFIRMATION"
  | "PURCHASE_ORDER"
  | "CREDIT_MEMO"
  | "STATEMENT"
  | "UNKNOWN";
export type VendorEvidenceType =
  | "SELLER_NAME"
  | "EMAIL_DOMAIN"
  | "WEB_DOMAIN"
  | "PHONE"
  | "DOCUMENT_PHRASE";
export interface VendorEvidence {
  type: VendorEvidenceType;
  value: string;
  normalizedValue: string;
  confidence: number;
  source: string;
}

const normalizeWords = (value: string) =>
  value
    .toLowerCase()
    .normalize("NFKC")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
const domain = (value: string) =>
  value
    .toLowerCase()
    .replace(/^https?:\/\//, "")
    .replace(/^www\./, "")
    .split(/[/@]/)
    .at(-1)
    ?.split(/[\s/]/)[0] ?? "";
const ignoredDomains = new Set(["gmail.com", "outlook.com", "yahoo.com", "hotmail.com"]);

export function classifyDocument(text: string): {
  type: DocumentType;
  confidence: number;
  evidence: string;
} {
  const rules: Array<[DocumentType, RegExp]> = [
    ["ORDER_CONFIRMATION", /\border\s+confirmation\b/i],
    ["CREDIT_MEMO", /\bcredit\s+(?:memo|memorandum)\b/i],
    ["PURCHASE_ORDER", /\bpurchase\s+order\b/i],
    ["STATEMENT", /\b(?:account\s+)?statement\b/i],
    ["INVOICE", /\bsales\s+invoice\b|\binvoice\s*(?:number|no\.?|#|:)/i],
  ];
  const matches = rules.filter(([, pattern]) => pattern.test(text));
  if (!matches.length) return { type: "UNKNOWN", confidence: 0, evidence: "" };
  const distinct = new Set(matches.map(([type]) => type));
  if (distinct.size > 1) {
    if (
      distinct.has("ORDER_CONFIRMATION") &&
      distinct.has("PURCHASE_ORDER") &&
      !distinct.has("INVOICE")
    )
      return { type: "ORDER_CONFIRMATION", confidence: 96, evidence: "Order Confirmation" };
    if (distinct.has("INVOICE") && distinct.has("PURCHASE_ORDER") && distinct.size === 2)
      return {
        type: "INVOICE",
        confidence: 96,
        evidence: "Explicit invoice identity with PO reference",
      };
    return { type: "UNKNOWN", confidence: 45, evidence: "Conflicting explicit document labels" };
  }
  return { type: matches[0][0], confidence: 96, evidence: text.match(matches[0][1])?.[0] ?? "" };
}

export function extractVendorEvidence(text: string): VendorEvidence[] {
  const evidence: VendorEvidence[] = [];
  const add = (type: VendorEvidenceType, value: string, confidence: number, source: string) => {
    const normalizedValue = type.endsWith("DOMAIN") ? domain(value) : normalizeWords(value);
    if (!normalizedValue || (type.endsWith("DOMAIN") && ignoredDomains.has(normalizedValue)))
      return;
    if (!evidence.some((item) => item.type === type && item.normalizedValue === normalizedValue))
      evidence.push({ type, value: value.trim(), normalizedValue, confidence, source });
  };
  for (const match of text.matchAll(/(?:https?:\/\/|www\.)[^\s]+/gi))
    add("WEB_DOMAIN", match[0], 96, "Explicit web domain");
  const lines = text.split(/\r?\n/);
  lines.forEach((line, index) => {
    const match = line.match(/[A-Z0-9._%+-]+@([A-Z0-9.-]+\.[A-Z]{2,})/i);
    if (
      match &&
      (/^\s*(?:seller\s+)?email\s*[:#-]?\s*$/i.test(lines[index - 1] ?? "") ||
        /\b(?:vendor|seller|sold by)\b/i.test(line))
    )
      add("EMAIL_DOMAIN", match[1], 94, "Seller email domain");
  });
  for (const match of text.matchAll(/(?:vendor|seller|sold by)\s*[:#-]\s*([^\n]{2,100})/gi))
    add("SELLER_NAME", match[1], 96, "Explicit seller label");
  for (const line of lines) {
    if (
      /\b(?:inc\.?|llc|ltd\.?|corp(?:oration)?|company)\b/i.test(line) &&
      !/\b(?:bill|ship)\s+to\b/i.test(line)
    )
      add("SELLER_NAME", line, 82, "Company identity outside recipient label");
    if (/^\s*\*{1,2}.+\*{1,2}\s*$/.test(line) && /\b(?:price|contract|account|terms)\b/i.test(line))
      add("DOCUMENT_PHRASE", line.replace(/\*/g, ""), 88, "Branded commercial notice");
  }
  return evidence;
}

export interface VendorIdentityCandidate {
  id: string;
  organizationId: string;
  name: string;
  normalizedName: string;
  email?: string | null;
  phone?: string | null;
  website?: string | null;
}
export interface RememberedVendorSignature {
  id: string;
  organizationId: string;
  vendorId: string;
  signatureType: VendorEvidenceType;
  normalizedValue: string;
}
export type VendorMatchState = "MATCHED" | "SUGGESTED" | "UNRESOLVED" | "CONFIRMED";
export interface VendorMatchResult {
  state: VendorMatchState;
  vendorId: string | null;
  confidence: number;
  evidence: VendorEvidence[];
  reason: string;
}

export function resolveVendor(
  organizationId: string,
  evidence: VendorEvidence[],
  vendors: VendorIdentityCandidate[],
  signatures: RememberedVendorSignature[],
): VendorMatchResult {
  const scopedVendors = vendors.filter((vendor) => vendor.organizationId === organizationId);
  const rememberedIds = new Set(
    signatures
      .filter(
        (signature) =>
          signature.organizationId === organizationId &&
          evidence.some(
            (item) =>
              item.type === signature.signatureType &&
              item.normalizedValue === signature.normalizedValue,
          ),
      )
      .map((signature) => signature.vendorId),
  );
  if (rememberedIds.size === 1)
    return {
      state: "MATCHED",
      vendorId: [...rememberedIds][0],
      confidence: 100,
      evidence,
      reason: "REMEMBERED_SIGNATURE",
    };
  if (rememberedIds.size > 1)
    return {
      state: "UNRESOLVED",
      vendorId: null,
      confidence: 0,
      evidence,
      reason: "CONFLICTING_REMEMBERED_SIGNATURES",
    };
  const exact = scopedVendors.filter((vendor) =>
    evidence.some((item) => {
      if (item.type === "WEB_DOMAIN") return domain(vendor.website ?? "") === item.normalizedValue;
      if (item.type === "EMAIL_DOMAIN") return domain(vendor.email ?? "") === item.normalizedValue;
      if (item.type === "SELLER_NAME")
        return normalizeWords(vendor.normalizedName || vendor.name) === item.normalizedValue;
      return false;
    }),
  );
  if (exact.length === 1)
    return {
      state: "MATCHED",
      vendorId: exact[0].id,
      confidence: 98,
      evidence,
      reason: "EXACT_VENDOR_IDENTITY",
    };
  const scored = scopedVendors
    .map((vendor) => {
      const tokens = normalizeWords(vendor.normalizedName || vendor.name)
        .split(" ")
        .filter((token) => token.length >= 5);
      const strong = evidence.filter(
        (item) =>
          item.type === "WEB_DOMAIN" ||
          item.type === "EMAIL_DOMAIN" ||
          item.type === "SELLER_NAME" ||
          item.type === "DOCUMENT_PHRASE",
      );
      const hits = tokens.filter((token) =>
        strong.some((item) => item.normalizedValue.includes(token)),
      );
      const branded = strong.some(
        (item) =>
          item.type === "DOCUMENT_PHRASE" &&
          hits.some((token) => item.normalizedValue.includes(token)),
      );
      return {
        vendor,
        score:
          tokens.length && hits.length === tokens.length
            ? 94
            : branded && hits.length
              ? 88
              : hits.length
                ? 78
                : 0,
      };
    })
    .filter((candidate) => candidate.score > 0)
    .sort((a, b) => b.score - a.score);
  if (scored.length === 1 && scored[0].score >= 88)
    return {
      state: "MATCHED",
      vendorId: scored[0].vendor.id,
      confidence: scored[0].score,
      evidence,
      reason: "DISTINCTIVE_SELLER_EVIDENCE",
    };
  if (scored.length === 1 || (scored[0] && scored[1] && scored[0].score - scored[1].score >= 15))
    return {
      state: "SUGGESTED",
      vendorId: scored[0].vendor.id,
      confidence: scored[0].score,
      evidence,
      reason: "PARTIAL_SELLER_EVIDENCE",
    };
  return {
    state: "UNRESOLVED",
    vendorId: null,
    confidence: 0,
    evidence,
    reason: scored.length > 1 ? "AMBIGUOUS_VENDOR_EVIDENCE" : "INSUFFICIENT_VENDOR_EVIDENCE",
  };
}
