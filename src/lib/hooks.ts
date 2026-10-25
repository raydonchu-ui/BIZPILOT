import { useQuery } from '@tanstack/react-query';
import { supabase, FILES_BUCKET } from './supabase';
import { unwrap } from './api';
import { newId } from './ids';
import { useAuth } from './auth';

export interface Product {
  id: string; business_id: string; name: string; sku: string; barcode: string | null; category_id: string | null;
  subcategory: string | null; condition?: string | null; single_item?: boolean; brand: string | null; description: string | null; image_path: string | null; base_unit: string;
  allow_fraction: boolean; purchase_cost: number; selling_price: number; qty_on_hand: number; stock_value: number; avg_cost: number;
  min_stock: number; lead_time_days: number | null; min_order_qty: number | null; preferred_supplier_id: string | null;
  location: string | null; track_expiry: boolean; variant_of: string | null; variant_label: string | null; status: 'active' | 'archived';
  attributes?: Record<string, string | number> | null;
  online_published?: boolean; online_images?: string[]; compare_at_price?: number | null; admin_hidden?: boolean; admin_hidden_reason?: string | null;
  created_at: string; updated_at: string; categories?: { name: string } | null; product_units?: ProductUnit[];
}

export interface Category {
  id: string; name: string; parent_id: string | null; sort_order: number; archived_at: string | null; attribute_set: string | null;
}

export interface ProductUnit {
  id: string; product_id: string; name: string; factor: number; selling_price: number | null; barcode: string | null;
  is_default_purchase: boolean; is_default_sale: boolean; active: boolean;
}

// Every category and subcategory of the business, archived ones included, in display order.
// True once the database has the October 2026 upgrade (catalogue + Store Lock); false while it
// does not (the app then keeps the previous behaviour); undefined while unknown.
export function useDbUpgraded(): boolean | undefined {
  const s = useAuth().storeLock.status;
  return s ? !s.unavailable : undefined;
}

export function useCategoryTree(businessId: string) {
  const upgraded = useDbUpgraded();
  return useQuery({
    queryKey: ['categories', businessId, 'tree', upgraded],
    enabled: upgraded !== undefined,
    queryFn: async () => {
      if (!upgraded) { // previous database: flat categories only
        const rows = unwrap(await supabase.from('categories').select('id,name').eq('business_id', businessId).order('name')) as { id: string; name: string }[];
        return rows.map((r) => ({ ...r, parent_id: null, sort_order: 0, archived_at: null, attribute_set: null })) as Category[];
      }
      return unwrap(await supabase.from('categories').select('id,name,parent_id,sort_order,archived_at,attribute_set')
        .eq('business_id', businessId).order('sort_order').order('name')) as Category[];
    },
  });
}

// Active top-level categories (for selectors and filters).
export function useCategories(businessId: string) {
  const tree = useCategoryTree(businessId);
  return { ...tree, data: tree.data?.filter((c) => !c.parent_id && !c.archived_at) };
}

export function subcategoriesOf(tree: Category[] | undefined, parentId: string | null | undefined, includeArchived = false) {
  if (!parentId) return [];
  return (tree ?? []).filter((c) => c.parent_id === parentId && (includeArchived || !c.archived_at));
}

export function useSuppliers(businessId: string, enabled = true) {
  return useQuery({
    queryKey: ['suppliers-list', businessId],
    enabled,
    queryFn: async () => unwrap(await supabase.from('suppliers').select('id,name,phone,payment_terms_days,lead_time_days,status')
      .eq('business_id', businessId).order('name')) as any[],
  });
}

export function useCustomers(businessId: string, enabled = true) {
  return useQuery({
    queryKey: ['customers-list', businessId],
    enabled,
    queryFn: async () => unwrap(await supabase.from('customers').select('id,name,phone,credit_limit,status')
      .eq('business_id', businessId).eq('status', 'active').order('name')) as any[],
  });
}

export function useAccounts(businessId: string, enabled = true) {
  return useQuery({
    queryKey: ['accounts', businessId],
    enabled,
    queryFn: async () => unwrap(await supabase.from('cash_accounts').select('*').eq('business_id', businessId).order('created_at')) as any[],
  });
}

export function useSettings(businessId: string) {
  return useQuery({
    queryKey: ['settings', businessId],
    queryFn: async () => unwrap(await supabase.from('business_settings').select('*').eq('business_id', businessId).single()) as any,
  });
}

export function useBusinessRow(businessId: string) {
  return useQuery({
    queryKey: ['business', businessId],
    queryFn: async () => unwrap(await supabase.from('businesses').select('*').eq('id', businessId).single()) as any,
  });
}

export function useSignedUrl(path: string | null | undefined) {
  return useQuery({
    queryKey: ['signed', path],
    enabled: Boolean(path),
    staleTime: 50 * 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.storage.from(FILES_BUCKET).createSignedUrl(path!, 3600);
      if (error) throw error;
      return data.signedUrl;
    },
  });
}

const MAX_BYTES = 5 * 1024 * 1024;
const ALLOWED = ['image/png', 'image/jpeg', 'image/webp', 'application/pdf'];

export async function uploadFile(businessId: string, folder: string, file: File): Promise<string> {
  if (file.size > MAX_BYTES) throw new Error('file_too_large');
  if (!ALLOWED.includes(file.type)) throw new Error('file_type_not_allowed');
  const ext = file.name.split('.').pop()?.toLowerCase().replace(/[^a-z0-9]/g, '') || 'bin';
  const path = `${businessId}/${folder}/${newId()}.${ext}`;
  const { error } = await supabase.storage.from(FILES_BUCKET).upload(path, file, { contentType: file.type, upsert: false });
  if (error) throw error;
  return path;
}

export async function attachFile(businessId: string, entityType: string, entityId: string, folder: string, file: File, userId: string) {
  const path = await uploadFile(businessId, folder, file);
  unwrap(await supabase.from('attachments').insert({
    business_id: businessId, entity_type: entityType, entity_id: entityId, path, file_name: file.name,
    mime_type: file.type, size_bytes: file.size, uploaded_by: userId,
  }));
  return path;
}

export function useAttachments(entityType: string, entityId: string | undefined) {
  return useQuery({
    queryKey: ['attachments', entityType, entityId],
    enabled: Boolean(entityId),
    queryFn: async () => unwrap(await supabase.from('attachments').select('*').eq('entity_type', entityType).eq('entity_id', entityId!)
      .order('created_at', { ascending: false })) as any[],
  });
}

export async function openFile(path: string) {
  const { data, error } = await supabase.storage.from(FILES_BUCKET).createSignedUrl(path, 600);
  if (error) throw error;
  window.open(data.signedUrl, '_blank', 'noopener');
}
