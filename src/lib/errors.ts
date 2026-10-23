import type { TParams } from '../i18n';

interface ErrLike { message?: string; details?: string | null; code?: string }

const CONSTRAINT_MESSAGES: [RegExp, string][] = [
  [/products_sku_unique/, 'errors.duplicate_sku'],
  [/products_barcode_unique/, 'errors.duplicate_barcode'],
  [/categories_name_unique/, 'errors.duplicate_name'],
  [/product_units_name/, 'errors.duplicate_name'],
  [/row-level security/, 'errors.permission_denied'],
  [/violates check constraint/, 'errors.invalid_input'],
  [/invalid input syntax/, 'errors.invalid_input'],
  [/Failed to fetch|NetworkError|Load failed|fetch failed/i, 'errors.network_error'],
];

export function errorKey(err: unknown): { key: string; params?: TParams; raw: string } {
  const e = (err ?? {}) as ErrLike;
  const raw = e.message ?? String(err);
  let params: TParams | undefined;
  if (e.details) {
    try { params = JSON.parse(e.details); } catch { /* not JSON */ }
  }
  return { key: `errors.${raw}`, params, raw };
}

export function errorMessage(err: unknown, t: (k: string, p?: TParams) => string, has: (k: string) => boolean): string {
  const { key, params, raw } = errorKey(err);
  if (has(key)) return t(key, params);
  // Supabase Auth errors carry a stable code (e.g. over_email_send_rate_limit).
  const code = (err as ErrLike | null)?.code;
  if (code && has(`errors.auth_${code}`)) return t(`errors.auth_${code}`);
  if (/Error sending .*email/i.test(raw)) return t('errors.email_send_failed');
  for (const [re, k] of CONSTRAINT_MESSAGES) if (re.test(raw)) return t(k);
  if (import.meta.env.DEV) console.error(err);
  return t('errors.generic');
}
