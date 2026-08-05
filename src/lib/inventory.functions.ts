import { createServerFn } from '@tanstack/react-start';
import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { requireSupabaseAuth } from '@/integrations/supabase/auth-middleware';
import type { Database } from '@/integrations/supabase/types';
import { getInventoryStatus } from '@/inventory/status';
import type { InventoryCategory, InventoryItem } from '@/types/inventory';

const uuid = z.string().uuid();
const optionalText = z.string().trim().max(500).optional().nullable();
const itemInput = z.object({ id: uuid.optional(), organizationId: uuid, name: z.string().trim().min(1).max(200),
  description: optionalText, sku: optionalText, vendorName: optionalText, category: optionalText,
  manufacturer: optionalText, quantity: z.number().nonnegative(), unit: z.string().trim().min(1).max(80),
  parLevel: z.number().nonnegative().optional().nullable() });

async function assertOwner(db: SupabaseClient<Database>, userId: string, organizationId: string) {
  const { data, error } = await db.from('organization_memberships').select('role')
    .eq('organization_id', organizationId).eq('user_id', userId).eq('active', true).maybeSingle();
  if (error) throw new Error(error.message);
  if (data?.role !== 'owner') throw new Error('Forbidden: owner access required');
}

const toItem = (row: Database['public']['Tables']['inventory_items']['Row']): InventoryItem => ({
  id: row.id, organizationId: row.organization_id, name: row.name, description: row.description, sku: row.sku,
  vendorName: row.vendor_name, category: row.category, manufacturer: row.manufacturer, quantity: row.quantity,
  unit: row.unit, parLevel: row.par_level, active: row.active, createdAt: row.created_at, updatedAt: row.updated_at,
});

export const listInventoryFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: uuid, search: z.string().max(120).default(''), category: z.string().max(120).default(''), status: z.enum(['all', 'active', 'archived']).default('active'), lowStock: z.boolean().default(false) }).parse(value))
  .handler(async ({ data, context }) => {
    let query = context.supabase.from('inventory_items').select('*').eq('organization_id', data.organizationId).order('name');
    if (data.status === 'active') query = query.eq('active', true);
    if (data.status === 'archived') query = query.eq('active', false);
    if (data.category) query = query.eq('category', data.category);
    const search = data.search.trim().replaceAll(',', '');
    if (search) query = query.or(`name.ilike.%${search}%,sku.ilike.%${search}%,vendor_name.ilike.%${search}%,manufacturer.ilike.%${search}%`);
    const [itemsResult, categoriesResult] = await Promise.all([
      query,
      context.supabase.from('inventory_categories').select('*').eq('organization_id', data.organizationId).order('name'),
    ]);
    if (itemsResult.error) throw new Error(itemsResult.error.message);
    if (categoriesResult.error) throw new Error(categoriesResult.error.message);
    const items = (itemsResult.data ?? []).map(toItem).filter((item) => !data.lowStock || ['low', 'critical'].includes(getInventoryStatus(item.quantity, item.parLevel, item.active)));
    const categories: InventoryCategory[] = (categoriesResult.data ?? []).map((row) => ({ id: row.id, organizationId: row.organization_id, name: row.name, createdAt: row.created_at }));
    return { items, categories };
  });

export const saveInventoryItemFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => itemInput.parse(value)).handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const payload = { name: data.name, description: data.description || null, sku: data.sku || null,
      vendor_name: data.vendorName || null, category: data.category || null, manufacturer: data.manufacturer || null,
      unit: data.unit, par_level: data.parLevel ?? null };
    if (data.id) {
      const { data: current, error: readError } = await context.supabase.from('inventory_items').select('quantity').eq('id', data.id).eq('organization_id', data.organizationId).single();
      if (readError) throw new Error(readError.message);
      const { error } = await context.supabase.from('inventory_items').update(payload).eq('id', data.id).eq('organization_id', data.organizationId);
      if (error) throw new Error(error.message);
      if (current.quantity !== data.quantity) {
        const { error: adjustmentError } = await context.supabase.rpc('adjust_inventory_quantity', { _organization_id: data.organizationId, _inventory_item_id: data.id, _adjustment_amount: data.quantity - current.quantity, _reason: 'Correction' });
        if (adjustmentError) throw new Error(adjustmentError.message);
      }
      return { id: data.id };
    }
    const { data: row, error } = await context.supabase.from('inventory_items').insert({ organization_id: data.organizationId, ...payload, quantity: 0 }).select('id').single();
    if (error) throw new Error(error.message);
    if (data.quantity > 0) {
      const { error: adjustmentError } = await context.supabase.rpc('adjust_inventory_quantity', { _organization_id: data.organizationId, _inventory_item_id: row.id, _adjustment_amount: data.quantity, _reason: 'Manual adjustment' });
      if (adjustmentError) throw new Error(adjustmentError.message);
    }
    return { id: row.id };
  });

export const adjustInventoryQuantityFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: uuid, inventoryItemId: uuid, amount: z.number().refine((n) => n !== 0), reason: z.enum(['Invoice received', 'Manual adjustment', 'Damaged', 'Expired', 'Correction']) }).parse(value))
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const { data: quantity, error } = await context.supabase.rpc('adjust_inventory_quantity', { _organization_id: data.organizationId, _inventory_item_id: data.inventoryItemId, _adjustment_amount: data.amount, _reason: data.reason });
    if (error) throw new Error(error.message); return { quantity };
  });

export const setInventoryItemActiveFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: uuid, id: uuid, active: z.boolean() }).parse(value))
  .handler(async ({ data, context }) => { await assertOwner(context.supabase, context.userId, data.organizationId); const { error } = await context.supabase.from('inventory_items').update({ active: data.active }).eq('id', data.id).eq('organization_id', data.organizationId); if (error) throw new Error(error.message); return { ok: true }; });

export const saveInventoryCategoryFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: uuid, id: uuid.optional(), name: z.string().trim().min(1).max(120) }).parse(value))
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    if (data.id) {
      const { data: previous, error: readError } = await context.supabase.from('inventory_categories').select('name').eq('id', data.id).eq('organization_id', data.organizationId).single();
      if (readError) throw new Error(readError.message);
      const { error } = await context.supabase.from('inventory_categories').update({ name: data.name }).eq('id', data.id).eq('organization_id', data.organizationId);
      if (error) throw new Error(error.code === '23505' ? 'That category already exists.' : error.message);
      const { error: itemError } = await context.supabase.from('inventory_items').update({ category: data.name }).eq('organization_id', data.organizationId).eq('category', previous.name);
      if (itemError) throw new Error(itemError.message); return { id: data.id };
    }
    const { data: row, error } = await context.supabase.from('inventory_categories').insert({ organization_id: data.organizationId, name: data.name }).select('id').single();
    if (error) throw new Error(error.code === '23505' ? 'That category already exists.' : error.message); return { id: row.id };
  });

export const deleteInventoryCategoryFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: uuid, id: uuid }).parse(value))
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const { data: category, error: readError } = await context.supabase.from('inventory_categories').select('name').eq('id', data.id).eq('organization_id', data.organizationId).single();
    if (readError) throw new Error(readError.message);
    const { count, error: useError } = await context.supabase.from('inventory_items').select('id', { count: 'exact', head: true }).eq('organization_id', data.organizationId).eq('category', category.name);
    if (useError) throw new Error(useError.message); if (count) throw new Error('Category is in use and cannot be deleted.');
    const { error } = await context.supabase.from('inventory_categories').delete().eq('id', data.id); if (error) throw new Error(error.message); return { ok: true };
  });
