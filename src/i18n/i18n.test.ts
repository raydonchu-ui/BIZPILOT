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
  'nav': ['dashboard', 'sales', 'purchases', 'products', 'inventory', 'suppliers', 'customers', 'expenses', 'cash', 'reports', 'advisor', 'staff', 'settings', 'newSale', 'newPurchase', 'addProduct', 'recordExpense', 'addSupplier'],
  'reports.tabs': ['pl', 'sales', 'products', 'categories', 'valuation', 'slow', 'aging', 'restock', 'suppliers', 'customers', 'discrepancies', 'efficiency', 'payments'],
  'admin.nav': ['overview', 'businesses', 'payments', 'plans', 'config', 'announcements', 'support', 'ai', 'audit'],
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
  'admin.configHelp': ['trial', 'grace_days', 'renewal_notice_days', 'payment_instructions', 'support_contact', 'ai'],
  'insights.limits': ['estimated_costs', 'zero_cost_sales', 'short_history', 'seasonality_unknown'],
  'notifications.types': ['low_stock', 'out_of_stock', 'expiring_soon', 'supplier_payment_due', 'supplier_payment_overdue', 'customer_overdue',
    'subscription_renewal_due', 'subscription_grace', 'subscription_expired', 'subscription_trial', 'billing_payment_verified', 'billing_payment_rejected'],
};
const INSIGHTS = ['insufficient_data', 'estimated_costs', 'profit_decreased', 'profit_increased', 'restock_needed', 'price_below_cost', 'weak_margin',
  'top_profit_product', 'category_leader', 'slow_moving_capital', 'expiring_stock', 'high_stock_losses', 'supplier_payments_due', 'customer_overdue'];
dyn['businessCategories'] = [...BUSINESS_TYPES];
dyn['catalog.attr'] = [...new Set(Object.values(ATTRIBUTE_FIELDS).flat().map((f) => f.key))];
dyn['catalog.opt'] = [...new Set(Object.values(ATTRIBUTE_FIELDS).flat().flatMap((f) => f.options ?? []))];
for (const [ns, vals] of Object.entries(dyn)) for (const v of vals) used.add(`${ns}.${v}`);
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
