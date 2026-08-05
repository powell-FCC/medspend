export interface InventoryMatchCandidate {
  sku: string | null;
  vendorName: string | null;
  name: string;
}

const normalize = (value: string | null) => value?.trim().toLowerCase() ?? '';
const normalizeName = (value: string) => normalize(value).replace(/[^a-z0-9]+/g, '');

export function inventoryMatchPriority(
  candidate: InventoryMatchCandidate,
  item: { sku: string; vendorName: string; name: string },
): 1 | 2 | 3 | null {
  const skuMatches = normalize(candidate.sku) !== '' && normalize(candidate.sku) === normalize(item.sku);
  if (skuMatches) return 1;
  if (normalize(candidate.vendorName) === normalize(item.vendorName) && normalize(candidate.name) === normalize(item.name)) return 2;
  if (normalizeName(candidate.name) === normalizeName(item.name)) return 3;
  return null;
}
