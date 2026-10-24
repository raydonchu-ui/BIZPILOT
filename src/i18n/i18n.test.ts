import { describe, expect, it } from 'vitest';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import * as common from './common';
import * as site from './site';
import * as auth from './auth';
import * as app from './app';
import * as admin from './admin';
import { ATTRIBUTE_FIELDS, BUSINESS_TYPES } from '../lib/catalogTemplates';

const dict = (l: 'en' | 'fr') => ({ ...common[l], ...site[l], ...auth[l], ...app[l], ...admin[l] }) as Record<string, any>;
const get = (d: any, k: string) => k.split('.').reduce((o, p) => (o && typeof o === 'object' ? o[p] : undefined), d);

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    return statSync(p).isDirectory() ? files(p) : /\.tsx?$/.test(f) && !f.endsWith('.test.ts') && !p.includes('/i18n/') ? [p] : [];
  });
}

// Literal keys passed to t('...'), tv('...') and has('...')
const used = new Set<string>();
for (const f of files(join(__dirname, '..'))) {
  const src = readFileSync(f, 'utf8');
  for (const m of src.matchAll(/\b(?:t|tv|has)\(\s*'([a-zA-Z][\w]*\.[\w.]+)'/g)) used.add(m[1]);
}

// Keys built dynamically from known value sets
const dyn: Record<string, string[]> = {
  'nav': ['dashboard', 'sales', 'purchases', 'products', 'inventory', 'suppliers', 'customers', 'expenses', 'cash', 'reports', 'advisor', 'staff', 'settings', 'newSale', 'newPurchase', 'addProduct', 'recordExpense', 'addSupplier',
    'myStore', 'orders', 'promotions', 'payments', 'categories'],
  'navGroups': ['online', 'shop', 'catalog', 'buy', 'money', 'insights', 'business'],
  'orders.status': ['pending', 'confirmed', 'processing', 'dispatched', 'delivered', 'cancelled', 'refunded'],
  'orders.payment': ['awaiting_payment', 'paid', 'failed', 'cod_pending', 'cod_collected', 'refund_pending', 'refunded', 'void'],
  'orders.onlineStatus': ['created', 'pending', 'successful', 'failed', 'expired', 'error'],
  'orders.filters': ['to_confirm', 'awaiting_payment', 'active', 'delivered', 'closed', 'all'],
  'orders.empty': ['to_confirm', 'awaiting_payment', 'active', 'delivered', 'closed', 'all'],
  'orders.done': ['confirm', 'processing', 'dispatch', 'deliver', 'reject', 'cancel', 'refund', 'message', 'note'],
  'orders.flags': ['payment_amount_mismatch', 'duplicate_payment', 'paid_after_cancellation', 'refund_after_cancellation', 'refund_after_delivery'],
  'orders.paymentEvents': ['failed', 'expired', 'online_payment_verified', 'amount_mismatch'],
  'orders.reasons': ['out_of_stock', 'cannot_deliver', 'customer_unreachable', 'customer_request', 'other'],
  'market.reasons': ['counterfeit', 'prohibited', 'misleading', 'scam', 'not_delivered', 'wrong_item', 'damaged', 'payment_problem', 'refund_problem', 'harassment', 'other'],
  'market.problems': ['product_unavailable', 'choose_option', 'invalid_quantity', 'insufficient_stock', 'pickup_not_available', 'zone_required', 'delivery_not_available',
    'invalid_delivery_method', 'promo_invalid', 'promo_min_order', 'below_minimum_order', 'cart_empty'],
  'market.sort': ['relevance', 'newest', 'price_asc', 'price_desc', 'rating'],
  'market.days': ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'],
  'market.actor': ['customer', 'seller', 'system', 'admin'],
  'market.cancelReasons': ['payment_not_completed', 'not_confirmed_in_time', 'cancelled_by_customer', 'other'],
  'seller.store.status': ['draft', 'published', 'suspended'],
  'seller.store.missing': ['profile', 'products', 'payment', 'delivery'],
  'seller.store.verify': ['unverified', 'pending', 'verified', 'rejected'],
  'seller.pay.kinds': ['order_payment', 'commission', 'processing_fee', 'refund', 'payout', 'adjustment'],
  'seller.promo.status': ['active', 'inactive', 'ended', 'scheduled', 'used_up'],
  'seller.dash': ['to_confirm', 'to_deliver', 'awaiting_payment', 'disputes'],
  'madmin.storeFilter': ['published', 'pending_verification', 'draft', 'suspended'],
  'madmin.reportStatus': ['open', 'reviewing', 'resolved', 'dismissed'],
  'madmin.kind': ['report', 'dispute'],
  'madmin.targetType': ['product', 'store', 'order'],
  'madmin.orderFilter': ['attention', 'refund_pending', 'online', 'all'],
  'features': ['promotions', 'store_customization'],
  'limits': ['max_online_products'],
  'reports.tabs': ['pl', 'sales', 'products', 'categories', 'valuation', 'slow', 'aging', 'restock', 'suppliers', 'customers', 'discrepancies', 'efficiency', 'payments'],
  'admin.nav': ['overview', 'businesses', 'payments', 'plans', 'config', 'announcements', 'support', 'ai', 'audit', 'market', 'stores', 'listings', 'reports', 'orders', 'settlements'],
  'sales.status': ['paid', 'partial', 'credit', 'returned', 'partially_returned'],
  'inventory.countStatus': ['draft', 'completed', 'cancelled'],
  'billing.paymentStatus': ['pending', 'verified', 'rejected'],
  'billing.stateHelp': ['free', 'trial', 'active', 'renewal_due', 'grace', 'expired', 'cancelled', 'suspended'],
  'billing': ['banner_grace', 'banner_expired', 'banner_suspended'],
  'help.status': ['open', 'in_progress', 'resolved', 'closed'],
  'cash.kinds': ['transfer', 'deposit', 'withdrawal', 'adjustment'],
  'cash.kindHelp': ['transfer', 'deposit', 'withdrawal', 'adjustment'],
  'purchases.creditKind': ['return', 'short_shipment', 'adjustment'],
  'reports.restock': ['p_urgent', 'p_soon', 'p_plan'],
  'reports.conf': ['low', 'medium', 'high'],
  'reports.slow': ['no_sales', 'slow'],
  'reports.eff': ['no_sales_after_purchase', 'possible_overbuying', 'stocked_out', 'balanced'],
  'reports.dow': ['1', '2', '3', '4', '5', '6', '7'],
  'reports.pl': ['cash_received', 'refunds_paid', 'supplier_payments', 'expenses_paid'],
  'parties.stmt': ['sale', 'return', 'sale_payment', 'customer_payment', 'customer_refund', 'purchase', 'credit_return', 'credit_short_shipment', 'credit_adjustment', 'supplier_payment', 'supplier_refund'],
  'parties': ['edit_supplier', 'edit_customer', 'new_supplier', 'new_customer', 'help_supplier_payment', 'help_supplier_refund', 'help_supplier_credit', 'help_customer_payment'],
  'imports.help': ['products', 'suppliers', 'customers'],
  'imports.errors': ['name_required', 'duplicate_sku', 'duplicate_sku_in_file', 'duplicate_barcode', 'duplicate_barcode_in_file', 'invalid_number', 'negative_number', 'fractional_quantity_not_allowed', 'duplicate_name'],
  'advisor.fallback': ['not_configured', 'refusal', 'ai_error', 'no_plan'],
  'advisor.presets': ['restock', 'profit', 'fastest', 'notSold', 'capital', 'categories', 'investigate', 'compare', 'declining', 'improve'],
  'admin.configHelp': ['trial', 'grace_days', 'renewal_notice_days', 'payment_instructions', 'support_contact', 'ai', 'marketplace'],
  'insights.limits': ['estimated_costs', 'zero_cost_sales', 'short_history', 'seasonality_unknown'],
  'notifications.types': ['low_stock', 'out_of_stock', 'expiring_soon', 'supplier_payment_due', 'supplier_payment_overdue', 'customer_overdue',
    'subscription_renewal_due', 'subscription_grace', 'subscription_expired', 'subscription_trial', 'billing_payment_verified', 'billing_payment_rejected',
    'market_order_new', 'market_order_paid', 'market_order_cancelled', 'market_message', 'market_dispute', 'market_store_status', 'market_listing_hidden',
    'market_listing_restored', 'market_payout'],
};
const INSIGHTS = ['insufficient_data', 'estimated_costs', 'profit_decreased', 'profit_increased', 'restock_needed', 'price_below_cost', 'weak_margin',
  'top_profit_product', 'category_leader', 'slow_moving_capital', 'expiring_stock', 'high_stock_losses', 'supplier_payments_due', 'customer_overdue'];
dyn['businessCategories'] = [...BUSINESS_TYPES];
dyn['catalog.attr'] = [...new Set(Object.values(ATTRIBUTE_FIELDS).flat().map((f) => f.key))];
dyn['catalog.opt'] = [...new Set(Object.values(ATTRIBUTE_FIELDS).flat().flatMap((f) => f.options ?? []))];
for (const [ns, vals] of Object.entries(dyn)) for (const v of vals) used.add(`${ns}.${v}`);
// Every error code raised by the database has a message.
for (const f of readdirSync(join(__dirname, '../../supabase/migrations'))) {
  if (!f.startsWith('202610250')) continue;
  for (const m of readFileSync(join(__dirname, '../../supabase/migrations', f), 'utf8').matchAll(/app\.raise\('([a-z_]+)'/g)) used.add(`errors.${m[1]}`);
}
for (const c of INSIGHTS) for (const part of ['title', 'finding', 'why', 'action']) used.add(`insights.${c}.${part}`);
for (const n of dyn['notifications.types']) { used.delete(`notifications.types.${n}`); used.add(`notifications.types.${n}.title`); used.add(`notifications.types.${n}.body`); }

describe('i18n', () => {
  for (const lang of ['en', 'fr'] as const) {
    it(`has every key used in the UI (${lang})`, () => {
      const d = dict(lang);
      const missing = [...used].filter((k) => get(d, k) === undefined).sort();
      if (missing.length) console.log(`${lang} missing (${missing.length}):\n` + missing.join('\n'));
      expect(missing).toEqual([]);
    });
  }
  it('French and English have identical structure', () => {
    const walk = (o: any, p = ''): string[] => Object.entries(o).flatMap(([k, v]) => (v && typeof v === 'object' && !Array.isArray(v) ? walk(v, `${p}${k}.`) : [`${p}${k}`]));
    expect(walk(dict('fr')).sort()).toEqual(walk(dict('en')).sort());
  });
});
