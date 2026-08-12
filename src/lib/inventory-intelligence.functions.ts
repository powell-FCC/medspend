import { createServerFn } from '@tanstack/react-start';
import { z } from 'zod';
import { requireSupabaseAuth } from '@/integrations/supabase/auth-middleware';
import {
  buildInventoryIntelligenceDashboard,
  canAccessInventoryIntelligence,
  type InventoryIntelligenceRole,
} from '@/inventory/intelligence';

const input = z.object({ organizationId: z.string().uuid() });
const OPEN_REQUEST_STATUSES = ['submitted', 'under_review', 'approved', 'ordered', 'received'] as const;

export const getInventoryIntelligenceDashboardFn = createServerFn({ method: 'POST' })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => input.parse(value))
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    const { data: membership, error: membershipError } = await db
      .from('organization_memberships')
      .select('role')
      .eq('organization_id', data.organizationId)
      .eq('user_id', context.userId)
      .eq('active', true)
      .maybeSingle();
    if (membershipError) throw new Error(membershipError.message);
    if (!membership || !canAccessInventoryIntelligence(membership.role as InventoryIntelligenceRole)) {
      throw new Error('Forbidden: administrator access required');
    }

    const { data: inventoryRows, error: inventoryError } = await db
      .from('inventory_items')
      .select('id,product_id,name,category,quantity,unit,par_level,last_purchase_price,last_purchase_date')
      .eq('organization_id', data.organizationId)
      .eq('active', true)
      .order('name');
    if (inventoryError) throw new Error(inventoryError.message);

    const productIds = Array.from(new Set<string>((inventoryRows ?? []).flatMap((row: any) => row.product_id ? [row.product_id] : [])));
    const inventoryItemIds = (inventoryRows ?? []).map((row: any) => row.id);

    const [productsResult, purchaseResult, demandResult, receiptsResult] = await Promise.all([
      productIds.length
        ? db.from('products')
          .select('id,name,category_id,preferred_vendor_id')
          .eq('organization_id', data.organizationId).in('id', productIds)
        : Promise.resolve({ data: [], error: null }),
      productIds.length
        ? db.from('inventory_price_history')
          .select('product_id,purchase_date,unit_price')
          .eq('organization_id', data.organizationId).in('product_id', productIds)
          .order('purchase_date', { ascending: false })
        : Promise.resolve({ data: [], error: null }),
      productIds.length
        ? db.from('supply_request_items')
          .select('supply_request_id,product_id,quantity,supply_requests!inner(status)')
          .eq('organization_id', data.organizationId).in('product_id', productIds)
          .in('supply_requests.status', [...OPEN_REQUEST_STATUSES])
        : Promise.resolve({ data: [], error: null }),
      inventoryItemIds.length
        ? db.from('inventory_adjustments')
          .select('inventory_item_id,created_at')
          .eq('organization_id', data.organizationId).in('inventory_item_id', inventoryItemIds)
          .eq('source_type', 'invoice').order('created_at', { ascending: false })
        : Promise.resolve({ data: [], error: null }),
    ]);
    for (const result of [productsResult, purchaseResult, demandResult, receiptsResult]) {
      if (result.error) throw new Error(result.error.message);
    }

    const categoryIds = Array.from(new Set<string>((productsResult.data ?? []).flatMap((row: any) => row.category_id ? [row.category_id] : [])));
    const vendorIds = Array.from(new Set<string>((productsResult.data ?? []).flatMap((row: any) => row.preferred_vendor_id ? [row.preferred_vendor_id] : [])));
    const [categoriesResult, vendorsResult] = await Promise.all([
      categoryIds.length
        ? db.from('product_categories').select('id,name').eq('organization_id', data.organizationId).in('id', categoryIds)
        : Promise.resolve({ data: [], error: null }),
      vendorIds.length
        ? db.from('vendors').select('id,name').eq('organization_id', data.organizationId).in('id', vendorIds)
        : Promise.resolve({ data: [], error: null }),
    ]);
    if (categoriesResult.error) throw new Error(categoriesResult.error.message);
    if (vendorsResult.error) throw new Error(vendorsResult.error.message);
    const categories = new Map<string, string>((categoriesResult.data ?? []).map((row: any) => [row.id, row.name]));
    const vendors = new Map<string, string>((vendorsResult.data ?? []).map((row: any) => [row.id, row.name]));

    return buildInventoryIntelligenceDashboard({
      inventoryItems: (inventoryRows ?? []).map((row: any) => ({
        inventoryItemId: row.id,
        productId: row.product_id,
        inventoryName: row.name,
        inventoryCategory: row.category,
        quantity: row.quantity,
        unit: row.unit,
        parLevel: row.par_level,
        inventoryLastPurchasePrice: row.last_purchase_price,
        inventoryLastPurchaseDate: row.last_purchase_date,
      })),
      products: (productsResult.data ?? []).map((row: any) => ({
        id: row.id,
        name: row.name,
        category: row.category_id ? categories.get(row.category_id) ?? null : null,
        preferredVendor: row.preferred_vendor_id ? vendors.get(row.preferred_vendor_id) ?? null : null,
      })),
      purchaseHistory: (purchaseResult.data ?? []).map((row: any) => ({
        productId: row.product_id,
        purchaseDate: row.purchase_date,
        unitPrice: row.unit_price,
      })),
      demand: (demandResult.data ?? []).flatMap((row: any) => row.product_id ? [{ requestId: row.supply_request_id, productId: row.product_id, quantity: row.quantity }] : []),
      receipts: (receiptsResult.data ?? []).map((row: any) => ({ inventoryItemId: row.inventory_item_id, receivedAt: row.created_at })),
    });
  });
