-- BizPilot: complete database setup (all migrations in order).
-- Paste into Supabase Dashboard -> SQL Editor -> New query, then Run. Run it ONCE on an empty project.
-- Generated from supabase/migrations by scripts/build-setup-sql.sh - do not edit by hand.
begin;

-- ===== 20261022000100_core.sql =====
-- BizPilot core: tenancy, memberships, permissions, configuration, audit.
-- Conventions
--   * Every business-owned table carries business_id and has RLS enabled.
--   * Financially significant writes happen only through SECURITY DEFINER RPCs in
--     schema public which validate membership + permission + entitlement.
--   * Helper functions live in schema "app" (not exposed through the REST API).
--   * Errors are raised with a stable machine code as the message (e.g.
--     'insufficient_stock') and optional JSON detail, translated by the client.

create schema if not exists app;
grant usage on schema app to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Platform configuration
-- ---------------------------------------------------------------------------
create table public.countries (
  code text primary key,
  name text not null,
  currency text not null,
  currency_decimals int not null default 0 check (currency_decimals between 0 and 3),
  default_language text not null default 'en',
  languages text[] not null,
  timezone text not null,
  registration_enabled boolean not null default false,
  payment_methods text[] not null default '{}'
);

insert into public.countries values
  ('CM', 'Cameroon', 'XAF', 0, 'fr', '{en,fr}', 'Africa/Douala', true,
   '{cash,mtn_momo,orange_money,bank_transfer,card,other}'),
  ('NG', 'Nigeria', 'NGN', 2, 'en', '{en}', 'Africa/Lagos', false, '{cash,bank_transfer,card,other}'),
  ('GH', 'Ghana', 'GHS', 2, 'en', '{en}', 'Africa/Accra', false, '{cash,bank_transfer,card,other}');

create table public.app_config (
  key text primary key,
  value jsonb not null,
  is_public boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

insert into public.app_config (key, value, is_public) values
  ('trial', '{"plan": "business", "days": 30}', true),
  ('grace_days', '7', true),
  ('renewal_notice_days', '7', false),
  ('payment_instructions', '{"mtn_momo": {"enabled": false, "number": "", "account_name": ""},
                            "orange_money": {"enabled": false, "number": "", "account_name": ""},
                            "notes_en": "", "notes_fr": ""}', true),
  ('support_contact', '{"email": "", "phone": "", "whatsapp": ""}', true),
  ('ai', '{"enabled": true}', false);

create table public.platform_admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  note text
);

-- ---------------------------------------------------------------------------
-- Users & businesses
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text,
  phone text,
  language text not null default 'en' check (language in ('en', 'fr')),
  theme text not null default 'light' check (theme in ('light', 'dark', 'system')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.businesses (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 2 and 120),
  owner_name text,
  email text,
  phone text,
  address text,
  city text,
  country_code text not null references public.countries (code),
  currency text not null,
  currency_decimals int not null default 0,
  timezone text not null default 'Africa/Douala',
  language text not null default 'fr' check (language in ('en', 'fr')),
  category text not null,
  logo_path text,
  tax_id text,
  trade_register text,
  reporting_start_date date not null default current_date,
  status text not null default 'active' check (status in ('active', 'suspended', 'closed')),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.business_settings (
  business_id uuid primary key references public.businesses (id) on delete cascade,
  allow_negative_stock boolean not null default false,
  cashier_max_discount_pct numeric(5, 2) not null default 10 check (cashier_max_discount_pct between 0 and 100),
  allow_credit_sales boolean not null default true,
  tax_enabled boolean not null default false,
  tax_rate numeric(5, 2) not null default 19.25 check (tax_rate between 0 and 100),
  tax_label text not null default 'TVA',
  default_lead_time_days int not null default 3 check (default_lead_time_days between 0 and 365),
  safety_stock_days int not null default 3 check (safety_stock_days between 0 and 365),
  planning_days int not null default 14 check (planning_days between 1 and 365),
  slow_moving_days int not null default 30 check (slow_moving_days between 7 and 365),
  expiry_alert_days int not null default 30 check (expiry_alert_days between 1 and 365),
  weak_margin_pct numeric(5, 2) not null default 10,
  low_stock_default numeric(14, 3) not null default 5,
  receipt_header text,
  receipt_footer text default 'Merci pour votre achat / Thank you for your purchase',
  updated_at timestamptz not null default now()
);

create table public.business_members (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null check (role in ('owner', 'manager', 'cashier')),
  permissions jsonb not null default '{}'::jsonb,
  display_name text,
  active boolean not null default true,
  invited_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, user_id)
);
create unique index business_members_one_owner on public.business_members (business_id)
  where role = 'owner' and active;
create index business_members_user on public.business_members (user_id) where active;

create table public.business_invites (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  email text not null,
  role text not null check (role in ('manager', 'cashier')),
  permissions jsonb not null default '{}'::jsonb,
  display_name text,
  invited_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  accepted_by uuid,
  revoked_at timestamptz
);
create unique index business_invites_pending on public.business_invites (business_id, lower(email))
  where accepted_at is null and revoked_at is null;

create table public.business_counters (
  business_id uuid not null references public.businesses (id) on delete cascade,
  key text not null,
  value bigint not null default 0,
  primary key (business_id, key)
);

create table public.audit_logs (
  id bigserial primary key,
  business_id uuid references public.businesses (id) on delete cascade,
  user_id uuid,
  action text not null,
  entity text,
  entity_id text,
  details jsonb,
  created_at timestamptz not null default now()
);
create index audit_logs_business on public.audit_logs (business_id, created_at desc);
create index audit_logs_platform on public.audit_logs (created_at desc) where business_id is null;

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------
create or replace function app.raise(code text, detail jsonb default null)
returns void language plpgsql as $$
begin
  if detail is null then
    raise exception using message = code, errcode = 'P0001';
  else
    raise exception using message = code, detail = detail::text, errcode = 'P0001';
  end if;
end $$;

create or replace function app.uid() returns uuid language sql stable as $$
  select auth.uid()
$$;

create or replace function app.require_auth() returns uuid language plpgsql stable as $$
declare v uuid := auth.uid();
begin
  if v is null then perform app.raise('not_authenticated'); end if;
  return v;
end $$;

create or replace function app.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid())
$$;

create or replace function app.my_business_ids() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(business_id), '{}') from public.business_members
  where user_id = auth.uid() and active
$$;

create or replace function app.member_role(bid uuid) returns text
language sql stable security definer set search_path = public as $$
  select role from public.business_members
  where business_id = bid and user_id = auth.uid() and active
$$;

create or replace function app.is_member(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.business_members
                 where business_id = bid and user_id = auth.uid() and active)
$$;

-- Read access: members, or platform admins holding an active, owner-granted
-- support access grant (redefined in the SaaS migration once that table exists).
create or replace function app.can_read(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_member(bid)
$$;

create or replace function app.role_permissions(r text) returns text[]
language sql immutable as $$
  select case r
    when 'owner' then array[
      'sales.create', 'sales.view', 'sales.refund', 'sales.discount_large', 'products.view',
      'products.manage', 'inventory.view', 'stock.adjust', 'purchases.manage', 'suppliers.manage',
      'customers.manage', 'customers.credit', 'expenses.manage', 'reports.view', 'cash.manage',
      'imports.manage', 'staff.manage', 'settings.manage', 'billing.manage', 'audit.view']
    when 'manager' then array[
      'sales.create', 'sales.view', 'sales.refund', 'sales.discount_large', 'products.view',
      'products.manage', 'inventory.view', 'stock.adjust', 'purchases.manage', 'suppliers.manage',
      'customers.manage', 'customers.credit', 'expenses.manage', 'reports.view', 'cash.manage',
      'imports.manage']
    when 'cashier' then array[
      'sales.create', 'sales.view', 'products.view', 'inventory.view', 'customers.manage']
    else array[]::text[]
  end
$$;

create or replace function app.all_permissions() returns text[]
language sql immutable as $$ select app.role_permissions('owner') $$;

create or replace function app.has_perm(bid uuid, perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case
      when m.role = 'owner' then true
      when m.permissions ? perm then (m.permissions ->> perm)::boolean
      else perm = any (app.role_permissions(m.role))
    end
    from public.business_members m
    join public.businesses b on b.id = m.business_id and b.status = 'active'
    where m.business_id = bid and m.user_id = auth.uid() and m.active
  ), false)
$$;

create or replace function app.require_perm(bid uuid, perm text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_auth();
  if not app.has_perm(bid, perm) then
    perform app.raise('permission_denied', jsonb_build_object('permission', perm));
  end if;
end $$;

create or replace function app.my_permissions(bid uuid) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(p order by p), '{}') from unnest(app.all_permissions()) p
  where app.has_perm(bid, p)
$$;

create or replace function app.next_number(bid uuid, k text, prefix text) returns text
language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  insert into public.business_counters as c (business_id, key, value) values (bid, k, 1)
  on conflict (business_id, key) do update set value = c.value + 1
  returning value into v;
  return prefix || lpad(v::text, 5, '0');
end $$;

create or replace function app.audit(bid uuid, act text, ent text, ent_id text, det jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.audit_logs (business_id, user_id, action, entity, entity_id, details)
  values (bid, auth.uid(), act, ent, ent_id, det)
$$;

create or replace function app.biz_tz(bid uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select timezone from public.businesses where id = bid), 'Africa/Douala')
$$;

create or replace function app.biz_today(bid uuid) returns date
language sql stable as $$ select (now() at time zone app.biz_tz(bid))::date $$;

-- Converts an inclusive local date range into a half-open timestamptz range.
create or replace function app.range_start(bid uuid, d date) returns timestamptz
language sql stable as $$ select (d::timestamp at time zone app.biz_tz(bid)) $$;
create or replace function app.range_end(bid uuid, d date) returns timestamptz
language sql stable as $$ select ((d + 1)::timestamp at time zone app.biz_tz(bid)) $$;

create or replace function app.money(bid uuid, v numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select round(v, coalesce((select currency_decimals from public.businesses where id = bid), 0))
$$;

create or replace function app.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

create or replace function app.is_internal() returns boolean language sql stable as $$
  -- True inside SECURITY DEFINER functions (owner) or for service/admin connections;
  -- false for requests executed directly as the API roles.
  select current_user not in ('authenticated', 'anon')
$$;

create trigger businesses_touch before update on public.businesses
  for each row execute function app.touch_updated_at();
create trigger business_settings_touch before update on public.business_settings
  for each row execute function app.touch_updated_at();
create trigger business_members_touch before update on public.business_members
  for each row execute function app.touch_updated_at();
create trigger profiles_touch before update on public.profiles
  for each row execute function app.touch_updated_at();

-- New auth user -> profile
create or replace function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone, language)
  values (new.id,
          nullif(new.raw_user_meta_data ->> 'full_name', ''),
          nullif(new.raw_user_meta_data ->> 'phone', ''),
          case when new.raw_user_meta_data ->> 'language' = 'fr' then 'fr' else 'en' end)
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function app.handle_new_user();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.countries enable row level security;
alter table public.app_config enable row level security;
alter table public.platform_admins enable row level security;
alter table public.profiles enable row level security;
alter table public.businesses enable row level security;
alter table public.business_settings enable row level security;
alter table public.business_members enable row level security;
alter table public.business_invites enable row level security;
alter table public.business_counters enable row level security;
alter table public.audit_logs enable row level security;

create policy countries_read on public.countries for select using (true);
create policy app_config_public_read on public.app_config for select
  using (is_public or app.is_platform_admin());
create policy platform_admins_self on public.platform_admins for select
  using (user_id = auth.uid() or app.is_platform_admin());

create policy profiles_self_read on public.profiles for select using (
  id = auth.uid()
  or exists (select 1 from public.business_members m
             where m.user_id = profiles.id and m.business_id in (select unnest(app.my_business_ids())))
  or app.is_platform_admin());
create policy profiles_self_update on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

create policy businesses_read on public.businesses for select
  using (id in (select unnest(app.my_business_ids())) or app.can_read(id) or app.is_platform_admin());

create policy settings_read on public.business_settings for select using (app.can_read(business_id));

create policy members_read on public.business_members for select
  using (business_id in (select unnest(app.my_business_ids())) or app.can_read(business_id));

create policy invites_read on public.business_invites for select
  using (app.has_perm(business_id, 'staff.manage'));

create policy audit_read on public.audit_logs for select
  using ((business_id is not null and app.has_perm(business_id, 'audit.view'))
         or app.is_platform_admin());

-- ===== 20261022000150_plans_entitlements.sql =====
-- Subscription plans, business subscriptions and server-side entitlements.
-- Prices, features, limits, trial and grace durations are data (editable by
-- platform administrators), not code.

create table public.plans (
  code text primary key check (code ~ '^[a-z0-9_]{2,30}$'),
  name_en text not null,
  name_fr text not null,
  description_en text,
  description_fr text,
  price_monthly numeric(12, 0) not null default 0 check (price_monthly >= 0),
  price_annual numeric(12, 0) check (price_annual >= 0),
  currency text not null default 'XAF',
  features text[] not null default '{}',
  limits jsonb not null default '{}'::jsonb,
  is_public boolean not null default true,
  active boolean not null default true,
  highlight boolean not null default false,
  sort int not null default 0,
  updated_at timestamptz not null default now()
);

-- Feature keys:
--   purchases, suppliers, expenses, customers_credit, stocktaking, staff, import,
--   cash_reconciliation, basic_analytics, advanced_analytics, restock,
--   reports_export, batch_tracking, ai_advisor
-- Limit keys (null = unlimited):
--   max_products, max_sales_per_month, max_staff, history_days, ai_queries_per_month
insert into public.plans (code, name_en, name_fr, description_en, description_fr, price_monthly, price_annual,
                          features, limits, highlight, sort) values
  ('free', 'Free', 'Gratuit',
   'Get started with basic stock and sales recording.',
   'Démarrez avec la gestion de base du stock et des ventes.',
   0, 0, '{stocktaking}',
   '{"max_products": 30, "max_sales_per_month": 150, "max_staff": 1, "history_days": 90, "ai_queries_per_month": 0}',
   false, 1),
  ('starter', 'Starter', 'Starter',
   'Suppliers, wholesale purchases, expenses and basic analytics.',
   'Fournisseurs, achats en gros, dépenses et analyses de base.',
   1500, 15000,
   '{stocktaking,purchases,suppliers,expenses,customers_credit,staff,import,cash_reconciliation,basic_analytics}',
   '{"max_products": 300, "max_sales_per_month": 2000, "max_staff": 3, "history_days": 365, "ai_queries_per_month": 0}',
   false, 2),
  ('business', 'Business', 'Business',
   'Advanced analytics, restocking recommendations, exports and the AI Advisor.',
   'Analyses avancées, recommandations de réapprovisionnement, exports et Conseiller IA.',
   3000, 30000,
   '{stocktaking,purchases,suppliers,expenses,customers_credit,staff,import,cash_reconciliation,basic_analytics,advanced_analytics,restock,reports_export,batch_tracking,ai_advisor}',
   '{"max_products": 5000, "max_sales_per_month": null, "max_staff": 10, "history_days": null, "ai_queries_per_month": 100}',
   true, 3);

create table public.business_subscriptions (
  business_id uuid primary key references public.businesses (id) on delete cascade,
  plan_code text not null references public.plans (code),
  status text not null check (status in ('trialing', 'active', 'cancelled', 'suspended')),
  billing_period text check (billing_period in ('monthly', 'annual')),
  current_period_start timestamptz,
  current_period_end timestamptz,
  trial_ends_at timestamptz,
  cancel_at_period_end boolean not null default false,
  suspended_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.billing_payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  plan_code text not null references public.plans (code),
  billing_period text not null check (billing_period in ('monthly', 'annual')),
  amount numeric(12, 0) not null check (amount > 0),
  expected_amount numeric(12, 0) not null,
  currency text not null default 'XAF',
  method text not null check (method in ('mtn_momo', 'orange_money', 'bank_transfer', 'cash', 'other')),
  transaction_ref text not null check (length(btrim(transaction_ref)) between 4 and 80),
  payer_phone text,
  payer_name text,
  proof_path text,
  note text,
  status text not null default 'pending' check (status in ('pending', 'verified', 'rejected')),
  submitted_by uuid,
  submitted_at timestamptz not null default now(),
  reviewed_by uuid,
  reviewed_at timestamptz,
  review_note text,
  period_start timestamptz,
  period_end timestamptz
);
-- The same provider transaction reference cannot be used twice (unless rejected).
create unique index billing_payments_ref_unique on public.billing_payments (method, lower(btrim(transaction_ref)))
  where status <> 'rejected';
create index billing_payments_business on public.billing_payments (business_id, submitted_at desc);
create index billing_payments_pending on public.billing_payments (submitted_at) where status = 'pending';

create trigger business_subscriptions_touch before update on public.business_subscriptions
  for each row execute function app.touch_updated_at();
create trigger plans_touch before update on public.plans
  for each row execute function app.touch_updated_at();

create or replace function app.config_int(k text, dflt int) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::int from public.app_config where key = k), dflt)
$$;

-- Subscription state machine (computed from dates; no cron job required).
create or replace function app.subscription_info(bid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  s public.business_subscriptions;
  grace int := app.config_int('grace_days', 7);
  notice int := app.config_int('renewal_notice_days', 7);
  st text; eff text; grace_end timestamptz; pending boolean;
begin
  select * into s from public.business_subscriptions where business_id = bid;
  pending := exists (select 1 from public.billing_payments where business_id = bid and status = 'pending');
  if not found or s.plan_code = 'free' then
    return jsonb_build_object('plan_code', 'free', 'effective_plan', 'free', 'state', 'free',
                              'payment_pending', pending);
  end if;
  if s.status = 'suspended' then
    st := 'suspended'; eff := 'free';
  elsif s.status = 'trialing' then
    if now() <= s.trial_ends_at then st := 'trial'; eff := s.plan_code; else st := 'expired'; eff := 'free'; end if;
  else
    grace_end := s.current_period_end + make_interval(days => grace);
    if now() <= s.current_period_end then
      eff := s.plan_code;
      st := case
        when s.status = 'cancelled' or s.cancel_at_period_end then 'cancelled'
        when s.current_period_end - now() <= make_interval(days => notice) then 'renewal_due'
        else 'active' end;
    elsif now() <= grace_end and s.status <> 'cancelled' then
      st := 'grace'; eff := s.plan_code;
    else
      st := 'expired'; eff := 'free';
    end if;
  end if;
  return jsonb_build_object(
    'plan_code', s.plan_code, 'effective_plan', eff, 'state', st, 'status', s.status,
    'billing_period', s.billing_period,
    'current_period_end', s.current_period_end, 'trial_ends_at', s.trial_ends_at,
    'grace_ends_at', grace_end, 'cancel_at_period_end', s.cancel_at_period_end,
    'payment_pending', pending);
end $$;

create or replace function app.effective_plan(bid uuid) returns public.plans
language sql stable security definer set search_path = public as $$
  select p.* from public.plans p where p.code = coalesce(app.subscription_info(bid) ->> 'effective_plan', 'free')
$$;

create or replace function app.has_feature(bid uuid, f text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(f = any ((app.effective_plan(bid)).features), false)
$$;

create or replace function app.require_feature(bid uuid, f text) returns void
language plpgsql stable as $$
begin
  if not app.has_feature(bid, f) then
    perform app.raise('feature_not_in_plan', jsonb_build_object('feature', f,
      'plan', (app.effective_plan(bid)).code));
  end if;
end $$;

create or replace function app.plan_limit(bid uuid, k text) returns numeric
language sql stable as $$
  select nullif((app.effective_plan(bid)).limits ->> k, '')::numeric
$$;

create or replace function app.history_cutoff(bid uuid) returns timestamptz
language sql stable security definer set search_path = public as $$
  select coalesce(now() - make_interval(days => app.plan_limit(bid, 'history_days')::int), '-infinity'::timestamptz)
$$;

create or replace function app.usage_count(bid uuid, k text) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare v numeric;
begin
  if k = 'max_products' then
    select count(*) into v from public.products where business_id = bid and status = 'active';
  elsif k = 'max_sales_per_month' then
    select count(*) into v from public.sales where business_id = bid
      and sold_at >= app.range_start(bid, date_trunc('month', app.biz_today(bid))::date);
  elsif k = 'max_staff' then
    select (select count(*) from public.business_members where business_id = bid and active)
         + (select count(*) from public.business_invites where business_id = bid
              and accepted_at is null and revoked_at is null) into v;
  elsif k = 'ai_queries_per_month' then
    select count(*) into v from public.ai_queries where business_id = bid
      and created_at >= date_trunc('month', now()) and status in ('started', 'completed');
  else
    v := 0;
  end if;
  return v;
end $$;

-- Raises plan_limit_reached when adding one more item would exceed the limit.
create or replace function app.check_limit(bid uuid, k text) returns void
language plpgsql stable as $$
declare lim numeric := app.plan_limit(bid, k); used numeric;
begin
  if lim is null then return; end if;
  used := app.usage_count(bid, k);
  if used + 1 > lim then
    perform app.raise('plan_limit_reached', jsonb_build_object('limit', k, 'max', lim, 'used', used));
  end if;
end $$;

create or replace function app.init_subscription(bid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t jsonb := (select value from public.app_config where key = 'trial');
        tplan text := coalesce(t ->> 'plan', 'business');
        tdays int := coalesce((t ->> 'days')::int, 0);
begin
  if tdays > 0 and exists (select 1 from public.plans where code = tplan and active) then
    insert into public.business_subscriptions (business_id, plan_code, status, trial_ends_at, current_period_start)
    values (bid, tplan, 'trialing', now() + make_interval(days => tdays), now());
  else
    insert into public.business_subscriptions (business_id, plan_code, status, current_period_start)
    values (bid, 'free', 'active', now());
  end if;
end $$;

alter table public.plans enable row level security;
alter table public.business_subscriptions enable row level security;
alter table public.billing_payments enable row level security;

create policy plans_public_read on public.plans for select using ((active and is_public) or app.is_platform_admin());
create policy subscriptions_read on public.business_subscriptions for select
  using (app.is_member(business_id) or app.is_platform_admin());
create policy billing_payments_read on public.billing_payments for select
  using (app.has_perm(business_id, 'billing.manage') or app.is_platform_admin());

-- ===== 20261022000200_catalog_inventory.sql =====
-- Catalog, units, batches and the stock movement ledger.
--
-- Inventory costing method: WEIGHTED AVERAGE COST (perpetual).
--   * Each product keeps qty_on_hand (in its base unit) and stock_value.
--     avg_cost = stock_value / qty_on_hand.
--   * Inflows (opening stock, receipts, customer returns, found stock) add
--     quantity * acquisition cost and recompute the average.
--   * Outflows (sales, supplier returns, losses) remove quantity at the current
--     average cost. The cost actually used is stored on the movement and on the
--     sale line, so historical profit is never recalculated with later costs.
--   * products.qty_on_hand / stock_value / avg_cost can only be changed by
--     app.apply_movement(), which also writes the immutable ledger row.

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 80),
  parent_id uuid references public.categories (id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index categories_name_unique on public.categories (business_id, lower(name));

create table public.import_batches (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  kind text not null check (kind in ('products', 'suppliers', 'customers')),
  file_name text,
  total_rows int not null default 0,
  created_count int not null default 0,
  skipped_count int not null default 0,
  issues jsonb not null default '[]'::jsonb,
  status text not null default 'completed' check (status in ('completed', 'rolled_back')),
  created_by uuid,
  created_at timestamptz not null default now(),
  rolled_back_at timestamptz,
  rolled_back_by uuid
);

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 120),
  contact_person text,
  phone text,
  email text,
  address text,
  reference text,
  payment_terms_days int check (payment_terms_days between 0 and 365),
  lead_time_days int check (lead_time_days between 0 and 365),
  quality_notes text,
  notes text,
  status text not null default 'active' check (status in ('active', 'archived')),
  import_batch_id uuid references public.import_batches (id) on delete set null,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index suppliers_business on public.suppliers (business_id, name);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 160),
  sku text not null check (length(btrim(sku)) between 1 and 64),
  barcode text,
  category_id uuid references public.categories (id) on delete set null,
  subcategory text,
  brand text,
  description text,
  image_path text,
  base_unit text not null default 'piece' check (length(btrim(base_unit)) between 1 and 30),
  allow_fraction boolean not null default false,
  purchase_cost numeric(18, 4) not null default 0 check (purchase_cost >= 0),
  selling_price numeric(14, 2) not null default 0 check (selling_price >= 0),
  qty_on_hand numeric(14, 3) not null default 0,
  stock_value numeric(18, 4) not null default 0,
  avg_cost numeric(18, 4) not null default 0,
  min_stock numeric(14, 3) not null default 0 check (min_stock >= 0),
  lead_time_days int check (lead_time_days between 0 and 365),
  min_order_qty numeric(14, 3) check (min_order_qty >= 0),
  preferred_supplier_id uuid references public.suppliers (id) on delete set null,
  location text,
  track_expiry boolean not null default false,
  variant_of uuid references public.products (id) on delete set null,
  variant_label text,
  status text not null default 'active' check (status in ('active', 'archived')),
  import_batch_id uuid references public.import_batches (id) on delete set null,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index products_sku_unique on public.products (business_id, lower(sku));
create unique index products_barcode_unique on public.products (business_id, barcode)
  where barcode is not null and barcode <> '';
create index products_business_name on public.products (business_id, status, name);
create index products_category on public.products (category_id);

-- Alternative units: factor = number of base units contained in one unit.
create table public.product_units (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 30),
  factor numeric(14, 4) not null check (factor > 0),
  barcode text,
  selling_price numeric(14, 2) check (selling_price >= 0),
  is_default_purchase boolean not null default false,
  is_default_sale boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index product_units_name on public.product_units (product_id, lower(name));

create table public.product_price_history (
  id bigserial primary key,
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  old_purchase_cost numeric(18, 4),
  new_purchase_cost numeric(18, 4),
  old_selling_price numeric(14, 2),
  new_selling_price numeric(14, 2),
  changed_by uuid,
  changed_at timestamptz not null default now()
);
create index product_price_history_product on public.product_price_history (product_id, changed_at desc);

create table public.stock_batches (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  batch_code text,
  expiry_date date,
  received_qty numeric(14, 3) not null default 0,
  remaining_qty numeric(14, 3) not null default 0 check (remaining_qty >= 0),
  supplier_id uuid references public.suppliers (id) on delete set null,
  purchase_id uuid,
  created_at timestamptz not null default now()
);
create index stock_batches_product on public.stock_batches (product_id, expiry_date) where remaining_qty > 0;
create index stock_batches_expiry on public.stock_batches (business_id, expiry_date) where remaining_qty > 0;

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id),
  movement_type text not null check (movement_type in (
    'opening', 'purchase_receipt', 'sale', 'sale_return', 'supplier_return',
    'damaged', 'expired', 'missing', 'found', 'correction', 'count', 'import_rollback')),
  quantity numeric(14, 3) not null check (quantity <> 0),   -- signed, base units
  unit_cost numeric(18, 4) not null,                         -- cost per base unit used
  value numeric(18, 4) not null,                             -- signed inventory value change
  qty_after numeric(14, 3) not null,
  avg_cost_after numeric(18, 4) not null,
  stock_value_after numeric(18, 4) not null,
  batch_id uuid references public.stock_batches (id) on delete set null,
  ref_type text,
  ref_id uuid,
  ref_number text,
  reason text,
  cost_estimated boolean not null default false,
  client_ref uuid,
  created_by uuid,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index stock_movements_product on public.stock_movements (product_id, occurred_at desc);
create index stock_movements_business on public.stock_movements (business_id, occurred_at desc);
create index stock_movements_ref on public.stock_movements (ref_type, ref_id);
create unique index stock_movements_client_ref on public.stock_movements (business_id, client_ref)
  where client_ref is not null;

create table public.stock_counts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  number text not null,
  status text not null default 'draft' check (status in ('draft', 'completed', 'cancelled')),
  scope text,
  notes text,
  created_by uuid,
  created_at timestamptz not null default now(),
  completed_by uuid,
  completed_at timestamptz,
  adjustment_value numeric(18, 4)
);

create table public.stock_count_lines (
  id uuid primary key default gen_random_uuid(),
  count_id uuid not null references public.stock_counts (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id),
  expected_qty numeric(14, 3) not null,      -- system quantity when the count was opened
  counted_qty numeric(14, 3),
  system_qty_at_completion numeric(14, 3),
  difference numeric(14, 3),
  value_difference numeric(18, 4),
  reason text,
  unique (count_id, product_id)
);

create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  entity_type text not null check (entity_type in ('purchase', 'expense', 'supplier', 'sale', 'customer', 'product', 'stock_count')),
  entity_id uuid not null,
  path text not null,
  file_name text,
  mime_type text,
  size_bytes int,
  uploaded_by uuid,
  created_at timestamptz not null default now()
);
create index attachments_entity on public.attachments (entity_type, entity_id);

create trigger suppliers_touch before update on public.suppliers
  for each row execute function app.touch_updated_at();
create trigger products_touch before update on public.products
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------
-- Runs as the invoking role (NOT security definer) so app.is_internal() can tell
-- direct API writes apart from writes made inside BizPilot's own RPCs.
create or replace function app.log_product_change(p_new public.products, p_old public.products) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_new.purchase_cost is distinct from p_old.purchase_cost
     or p_new.selling_price is distinct from p_old.selling_price then
    insert into public.product_price_history (business_id, product_id, old_purchase_cost,
      new_purchase_cost, old_selling_price, new_selling_price, changed_by)
    values (p_new.business_id, p_new.id, p_old.purchase_cost, p_new.purchase_cost,
            p_old.selling_price, p_new.selling_price, auth.uid());
  end if;
  if p_new.status = 'archived' and p_old.status <> 'archived' then
    perform app.audit(p_new.business_id, 'product.archived', 'product', p_new.id::text,
                      jsonb_build_object('name', p_new.name));
  end if;
end $$;

create or replace function app.products_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not app.is_internal() then
      new.qty_on_hand := 0;
      new.stock_value := 0;
      new.created_by := auth.uid();
    end if;
    new.avg_cost := coalesce(nullif(new.avg_cost, 0), new.purchase_cost, 0);
    new.sku := btrim(new.sku);
    new.barcode := nullif(btrim(coalesce(new.barcode, '')), '');
    perform app.check_limit(new.business_id, 'max_products');
    return new;
  end if;
  -- UPDATE
  if not app.is_internal() then
    if new.qty_on_hand is distinct from old.qty_on_hand
       or new.stock_value is distinct from old.stock_value
       or new.avg_cost is distinct from old.avg_cost
       or new.business_id is distinct from old.business_id
       or new.import_batch_id is distinct from old.import_batch_id then
      perform app.raise('protected_field');
    end if;
  end if;
  new.sku := btrim(new.sku);
  new.barcode := nullif(btrim(coalesce(new.barcode, '')), '');
  perform app.log_product_change(new, old);
  return new;
end $$;

create trigger products_guard before insert or update on public.products
  for each row execute function app.products_guard();

create or replace function app.same_business_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- Child rows must point at a product of the same business.
  if not exists (select 1 from public.products p where p.id = new.product_id and p.business_id = new.business_id) then
    perform app.raise('invalid_product');
  end if;
  return new;
end $$;

create trigger product_units_business before insert or update on public.product_units
  for each row execute function app.same_business_guard();

create or replace function app.product_refs_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.category_id is not null and not exists (
    select 1 from public.categories c where c.id = new.category_id and c.business_id = new.business_id) then
    perform app.raise('invalid_category');
  end if;
  if new.preferred_supplier_id is not null and not exists (
    select 1 from public.suppliers s where s.id = new.preferred_supplier_id and s.business_id = new.business_id) then
    perform app.raise('invalid_supplier');
  end if;
  if new.variant_of is not null and not exists (
    select 1 from public.products p where p.id = new.variant_of and p.business_id = new.business_id) then
    perform app.raise('invalid_product');
  end if;
  return new;
end $$;

create trigger products_refs before insert or update on public.products
  for each row execute function app.product_refs_guard();

-- ---------------------------------------------------------------------------
-- Core stock movement routine (the only writer of product stock figures)
-- ---------------------------------------------------------------------------
create or replace function app.apply_movement(
  p_business uuid,
  p_product uuid,
  p_type text,
  p_qty numeric,              -- signed quantity in base units
  p_unit_cost numeric,        -- acquisition cost per base unit for inflows; null = current average
  p_ref_type text default null,
  p_ref_id uuid default null,
  p_ref_number text default null,
  p_reason text default null,
  p_batch uuid default null,
  p_cost_estimated boolean default false,
  p_client_ref uuid default null,
  p_occurred_at timestamptz default now(),
  p_allow_negative boolean default null
) returns public.stock_movements
language plpgsql security definer set search_path = public as $$
declare
  pr public.products;
  allow_neg boolean;
  v_cost numeric(18, 4);
  v_value numeric(18, 4);
  new_qty numeric(14, 3);
  new_value numeric(18, 4);
  new_avg numeric(18, 4);
  mv public.stock_movements;
begin
  if p_qty is null or p_qty = 0 then perform app.raise('invalid_quantity'); end if;

  select * into pr from public.products where id = p_product and business_id = p_business for update;
  if not found then perform app.raise('invalid_product'); end if;

  if not pr.allow_fraction and p_qty <> trunc(p_qty) then
    perform app.raise('fractional_quantity_not_allowed', jsonb_build_object('product', pr.name));
  end if;

  new_qty := pr.qty_on_hand + p_qty;

  if p_qty > 0 then
    v_cost := coalesce(p_unit_cost, pr.avg_cost);
    if v_cost < 0 then perform app.raise('invalid_cost'); end if;
    v_value := round(p_qty * v_cost, 4);
    if pr.qty_on_hand <= 0 then
      -- Restarting from empty (or negative) stock: value the remaining stock at the new cost.
      new_value := round(new_qty * v_cost, 4);
      new_avg := v_cost;
    else
      new_value := pr.stock_value + v_value;
      new_avg := round(new_value / new_qty, 4);
    end if;
  else
    select allow_negative_stock into allow_neg from public.business_settings where business_id = p_business;
    allow_neg := coalesce(p_allow_negative, allow_neg, false);
    if new_qty < 0 and not allow_neg then
      perform app.raise('insufficient_stock', jsonb_build_object(
        'product', pr.name, 'available', pr.qty_on_hand, 'requested', -p_qty, 'unit', pr.base_unit));
    end if;
    v_cost := pr.avg_cost;
    if new_qty = 0 then
      v_value := -pr.stock_value;              -- remove the full remaining value: no rounding residue
      new_value := 0;
    else
      v_value := round(p_qty * v_cost, 4);
      new_value := case when new_qty < 0 then round(new_qty * v_cost, 4) else pr.stock_value + v_value end;
    end if;
    new_avg := pr.avg_cost;
  end if;

  update public.products
     set qty_on_hand = new_qty, stock_value = new_value, avg_cost = new_avg
   where id = p_product;

  insert into public.stock_movements (business_id, product_id, movement_type, quantity, unit_cost, value,
    qty_after, avg_cost_after, stock_value_after, batch_id, ref_type, ref_id, ref_number, reason,
    cost_estimated, client_ref, created_by, occurred_at)
  values (p_business, p_product, p_type, p_qty, v_cost, v_value, new_qty, new_avg, new_value, p_batch,
    p_ref_type, p_ref_id, p_ref_number, p_reason, p_cost_estimated, p_client_ref, auth.uid(),
    coalesce(p_occurred_at, now()))
  returning * into mv;
  return mv;
end $$;

-- Consume batch quantities first-expiry-first-out (tracking only; costing stays WAC).
create or replace function app.consume_batches(p_product uuid, p_qty numeric) returns void
language plpgsql security definer set search_path = public as $$
declare b record; remaining numeric := p_qty; take numeric;
begin
  for b in select id, remaining_qty from public.stock_batches
           where product_id = p_product and remaining_qty > 0
           order by expiry_date nulls last, created_at for update loop
    exit when remaining <= 0;
    take := least(b.remaining_qty, remaining);
    update public.stock_batches set remaining_qty = remaining_qty - take where id = b.id;
    remaining := remaining - take;
  end loop;
end $$;

-- Resolve a unit for a product. Returns (unit_id, name, factor). Never trusts a client factor.
create or replace function app.resolve_unit(p_product uuid, p_unit uuid, out unit_id uuid, out unit_name text, out factor numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if p_unit is null then
    select null, base_unit, 1 into unit_id, unit_name, factor from public.products where id = p_product;
  else
    select id, name, product_units.factor into unit_id, unit_name, factor
    from public.product_units where id = p_unit and product_id = p_product and active;
    if not found then perform app.raise('invalid_unit'); end if;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- RPCs: opening stock, adjustments, stocktaking
-- ---------------------------------------------------------------------------
create or replace function public.record_opening_stock(
  p_business uuid, p_product uuid, p_quantity numeric, p_unit_cost numeric,
  p_cost_known boolean default true, p_unit uuid default null,
  p_batch_code text default null, p_expiry date default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare u record; mv public.stock_movements; bid uuid; existing uuid; batch uuid; cost numeric;
begin
  perform app.require_perm(p_business, 'products.manage');
  if p_client_ref is not null then
    select id into existing from public.stock_movements where business_id = p_business and client_ref = p_client_ref;
    if found then return existing; end if;
  end if;
  if p_quantity is null or p_quantity <= 0 then perform app.raise('invalid_quantity'); end if;
  select * into u from app.resolve_unit(p_product, p_unit);
  cost := coalesce(p_unit_cost, 0);
  if cost < 0 then perform app.raise('invalid_cost'); end if;
  if not coalesce(p_cost_known, true) and cost = 0 then
    select purchase_cost into cost from public.products where id = p_product;
    cost := cost * u.factor;
  end if;
  if exists (select 1 from public.products where id = p_product and track_expiry)
     and (p_batch_code is not null or p_expiry is not null) then
    insert into public.stock_batches (business_id, product_id, batch_code, expiry_date, received_qty, remaining_qty)
    values (p_business, p_product, p_batch_code, p_expiry, p_quantity * u.factor, p_quantity * u.factor)
    returning id into batch;
  end if;
  mv := app.apply_movement(p_business, p_product, 'opening', p_quantity * u.factor, cost / u.factor,
    'opening', null, null, 'Opening stock', batch, not coalesce(p_cost_known, true), p_client_ref);
  perform app.audit(p_business, 'stock.opening', 'product', p_product::text,
    jsonb_build_object('quantity', p_quantity * u.factor, 'unit_cost', cost / u.factor, 'cost_known', p_cost_known));
  return mv.id;
end $$;

create or replace function public.adjust_stock(
  p_business uuid, p_product uuid, p_kind text, p_quantity numeric, p_reason text,
  p_batch uuid default null, p_unit_cost numeric default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
-- p_quantity: positive number of base units. Direction is implied by p_kind,
-- except for 'correction' where the sign of p_quantity is used.
declare signed numeric; mv public.stock_movements; existing uuid;
begin
  perform app.require_perm(p_business, 'stock.adjust');
  if p_client_ref is not null then
    select id into existing from public.stock_movements where business_id = p_business and client_ref = p_client_ref;
    if found then return existing; end if;
  end if;
  if p_kind not in ('damaged', 'expired', 'missing', 'found', 'correction') then
    perform app.raise('invalid_adjustment_type');
  end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  if p_quantity is null or p_quantity = 0 then perform app.raise('invalid_quantity'); end if;
  signed := case
    when p_kind in ('damaged', 'expired', 'missing') then -abs(p_quantity)
    when p_kind = 'found' then abs(p_quantity)
    else p_quantity end;
  if p_batch is not null then
    if not exists (select 1 from public.stock_batches where id = p_batch and product_id = p_product) then
      perform app.raise('invalid_batch');
    end if;
    if signed < 0 then
      update public.stock_batches set remaining_qty = remaining_qty + signed
       where id = p_batch and remaining_qty + signed >= 0;
      if not found then perform app.raise('insufficient_batch_quantity'); end if;
    else
      update public.stock_batches set remaining_qty = remaining_qty + signed where id = p_batch;
    end if;
  elsif signed < 0 then
    perform app.consume_batches(p_product, -signed);
  end if;
  mv := app.apply_movement(p_business, p_product, p_kind, signed, p_unit_cost, 'adjustment', null, null,
    btrim(p_reason), p_batch, false, p_client_ref, now(), false);
  perform app.audit(p_business, 'stock.adjusted', 'product', p_product::text,
    jsonb_build_object('kind', p_kind, 'quantity', signed, 'reason', p_reason, 'value', mv.value));
  return mv.id;
end $$;

create or replace function public.create_stock_count(
  p_business uuid, p_product_ids uuid[] default null, p_category uuid default null, p_notes text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; n int;
begin
  perform app.require_perm(p_business, 'stock.adjust');
  insert into public.stock_counts (business_id, number, scope, notes, created_by)
  values (p_business, app.next_number(p_business, 'count', 'CNT-'),
          case when p_product_ids is not null then 'selected'
               when p_category is not null then 'category' else 'all' end,
          p_notes, auth.uid())
  returning id into cid;
  insert into public.stock_count_lines (count_id, business_id, product_id, expected_qty)
  select cid, p_business, p.id, p.qty_on_hand from public.products p
  where p.business_id = p_business and p.status = 'active'
    and (p_product_ids is null or p.id = any (p_product_ids))
    and (p_category is null or p.category_id = p_category);
  get diagnostics n = row_count;
  if n = 0 then perform app.raise('no_products_selected'); end if;
  perform app.audit(p_business, 'stock_count.created', 'stock_count', cid::text, jsonb_build_object('lines', n));
  return cid;
end $$;

create or replace function public.save_stock_count_lines(p_count uuid, p_lines jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare c public.stock_counts; l jsonb;
begin
  select * into c from public.stock_counts where id = p_count;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(c.business_id, 'stock.adjust');
  if c.status <> 'draft' then perform app.raise('count_not_editable'); end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    if (l ->> 'counted_qty') is not null and (l ->> 'counted_qty')::numeric < 0 then
      perform app.raise('invalid_quantity');
    end if;
    update public.stock_count_lines
       set counted_qty = (l ->> 'counted_qty')::numeric, reason = nullif(l ->> 'reason', '')
     where count_id = p_count and product_id = (l ->> 'product_id')::uuid;
  end loop;
end $$;

create or replace function public.complete_stock_count(p_count uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.stock_counts; l record; diff numeric; mv public.stock_movements; total numeric := 0; adjusted int := 0;
begin
  select * into c from public.stock_counts where id = p_count for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(c.business_id, 'stock.adjust');
  if c.status <> 'draft' then perform app.raise('count_not_editable'); end if;
  for l in select cl.*, p.qty_on_hand from public.stock_count_lines cl
           join public.products p on p.id = cl.product_id
           where cl.count_id = p_count and cl.counted_qty is not null
           order by cl.product_id loop
    diff := l.counted_qty - l.qty_on_hand;
    if diff <> 0 and coalesce(btrim(l.reason), '') = '' then
      perform app.raise('reason_required_for_discrepancy');
    end if;
    update public.stock_count_lines set system_qty_at_completion = l.qty_on_hand, difference = diff
     where id = l.id;
    if diff <> 0 then
      if diff < 0 then perform app.consume_batches(l.product_id, -diff); end if;
      mv := app.apply_movement(c.business_id, l.product_id, 'count', diff, null, 'stock_count', c.id, c.number,
        l.reason, null, false, null, now(), true);
      update public.stock_count_lines set value_difference = mv.value where id = l.id;
      total := total + mv.value;
      adjusted := adjusted + 1;
    end if;
  end loop;
  update public.stock_counts set status = 'completed', completed_by = auth.uid(), completed_at = now(),
         adjustment_value = total where id = p_count;
  perform app.audit(c.business_id, 'stock_count.completed', 'stock_count', p_count::text,
    jsonb_build_object('adjusted_lines', adjusted, 'value', total));
  return jsonb_build_object('adjusted_lines', adjusted, 'value_difference', total);
end $$;

create or replace function public.cancel_stock_count(p_count uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c public.stock_counts;
begin
  select * into c from public.stock_counts where id = p_count for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(c.business_id, 'stock.adjust');
  if c.status <> 'draft' then perform app.raise('count_not_editable'); end if;
  update public.stock_counts set status = 'cancelled' where id = p_count;
  perform app.audit(c.business_id, 'stock_count.cancelled', 'stock_count', p_count::text);
end $$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.categories enable row level security;
alter table public.import_batches enable row level security;
alter table public.suppliers enable row level security;
alter table public.products enable row level security;
alter table public.product_units enable row level security;
alter table public.product_price_history enable row level security;
alter table public.stock_batches enable row level security;
alter table public.stock_movements enable row level security;
alter table public.stock_counts enable row level security;
alter table public.stock_count_lines enable row level security;
alter table public.attachments enable row level security;

create policy categories_read on public.categories for select using (app.can_read(business_id));
create policy categories_write on public.categories for insert with check (app.has_perm(business_id, 'products.manage'));
create policy categories_update on public.categories for update using (app.has_perm(business_id, 'products.manage'))
  with check (app.has_perm(business_id, 'products.manage'));
create policy categories_delete on public.categories for delete using (app.has_perm(business_id, 'products.manage'));

create policy import_batches_read on public.import_batches for select using (app.has_perm(business_id, 'imports.manage'));

create policy suppliers_read on public.suppliers for select using (app.can_read(business_id));
create policy suppliers_insert on public.suppliers for insert with check (
  app.has_perm(business_id, 'suppliers.manage') and app.has_feature(business_id, 'suppliers'));
create policy suppliers_update on public.suppliers for update using (app.has_perm(business_id, 'suppliers.manage'))
  with check (app.has_perm(business_id, 'suppliers.manage'));

create policy products_read on public.products for select using (app.can_read(business_id));
create policy products_insert on public.products for insert with check (app.has_perm(business_id, 'products.manage'));
create policy products_update on public.products for update using (app.has_perm(business_id, 'products.manage'))
  with check (app.has_perm(business_id, 'products.manage'));

create policy product_units_read on public.product_units for select using (app.can_read(business_id));
create policy product_units_insert on public.product_units for insert with check (app.has_perm(business_id, 'products.manage'));
create policy product_units_update on public.product_units for update using (app.has_perm(business_id, 'products.manage'))
  with check (app.has_perm(business_id, 'products.manage'));

create policy price_history_read on public.product_price_history for select using (app.has_perm(business_id, 'products.manage'));
create policy batches_read on public.stock_batches for select using (app.can_read(business_id));
create policy movements_read on public.stock_movements for select
  using (app.can_read(business_id) and occurred_at >= app.history_cutoff(business_id));
create policy counts_read on public.stock_counts for select using (app.can_read(business_id));
create policy count_lines_read on public.stock_count_lines for select using (app.can_read(business_id));

create policy attachments_read on public.attachments for select using (app.can_read(business_id));
create policy attachments_insert on public.attachments for insert with check (
  app.is_member(business_id) and uploaded_by = auth.uid()
  and split_part(path, '/', 1) = business_id::text);

-- ===== 20261022000300_money_purchases.sql =====
-- Customers, money accounts, payments, wholesale purchasing and supplier balances.
--
-- Supplier balance (amount the business owes a supplier):
--     sum(total of purchases in status ordered / partially_received / received)
--   - sum(supplier credits: returns, short shipments, adjustments)
--   - sum(supplier payments) + sum(supplier refunds received)
-- Draft and cancelled purchases create no obligation. Allocations of payments to
-- individual purchases are derived deterministically (targeted purchase first,
-- then oldest outstanding purchase first) by app.rebalance_supplier().

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 120),
  phone text,
  email text,
  address text,
  credit_limit numeric(14, 2) check (credit_limit >= 0),
  notes text,
  status text not null default 'active' check (status in ('active', 'archived')),
  import_batch_id uuid references public.import_batches (id) on delete set null,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index customers_business on public.customers (business_id, name);
create trigger customers_touch before update on public.customers
  for each row execute function app.touch_updated_at();

create table public.cash_accounts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null,
  kind text not null check (kind in ('cash', 'mtn_momo', 'orange_money', 'bank', 'other')),
  opening_balance numeric(14, 2) not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (business_id, kind)
);

create or replace function app.init_accounts(bid uuid) returns void
language sql security definer set search_path = public as $$
  insert into public.cash_accounts (business_id, name, kind) values
    (bid, 'Cash', 'cash'), (bid, 'MTN Mobile Money', 'mtn_momo'), (bid, 'Orange Money', 'orange_money'),
    (bid, 'Bank', 'bank'), (bid, 'Other', 'other')
  on conflict do nothing
$$;

create or replace function app.account_for_method(bid uuid, m text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare k text; aid uuid;
begin
  if m not in ('cash', 'mtn_momo', 'orange_money', 'bank_transfer', 'card', 'other') then
    perform app.raise('invalid_payment_method');
  end if;
  k := case m when 'bank_transfer' then 'bank' when 'card' then 'bank' else m end;
  select id into aid from public.cash_accounts where business_id = bid and kind = k;
  return aid;
end $$;

create table public.purchases (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  number text not null,
  client_ref uuid,
  supplier_id uuid not null references public.suppliers (id),
  invoice_number text,
  purchase_date date not null,
  expected_date date,
  due_date date,
  status text not null default 'draft' check (status in ('draft', 'ordered', 'partially_received', 'received', 'cancelled')),
  subtotal numeric(14, 2) not null default 0,
  discount_amount numeric(14, 2) not null default 0 check (discount_amount >= 0),
  tax_total numeric(14, 2) not null default 0,
  transport_cost numeric(14, 2) not null default 0 check (transport_cost >= 0),
  other_costs numeric(14, 2) not null default 0 check (other_costs >= 0),
  total numeric(14, 2) not null default 0 check (total >= 0),
  received_value numeric(18, 4) not null default 0,
  credited_total numeric(14, 2) not null default 0,
  paid_total numeric(14, 2) not null default 0,
  closed_short boolean not null default false,
  notes text,
  first_received_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index purchases_client_ref on public.purchases (business_id, client_ref) where client_ref is not null;
create unique index purchases_number on public.purchases (business_id, number);
create index purchases_business_date on public.purchases (business_id, purchase_date desc);
create index purchases_supplier on public.purchases (supplier_id, purchase_date);
create trigger purchases_touch before update on public.purchases
  for each row execute function app.touch_updated_at();

create table public.purchase_lines (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.purchases (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id),
  unit_id uuid references public.product_units (id),
  unit_name text not null,
  unit_factor numeric(14, 4) not null check (unit_factor > 0),
  qty_ordered numeric(14, 3) not null check (qty_ordered > 0),
  qty_received numeric(14, 3) not null default 0 check (qty_received >= 0),
  qty_returned numeric(14, 3) not null default 0 check (qty_returned >= 0),   -- base units
  unit_cost numeric(14, 2) not null check (unit_cost >= 0),                   -- per purchase unit
  discount_amount numeric(14, 2) not null default 0 check (discount_amount >= 0),
  tax_amount numeric(14, 2) not null default 0 check (tax_amount >= 0),
  line_total numeric(14, 2) not null check (line_total >= 0),
  landed_unit_cost_base numeric(18, 4),   -- fixed at first receipt, includes allocated transport/other costs
  sort int not null default 0,
  check (qty_received <= qty_ordered)
);
create index purchase_lines_purchase on public.purchase_lines (purchase_id);
create index purchase_lines_product on public.purchase_lines (product_id);

create table public.purchase_receipts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  purchase_id uuid not null references public.purchases (id),
  number text not null,
  received_at timestamptz not null default now(),
  received_by uuid,
  notes text,
  value numeric(18, 4) not null default 0,
  client_ref uuid
);
create unique index purchase_receipts_client_ref on public.purchase_receipts (business_id, client_ref) where client_ref is not null;
create index purchase_receipts_purchase on public.purchase_receipts (purchase_id);

create table public.purchase_receipt_lines (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references public.purchase_receipts (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  purchase_line_id uuid not null references public.purchase_lines (id),
  product_id uuid not null references public.products (id),
  quantity numeric(14, 3) not null check (quantity > 0),   -- purchase units
  base_quantity numeric(14, 3) not null,
  unit_cost_base numeric(18, 4) not null,
  value numeric(18, 4) not null,
  batch_id uuid references public.stock_batches (id),
  movement_id uuid references public.stock_movements (id)
);

create table public.supplier_credits (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  supplier_id uuid not null references public.suppliers (id),
  purchase_id uuid references public.purchases (id),
  kind text not null check (kind in ('return', 'short_shipment', 'adjustment')),
  amount numeric(14, 2) not null check (amount > 0),
  reason text not null,
  reference_id uuid,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index supplier_credits_supplier on public.supplier_credits (supplier_id);

create table public.supplier_returns (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  number text not null,
  purchase_id uuid not null references public.purchases (id),
  supplier_id uuid not null references public.suppliers (id),
  reason text not null,
  credit_amount numeric(14, 2) not null,
  stock_value numeric(18, 4) not null,
  client_ref uuid,
  created_by uuid,
  created_at timestamptz not null default now()
);
create unique index supplier_returns_client_ref on public.supplier_returns (business_id, client_ref) where client_ref is not null;

create table public.supplier_return_lines (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references public.supplier_returns (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  purchase_line_id uuid not null references public.purchase_lines (id),
  product_id uuid not null references public.products (id),
  base_quantity numeric(14, 3) not null check (base_quantity > 0),
  credit_amount numeric(14, 2) not null,
  stock_value numeric(18, 4) not null
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  direction text not null check (direction in ('in', 'out')),
  kind text not null check (kind in ('sale_payment', 'customer_payment', 'customer_refund',
                                     'supplier_payment', 'supplier_refund', 'expense_payment', 'expense_refund')),
  method text not null check (method in ('cash', 'mtn_momo', 'orange_money', 'bank_transfer', 'card', 'other')),
  account_id uuid references public.cash_accounts (id),
  amount numeric(14, 2) not null check (amount > 0),
  customer_id uuid references public.customers (id),
  supplier_id uuid references public.suppliers (id),
  sale_id uuid,
  sale_return_id uuid,
  purchase_id uuid references public.purchases (id),
  expense_id uuid,
  reference text,
  notes text,
  paid_at timestamptz not null default now(),
  client_ref uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  check ((direction = 'in') = (kind in ('sale_payment', 'customer_payment', 'supplier_refund', 'expense_refund')))
);
create unique index payments_client_ref on public.payments (business_id, client_ref) where client_ref is not null;
create index payments_business_date on public.payments (business_id, paid_at desc);
create index payments_customer on public.payments (customer_id) where customer_id is not null;
create index payments_supplier on public.payments (supplier_id) where supplier_id is not null;
create index payments_sale on public.payments (sale_id) where sale_id is not null;

create table public.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  payment_id uuid not null references public.payments (id) on delete cascade,
  sale_id uuid,
  purchase_id uuid references public.purchases (id),
  expense_id uuid,
  amount numeric(14, 2) not null check (amount > 0),
  created_at timestamptz not null default now(),
  check (num_nonnulls(sale_id, purchase_id, expense_id) = 1)
);
create index payment_allocations_payment on public.payment_allocations (payment_id);
create index payment_allocations_purchase on public.payment_allocations (purchase_id) where purchase_id is not null;
create index payment_allocations_sale on public.payment_allocations (sale_id) where sale_id is not null;

-- ---------------------------------------------------------------------------
-- Supplier balances & allocations
-- ---------------------------------------------------------------------------
create or replace function app.supplier_balance(p_supplier uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(total) from public.purchases where supplier_id = p_supplier
                     and status in ('ordered', 'partially_received', 'received')), 0)
       - coalesce((select sum(amount) from public.supplier_credits where supplier_id = p_supplier), 0)
       - coalesce((select sum(amount) from public.payments where supplier_id = p_supplier and kind = 'supplier_payment'), 0)
       + coalesce((select sum(amount) from public.payments where supplier_id = p_supplier and kind = 'supplier_refund'), 0)
$$;

create or replace function app.rebalance_supplier(p_supplier uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  pay record; pur record; refunds numeric; avail numeric; take numeric; outstanding numeric;
begin
  delete from public.payment_allocations a using public.payments p
   where a.payment_id = p.id and p.supplier_id = p_supplier and p.kind = 'supplier_payment';

  create temp table if not exists _avail (payment_id uuid primary key, purchase_id uuid, paid_at timestamptz, amount numeric) on commit drop;
  delete from _avail where true;
  insert into _avail select id, purchase_id, paid_at, amount from public.payments
   where supplier_id = p_supplier and kind = 'supplier_payment';

  -- Refunds received from the supplier reduce the most recent payments first.
  select coalesce(sum(amount), 0) into refunds from public.payments
   where supplier_id = p_supplier and kind = 'supplier_refund';
  for pay in select * from _avail order by paid_at desc, payment_id loop
    exit when refunds <= 0;
    take := least(pay.amount, refunds);
    update _avail set amount = amount - take where payment_id = pay.payment_id;
    refunds := refunds - take;
  end loop;

  create temp table if not exists _owed (purchase_id uuid primary key, pdate date, created timestamptz, owed numeric) on commit drop;
  delete from _owed where true;
  insert into _owed select id, purchase_date, created_at, total - credited_total
    from public.purchases where supplier_id = p_supplier
     and status in ('ordered', 'partially_received', 'received') and total - credited_total > 0;

  -- Pass 1: payments explicitly made for a purchase.
  for pay in select * from _avail where purchase_id is not null and amount > 0 order by paid_at, payment_id loop
    select owed into outstanding from _owed where purchase_id = pay.purchase_id;
    if coalesce(outstanding, 0) > 0 then
      take := least(pay.amount, outstanding);
      insert into public.payment_allocations (business_id, payment_id, purchase_id, amount)
      select business_id, pay.payment_id, pay.purchase_id, take from public.payments where id = pay.payment_id;
      update _owed set owed = owed - take where purchase_id = pay.purchase_id;
      update _avail set amount = amount - take where payment_id = pay.payment_id;
    end if;
  end loop;

  -- Pass 2: oldest outstanding purchase first.
  for pay in select * from _avail where amount > 0 order by paid_at, payment_id loop
    avail := pay.amount;
    for pur in select * from _owed where owed > 0 order by pdate, created, purchase_id loop
      exit when avail <= 0;
      take := least(avail, pur.owed);
      insert into public.payment_allocations (business_id, payment_id, purchase_id, amount)
      select business_id, pay.payment_id, pur.purchase_id, take from public.payments where id = pay.payment_id;
      update _owed set owed = owed - take where purchase_id = pur.purchase_id;
      avail := avail - take;
    end loop;
  end loop;

  update public.purchases pu set paid_total = coalesce((
      select sum(a.amount) from public.payment_allocations a where a.purchase_id = pu.id), 0)
   where pu.supplier_id = p_supplier;
end $$;

-- ---------------------------------------------------------------------------
-- Purchases
-- ---------------------------------------------------------------------------
create or replace function app.purchase_feature_check(bid uuid) returns void
language plpgsql stable as $$
begin
  perform app.require_perm(bid, 'purchases.manage');
  perform app.require_feature(bid, 'purchases');
end $$;

create or replace function app.insert_payment(
  p_business uuid, p_kind text, p_method text, p_amount numeric, p_paid_at timestamptz,
  p_reference text, p_notes text, p_client_ref uuid,
  p_customer uuid default null, p_supplier uuid default null, p_sale uuid default null,
  p_purchase uuid default null, p_expense uuid default null, p_return uuid default null)
returns public.payments language plpgsql security definer set search_path = public as $$
declare r public.payments;
begin
  if p_amount is null or p_amount <= 0 then perform app.raise('invalid_amount'); end if;
  insert into public.payments (business_id, direction, kind, method, account_id, amount, customer_id, supplier_id,
    sale_id, purchase_id, expense_id, sale_return_id, reference, notes, paid_at, client_ref, created_by)
  values (p_business,
    case when p_kind in ('sale_payment', 'customer_payment', 'supplier_refund', 'expense_refund') then 'in' else 'out' end,
    p_kind, p_method, app.account_for_method(p_business, p_method), app.money(p_business, p_amount),
    p_customer, p_supplier, p_sale, p_purchase, p_expense, p_return,
    nullif(btrim(coalesce(p_reference, '')), ''), p_notes, coalesce(p_paid_at, now()), p_client_ref, auth.uid())
  returning * into r;
  return r;
end $$;

create or replace function public.save_purchase(p_business uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  pid uuid := nullif(p ->> 'id', '')::uuid;
  cref uuid := nullif(p ->> 'client_ref', '')::uuid;
  cur public.purchases;
  sup public.suppliers;
  l jsonb; u record; i int := 0;
  v_qty numeric; v_cost numeric; v_disc numeric; v_tax numeric; v_total numeric;
  sub numeric := 0; taxes numeric := 0; hdr_disc numeric; transport numeric; other numeric; grand numeric;
  st text := coalesce(p ->> 'status', 'draft');
  pdate date := coalesce(nullif(p ->> 'purchase_date', '')::date, app.biz_today(p_business));
  due date := nullif(p ->> 'due_date', '')::date;
begin
  perform app.purchase_feature_check(p_business);
  if st not in ('draft', 'ordered') then perform app.raise('invalid_status'); end if;

  if pid is null and cref is not null then
    select id into pid from public.purchases where business_id = p_business and client_ref = cref;
    if found then return pid; end if;   -- idempotent retry
  end if;

  select * into sup from public.suppliers where id = (p ->> 'supplier_id')::uuid and business_id = p_business;
  if not found then perform app.raise('invalid_supplier'); end if;
  if jsonb_typeof(p -> 'lines') <> 'array' or jsonb_array_length(p -> 'lines') = 0 then
    perform app.raise('lines_required');
  end if;

  hdr_disc := coalesce((p ->> 'discount_amount')::numeric, 0);
  transport := coalesce((p ->> 'transport_cost')::numeric, 0);
  other := coalesce((p ->> 'other_costs')::numeric, 0);
  if hdr_disc < 0 or transport < 0 or other < 0 then perform app.raise('invalid_amount'); end if;
  if due is null and sup.payment_terms_days is not null then due := pdate + sup.payment_terms_days; end if;

  if pid is not null then
    select * into cur from public.purchases where id = pid and business_id = p_business for update;
    if not found then perform app.raise('not_found'); end if;
    if cur.status not in ('draft', 'ordered') or exists (
         select 1 from public.purchase_lines where purchase_id = pid and qty_received > 0) then
      perform app.raise('purchase_locked');
    end if;
    delete from public.purchase_lines where purchase_id = pid;
    update public.purchases set supplier_id = sup.id, invoice_number = nullif(p ->> 'invoice_number', ''),
      purchase_date = pdate, expected_date = nullif(p ->> 'expected_date', '')::date, due_date = due,
      status = st, discount_amount = hdr_disc, transport_cost = transport, other_costs = other,
      notes = nullif(p ->> 'notes', '')
     where id = pid;
  else
    insert into public.purchases (business_id, number, client_ref, supplier_id, invoice_number, purchase_date,
      expected_date, due_date, status, discount_amount, transport_cost, other_costs, notes, created_by)
    values (p_business, app.next_number(p_business, 'purchase', 'PO-'), cref, sup.id,
      nullif(p ->> 'invoice_number', ''), pdate, nullif(p ->> 'expected_date', '')::date, due, st,
      hdr_disc, transport, other, nullif(p ->> 'notes', ''), auth.uid())
    returning id into pid;
  end if;

  for l in select * from jsonb_array_elements(p -> 'lines') loop
    i := i + 1;
    if not exists (select 1 from public.products where id = (l ->> 'product_id')::uuid and business_id = p_business) then
      perform app.raise('invalid_product');
    end if;
    select * into u from app.resolve_unit((l ->> 'product_id')::uuid, nullif(l ->> 'unit_id', '')::uuid);
    v_qty := (l ->> 'quantity')::numeric;
    v_cost := coalesce((l ->> 'unit_cost')::numeric, 0);
    v_disc := coalesce((l ->> 'discount_amount')::numeric, 0);
    v_tax := coalesce((l ->> 'tax_amount')::numeric, 0);
    if v_qty is null or v_qty <= 0 then perform app.raise('invalid_quantity'); end if;
    if v_cost < 0 or v_disc < 0 or v_tax < 0 then perform app.raise('invalid_amount'); end if;
    v_total := app.money(p_business, v_qty * v_cost - v_disc + v_tax);
    if v_total < 0 then perform app.raise('discount_exceeds_line'); end if;
    insert into public.purchase_lines (purchase_id, business_id, product_id, unit_id, unit_name, unit_factor,
      qty_ordered, unit_cost, discount_amount, tax_amount, line_total, sort)
    values (pid, p_business, (l ->> 'product_id')::uuid, u.unit_id, u.unit_name, u.factor,
      v_qty, v_cost, v_disc, v_tax, v_total, i);
    sub := sub + v_total;
    taxes := taxes + v_tax;
  end loop;

  grand := sub + transport + other - hdr_disc;
  if grand < 0 then perform app.raise('discount_exceeds_total'); end if;
  update public.purchases set subtotal = sub, tax_total = taxes, total = grand where id = pid;

  perform app.audit(p_business, case when cur.id is null then 'purchase.created' else 'purchase.updated' end,
    'purchase', pid::text, jsonb_build_object('status', st, 'total', grand));

  -- Optional immediate payment (only once the purchase is an obligation).
  if st = 'ordered' and coalesce((p #>> '{payment,amount}')::numeric, 0) > 0 then
    perform public.record_supplier_payment(p_business, sup.id, (p #>> '{payment,amount}')::numeric,
      coalesce(p #>> '{payment,method}', 'cash'), p #>> '{payment,reference}', null, pid, null,
      nullif(p #>> '{payment,client_ref}', '')::uuid);
  end if;

  -- One-step "bought and received": receive every line in full.
  if coalesce((p ->> 'receive_now')::boolean, false) then
    if st <> 'ordered' then perform app.raise('invalid_status'); end if;
    perform public.receive_purchase(pid, (
      select jsonb_agg(jsonb_build_object('line_id', pl.id, 'quantity', pl.qty_ordered,
                                          'batch_code', ln ->> 'batch_code', 'expiry_date', ln ->> 'expiry_date'))
      from public.purchase_lines pl
      left join lateral (select x as ln from jsonb_array_elements(p -> 'lines') with ordinality t(x, n)
                         where n = pl.sort) q on true
      where pl.purchase_id = pid), null, null);
  end if;

  perform app.rebalance_supplier(sup.id);
  return pid;
end $$;

create or replace function public.mark_purchase_ordered(p_purchase uuid)
returns void language plpgsql security definer set search_path = public as $$
declare pu public.purchases;
begin
  select * into pu from public.purchases where id = p_purchase for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.purchase_feature_check(pu.business_id);
  if pu.status <> 'draft' then perform app.raise('invalid_status'); end if;
  update public.purchases set status = 'ordered' where id = p_purchase;
  perform app.audit(pu.business_id, 'purchase.ordered', 'purchase', p_purchase::text);
  perform app.rebalance_supplier(pu.supplier_id);
end $$;

create or replace function public.receive_purchase(
  p_purchase uuid, p_lines jsonb, p_client_ref uuid default null, p_notes text default null,
  p_received_at timestamptz default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  pu public.purchases; pl public.purchase_lines; pr public.products;
  rid uuid; l jsonb; f numeric; qty numeric; base numeric; landed numeric; batch uuid; mv public.stock_movements;
  total_value numeric := 0; at timestamptz := coalesce(p_received_at, now());
begin
  select * into pu from public.purchases where id = p_purchase for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.purchase_feature_check(pu.business_id);

  if p_client_ref is not null then
    select id into rid from public.purchase_receipts where business_id = pu.business_id and client_ref = p_client_ref;
    if found then return rid; end if;
  end if;
  if pu.status not in ('draft', 'ordered', 'partially_received') then perform app.raise('invalid_status'); end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then perform app.raise('lines_required'); end if;

  -- Directly attributable costs (transport, other) less header discount, spread by line value.
  f := case when pu.subtotal > 0 then (pu.transport_cost + pu.other_costs - pu.discount_amount) / pu.subtotal else 0 end;

  insert into public.purchase_receipts (business_id, purchase_id, number, received_at, received_by, notes, client_ref)
  values (pu.business_id, pu.id, app.next_number(pu.business_id, 'receipt', 'GRN-'), at, auth.uid(), p_notes, p_client_ref)
  returning id into rid;

  for l in select * from jsonb_array_elements(p_lines) order by (value ->> 'line_id') loop
    qty := coalesce((l ->> 'quantity')::numeric, 0);
    continue when qty = 0;
    if qty < 0 then perform app.raise('invalid_quantity'); end if;
    select * into pl from public.purchase_lines where id = (l ->> 'line_id')::uuid and purchase_id = pu.id for update;
    if not found then perform app.raise('invalid_line'); end if;
    if pl.qty_received + qty > pl.qty_ordered then
      perform app.raise('over_receipt', jsonb_build_object('ordered', pl.qty_ordered, 'received', pl.qty_received,
                                                            'requested', qty));
    end if;
    landed := coalesce(pl.landed_unit_cost_base,
                       round(pl.line_total * (1 + f) / (pl.qty_ordered * pl.unit_factor), 4));
    base := qty * pl.unit_factor;
    select * into pr from public.products where id = pl.product_id;
    batch := null;
    if pr.track_expiry then
      insert into public.stock_batches (business_id, product_id, batch_code, expiry_date, received_qty, remaining_qty,
                                        supplier_id, purchase_id)
      values (pu.business_id, pl.product_id, nullif(l ->> 'batch_code', ''), nullif(l ->> 'expiry_date', '')::date,
              base, base, pu.supplier_id, pu.id)
      returning id into batch;
    end if;
    mv := app.apply_movement(pu.business_id, pl.product_id, 'purchase_receipt', base, landed, 'purchase', pu.id,
                             pu.number, null, batch, false, null, at);
    insert into public.purchase_receipt_lines (receipt_id, business_id, purchase_line_id, product_id, quantity,
      base_quantity, unit_cost_base, value, batch_id, movement_id)
    values (rid, pu.business_id, pl.id, pl.product_id, qty, base, landed, mv.value, batch, mv.id);
    update public.purchase_lines set qty_received = qty_received + qty, landed_unit_cost_base = landed where id = pl.id;
    update public.products set purchase_cost = landed,
           preferred_supplier_id = coalesce(preferred_supplier_id, pu.supplier_id)
     where id = pl.product_id;
    total_value := total_value + mv.value;
  end loop;

  if total_value = 0 and not exists (select 1 from public.purchase_receipt_lines where receipt_id = rid) then
    perform app.raise('nothing_to_receive');
  end if;

  update public.purchase_receipts set value = total_value where id = rid;
  update public.purchases set
    received_value = received_value + total_value,
    first_received_at = coalesce(first_received_at, at),
    status = case when exists (select 1 from public.purchase_lines where purchase_id = pu.id and qty_received < qty_ordered)
                  then 'partially_received' else 'received' end
   where id = pu.id;
  perform app.audit(pu.business_id, 'purchase.received', 'purchase', pu.id::text,
                    jsonb_build_object('receipt_id', rid, 'value', total_value));
  if pu.status = 'draft' then perform app.rebalance_supplier(pu.supplier_id); end if;
  return rid;
end $$;

create or replace function public.cancel_purchase(p_purchase uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare pu public.purchases;
begin
  select * into pu from public.purchases where id = p_purchase for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.purchase_feature_check(pu.business_id);
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  if pu.status not in ('draft', 'ordered') or exists (
      select 1 from public.purchase_lines where purchase_id = pu.id and qty_received > 0) then
    -- Goods already received: use close-short and supplier returns instead.
    perform app.raise('purchase_has_receipts');
  end if;
  update public.purchases set status = 'cancelled', cancelled_at = now(), cancel_reason = btrim(p_reason)
   where id = pu.id;
  perform app.audit(pu.business_id, 'purchase.cancelled', 'purchase', pu.id::text,
                    jsonb_build_object('reason', p_reason, 'total', pu.total, 'paid', pu.paid_total));
  perform app.rebalance_supplier(pu.supplier_id);   -- payments become a supplier advance
end $$;

create or replace function public.close_purchase_short(p_purchase uuid, p_reason text)
returns numeric language plpgsql security definer set search_path = public as $$
declare pu public.purchases; f numeric; credit numeric;
begin
  select * into pu from public.purchases where id = p_purchase for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.purchase_feature_check(pu.business_id);
  if pu.status <> 'partially_received' then perform app.raise('invalid_status'); end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  f := case when pu.subtotal > 0 then (pu.transport_cost + pu.other_costs - pu.discount_amount) / pu.subtotal else 0 end;
  select app.money(pu.business_id, sum((qty_ordered - qty_received) / qty_ordered * line_total * (1 + f)))
    into credit from public.purchase_lines where purchase_id = pu.id;
  if credit > 0 then
    insert into public.supplier_credits (business_id, supplier_id, purchase_id, kind, amount, reason, created_by)
    values (pu.business_id, pu.supplier_id, pu.id, 'short_shipment', credit, btrim(p_reason), auth.uid());
  end if;
  update public.purchases set status = 'received', closed_short = true,
         credited_total = credited_total + coalesce(credit, 0) where id = pu.id;
  perform app.audit(pu.business_id, 'purchase.closed_short', 'purchase', pu.id::text,
                    jsonb_build_object('credit', credit, 'reason', p_reason));
  perform app.rebalance_supplier(pu.supplier_id);
  return coalesce(credit, 0);
end $$;

create or replace function public.return_to_supplier(p_purchase uuid, p_lines jsonb, p_reason text, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
-- p_lines: [{line_id, base_quantity}]. Stock leaves at current average cost (WAC);
-- the supplier credit is valued at the purchase line's landed cost.
declare pu public.purchases; pl public.purchase_lines; rid uuid; l jsonb; q numeric; credit numeric;
        tot_credit numeric := 0; tot_value numeric := 0; mv public.stock_movements; num text;
begin
  select * into pu from public.purchases where id = p_purchase for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.purchase_feature_check(pu.business_id);
  if p_client_ref is not null then
    select id into rid from public.supplier_returns where business_id = pu.business_id and client_ref = p_client_ref;
    if found then return rid; end if;
  end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  num := app.next_number(pu.business_id, 'supplier_return', 'SR-');
  insert into public.supplier_returns (business_id, number, purchase_id, supplier_id, reason, credit_amount, stock_value,
                                       client_ref, created_by)
  values (pu.business_id, num, pu.id, pu.supplier_id, btrim(p_reason), 0, 0, p_client_ref, auth.uid())
  returning id into rid;
  for l in select * from jsonb_array_elements(p_lines) loop
    q := coalesce((l ->> 'base_quantity')::numeric, 0);
    continue when q = 0;
    if q < 0 then perform app.raise('invalid_quantity'); end if;
    select * into pl from public.purchase_lines where id = (l ->> 'line_id')::uuid and purchase_id = pu.id for update;
    if not found then perform app.raise('invalid_line'); end if;
    if pl.qty_returned + q > pl.qty_received * pl.unit_factor then perform app.raise('return_exceeds_received'); end if;
    perform app.consume_batches(pl.product_id, q);
    mv := app.apply_movement(pu.business_id, pl.product_id, 'supplier_return', -q, null, 'supplier_return', rid, num,
                             p_reason);
    credit := app.money(pu.business_id, q * pl.landed_unit_cost_base);
    insert into public.supplier_return_lines (return_id, business_id, purchase_line_id, product_id, base_quantity,
                                              credit_amount, stock_value)
    values (rid, pu.business_id, pl.id, pl.product_id, q, credit, -mv.value);
    update public.purchase_lines set qty_returned = qty_returned + q where id = pl.id;
    tot_credit := tot_credit + credit;
    tot_value := tot_value - mv.value;
  end loop;
  if tot_credit = 0 and tot_value = 0 then perform app.raise('lines_required'); end if;
  update public.supplier_returns set credit_amount = tot_credit, stock_value = tot_value where id = rid;
  if tot_credit > 0 then
    insert into public.supplier_credits (business_id, supplier_id, purchase_id, kind, amount, reason, reference_id, created_by)
    values (pu.business_id, pu.supplier_id, pu.id, 'return', tot_credit, btrim(p_reason), rid, auth.uid());
    update public.purchases set credited_total = credited_total + tot_credit where id = pu.id;
  end if;
  perform app.audit(pu.business_id, 'purchase.returned', 'purchase', pu.id::text,
                    jsonb_build_object('return_id', rid, 'credit', tot_credit, 'stock_value', tot_value));
  perform app.rebalance_supplier(pu.supplier_id);
  return rid;
end $$;

create or replace function public.record_supplier_payment(
  p_business uuid, p_supplier uuid, p_amount numeric, p_method text, p_reference text default null,
  p_paid_at timestamptz default null, p_purchase uuid default null, p_notes text default null,
  p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.payments; existing uuid;
begin
  perform app.purchase_feature_check(p_business);
  if p_client_ref is not null then
    select id into existing from public.payments where business_id = p_business and client_ref = p_client_ref;
    if found then return existing; end if;
  end if;
  if not exists (select 1 from public.suppliers where id = p_supplier and business_id = p_business) then
    perform app.raise('invalid_supplier');
  end if;
  if p_purchase is not null and not exists (
      select 1 from public.purchases where id = p_purchase and supplier_id = p_supplier) then
    perform app.raise('invalid_purchase');
  end if;
  r := app.insert_payment(p_business, 'supplier_payment', p_method, p_amount, p_paid_at, p_reference, p_notes,
                          p_client_ref, null, p_supplier, null, p_purchase);
  perform app.audit(p_business, 'supplier.payment', 'supplier', p_supplier::text,
                    jsonb_build_object('payment_id', r.id, 'amount', r.amount, 'method', p_method));
  perform app.rebalance_supplier(p_supplier);
  return r.id;
end $$;

create or replace function public.record_supplier_refund(
  p_business uuid, p_supplier uuid, p_amount numeric, p_method text, p_reference text default null,
  p_notes text default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.payments; existing uuid;
begin
  perform app.purchase_feature_check(p_business);
  if p_client_ref is not null then
    select id into existing from public.payments where business_id = p_business and client_ref = p_client_ref;
    if found then return existing; end if;
  end if;
  if not exists (select 1 from public.suppliers where id = p_supplier and business_id = p_business) then
    perform app.raise('invalid_supplier');
  end if;
  -- Only money the supplier actually owes back (a credit balance) can be refunded.
  if app.supplier_balance(p_supplier) + p_amount > 0 then perform app.raise('refund_exceeds_credit'); end if;
  r := app.insert_payment(p_business, 'supplier_refund', p_method, p_amount, null, p_reference, p_notes,
                          p_client_ref, null, p_supplier);
  perform app.audit(p_business, 'supplier.refund', 'supplier', p_supplier::text,
                    jsonb_build_object('payment_id', r.id, 'amount', r.amount));
  perform app.rebalance_supplier(p_supplier);
  return r.id;
end $$;

create or replace function public.record_supplier_credit(
  p_business uuid, p_supplier uuid, p_amount numeric, p_reason text, p_purchase uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  perform app.purchase_feature_check(p_business);
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  if p_amount is null or p_amount <= 0 then perform app.raise('invalid_amount'); end if;
  if not exists (select 1 from public.suppliers where id = p_supplier and business_id = p_business) then
    perform app.raise('invalid_supplier');
  end if;
  if p_purchase is not null and not exists (select 1 from public.purchases where id = p_purchase and supplier_id = p_supplier) then
    perform app.raise('invalid_purchase');
  end if;
  insert into public.supplier_credits (business_id, supplier_id, purchase_id, kind, amount, reason, created_by)
  values (p_business, p_supplier, p_purchase, 'adjustment', app.money(p_business, p_amount), btrim(p_reason), auth.uid())
  returning id into cid;
  if p_purchase is not null then
    update public.purchases set credited_total = credited_total + app.money(p_business, p_amount) where id = p_purchase;
  end if;
  perform app.audit(p_business, 'supplier.credit', 'supplier', p_supplier::text,
                    jsonb_build_object('amount', p_amount, 'reason', p_reason));
  perform app.rebalance_supplier(p_supplier);
  return cid;
end $$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.customers enable row level security;
alter table public.cash_accounts enable row level security;
alter table public.purchases enable row level security;
alter table public.purchase_lines enable row level security;
alter table public.purchase_receipts enable row level security;
alter table public.purchase_receipt_lines enable row level security;
alter table public.supplier_credits enable row level security;
alter table public.supplier_returns enable row level security;
alter table public.supplier_return_lines enable row level security;
alter table public.payments enable row level security;
alter table public.payment_allocations enable row level security;

create policy customers_read on public.customers for select using (app.can_read(business_id));
create policy customers_insert on public.customers for insert with check (app.has_perm(business_id, 'customers.manage'));
create policy customers_update on public.customers for update using (app.has_perm(business_id, 'customers.manage'))
  with check (app.has_perm(business_id, 'customers.manage'));

create policy cash_accounts_read on public.cash_accounts for select using (app.can_read(business_id));
create policy cash_accounts_update on public.cash_accounts for update using (app.has_perm(business_id, 'cash.manage'))
  with check (app.has_perm(business_id, 'cash.manage'));

create policy purchases_read on public.purchases for select
  using (app.has_perm(business_id, 'purchases.manage') and created_at >= app.history_cutoff(business_id)
         or app.can_read(business_id) and not app.is_member(business_id));
create policy purchase_lines_read on public.purchase_lines for select using (app.has_perm(business_id, 'purchases.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy purchase_receipts_read on public.purchase_receipts for select using (app.has_perm(business_id, 'purchases.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy purchase_receipt_lines_read on public.purchase_receipt_lines for select using (app.has_perm(business_id, 'purchases.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy supplier_credits_read on public.supplier_credits for select using (app.has_perm(business_id, 'purchases.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy supplier_returns_read on public.supplier_returns for select using (app.has_perm(business_id, 'purchases.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy supplier_return_lines_read on public.supplier_return_lines for select using (app.has_perm(business_id, 'purchases.manage') or app.can_read(business_id) and not app.is_member(business_id));

-- Cashiers see payments they can act on (sales); managers/owners see all money movements.
create policy payments_read on public.payments for select using (
  (app.has_perm(business_id, 'cash.manage') or app.has_perm(business_id, 'reports.view')
   or (app.has_perm(business_id, 'sales.view') and kind in ('sale_payment', 'customer_payment', 'customer_refund')))
  and paid_at >= app.history_cutoff(business_id)
  or app.can_read(business_id) and not app.is_member(business_id));
create policy payment_allocations_read on public.payment_allocations for select using (app.can_read(business_id));

-- ===== 20261022000400_sales_expenses_cash.sql =====
-- Sales, returns/refunds, customer balances, expenses, cash movements, reconciliation.
--
-- Reporting conventions (documented in docs/FINANCIAL_RULES.md):
--   * Net sales revenue = sale line amounts after all discounts, excluding any
--     configured sales tax, minus returns. Sales are counted on the sale date,
--     returns on the return date.
--   * COGS = weighted-average cost captured on each sale line at the time of sale,
--     minus the cost of restocked returns.
--   * Customer balance = sum(sale total - returned + refunded) - payments received.

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  number text not null,
  client_ref uuid not null,
  customer_id uuid references public.customers (id),
  sold_at timestamptz not null default now(),
  status text not null default 'completed' check (status in ('completed')),
  subtotal numeric(14, 2) not null default 0,         -- sum of qty * unit price
  list_total numeric(14, 2) not null default 0,       -- sum of qty * catalogue price (for discount control)
  line_discount_total numeric(14, 2) not null default 0,
  sale_discount numeric(14, 2) not null default 0,
  total numeric(14, 2) not null default 0,             -- amount charged, tax inclusive
  tax_total numeric(14, 2) not null default 0,
  cost_total numeric(18, 4) not null default 0,
  paid_total numeric(14, 2) not null default 0,        -- allocated customer payments
  returned_total numeric(14, 2) not null default 0,
  returned_tax numeric(14, 2) not null default 0,
  returned_cost numeric(18, 4) not null default 0,
  refunded_total numeric(14, 2) not null default 0,
  due_date date,
  notes text,
  offline boolean not null default false,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (business_id, client_ref)
);
create unique index sales_number on public.sales (business_id, number);
create index sales_business_date on public.sales (business_id, sold_at desc);
create index sales_customer on public.sales (customer_id, sold_at) where customer_id is not null;

create table public.sale_lines (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id),
  unit_id uuid references public.product_units (id),
  unit_name text not null,
  unit_factor numeric(14, 4) not null check (unit_factor > 0),
  quantity numeric(14, 3) not null check (quantity > 0),
  base_quantity numeric(14, 3) not null check (base_quantity > 0),
  list_price numeric(14, 2) not null,
  unit_price numeric(14, 2) not null check (unit_price >= 0),
  line_discount numeric(14, 2) not null default 0 check (line_discount >= 0),
  sale_discount_alloc numeric(14, 2) not null default 0,
  net_amount numeric(14, 2) not null check (net_amount >= 0),   -- charged, tax inclusive
  tax_amount numeric(14, 2) not null default 0,
  cost_unit_base numeric(18, 4) not null,
  cost_amount numeric(18, 4) not null,
  returned_base_qty numeric(14, 3) not null default 0,
  returned_amount numeric(14, 2) not null default 0,
  returned_tax numeric(14, 2) not null default 0,
  returned_cost numeric(18, 4) not null default 0,
  sort int not null default 0,
  check (returned_base_qty <= base_quantity)
);
create index sale_lines_sale on public.sale_lines (sale_id);
create index sale_lines_product on public.sale_lines (product_id);
create index sale_lines_business on public.sale_lines (business_id);

create table public.sale_returns (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  number text not null,
  sale_id uuid not null references public.sales (id),
  customer_id uuid references public.customers (id),
  returned_at timestamptz not null default now(),
  reason text not null,
  restock boolean not null default true,
  total numeric(14, 2) not null default 0,
  tax_amount numeric(14, 2) not null default 0,
  cost_amount numeric(18, 4) not null default 0,
  refund_amount numeric(14, 2) not null default 0,
  refund_method text,
  client_ref uuid,
  created_by uuid,
  created_at timestamptz not null default now()
);
create unique index sale_returns_client_ref on public.sale_returns (business_id, client_ref) where client_ref is not null;
create index sale_returns_business_date on public.sale_returns (business_id, returned_at desc);
create index sale_returns_sale on public.sale_returns (sale_id);

create table public.sale_return_lines (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references public.sale_returns (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  sale_line_id uuid not null references public.sale_lines (id),
  product_id uuid not null references public.products (id),
  base_quantity numeric(14, 3) not null check (base_quantity > 0),
  amount numeric(14, 2) not null,
  tax_amount numeric(14, 2) not null default 0,
  cost_amount numeric(18, 4) not null default 0
);
create index sale_return_lines_product on public.sale_return_lines (product_id);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  number text not null,
  client_ref uuid,
  category text not null check (category in ('rent', 'salaries', 'utilities', 'transport', 'communication',
    'packaging', 'repairs', 'marketing', 'bank_fees', 'taxes_licences', 'security', 'cleaning', 'other')),
  description text not null check (length(btrim(description)) between 1 and 200),
  amount numeric(14, 2) not null check (amount > 0),
  expense_date date not null,
  due_date date,
  status text not null default 'unpaid' check (status in ('unpaid', 'partially_paid', 'paid', 'voided')),
  paid_amount numeric(14, 2) not null default 0,
  payee text,
  notes text,
  void_reason text,
  created_by uuid,
  created_at timestamptz not null default now()
);
create unique index expenses_client_ref on public.expenses (business_id, client_ref) where client_ref is not null;
create index expenses_business_date on public.expenses (business_id, expense_date desc);

alter table public.payments add constraint payments_sale_fk foreign key (sale_id) references public.sales (id);
alter table public.payments add constraint payments_return_fk foreign key (sale_return_id) references public.sale_returns (id);
alter table public.payments add constraint payments_expense_fk foreign key (expense_id) references public.expenses (id);
alter table public.payment_allocations add constraint alloc_sale_fk foreign key (sale_id) references public.sales (id);
alter table public.payment_allocations add constraint alloc_expense_fk foreign key (expense_id) references public.expenses (id);

create table public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  kind text not null check (kind in ('transfer', 'deposit', 'withdrawal', 'adjustment')),
  from_account_id uuid references public.cash_accounts (id),
  to_account_id uuid references public.cash_accounts (id),
  amount numeric(14, 2) not null check (amount > 0),
  note text,
  occurred_at timestamptz not null default now(),
  client_ref uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  check ((kind = 'transfer' and from_account_id is not null and to_account_id is not null and from_account_id <> to_account_id)
      or (kind = 'deposit' and from_account_id is null and to_account_id is not null)
      or (kind = 'withdrawal' and from_account_id is not null and to_account_id is null)
      or (kind = 'adjustment' and num_nonnulls(from_account_id, to_account_id) = 1))
);
create unique index cash_movements_client_ref on public.cash_movements (business_id, client_ref) where client_ref is not null;
create index cash_movements_business on public.cash_movements (business_id, occurred_at desc);

create table public.cash_reconciliations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  recon_date date not null,
  notes text,
  total_expected numeric(14, 2) not null,
  total_counted numeric(14, 2) not null,
  total_difference numeric(14, 2) not null,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index cash_reconciliations_business on public.cash_reconciliations (business_id, recon_date desc);

create table public.cash_reconciliation_lines (
  id uuid primary key default gen_random_uuid(),
  reconciliation_id uuid not null references public.cash_reconciliations (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  account_id uuid not null references public.cash_accounts (id),
  expected numeric(14, 2) not null,
  counted numeric(14, 2) not null,
  difference numeric(14, 2) not null,
  day_inflows numeric(14, 2) not null default 0,
  day_outflows numeric(14, 2) not null default 0
);

-- ---------------------------------------------------------------------------
-- Customer balances
-- ---------------------------------------------------------------------------
create or replace function app.customer_balance(p_customer uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(total - returned_total + refunded_total) from public.sales where customer_id = p_customer), 0)
       - coalesce((select sum(amount) from public.payments where customer_id = p_customer
                     and kind in ('sale_payment', 'customer_payment')), 0)
$$;

-- Deterministic allocation of incoming payments to sales: the targeted sale first,
-- then the oldest sale with an outstanding amount. p_sale is used for walk-in sales.
create or replace function app.rebalance_customer(p_customer uuid, p_sale uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare pay record; s record; avail numeric; take numeric; outstanding numeric;
begin
  create temp table if not exists _cpay (payment_id uuid primary key, sale_id uuid, paid_at timestamptz, amount numeric) on commit drop;
  create temp table if not exists _cowed (sale_id uuid primary key, sold_at timestamptz, owed numeric) on commit drop;
  delete from _cpay where true; delete from _cowed where true;

  if p_customer is null then
    delete from public.payment_allocations a using public.payments p
     where a.payment_id = p.id and p.sale_id = p_sale and p.customer_id is null and p.kind = 'sale_payment';
    insert into _cpay select id, sale_id, paid_at, amount from public.payments
     where sale_id = p_sale and customer_id is null and kind = 'sale_payment';
    insert into _cowed select id, sold_at, total - returned_total + refunded_total from public.sales where id = p_sale;
  else
    delete from public.payment_allocations a using public.payments p
     where a.payment_id = p.id and p.customer_id = p_customer and p.kind in ('sale_payment', 'customer_payment');
    insert into _cpay select id, sale_id, paid_at, amount from public.payments
     where customer_id = p_customer and kind in ('sale_payment', 'customer_payment');
    insert into _cowed select id, sold_at, total - returned_total + refunded_total from public.sales
     where customer_id = p_customer and total - returned_total + refunded_total > 0;
  end if;

  for pay in select * from _cpay where sale_id is not null order by paid_at, payment_id loop
    select owed into outstanding from _cowed where sale_id = pay.sale_id;
    if coalesce(outstanding, 0) > 0 then
      take := least(pay.amount, outstanding);
      insert into public.payment_allocations (business_id, payment_id, sale_id, amount)
      select business_id, pay.payment_id, pay.sale_id, take from public.payments where id = pay.payment_id;
      update _cowed set owed = owed - take where sale_id = pay.sale_id;
      update _cpay set amount = amount - take where payment_id = pay.payment_id;
    end if;
  end loop;

  for pay in select * from _cpay where amount > 0 order by paid_at, payment_id loop
    avail := pay.amount;
    for s in select * from _cowed where owed > 0 order by sold_at, sale_id loop
      exit when avail <= 0;
      take := least(avail, s.owed);
      insert into public.payment_allocations (business_id, payment_id, sale_id, amount)
      select business_id, pay.payment_id, s.sale_id, take from public.payments where id = pay.payment_id;
      update _cowed set owed = owed - take where sale_id = s.sale_id;
      avail := avail - take;
    end loop;
  end loop;

  update public.sales sa set paid_total = coalesce((
      select sum(a.amount) from public.payment_allocations a where a.sale_id = sa.id), 0)
   where (p_customer is not null and sa.customer_id = p_customer) or sa.id = p_sale;
end $$;

-- ---------------------------------------------------------------------------
-- Sales
-- ---------------------------------------------------------------------------
create or replace function public.create_sale(p_business uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cref uuid := coalesce(nullif(p ->> 'client_ref', '')::uuid, gen_random_uuid());
  sid uuid; num text; existing public.sales; cust public.customers; st public.business_settings;
  l jsonb; u record; pr public.products; mv public.stock_movements;
  i int := 0; n int;
  v_qty numeric; v_price numeric; v_list numeric; v_disc numeric; v_net numeric;
  list_sum numeric := 0; gross_sum numeric := 0; disc_sum numeric := 0; net_sum numeric := 0;
  sale_disc numeric := coalesce((p ->> 'discount_amount')::numeric, 0);
  alloc numeric; alloc_left numeric; tax numeric; tax_sum numeric := 0; cost_sum numeric := 0;
  pay jsonb; paid numeric := 0; v_tot numeric; disc_pct numeric;
  at timestamptz := coalesce(nullif(p ->> 'sold_at', '')::timestamptz, now());
  line_ids uuid[] := '{}';
begin
  perform app.require_perm(p_business, 'sales.create');

  select * into existing from public.sales where business_id = p_business and client_ref = cref;
  if found then
    return jsonb_build_object('id', existing.id, 'number', existing.number, 'total', existing.total, 'duplicate', true);
  end if;

  perform app.check_limit(p_business, 'max_sales_per_month');
  if at > now() + interval '10 minutes' then perform app.raise('invalid_date'); end if;
  if jsonb_typeof(p -> 'lines') <> 'array' or jsonb_array_length(p -> 'lines') = 0 then
    perform app.raise('lines_required');
  end if;
  if sale_disc < 0 then perform app.raise('invalid_amount'); end if;
  select * into st from public.business_settings where business_id = p_business;

  if nullif(p ->> 'customer_id', '') is not null then
    select * into cust from public.customers where id = (p ->> 'customer_id')::uuid and business_id = p_business;
    if not found then perform app.raise('invalid_customer'); end if;
  end if;

  begin
    insert into public.sales (business_id, number, client_ref, customer_id, sold_at, due_date, notes, offline, created_by)
    values (p_business, app.next_number(p_business, 'sale', 'S-'), cref, cust.id, at,
            nullif(p ->> 'due_date', '')::date, nullif(p ->> 'notes', ''),
            coalesce((p ->> 'offline')::boolean, false), auth.uid())
    returning id, number into sid, num;
  exception when unique_violation then
    -- Concurrent retry of the same sale: return the committed one.
    select * into existing from public.sales where business_id = p_business and client_ref = cref;
    return jsonb_build_object('id', existing.id, 'number', existing.number, 'total', existing.total, 'duplicate', true);
  end;

  -- Lock all products of the sale in a stable order to avoid deadlocks.
  perform 1 from public.products
   where business_id = p_business
     and id in (select (x ->> 'product_id')::uuid from jsonb_array_elements(p -> 'lines') x)
   order by id for update;

  -- Pass 1: validate and price lines.
  create temp table if not exists _sl (sort int primary key, product_id uuid, unit_id uuid, unit_name text,
    factor numeric, qty numeric, base numeric, list_price numeric, unit_price numeric, disc numeric, net numeric) on commit drop;
  delete from _sl where true;
  for l in select * from jsonb_array_elements(p -> 'lines') loop
    i := i + 1;
    select * into pr from public.products where id = (l ->> 'product_id')::uuid and business_id = p_business;
    if not found then perform app.raise('invalid_product'); end if;
    if pr.status <> 'active' then perform app.raise('product_archived', jsonb_build_object('product', pr.name)); end if;
    select * into u from app.resolve_unit(pr.id, nullif(l ->> 'unit_id', '')::uuid);
    v_qty := (l ->> 'quantity')::numeric;
    if v_qty is null or v_qty <= 0 then perform app.raise('invalid_quantity'); end if;
    v_list := coalesce((select selling_price from public.product_units where id = u.unit_id), pr.selling_price * u.factor);
    v_price := coalesce((l ->> 'unit_price')::numeric, v_list);
    v_disc := coalesce((l ->> 'discount_amount')::numeric, 0);
    if v_price < 0 or v_disc < 0 then perform app.raise('invalid_amount'); end if;
    v_net := app.money(p_business, v_qty * v_price - v_disc);
    if v_net < 0 then perform app.raise('discount_exceeds_line'); end if;
    insert into _sl values (i, pr.id, u.unit_id, u.unit_name, u.factor, v_qty, v_qty * u.factor,
                            v_list, v_price, v_disc, v_net);
    list_sum := list_sum + app.money(p_business, v_qty * v_list);
    gross_sum := gross_sum + app.money(p_business, v_qty * v_price);
    disc_sum := disc_sum + v_disc;
    net_sum := net_sum + v_net;
  end loop;

  if sale_disc > net_sum then perform app.raise('discount_exceeds_total'); end if;
  v_tot := net_sum - sale_disc;

  -- Discount control: price reductions + discounts against catalogue prices.
  if list_sum > 0 then
    disc_pct := greatest(0, (list_sum - v_tot) / list_sum * 100);
    if disc_pct > st.cashier_max_discount_pct and not app.has_perm(p_business, 'sales.discount_large') then
      perform app.raise('discount_requires_approval', jsonb_build_object('max_pct', st.cashier_max_discount_pct,
        'pct', round(disc_pct, 1)));
    end if;
  end if;

  -- Pass 2: allocate sale discount, compute tax, move stock, capture cost.
  alloc_left := sale_disc;
  select count(*) into n from _sl;
  for l in select to_jsonb(_sl) from _sl order by sort loop
    if (l ->> 'sort')::int = n then
      alloc := alloc_left;
    elsif net_sum > 0 then
      alloc := least(alloc_left, app.money(p_business, sale_disc * (l ->> 'net')::numeric / net_sum));
    else
      alloc := 0;
    end if;
    alloc_left := alloc_left - alloc;
    v_net := (l ->> 'net')::numeric - alloc;
    tax := case when st.tax_enabled then app.money(p_business, v_net * st.tax_rate / (100 + st.tax_rate)) else 0 end;
    perform app.consume_batches((l ->> 'product_id')::uuid, (l ->> 'base')::numeric);
    mv := app.apply_movement(p_business, (l ->> 'product_id')::uuid, 'sale', -(l ->> 'base')::numeric, null,
                             'sale', sid, num, null, null, false, null, at);
    insert into public.sale_lines (sale_id, business_id, product_id, unit_id, unit_name, unit_factor, quantity,
      base_quantity, list_price, unit_price, line_discount, sale_discount_alloc, net_amount, tax_amount,
      cost_unit_base, cost_amount, sort)
    values (sid, p_business, (l ->> 'product_id')::uuid, nullif(l ->> 'unit_id', '')::uuid, l ->> 'unit_name',
      (l ->> 'factor')::numeric, (l ->> 'qty')::numeric, (l ->> 'base')::numeric, (l ->> 'list_price')::numeric,
      (l ->> 'unit_price')::numeric, (l ->> 'disc')::numeric, alloc, v_net, tax, mv.unit_cost, -mv.value,
      (l ->> 'sort')::int);
    tax_sum := tax_sum + tax;
    cost_sum := cost_sum - mv.value;
  end loop;

  -- Payments
  if p -> 'payments' is not null and jsonb_typeof(p -> 'payments') = 'array' then
    for pay in select * from jsonb_array_elements(p -> 'payments') loop
      continue when coalesce((pay ->> 'amount')::numeric, 0) = 0;
      perform app.insert_payment(p_business, 'sale_payment', coalesce(pay ->> 'method', 'cash'),
        (pay ->> 'amount')::numeric, at, pay ->> 'reference', null, null, cust.id, null, sid);
      paid := paid + app.money(p_business, (pay ->> 'amount')::numeric);
    end loop;
  end if;
  if paid > v_tot then perform app.raise('overpayment', jsonb_build_object('total', v_tot, 'paid', paid)); end if;

  if paid < v_tot then
    if cust.id is null then perform app.raise('customer_required_for_credit'); end if;
    if not st.allow_credit_sales then perform app.raise('credit_sales_disabled'); end if;
    perform app.require_feature(p_business, 'customers_credit');
    if not app.has_perm(p_business, 'customers.credit') then
      perform app.raise('permission_denied', jsonb_build_object('permission', 'customers.credit'));
    end if;
    if cust.credit_limit is not null and app.customer_balance(cust.id) + (v_tot - paid) > cust.credit_limit then
      perform app.raise('credit_limit_exceeded', jsonb_build_object('limit', cust.credit_limit,
        'balance', app.customer_balance(cust.id)));
    end if;
  end if;

  update public.sales set subtotal = gross_sum, list_total = list_sum, line_discount_total = disc_sum,
         sale_discount = sale_disc, total = v_tot, tax_total = tax_sum, cost_total = cost_sum
   where id = sid;

  perform app.rebalance_customer(cust.id, sid);
  perform app.audit(p_business, 'sale.created', 'sale', sid::text,
    jsonb_build_object('number', num, 'total', v_tot, 'paid', paid, 'offline', coalesce((p ->> 'offline')::boolean, false)));
  return jsonb_build_object('id', sid, 'number', num, 'total', v_tot, 'paid', paid, 'duplicate', false);
end $$;

create or replace function public.record_customer_payment(
  p_business uuid, p_customer uuid, p_amount numeric, p_method text, p_reference text default null,
  p_sale uuid default null, p_paid_at timestamptz default null, p_notes text default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.payments; existing uuid;
begin
  perform app.require_perm(p_business, 'sales.create');
  if p_client_ref is not null then
    select id into existing from public.payments where business_id = p_business and client_ref = p_client_ref;
    if found then return existing; end if;
  end if;
  if not exists (select 1 from public.customers where id = p_customer and business_id = p_business) then
    perform app.raise('invalid_customer');
  end if;
  if p_sale is not null and not exists (select 1 from public.sales where id = p_sale and customer_id = p_customer) then
    perform app.raise('invalid_sale');
  end if;
  r := app.insert_payment(p_business, 'customer_payment', p_method, p_amount, p_paid_at, p_reference, p_notes,
                          p_client_ref, p_customer, null, p_sale);
  perform app.audit(p_business, 'customer.payment', 'customer', p_customer::text,
                    jsonb_build_object('payment_id', r.id, 'amount', r.amount, 'method', p_method));
  perform app.rebalance_customer(p_customer);
  return r.id;
end $$;

create or replace function public.create_sale_return(p_sale uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
-- p: {client_ref, reason, restock (default true), lines: [{sale_line_id, base_quantity}],
--     refund: {amount, method, reference}}
declare
  s public.sales; sl public.sale_lines; rid uuid; num text; l jsonb; q numeric;
  amt numeric; tx numeric; cst numeric; restock boolean := coalesce((p ->> 'restock')::boolean, true);
  tot numeric := 0; tot_tax numeric := 0; tot_cost numeric := 0; refund numeric := coalesce((p #>> '{refund,amount}')::numeric, 0);
  available numeric; mv public.stock_movements; cref uuid := nullif(p ->> 'client_ref', '')::uuid;
begin
  select * into s from public.sales where id = p_sale for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(s.business_id, 'sales.refund');
  if cref is not null then
    select id into rid from public.sale_returns where business_id = s.business_id and client_ref = cref;
    if found then return rid; end if;
  end if;
  if coalesce(btrim(p ->> 'reason'), '') = '' then perform app.raise('reason_required'); end if;
  num := app.next_number(s.business_id, 'return', 'RT-');
  insert into public.sale_returns (business_id, number, sale_id, customer_id, reason, restock, client_ref, created_by)
  values (s.business_id, num, s.id, s.customer_id, btrim(p ->> 'reason'), restock, cref, auth.uid())
  returning id into rid;

  for l in select * from jsonb_array_elements(p -> 'lines') loop
    q := coalesce((l ->> 'base_quantity')::numeric, 0);
    continue when q = 0;
    if q < 0 then perform app.raise('invalid_quantity'); end if;
    select * into sl from public.sale_lines where id = (l ->> 'sale_line_id')::uuid and sale_id = s.id for update;
    if not found then perform app.raise('invalid_line'); end if;
    if sl.returned_base_qty + q > sl.base_quantity then perform app.raise('return_exceeds_sold'); end if;
    if sl.returned_base_qty + q = sl.base_quantity then
      amt := sl.net_amount - sl.returned_amount;            -- last return takes the exact remainder
      tx := sl.tax_amount - sl.returned_tax;
    else
      amt := app.money(s.business_id, sl.net_amount * q / sl.base_quantity);
      tx := app.money(s.business_id, sl.tax_amount * q / sl.base_quantity);
    end if;
    cst := 0;
    if restock then
      cst := round(sl.cost_amount * q / sl.base_quantity, 4);
      mv := app.apply_movement(s.business_id, sl.product_id, 'sale_return', q, cst / q, 'sale_return', rid, num,
                               p ->> 'reason');
    end if;
    insert into public.sale_return_lines (return_id, business_id, sale_line_id, product_id, base_quantity, amount,
                                          tax_amount, cost_amount)
    values (rid, s.business_id, sl.id, sl.product_id, q, amt, tx, cst);
    update public.sale_lines set returned_base_qty = returned_base_qty + q, returned_amount = returned_amount + amt,
           returned_tax = returned_tax + tx, returned_cost = returned_cost + cst where id = sl.id;
    tot := tot + amt; tot_tax := tot_tax + tx; tot_cost := tot_cost + cst;
  end loop;
  if tot = 0 and tot_cost = 0 and not exists (select 1 from public.sale_return_lines where return_id = rid) then
    perform app.raise('lines_required');
  end if;

  -- Refundable cash: what was paid on this sale beyond what is still charged after the return.
  available := s.paid_total - (s.total - (s.returned_total + tot) + s.refunded_total);
  if s.customer_id is null then
    -- Walk-in customers cannot hold store credit: the returned value must be refunded.
    refund := tot;
  end if;
  if refund < 0 or refund > tot or refund > greatest(available, 0) then
    perform app.raise('invalid_refund_amount', jsonb_build_object('max', least(tot, greatest(available, 0))));
  end if;

  update public.sales set returned_total = returned_total + tot, returned_tax = returned_tax + tot_tax,
         returned_cost = returned_cost + tot_cost, refunded_total = refunded_total + refund
   where id = s.id;
  update public.sale_returns set total = tot, tax_amount = tot_tax, cost_amount = tot_cost, refund_amount = refund,
         refund_method = case when refund > 0 then coalesce(p #>> '{refund,method}', 'cash') end
   where id = rid;
  if refund > 0 then
    perform app.insert_payment(s.business_id, 'customer_refund', coalesce(p #>> '{refund,method}', 'cash'), refund,
      now(), p #>> '{refund,reference}', null, null, s.customer_id, null, s.id, null, null, rid);
  end if;
  perform app.rebalance_customer(s.customer_id, s.id);
  perform app.audit(s.business_id, 'sale.returned', 'sale', s.id::text,
    jsonb_build_object('return_id', rid, 'amount', tot, 'refund', refund, 'restock', restock));
  return rid;
end $$;

-- ---------------------------------------------------------------------------
-- Expenses
-- ---------------------------------------------------------------------------
create or replace function app.refresh_expense(p_expense uuid) returns void
language sql security definer set search_path = public as $$
  update public.expenses e set
    paid_amount = coalesce((select sum(case when p.kind = 'expense_payment' then p.amount else -p.amount end)
                            from public.payments p where p.expense_id = e.id), 0),
    status = case when e.status = 'voided' then 'voided'
      else case
        when coalesce((select sum(case when p.kind = 'expense_payment' then p.amount else -p.amount end)
                       from public.payments p where p.expense_id = e.id), 0) >= e.amount then 'paid'
        when coalesce((select sum(case when p.kind = 'expense_payment' then p.amount else -p.amount end)
                       from public.payments p where p.expense_id = e.id), 0) > 0 then 'partially_paid'
        else 'unpaid' end end
  where e.id = p_expense
$$;

create or replace function public.record_expense(p_business uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare eid uuid; cref uuid := nullif(p ->> 'client_ref', '')::uuid; amt numeric; paid numeric;
begin
  perform app.require_perm(p_business, 'expenses.manage');
  perform app.require_feature(p_business, 'expenses');
  if cref is not null then
    select id into eid from public.expenses where business_id = p_business and client_ref = cref;
    if found then return eid; end if;
  end if;
  amt := app.money(p_business, (p ->> 'amount')::numeric);
  if amt is null or amt <= 0 then perform app.raise('invalid_amount'); end if;
  paid := coalesce((p ->> 'paid_amount')::numeric, 0);
  if paid < 0 or paid > amt then perform app.raise('invalid_amount'); end if;
  insert into public.expenses (business_id, number, client_ref, category, description, amount, expense_date, due_date,
                               payee, notes, created_by)
  values (p_business, app.next_number(p_business, 'expense', 'EXP-'), cref, p ->> 'category', btrim(p ->> 'description'),
          amt, coalesce(nullif(p ->> 'expense_date', '')::date, app.biz_today(p_business)),
          nullif(p ->> 'due_date', '')::date, nullif(p ->> 'payee', ''), nullif(p ->> 'notes', ''), auth.uid())
  returning id into eid;
  if paid > 0 then
    perform app.insert_payment(p_business, 'expense_payment', coalesce(p ->> 'method', 'cash'), paid,
      coalesce(nullif(p ->> 'expense_date', '')::date::timestamp at time zone app.biz_tz(p_business) + interval '12 hours', now()),
      p ->> 'reference', null, null, null, null, null, null, eid);
  end if;
  perform app.refresh_expense(eid);
  perform app.audit(p_business, 'expense.created', 'expense', eid::text,
                    jsonb_build_object('amount', amt, 'category', p ->> 'category', 'paid', paid));
  return eid;
end $$;

create or replace function public.pay_expense(p_expense uuid, p_amount numeric, p_method text,
  p_reference text default null, p_paid_at timestamptz default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare e public.expenses; r public.payments; existing uuid;
begin
  select * into e from public.expenses where id = p_expense for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(e.business_id, 'expenses.manage');
  if p_client_ref is not null then
    select id into existing from public.payments where business_id = e.business_id and client_ref = p_client_ref;
    if found then return existing; end if;
  end if;
  if e.status = 'voided' then perform app.raise('expense_voided'); end if;
  if p_amount is null or p_amount <= 0 or e.paid_amount + p_amount > e.amount then perform app.raise('invalid_amount'); end if;
  r := app.insert_payment(e.business_id, 'expense_payment', p_method, p_amount, p_paid_at, p_reference, null,
                          p_client_ref, null, null, null, null, e.id);
  perform app.refresh_expense(e.id);
  perform app.audit(e.business_id, 'expense.paid', 'expense', e.id::text, jsonb_build_object('amount', p_amount));
  return r.id;
end $$;

create or replace function public.void_expense(p_expense uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare e public.expenses; pm record;
begin
  select * into e from public.expenses where id = p_expense for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(e.business_id, 'expenses.manage');
  if e.status = 'voided' then perform app.raise('expense_voided'); end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  -- Reverse each recorded payment with an explicit counter-entry (history is kept).
  for pm in select method, sum(case when kind = 'expense_payment' then amount else -amount end) amt
            from public.payments where expense_id = e.id group by method loop
    if pm.amt > 0 then
      perform app.insert_payment(e.business_id, 'expense_refund', pm.method, pm.amt, now(), 'VOID ' || e.number,
                                 btrim(p_reason), null, null, null, null, null, e.id);
    end if;
  end loop;
  update public.expenses set status = 'voided', void_reason = btrim(p_reason) where id = e.id;
  perform app.refresh_expense(e.id);
  perform app.audit(e.business_id, 'expense.voided', 'expense', e.id::text, jsonb_build_object('reason', p_reason));
end $$;

-- ---------------------------------------------------------------------------
-- Cash accounts, movements and reconciliation
-- ---------------------------------------------------------------------------
create or replace function app.account_balance(p_account uuid, p_until timestamptz) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select opening_balance from public.cash_accounts where id = p_account), 0)
       + coalesce((select sum(case when direction = 'in' then amount else -amount end)
                   from public.payments where account_id = p_account and paid_at < p_until), 0)
       + coalesce((select sum(amount) from public.cash_movements where to_account_id = p_account and occurred_at < p_until), 0)
       - coalesce((select sum(amount) from public.cash_movements where from_account_id = p_account and occurred_at < p_until), 0)
$$;

create or replace function public.record_cash_movement(p_business uuid, p_kind text, p_from uuid, p_to uuid,
  p_amount numeric, p_note text, p_occurred_at timestamptz default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare mid uuid;
begin
  perform app.require_perm(p_business, 'cash.manage');
  if p_client_ref is not null then
    select id into mid from public.cash_movements where business_id = p_business and client_ref = p_client_ref;
    if found then return mid; end if;
  end if;
  if p_kind in ('withdrawal', 'adjustment') and coalesce(btrim(p_note), '') = '' then perform app.raise('reason_required'); end if;
  if (p_from is not null and not exists (select 1 from public.cash_accounts where id = p_from and business_id = p_business))
     or (p_to is not null and not exists (select 1 from public.cash_accounts where id = p_to and business_id = p_business)) then
    perform app.raise('invalid_account');
  end if;
  insert into public.cash_movements (business_id, kind, from_account_id, to_account_id, amount, note, occurred_at,
                                     client_ref, created_by)
  values (p_business, p_kind, p_from, p_to, app.money(p_business, p_amount), p_note, coalesce(p_occurred_at, now()),
          p_client_ref, auth.uid())
  returning id into mid;
  perform app.audit(p_business, 'cash.movement', 'cash_movement', mid::text,
                    jsonb_build_object('kind', p_kind, 'amount', p_amount, 'note', p_note));
  return mid;
end $$;

create or replace function public.cash_position(p_business uuid, p_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s timestamptz := app.range_start(p_business, p_date); e timestamptz := app.range_end(p_business, p_date);
begin
  perform app.require_perm(p_business, 'cash.manage');
  return (select coalesce(jsonb_agg(row_to_json(t) order by t.sort), '[]'::jsonb) from (
    select a.id as account_id, a.name, a.kind,
      case a.kind when 'cash' then 1 when 'mtn_momo' then 2 when 'orange_money' then 3 when 'bank' then 4 else 5 end as sort,
      app.account_balance(a.id, s) as opening,
      coalesce((select sum(amount) from public.payments where account_id = a.id and paid_at >= s and paid_at < e
                and kind = 'sale_payment'), 0) as sales_in,
      coalesce((select sum(amount) from public.payments where account_id = a.id and paid_at >= s and paid_at < e
                and kind = 'customer_payment'), 0) as debt_collected,
      coalesce((select sum(amount) from public.payments where account_id = a.id and paid_at >= s and paid_at < e
                and kind in ('supplier_refund', 'expense_refund')), 0) as other_in,
      coalesce((select sum(amount) from public.payments where account_id = a.id and paid_at >= s and paid_at < e
                and kind = 'customer_refund'), 0) as refunds_out,
      coalesce((select sum(amount) from public.payments where account_id = a.id and paid_at >= s and paid_at < e
                and kind = 'supplier_payment'), 0) as supplier_out,
      coalesce((select sum(amount) from public.payments where account_id = a.id and paid_at >= s and paid_at < e
                and kind = 'expense_payment'), 0) as expenses_out,
      coalesce((select sum(amount) from public.cash_movements where to_account_id = a.id and occurred_at >= s and occurred_at < e), 0) as transfers_in,
      coalesce((select sum(amount) from public.cash_movements where from_account_id = a.id and occurred_at >= s and occurred_at < e), 0) as transfers_out,
      app.account_balance(a.id, e) as expected
    from public.cash_accounts a where a.business_id = p_business and a.active) t);
end $$;

create or replace function public.save_cash_reconciliation(p_business uuid, p_date date, p_lines jsonb, p_notes text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare rid uuid; pos jsonb; l jsonb; a jsonb; te numeric := 0; tc numeric := 0; cnt numeric;
begin
  perform app.require_perm(p_business, 'cash.manage');
  perform app.require_feature(p_business, 'cash_reconciliation');
  pos := public.cash_position(p_business, p_date);
  insert into public.cash_reconciliations (business_id, recon_date, notes, total_expected, total_counted, total_difference, created_by)
  values (p_business, p_date, p_notes, 0, 0, 0, auth.uid()) returning id into rid;
  for l in select * from jsonb_array_elements(p_lines) loop
    select x into a from jsonb_array_elements(pos) x where x ->> 'account_id' = l ->> 'account_id';
    if a is null then perform app.raise('invalid_account'); end if;
    cnt := (l ->> 'counted')::numeric;
    if cnt is null then continue; end if;
    insert into public.cash_reconciliation_lines (reconciliation_id, business_id, account_id, expected, counted, difference,
                                                  day_inflows, day_outflows)
    values (rid, p_business, (a ->> 'account_id')::uuid, (a ->> 'expected')::numeric, cnt, cnt - (a ->> 'expected')::numeric,
            (a ->> 'sales_in')::numeric + (a ->> 'debt_collected')::numeric + (a ->> 'other_in')::numeric + (a ->> 'transfers_in')::numeric,
            (a ->> 'refunds_out')::numeric + (a ->> 'supplier_out')::numeric + (a ->> 'expenses_out')::numeric + (a ->> 'transfers_out')::numeric);
    te := te + (a ->> 'expected')::numeric; tc := tc + cnt;
  end loop;
  if tc = 0 and te = 0 and not exists (select 1 from public.cash_reconciliation_lines where reconciliation_id = rid) then
    perform app.raise('lines_required');
  end if;
  update public.cash_reconciliations set total_expected = te, total_counted = tc, total_difference = tc - te where id = rid;
  perform app.audit(p_business, 'cash.reconciled', 'cash_reconciliation', rid::text,
                    jsonb_build_object('date', p_date, 'difference', tc - te));
  return rid;
end $$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.sales enable row level security;
alter table public.sale_lines enable row level security;
alter table public.sale_returns enable row level security;
alter table public.sale_return_lines enable row level security;
alter table public.expenses enable row level security;
alter table public.cash_movements enable row level security;
alter table public.cash_reconciliations enable row level security;
alter table public.cash_reconciliation_lines enable row level security;

create policy sales_read on public.sales for select using (
  app.has_perm(business_id, 'sales.view') and sold_at >= app.history_cutoff(business_id)
  or app.can_read(business_id) and not app.is_member(business_id));
create policy sale_lines_read on public.sale_lines for select using (app.has_perm(business_id, 'sales.view') or app.can_read(business_id) and not app.is_member(business_id));
create policy sale_returns_read on public.sale_returns for select using (app.has_perm(business_id, 'sales.view') or app.can_read(business_id) and not app.is_member(business_id));
create policy sale_return_lines_read on public.sale_return_lines for select using (app.has_perm(business_id, 'sales.view') or app.can_read(business_id) and not app.is_member(business_id));
create policy expenses_read on public.expenses for select using (
  app.has_perm(business_id, 'expenses.manage') and created_at >= app.history_cutoff(business_id)
  or app.can_read(business_id) and not app.is_member(business_id));
create policy cash_movements_read on public.cash_movements for select using (app.has_perm(business_id, 'cash.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy cash_recon_read on public.cash_reconciliations for select using (app.has_perm(business_id, 'cash.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy cash_recon_lines_read on public.cash_reconciliation_lines for select using (app.has_perm(business_id, 'cash.manage') or app.can_read(business_id) and not app.is_member(business_id));

-- ===== 20261022000500_saas_admin.sql =====
-- Onboarding, staff, billing verification, platform administration, notifications,
-- support, announcements, AI usage tracking, imports and data export.

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  type text not null,
  severity text not null default 'info' check (severity in ('info', 'success', 'warning', 'critical')),
  params jsonb not null default '{}'::jsonb,
  link text,
  required_perm text,
  dedupe_key text,
  created_at timestamptz not null default now()
);
create unique index notifications_dedupe on public.notifications (business_id, dedupe_key) where dedupe_key is not null;
create index notifications_business on public.notifications (business_id, created_at desc);

create table public.notification_reads (
  notification_id uuid not null references public.notifications (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (notification_id, user_id)
);

create table public.support_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses (id) on delete set null,
  user_id uuid references auth.users (id) on delete set null,
  name text,
  email text,
  phone text,
  category text not null default 'question' check (category in ('question', 'bug', 'billing', 'feedback',
                                                                  'account_closure', 'data_export', 'other')),
  subject text not null check (length(btrim(subject)) between 3 and 150),
  message text not null check (length(btrim(message)) between 5 and 5000),
  status text not null default 'open' check (status in ('open', 'in_progress', 'resolved', 'closed')),
  admin_response text,
  responded_by uuid,
  responded_at timestamptz,
  created_at timestamptz not null default now()
);
create index support_requests_status on public.support_requests (status, created_at desc);

create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  title_en text not null,
  title_fr text not null,
  body_en text,
  body_fr text,
  level text not null default 'info' check (level in ('info', 'warning', 'maintenance')),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  active boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now()
);

create table public.support_access_grants (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  granted_by uuid not null,
  reason text not null,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.ai_queries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  user_id uuid,
  question text not null,
  answer text,
  model text,
  status text not null default 'started' check (status in ('started', 'completed', 'failed', 'rejected', 'fallback')),
  period_from date,
  period_to date,
  input_tokens int,
  output_tokens int,
  error text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index ai_queries_business on public.ai_queries (business_id, created_at desc);

create table public.rate_limits (
  key text not null,
  window_start timestamptz not null,
  count int not null default 0,
  primary key (key, window_start)
);

-- Support access: a platform admin may read a business's records only while the
-- owner has granted (time-limited, revocable, audited) support access.
create or replace function app.can_read(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_member(bid) or (
    app.is_platform_admin() and exists (
      select 1 from public.support_access_grants g
      where g.business_id = bid and g.revoked_at is null and g.expires_at > now()))
$$;

create or replace function app.rate_limit(k text, max_count int, window_seconds int) returns void
language plpgsql security definer set search_path = public as $$
declare ws timestamptz := to_timestamp(floor(extract(epoch from now()) / window_seconds) * window_seconds); c int;
begin
  insert into public.rate_limits as r (key, window_start, count) values (k, ws, 1)
  on conflict (key, window_start) do update set count = r.count + 1 returning count into c;
  if c > max_count then perform app.raise('rate_limited'); end if;
  delete from public.rate_limits where window_start < now() - interval '2 days';
end $$;

-- ---------------------------------------------------------------------------
-- Onboarding
-- ---------------------------------------------------------------------------
create or replace function app.default_categories(cat text, lang text) returns text[]
language sql immutable as $$
  select case
    when cat = 'grocery' then case when lang = 'fr'
      then array['Alimentation', 'Boissons', 'Entretien ménager', 'Hygiène & beauté', 'Divers']
      else array['Food', 'Beverages', 'Household', 'Personal Care', 'Others'] end
    when cat = 'drinks' then case when lang = 'fr'
      then array['Bières', 'Boissons gazeuses', 'Eaux', 'Jus', 'Vins & spiritueux', 'Emballages']
      else array['Beer', 'Soft Drinks', 'Water', 'Juice', 'Wine & Spirits', 'Crates & Empties'] end
    when cat = 'hardware' then case when lang = 'fr'
      then array['Matériaux de construction', 'Outillage', 'Électricité', 'Plomberie', 'Peinture', 'Divers']
      else array['Building Materials', 'Tools', 'Electrical', 'Plumbing', 'Paint', 'Others'] end
    when cat = 'electronics' then case when lang = 'fr'
      then array['Téléphones', 'Accessoires', 'Électroménager', 'Informatique', 'Divers']
      else array['Phones', 'Accessories', 'Appliances', 'Computers', 'Others'] end
    when cat = 'fashion' then case when lang = 'fr'
      then array['Vêtements', 'Chaussures', 'Sacs & accessoires', 'Tissus', 'Divers']
      else array['Clothing', 'Shoes', 'Bags & Accessories', 'Fabrics', 'Others'] end
    when cat = 'cosmetics' then case when lang = 'fr'
      then array['Soins de la peau', 'Cheveux', 'Maquillage', 'Parfums', 'Hygiène', 'Divers']
      else array['Skin Care', 'Hair Care', 'Make-up', 'Fragrances', 'Hygiene', 'Others'] end
    else case when lang = 'fr'
      then array['Alimentation & boissons', 'Entretien ménager', 'Hygiène & beauté', 'Matériaux', 'Électronique', 'Divers']
      else array['Food & Beverages', 'Household', 'Personal Care', 'Building Materials', 'Electronics', 'Others'] end
  end
$$;

create or replace function public.create_business(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := app.require_auth(); c public.countries; bid uuid; lang text; cat text; nm text;
begin
  perform app.rate_limit('create_business:' || uid, 5, 86400);
  if (select count(*) from public.business_members where user_id = uid and role = 'owner' and active) >= 5 then
    perform app.raise('too_many_businesses');
  end if;
  select * into c from public.countries where code = coalesce(nullif(p ->> 'country_code', ''), 'CM');
  if not found or not c.registration_enabled then perform app.raise('country_not_available'); end if;
  lang := case when p ->> 'language' in ('en', 'fr') then p ->> 'language' else c.default_language end;
  cat := coalesce(nullif(p ->> 'category', ''), 'general');
  if cat not in ('grocery', 'general', 'drinks', 'hardware', 'electronics', 'fashion', 'cosmetics', 'other') then
    perform app.raise('invalid_category');
  end if;
  nm := btrim(coalesce(p ->> 'name', ''));
  if length(nm) < 2 then perform app.raise('business_name_required'); end if;

  insert into public.businesses (name, owner_name, email, phone, address, city, country_code, currency,
    currency_decimals, timezone, language, category, reporting_start_date, created_by)
  values (nm, nullif(p ->> 'owner_name', ''), nullif(p ->> 'email', ''), nullif(p ->> 'phone', ''),
    nullif(p ->> 'address', ''), nullif(p ->> 'city', ''), c.code, c.currency, c.currency_decimals, c.timezone,
    lang, cat, coalesce(nullif(p ->> 'reporting_start_date', '')::date, (now() at time zone c.timezone)::date), uid)
  returning id into bid;

  insert into public.business_settings (business_id) values (bid);
  insert into public.business_members (business_id, user_id, role, display_name)
  values (bid, uid, 'owner', nullif(p ->> 'owner_name', ''));
  perform app.init_accounts(bid);
  perform app.init_subscription(bid);
  insert into public.categories (business_id, name)
  select bid, x from unnest(app.default_categories(cat, lang)) x on conflict do nothing;

  update public.profiles set full_name = coalesce(nullif(p ->> 'owner_name', ''), full_name),
         phone = coalesce(nullif(p ->> 'phone', ''), phone), language = lang
   where id = uid;
  perform app.audit(bid, 'business.created', 'business', bid::text, jsonb_build_object('name', nm, 'category', cat));
  return bid;
end $$;

create or replace function public.update_business(p_business uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'settings.manage');
  if p ? 'name' and length(btrim(p ->> 'name')) < 2 then perform app.raise('business_name_required'); end if;
  update public.businesses set
    name = coalesce(btrim(p ->> 'name'), name),
    owner_name = case when p ? 'owner_name' then nullif(p ->> 'owner_name', '') else owner_name end,
    email = case when p ? 'email' then nullif(p ->> 'email', '') else email end,
    phone = case when p ? 'phone' then nullif(p ->> 'phone', '') else phone end,
    address = case when p ? 'address' then nullif(p ->> 'address', '') else address end,
    city = case when p ? 'city' then nullif(p ->> 'city', '') else city end,
    language = case when p ->> 'language' in ('en', 'fr') then p ->> 'language' else language end,
    category = case when p ->> 'category' in ('grocery', 'general', 'drinks', 'hardware', 'electronics', 'fashion', 'cosmetics', 'other')
                    then p ->> 'category' else category end,
    logo_path = case when p ? 'logo_path' then nullif(p ->> 'logo_path', '') else logo_path end,
    tax_id = case when p ? 'tax_id' then nullif(p ->> 'tax_id', '') else tax_id end,
    trade_register = case when p ? 'trade_register' then nullif(p ->> 'trade_register', '') else trade_register end,
    reporting_start_date = coalesce(nullif(p ->> 'reporting_start_date', '')::date, reporting_start_date)
  where id = p_business;
  perform app.audit(p_business, 'business.updated', 'business', p_business::text, p);
end $$;

create or replace function public.update_business_settings(p_business uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'settings.manage');
  update public.business_settings set
    allow_negative_stock = coalesce((p ->> 'allow_negative_stock')::boolean, allow_negative_stock),
    cashier_max_discount_pct = coalesce((p ->> 'cashier_max_discount_pct')::numeric, cashier_max_discount_pct),
    allow_credit_sales = coalesce((p ->> 'allow_credit_sales')::boolean, allow_credit_sales),
    tax_enabled = coalesce((p ->> 'tax_enabled')::boolean, tax_enabled),
    tax_rate = coalesce((p ->> 'tax_rate')::numeric, tax_rate),
    tax_label = coalesce(nullif(p ->> 'tax_label', ''), tax_label),
    default_lead_time_days = coalesce((p ->> 'default_lead_time_days')::int, default_lead_time_days),
    safety_stock_days = coalesce((p ->> 'safety_stock_days')::int, safety_stock_days),
    planning_days = coalesce((p ->> 'planning_days')::int, planning_days),
    slow_moving_days = coalesce((p ->> 'slow_moving_days')::int, slow_moving_days),
    expiry_alert_days = coalesce((p ->> 'expiry_alert_days')::int, expiry_alert_days),
    weak_margin_pct = coalesce((p ->> 'weak_margin_pct')::numeric, weak_margin_pct),
    low_stock_default = coalesce((p ->> 'low_stock_default')::numeric, low_stock_default),
    receipt_header = case when p ? 'receipt_header' then nullif(p ->> 'receipt_header', '') else receipt_header end,
    receipt_footer = case when p ? 'receipt_footer' then nullif(p ->> 'receipt_footer', '') else receipt_footer end
  where business_id = p_business;
  perform app.audit(p_business, 'settings.updated', 'business_settings', p_business::text, p);
end $$;

create or replace function public.get_my_context()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return null; end if;
  return jsonb_build_object(
    'user_id', uid,
    'email', (select email from auth.users where id = uid),
    'email_confirmed', (select email_confirmed_at is not null from auth.users where id = uid),
    'profile', (select to_jsonb(pr) from public.profiles pr where pr.id = uid),
    'is_platform_admin', app.is_platform_admin(),
    'pending_invites', (select count(*) from public.business_invites i
                        where lower(i.email) = lower((select email from auth.users where id = uid))
                          and i.accepted_at is null and i.revoked_at is null),
    'businesses', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', b.id, 'name', b.name, 'role', m.role, 'status', b.status, 'currency', b.currency,
        'currency_decimals', b.currency_decimals, 'language', b.language, 'timezone', b.timezone,
        'category', b.category, 'logo_path', b.logo_path, 'country_code', b.country_code,
        'permissions', to_jsonb(app.my_permissions(b.id)),
        'subscription', app.subscription_info(b.id),
        'plan', (select jsonb_build_object('code', ep.code, 'name_en', ep.name_en, 'name_fr', ep.name_fr,
                                           'features', ep.features, 'limits', ep.limits)
                 from app.effective_plan(b.id) ep)
      ) order by b.created_at)
      from public.business_members m join public.businesses b on b.id = m.business_id
      where m.user_id = uid and m.active and b.status <> 'closed'), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------------
create or replace function public.invite_member(p_business uuid, p_email text, p_role text,
  p_display_name text default null, p_permissions jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare iid uuid; em text := lower(btrim(p_email));
begin
  perform app.require_perm(p_business, 'staff.manage');
  perform app.require_feature(p_business, 'staff');
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then perform app.raise('invalid_email'); end if;
  if p_role not in ('manager', 'cashier') then perform app.raise('invalid_role'); end if;
  if exists (select 1 from public.business_members m join auth.users u on u.id = m.user_id
             where m.business_id = p_business and lower(u.email) = em and m.active) then
    perform app.raise('already_member');
  end if;
  perform app.check_limit(p_business, 'max_staff');
  insert into public.business_invites (business_id, email, role, permissions, display_name, invited_by)
  values (p_business, em, p_role, coalesce(p_permissions, '{}'), p_display_name, auth.uid())
  returning id into iid;
  perform app.audit(p_business, 'staff.invited', 'invite', iid::text, jsonb_build_object('email', em, 'role', p_role));
  return iid;
end $$;

create or replace function public.revoke_invite(p_invite uuid)
returns void language plpgsql security definer set search_path = public as $$
declare i public.business_invites;
begin
  select * into i from public.business_invites where id = p_invite;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(i.business_id, 'staff.manage');
  update public.business_invites set revoked_at = now() where id = p_invite and accepted_at is null;
  perform app.audit(i.business_id, 'staff.invite_revoked', 'invite', p_invite::text);
end $$;

create or replace function public.accept_invites()
returns int language plpgsql security definer set search_path = public as $$
declare uid uuid := app.require_auth(); u auth.users; i record; n int := 0;
begin
  select * into u from auth.users where id = uid;
  if u.email_confirmed_at is null then return 0; end if;   -- only verified addresses can claim invites
  for i in select * from public.business_invites
           where lower(email) = lower(u.email) and accepted_at is null and revoked_at is null for update loop
    insert into public.business_members (business_id, user_id, role, permissions, display_name, invited_by)
    values (i.business_id, uid, i.role, i.permissions, i.display_name, i.invited_by)
    on conflict (business_id, user_id) do update set active = true, role = excluded.role,
       permissions = excluded.permissions;
    update public.business_invites set accepted_at = now(), accepted_by = uid where id = i.id;
    perform app.audit(i.business_id, 'staff.joined', 'member', uid::text, jsonb_build_object('role', i.role));
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.update_member(p_member uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare m public.business_members;
begin
  select * into m from public.business_members where id = p_member;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(m.business_id, 'staff.manage');
  if m.role = 'owner' then perform app.raise('cannot_modify_owner'); end if;
  if m.user_id = auth.uid() then perform app.raise('cannot_modify_self'); end if;
  if p ? 'role' and p ->> 'role' not in ('manager', 'cashier') then perform app.raise('invalid_role'); end if;
  if coalesce((p ->> 'active')::boolean, m.active) and not m.active then
    perform app.check_limit(m.business_id, 'max_staff');
  end if;
  update public.business_members set
    role = coalesce(p ->> 'role', role),
    permissions = coalesce(p -> 'permissions', permissions),
    active = coalesce((p ->> 'active')::boolean, active),
    display_name = case when p ? 'display_name' then nullif(p ->> 'display_name', '') else display_name end
  where id = p_member;
  perform app.audit(m.business_id, 'staff.updated', 'member', p_member::text, p);
end $$;

create or replace function public.transfer_ownership(p_business uuid, p_member uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m public.business_members;
begin
  perform app.require_auth();
  if app.member_role(p_business) <> 'owner' then perform app.raise('permission_denied'); end if;
  select * into m from public.business_members where id = p_member and business_id = p_business and active;
  if not found or m.user_id = auth.uid() then perform app.raise('invalid_member'); end if;
  update public.business_members set role = 'manager' where business_id = p_business and user_id = auth.uid();
  update public.business_members set role = 'owner', permissions = '{}' where id = p_member;
  perform app.audit(p_business, 'business.ownership_transferred', 'member', p_member::text);
end $$;

-- ---------------------------------------------------------------------------
-- Billing (manual verification workflow)
-- ---------------------------------------------------------------------------
create or replace function public.submit_billing_payment(p_business uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare pl public.plans; per text := coalesce(p ->> 'billing_period', 'monthly'); expected numeric; pid uuid;
begin
  perform app.require_perm(p_business, 'billing.manage');
  perform app.rate_limit('billing:' || p_business, 10, 86400);
  select * into pl from public.plans where code = p ->> 'plan_code' and active and price_monthly > 0;
  if not found then perform app.raise('invalid_plan'); end if;
  if per not in ('monthly', 'annual') then perform app.raise('invalid_billing_period'); end if;
  expected := case when per = 'annual' then coalesce(pl.price_annual, pl.price_monthly * 12) else pl.price_monthly end;
  if (select count(*) from public.billing_payments where business_id = p_business and status = 'pending') >= 3 then
    perform app.raise('too_many_pending_payments');
  end if;
  begin
    insert into public.billing_payments (business_id, plan_code, billing_period, amount, expected_amount, method,
      transaction_ref, payer_phone, payer_name, proof_path, note, submitted_by)
    values (p_business, pl.code, per, coalesce((p ->> 'amount')::numeric, expected), expected, p ->> 'method',
      btrim(p ->> 'transaction_ref'), nullif(p ->> 'payer_phone', ''), nullif(p ->> 'payer_name', ''),
      nullif(p ->> 'proof_path', ''), nullif(p ->> 'note', ''), auth.uid())
    returning id into pid;
  exception when unique_violation then
    perform app.raise('duplicate_transaction_reference');
  end;
  perform app.audit(p_business, 'billing.payment_submitted', 'billing_payment', pid::text,
                    jsonb_build_object('plan', pl.code, 'amount', expected, 'method', p ->> 'method'));
  return pid;
end $$;

create or replace function public.cancel_subscription(p_business uuid, p_cancel boolean default true)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'billing.manage');
  update public.business_subscriptions set cancel_at_period_end = p_cancel where business_id = p_business;
  perform app.audit(p_business, case when p_cancel then 'subscription.cancel_requested' else 'subscription.resumed' end,
                    'subscription', p_business::text);
end $$;

-- ---------------------------------------------------------------------------
-- Platform administration
-- ---------------------------------------------------------------------------
create or replace function app.require_platform_admin() returns void
language plpgsql stable as $$
begin
  perform app.require_auth();
  if not app.is_platform_admin() then perform app.raise('permission_denied'); end if;
end $$;

-- Run once by the deployer (SQL editor / psql as postgres). Not callable through the API.
create or replace function app.bootstrap_platform_admin(p_email text) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  select id into uid from auth.users where lower(email) = lower(btrim(p_email));
  if uid is null then raise exception 'No user with email % - sign up first', p_email; end if;
  insert into public.platform_admins (user_id, note) values (uid, 'bootstrap') on conflict do nothing;
  insert into public.audit_logs (action, entity, entity_id, details)
  values ('platform.admin_bootstrapped', 'user', uid::text, jsonb_build_object('email', p_email));
  return uid;
end $$;
revoke all on function app.bootstrap_platform_admin(text) from public, anon, authenticated;

create or replace function public.admin_review_billing_payment(p_payment uuid, p_approve boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare bp public.billing_payments; s public.business_subscriptions; start_at timestamptz; end_at timestamptz;
begin
  perform app.require_platform_admin();
  select * into bp from public.billing_payments where id = p_payment for update;
  if not found then perform app.raise('not_found'); end if;
  if bp.status <> 'pending' then perform app.raise('already_reviewed'); end if;
  if not p_approve then
    if coalesce(btrim(p_note), '') = '' then perform app.raise('reason_required'); end if;
    update public.billing_payments set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(),
           review_note = p_note where id = p_payment;
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (bp.business_id, 'billing_payment_rejected', 'warning',
            jsonb_build_object('reference', bp.transaction_ref, 'note', p_note), '/app/billing', 'billing.manage');
  else
    select * into s from public.business_subscriptions where business_id = bp.business_id for update;
    -- Extend from the current paid period end when still running, otherwise from now.
    start_at := case when s.status in ('active', 'cancelled') and s.plan_code = bp.plan_code
                          and s.current_period_end > now() then s.current_period_end else now() end;
    end_at := start_at + case when bp.billing_period = 'annual' then interval '1 year' else interval '1 month' end;
    insert into public.business_subscriptions (business_id, plan_code, status, billing_period, current_period_start,
                                               current_period_end, cancel_at_period_end)
    values (bp.business_id, bp.plan_code, 'active', bp.billing_period, start_at, end_at, false)
    on conflict (business_id) do update set plan_code = excluded.plan_code, status = 'active',
      billing_period = excluded.billing_period, current_period_start = excluded.current_period_start,
      current_period_end = excluded.current_period_end, cancel_at_period_end = false, suspended_reason = null;
    update public.billing_payments set status = 'verified', reviewed_by = auth.uid(), reviewed_at = now(),
           review_note = p_note, period_start = start_at, period_end = end_at where id = p_payment;
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (bp.business_id, 'billing_payment_verified', 'success',
            jsonb_build_object('plan', bp.plan_code, 'period_end', end_at), '/app/billing', 'billing.manage');
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity, entity_id, details)
  values (bp.business_id, auth.uid(), case when p_approve then 'billing.payment_verified' else 'billing.payment_rejected' end,
          'billing_payment', p_payment::text, jsonb_build_object('note', p_note, 'amount', bp.amount,
          'expected', bp.expected_amount, 'reference', bp.transaction_ref));
  return jsonb_build_object('status', case when p_approve then 'verified' else 'rejected' end, 'period_end', end_at);
end $$;

create or replace function public.admin_set_subscription(p_business uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if coalesce(btrim(p ->> 'reason'), '') = '' then perform app.raise('reason_required'); end if;
  update public.business_subscriptions set
    plan_code = coalesce(p ->> 'plan_code', plan_code),
    status = coalesce(p ->> 'status', status),
    current_period_end = coalesce(nullif(p ->> 'current_period_end', '')::timestamptz, current_period_end),
    trial_ends_at = coalesce(nullif(p ->> 'trial_ends_at', '')::timestamptz, trial_ends_at),
    suspended_reason = case when p ->> 'status' = 'suspended' then p ->> 'reason' else null end
  where business_id = p_business;
  insert into public.audit_logs (business_id, user_id, action, entity, entity_id, details)
  values (p_business, auth.uid(), 'admin.subscription_changed', 'subscription', p_business::text, p);
end $$;

create or replace function public.admin_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return jsonb_build_object(
    'businesses', (select count(*) from public.businesses),
    'businesses_30d', (select count(*) from public.businesses where created_at > now() - interval '30 days'),
    'users', (select count(*) from auth.users),
    'active_paid', (select count(*) from public.businesses b where (app.subscription_info(b.id) ->> 'effective_plan') <> 'free'
                     and (app.subscription_info(b.id) ->> 'state') <> 'trial'),
    'trials', (select count(*) from public.businesses b where app.subscription_info(b.id) ->> 'state' = 'trial'),
    'pending_payments', (select count(*) from public.billing_payments where status = 'pending'),
    'verified_revenue_30d', (select coalesce(sum(amount), 0) from public.billing_payments
                             where status = 'verified' and reviewed_at > now() - interval '30 days'),
    'open_support', (select count(*) from public.support_requests where status in ('open', 'in_progress')),
    'ai_queries_30d', (select count(*) from public.ai_queries where created_at > now() - interval '30 days'),
    'ai_failures_30d', (select count(*) from public.ai_queries where status = 'failed' and created_at > now() - interval '30 days'),
    'sales_30d', (select count(*) from public.sales where created_at > now() - interval '30 days'),
    'plans', (select jsonb_object_agg(code, n) from (
      select app.subscription_info(b.id) ->> 'effective_plan' code, count(*) n from public.businesses b group by 1) t));
end $$;

-- Platform-level listing: business metadata and usage counts only (no private records).
create or replace function public.admin_list_businesses(p_search text default null, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select b.id, b.name, b.category, b.country_code, b.status, b.created_at, b.phone,
           (select u.email from public.business_members m join auth.users u on u.id = m.user_id
             where m.business_id = b.id and m.role = 'owner' and m.active) as owner_email,
           app.subscription_info(b.id) as subscription,
           (select count(*) from public.business_members m where m.business_id = b.id and m.active) as members,
           (select count(*) from public.products p where p.business_id = b.id) as products,
           (select count(*) from public.sales s where s.business_id = b.id) as sales_count,
           (select max(s.created_at) from public.sales s where s.business_id = b.id) as last_sale_at,
           exists (select 1 from public.support_access_grants g where g.business_id = b.id
                   and g.revoked_at is null and g.expires_at > now()) as support_access
    from public.businesses b
    where p_search is null or b.name ilike '%' || p_search || '%' or exists (
      select 1 from public.business_members m join auth.users u on u.id = m.user_id
      where m.business_id = b.id and u.email ilike '%' || p_search || '%')
    order by b.created_at desc limit least(p_limit, 200) offset p_offset) t), '[]'::jsonb);
end $$;

create or replace function public.admin_upsert_plan(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  insert into public.plans (code, name_en, name_fr, description_en, description_fr, price_monthly, price_annual,
                            features, limits, is_public, active, highlight, sort)
  values (p ->> 'code', p ->> 'name_en', p ->> 'name_fr', p ->> 'description_en', p ->> 'description_fr',
          (p ->> 'price_monthly')::numeric, nullif(p ->> 'price_annual', '')::numeric,
          array(select jsonb_array_elements_text(p -> 'features')), coalesce(p -> 'limits', '{}'),
          coalesce((p ->> 'is_public')::boolean, true), coalesce((p ->> 'active')::boolean, true),
          coalesce((p ->> 'highlight')::boolean, false), coalesce((p ->> 'sort')::int, 0))
  on conflict (code) do update set name_en = excluded.name_en, name_fr = excluded.name_fr,
    description_en = excluded.description_en, description_fr = excluded.description_fr,
    price_monthly = excluded.price_monthly, price_annual = excluded.price_annual, features = excluded.features,
    limits = excluded.limits, is_public = excluded.is_public, active = excluded.active,
    highlight = excluded.highlight, sort = excluded.sort;
  insert into public.audit_logs (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'admin.plan_saved', 'plan', p ->> 'code', p);
end $$;

create or replace function public.admin_set_config(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if p_key not in ('trial', 'grace_days', 'renewal_notice_days', 'payment_instructions', 'support_contact', 'ai') then
    perform app.raise('invalid_config_key');
  end if;
  update public.app_config set value = p_value, updated_at = now(), updated_by = auth.uid() where key = p_key;
  insert into public.audit_logs (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'admin.config_changed', 'config', p_key, p_value);
end $$;

create or replace function public.admin_save_announcement(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare aid uuid := nullif(p ->> 'id', '')::uuid;
begin
  perform app.require_platform_admin();
  if aid is null then
    insert into public.announcements (title_en, title_fr, body_en, body_fr, level, starts_at, ends_at, active, created_by)
    values (p ->> 'title_en', p ->> 'title_fr', p ->> 'body_en', p ->> 'body_fr', coalesce(p ->> 'level', 'info'),
            coalesce(nullif(p ->> 'starts_at', '')::timestamptz, now()), nullif(p ->> 'ends_at', '')::timestamptz,
            coalesce((p ->> 'active')::boolean, true), auth.uid())
    returning id into aid;
  else
    update public.announcements set title_en = p ->> 'title_en', title_fr = p ->> 'title_fr', body_en = p ->> 'body_en',
      body_fr = p ->> 'body_fr', level = coalesce(p ->> 'level', level),
      ends_at = nullif(p ->> 'ends_at', '')::timestamptz, active = coalesce((p ->> 'active')::boolean, active)
    where id = aid;
  end if;
  insert into public.audit_logs (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'admin.announcement_saved', 'announcement', aid::text, p);
  return aid;
end $$;

create or replace function public.admin_respond_support(p_request uuid, p_status text, p_response text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  update public.support_requests set status = p_status,
    admin_response = coalesce(nullif(p_response, ''), admin_response),
    responded_by = auth.uid(), responded_at = now()
  where id = p_request;
  insert into public.audit_logs (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'admin.support_updated', 'support_request', p_request::text, jsonb_build_object('status', p_status));
end $$;

create or replace function public.admin_add_platform_admin(p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  perform app.require_platform_admin();
  select id into uid from auth.users where lower(email) = lower(btrim(p_email)) and email_confirmed_at is not null;
  if uid is null then perform app.raise('user_not_found'); end if;
  insert into public.platform_admins (user_id, note) values (uid, 'added by ' || auth.uid()) on conflict do nothing;
  insert into public.audit_logs (user_id, action, entity, entity_id) values (auth.uid(), 'admin.admin_added', 'user', uid::text);
end $$;

create or replace function public.admin_ai_usage()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select date_trunc('day', created_at)::date as day, count(*) as queries,
           count(*) filter (where status = 'completed') as completed,
           count(*) filter (where status = 'failed') as failed,
           count(*) filter (where status = 'fallback') as fallback,
           coalesce(sum(input_tokens), 0) as input_tokens, coalesce(sum(output_tokens), 0) as output_tokens,
           count(distinct business_id) as businesses
    from public.ai_queries where created_at > now() - interval '30 days'
    group by 1 order by 1 desc) t), '[]'::jsonb);
end $$;

-- Support access granted by the owner (time-limited).
create or replace function public.grant_support_access(p_business uuid, p_hours int, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
  perform app.require_perm(p_business, 'settings.manage');
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  insert into public.support_access_grants (business_id, granted_by, reason, expires_at)
  values (p_business, auth.uid(), btrim(p_reason), now() + make_interval(hours => least(greatest(p_hours, 1), 72)))
  returning id into gid;
  perform app.audit(p_business, 'support_access.granted', 'support_access', gid::text,
                    jsonb_build_object('hours', p_hours, 'reason', p_reason));
  return gid;
end $$;

create or replace function public.revoke_support_access(p_grant uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g public.support_access_grants;
begin
  select * into g from public.support_access_grants where id = p_grant;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(g.business_id, 'settings.manage');
  update public.support_access_grants set revoked_at = now() where id = p_grant;
  perform app.audit(g.business_id, 'support_access.revoked', 'support_access', p_grant::text);
end $$;

-- Admins must open (and thereby log) a support session before viewing a business.
create or replace function public.admin_open_support_session(p_business uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if not exists (select 1 from public.support_access_grants where business_id = p_business
                 and revoked_at is null and expires_at > now()) then
    perform app.raise('no_support_access');
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity, entity_id, details)
  values (p_business, auth.uid(), 'admin.support_session_opened', 'business', p_business::text,
          jsonb_build_object('reason', p_reason));
end $$;

-- ---------------------------------------------------------------------------
-- Support & contact
-- ---------------------------------------------------------------------------
create or replace function public.submit_support_request(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare rid uuid; uid uuid := auth.uid(); bid uuid := nullif(p ->> 'business_id', '')::uuid; em text;
begin
  em := lower(btrim(coalesce(p ->> 'email', (select email from auth.users where id = uid), '')));
  if uid is null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then perform app.raise('invalid_email'); end if;
  perform app.rate_limit('support:' || coalesce(uid::text, em), 5, 3600);
  if bid is not null and not app.is_member(bid) then bid := null; end if;
  insert into public.support_requests (business_id, user_id, name, email, phone, category, subject, message)
  values (bid, uid, nullif(p ->> 'name', ''), nullif(em, ''), nullif(p ->> 'phone', ''),
          coalesce(nullif(p ->> 'category', ''), 'question'), btrim(p ->> 'subject'), btrim(p ->> 'message'))
  returning id into rid;
  return rid;
end $$;

-- ---------------------------------------------------------------------------
-- Notifications (generated from real records; in-app delivery only)
-- ---------------------------------------------------------------------------
-- Alert generation. app.build_alerts has no caller check and is not exposed to API roles; the
-- app calls public.generate_alerts (members only) and a scheduler can call app.generate_all_alerts().
create or replace function app.build_alerts(p_business uuid)
returns int language plpgsql security definer set search_path = public as $$
declare today date; n int := 0; c int; st public.business_settings; sub jsonb; r record; added int;
begin
  today := app.biz_today(p_business);
  select * into st from public.business_settings where business_id = p_business;

  select count(*) into c from public.products where business_id = p_business and status = 'active'
     and qty_on_hand <= 0 and exists (select 1 from public.stock_movements m where m.product_id = products.id);
  if c > 0 then
    insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
    values (p_business, 'out_of_stock', 'critical', jsonb_build_object('count', c), '/app/inventory?filter=out',
            'out_of_stock:' || today) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;

  select count(*) into c from public.products where business_id = p_business and status = 'active'
     and qty_on_hand > 0 and qty_on_hand <= greatest(min_stock, 0) and min_stock > 0;
  if c > 0 then
    insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
    values (p_business, 'low_stock', 'warning', jsonb_build_object('count', c), '/app/inventory?filter=low',
            'low_stock:' || today) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;

  select count(*), min(expiry_date) into r from public.stock_batches
   where business_id = p_business and remaining_qty > 0 and expiry_date <= today + st.expiry_alert_days;
  if r.count > 0 then
    insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
    values (p_business, 'expiring_soon', 'warning', jsonb_build_object('count', r.count, 'first_expiry', r.min),
            '/app/inventory?tab=expiry', 'expiring:' || today) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;

  for r in select pu.id, pu.number, pu.due_date, pu.total - pu.credited_total - pu.paid_total as owed, s.name
           from public.purchases pu join public.suppliers s on s.id = pu.supplier_id
           where pu.business_id = p_business and pu.status in ('ordered', 'partially_received', 'received')
             and pu.due_date is not null and pu.due_date <= today + 3
             and pu.total - pu.credited_total - pu.paid_total > 0 loop
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (p_business, case when r.due_date < today then 'supplier_payment_overdue' else 'supplier_payment_due' end,
            case when r.due_date < today then 'critical' else 'warning' end,
            jsonb_build_object('supplier', r.name, 'number', r.number, 'due_date', r.due_date, 'amount', r.owed),
            '/app/purchases/' || r.id, 'purchases.manage',
            'supplier_due:' || r.id || ':' || (r.due_date < today)) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end loop;

  select count(*), coalesce(sum(s.total - s.returned_total + s.refunded_total - s.paid_total), 0) into r
    from public.sales s where s.business_id = p_business and s.customer_id is not null
     and s.due_date is not null and s.due_date < today and s.total - s.returned_total + s.refunded_total - s.paid_total > 0;
  if r.count > 0 then
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (p_business, 'customer_overdue', 'warning', jsonb_build_object('count', r.count, 'amount', r.coalesce),
            '/app/customers?filter=overdue', 'customers.credit', 'customer_overdue:' || today) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;

  sub := app.subscription_info(p_business);
  if sub ->> 'state' in ('renewal_due', 'grace', 'expired') or
     (sub ->> 'state' = 'trial' and (sub ->> 'trial_ends_at')::timestamptz < now() + interval '5 days') then
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (p_business, 'subscription_' || (sub ->> 'state'),
            case when sub ->> 'state' in ('grace', 'expired') then 'critical' else 'warning' end,
            sub, '/app/billing', 'billing.manage',
            'subscription:' || (sub ->> 'state') || ':' || coalesce(sub ->> 'current_period_end', sub ->> 'trial_ends_at', ''))
    on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;
  return n;
end $$;

create or replace function public.generate_alerts(p_business uuid)
returns int language plpgsql security definer set search_path = public as $$
begin
  if not app.is_member(p_business) then perform app.raise('permission_denied'); end if;
  return app.build_alerts(p_business);
end $$;

create or replace function app.generate_all_alerts()
returns int language plpgsql security definer set search_path = public as $$
declare b uuid; n int := 0;
begin
  for b in select id from public.businesses loop
    n := n + app.build_alerts(b);
  end loop;
  return n;
end $$;
revoke all on function app.build_alerts(uuid) from public, anon, authenticated;
revoke all on function app.generate_all_alerts() from public, anon, authenticated;

create or replace function public.mark_notifications_read(p_business uuid, p_ids uuid[] default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not app.is_member(p_business) then perform app.raise('permission_denied'); end if;
  insert into public.notification_reads (notification_id, user_id)
  select id, auth.uid() from public.notifications
   where business_id = p_business and (p_ids is null or id = any (p_ids))
  on conflict do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- AI usage metering (called by the ai-advisor Edge Function with the user's JWT)
-- ---------------------------------------------------------------------------
create or replace function public.ai_begin_query(p_business uuid, p_question text, p_from date, p_to date)
returns uuid language plpgsql security definer set search_path = public as $$
declare qid uuid;
begin
  perform app.require_perm(p_business, 'reports.view');
  perform app.require_feature(p_business, 'ai_advisor');
  if coalesce(btrim(p_question), '') = '' or length(p_question) > 1000 then perform app.raise('invalid_question'); end if;
  perform app.rate_limit('ai:' || auth.uid(), 20, 3600);
  perform app.check_limit(p_business, 'ai_queries_per_month');
  insert into public.ai_queries (business_id, user_id, question, period_from, period_to)
  values (p_business, auth.uid(), btrim(p_question), p_from, p_to) returning id into qid;
  return qid;
end $$;

create or replace function public.ai_complete_query(p_query uuid, p_status text, p_answer text, p_model text,
  p_input_tokens int default null, p_output_tokens int default null, p_error text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('completed', 'failed', 'fallback') then perform app.raise('invalid_status'); end if;
  update public.ai_queries set status = p_status, answer = p_answer, model = p_model, input_tokens = p_input_tokens,
         output_tokens = p_output_tokens, error = left(p_error, 500), completed_at = now()
   where id = p_query and user_id = auth.uid() and status = 'started';
  if not found then perform app.raise('not_found'); end if;
end $$;

-- ---------------------------------------------------------------------------
-- Imports (validated, previewable, duplicate-safe, reversible)
-- ---------------------------------------------------------------------------
create or replace function app.num_or_null(v text) returns numeric language plpgsql immutable as $$
begin
  if v is null or btrim(v) = '' then return null; end if;
  return replace(replace(btrim(v), ' ', ''), ',', '.')::numeric;
exception when others then
  return 'NaN'::numeric;
end $$;

create or replace function public.preview_product_import(p_business uuid, p_rows jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb; i int := 0; errs text[]; out jsonb := '[]'; seen_sku text[] := '{}'; seen_bc text[] := '{}';
        v_sku text; v_bc text; ok int := 0; bad int := 0; v numeric; f text;
begin
  perform app.require_perm(p_business, 'imports.manage');
  if jsonb_typeof(p_rows) <> 'array' then perform app.raise('invalid_file'); end if;
  if jsonb_array_length(p_rows) > 2000 then perform app.raise('too_many_rows'); end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1; errs := '{}';
    if coalesce(btrim(r ->> 'name'), '') = '' then errs := errs || 'name_required'::text; end if;
    v_sku := lower(btrim(coalesce(r ->> 'sku', '')));
    if v_sku <> '' then
      if v_sku = any (seen_sku) then errs := errs || 'duplicate_sku_in_file'::text;
      elsif exists (select 1 from public.products where business_id = p_business and lower(products.sku) = v_sku) then
        errs := errs || 'duplicate_sku'::text;
      end if;
      seen_sku := seen_sku || v_sku;
    end if;
    v_bc := btrim(coalesce(r ->> 'barcode', ''));
    if v_bc <> '' then
      if v_bc = any (seen_bc) then errs := errs || 'duplicate_barcode_in_file'::text;
      elsif exists (select 1 from public.products where business_id = p_business and barcode = v_bc) then
        errs := errs || 'duplicate_barcode'::text;
      end if;
      seen_bc := seen_bc || v_bc;
    end if;
    foreach f in array array['purchase_cost', 'selling_price', 'min_stock', 'opening_qty', 'opening_unit_cost'] loop
      v := app.num_or_null(r ->> f);
      if v = 'NaN'::numeric then errs := errs || ('invalid_number:' || f);
      elsif v < 0 then errs := errs || ('negative_number:' || f); end if;
    end loop;
    if app.num_or_null(r ->> 'opening_qty') > 0 and app.num_or_null(r ->> 'opening_qty') <> trunc(app.num_or_null(r ->> 'opening_qty'))
       and lower(coalesce(r ->> 'allow_fraction', '')) not in ('yes', 'true', '1', 'oui') then
      errs := errs || 'fractional_quantity_not_allowed'::text;
    end if;
    if cardinality(errs) = 0 then ok := ok + 1; else bad := bad + 1; end if;
    out := out || jsonb_build_object('row', i, 'ok', cardinality(errs) = 0, 'errors', to_jsonb(errs));
  end loop;
  return jsonb_build_object('rows', out, 'valid', ok, 'invalid', bad, 'total', i,
    'limit', app.plan_limit(p_business, 'max_products'), 'current_products', app.usage_count(p_business, 'max_products'));
end $$;

create or replace function public.import_products(p_business uuid, p_rows jsonb, p_file_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pv jsonb; r jsonb; i int := 0; bid uuid; created int := 0; skipped int := 0; v_issues jsonb := '[]';
        pid uuid; cat uuid; sku text; oq numeric; oc numeric; lim numeric; known boolean;
begin
  perform app.require_perm(p_business, 'imports.manage');
  perform app.require_feature(p_business, 'import');
  pv := public.preview_product_import(p_business, p_rows);
  lim := app.plan_limit(p_business, 'max_products');
  if lim is not null and app.usage_count(p_business, 'max_products') + (pv ->> 'valid')::int > lim then
    perform app.raise('plan_limit_reached', jsonb_build_object('limit', 'max_products', 'max', lim,
      'used', app.usage_count(p_business, 'max_products')));
  end if;
  insert into public.import_batches (business_id, kind, file_name, total_rows, created_by)
  values (p_business, 'products', p_file_name, jsonb_array_length(p_rows), auth.uid()) returning id into bid;

  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    if not ((pv -> 'rows' -> (i - 1)) ->> 'ok')::boolean then
      skipped := skipped + 1;
      v_issues := v_issues || jsonb_build_object('row', i, 'errors', (pv -> 'rows' -> (i - 1)) -> 'errors');
      continue;
    end if;
    cat := null;
    if coalesce(btrim(r ->> 'category'), '') <> '' then
      insert into public.categories (business_id, name) values (p_business, btrim(r ->> 'category'))
      on conflict (business_id, lower(name)) do nothing;
      select id into cat from public.categories where business_id = p_business and lower(name) = lower(btrim(r ->> 'category'));
    end if;
    sku := coalesce(nullif(btrim(r ->> 'sku'), ''), app.next_number(p_business, 'sku', 'SKU-'));
    insert into public.products (business_id, name, sku, barcode, category_id, brand, description, base_unit,
      allow_fraction, purchase_cost, selling_price, min_stock, location, import_batch_id, created_by)
    values (p_business, btrim(r ->> 'name'), sku, nullif(btrim(r ->> 'barcode'), ''), cat, nullif(r ->> 'brand', ''),
      nullif(r ->> 'description', ''), coalesce(nullif(btrim(r ->> 'base_unit'), ''), 'piece'),
      lower(coalesce(r ->> 'allow_fraction', '')) in ('yes', 'true', '1', 'oui'),
      coalesce(app.num_or_null(r ->> 'purchase_cost'), 0), coalesce(app.num_or_null(r ->> 'selling_price'), 0),
      coalesce(app.num_or_null(r ->> 'min_stock'), 0), nullif(r ->> 'location', ''), bid, auth.uid())
    returning id into pid;
    oq := coalesce(app.num_or_null(r ->> 'opening_qty'), 0);
    if oq > 0 then
      oc := app.num_or_null(r ->> 'opening_unit_cost');
      known := oc is not null;
      oc := coalesce(oc, app.num_or_null(r ->> 'purchase_cost'), 0);
      perform app.apply_movement(p_business, pid, 'opening', oq, oc, 'import', bid, null, 'Imported opening stock',
                                 null, not known);
    end if;
    created := created + 1;
  end loop;
  update public.import_batches set created_count = created, skipped_count = skipped, issues = v_issues where id = bid;
  perform app.audit(p_business, 'import.products', 'import_batch', bid::text,
                    jsonb_build_object('created', created, 'skipped', skipped, 'file', p_file_name));
  return jsonb_build_object('batch_id', bid, 'created', created, 'skipped', skipped, 'issues', v_issues);
end $$;

create or replace function public.rollback_import(p_batch uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.import_batches; blocked text[]; n int;
begin
  select * into b from public.import_batches where id = p_batch for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(b.business_id, 'imports.manage');
  if b.status <> 'completed' then perform app.raise('already_rolled_back'); end if;
  if b.kind = 'products' then
    select array_agg(p.name) into blocked from public.products p where p.import_batch_id = p_batch and (
      exists (select 1 from public.stock_movements m where m.product_id = p.id and not (m.ref_type = 'import' and m.ref_id = p_batch))
      or exists (select 1 from public.sale_lines where product_id = p.id)
      or exists (select 1 from public.purchase_lines where product_id = p.id)
      or exists (select 1 from public.stock_count_lines where product_id = p.id));
    if blocked is not null then
      perform app.raise('import_has_activity', jsonb_build_object('products', to_jsonb(blocked[1:10])));
    end if;
    delete from public.stock_movements where ref_type = 'import' and ref_id = p_batch;
    delete from public.products where import_batch_id = p_batch;
    get diagnostics n = row_count;
  elsif b.kind = 'suppliers' then
    if exists (select 1 from public.suppliers s where s.import_batch_id = p_batch and (
         exists (select 1 from public.purchases where supplier_id = s.id)
         or exists (select 1 from public.payments where supplier_id = s.id))) then
      perform app.raise('import_has_activity');
    end if;
    update public.products set preferred_supplier_id = null
     where preferred_supplier_id in (select id from public.suppliers where import_batch_id = p_batch);
    delete from public.suppliers where import_batch_id = p_batch;
    get diagnostics n = row_count;
  else
    if exists (select 1 from public.customers c where c.import_batch_id = p_batch and (
         exists (select 1 from public.sales where customer_id = c.id)
         or exists (select 1 from public.payments where customer_id = c.id))) then
      perform app.raise('import_has_activity');
    end if;
    delete from public.customers where import_batch_id = p_batch;
    get diagnostics n = row_count;
  end if;
  update public.import_batches set status = 'rolled_back', rolled_back_at = now(), rolled_back_by = auth.uid()
   where id = p_batch;
  perform app.audit(b.business_id, 'import.rolled_back', 'import_batch', p_batch::text, jsonb_build_object('removed', n));
  return jsonb_build_object('removed', n);
end $$;

create or replace function public.import_parties(p_business uuid, p_kind text, p_rows jsonb, p_file_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; i int := 0; bid uuid; created int := 0; skipped int := 0; v_issues jsonb := '[]'; nm text;
begin
  if p_kind = 'suppliers' then
    perform app.require_perm(p_business, 'suppliers.manage');
    perform app.require_feature(p_business, 'suppliers');
  elsif p_kind = 'customers' then
    perform app.require_perm(p_business, 'customers.manage');
  else
    perform app.raise('invalid_kind');
  end if;
  perform app.require_feature(p_business, 'import');
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 2000 then perform app.raise('invalid_file'); end if;
  insert into public.import_batches (business_id, kind, file_name, total_rows, created_by)
  values (p_business, p_kind, p_file_name, jsonb_array_length(p_rows), auth.uid()) returning id into bid;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    nm := btrim(coalesce(r ->> 'name', ''));
    if nm = '' then
      skipped := skipped + 1; v_issues := v_issues || jsonb_build_object('row', i, 'errors', '["name_required"]'::jsonb);
      continue;
    end if;
    if p_kind = 'suppliers' then
      if exists (select 1 from public.suppliers where business_id = p_business and lower(name) = lower(nm)) then
        skipped := skipped + 1; v_issues := v_issues || jsonb_build_object('row', i, 'errors', '["duplicate_name"]'::jsonb);
        continue;
      end if;
      insert into public.suppliers (business_id, name, contact_person, phone, email, address, reference,
                                    payment_terms_days, notes, import_batch_id, created_by)
      values (p_business, nm, nullif(r ->> 'contact_person', ''), nullif(r ->> 'phone', ''), nullif(r ->> 'email', ''),
              nullif(r ->> 'address', ''), nullif(r ->> 'reference', ''),
              case when app.num_or_null(r ->> 'payment_terms_days') >= 0 then app.num_or_null(r ->> 'payment_terms_days')::int end,
              nullif(r ->> 'notes', ''), bid, auth.uid());
    else
      if exists (select 1 from public.customers where business_id = p_business and
                 (lower(name) = lower(nm) and coalesce(phone, '') = coalesce(nullif(r ->> 'phone', ''), ''))) then
        skipped := skipped + 1; v_issues := v_issues || jsonb_build_object('row', i, 'errors', '["duplicate_name"]'::jsonb);
        continue;
      end if;
      insert into public.customers (business_id, name, phone, email, address, notes, import_batch_id, created_by)
      values (p_business, nm, nullif(r ->> 'phone', ''), nullif(r ->> 'email', ''), nullif(r ->> 'address', ''),
              nullif(r ->> 'notes', ''), bid, auth.uid());
    end if;
    created := created + 1;
  end loop;
  update public.import_batches set created_count = created, skipped_count = skipped, issues = v_issues where id = bid;
  perform app.audit(p_business, 'import.' || p_kind, 'import_batch', bid::text, jsonb_build_object('created', created));
  return jsonb_build_object('batch_id', bid, 'created', created, 'skipped', skipped, 'issues', v_issues);
end $$;

-- ---------------------------------------------------------------------------
-- Full data export (owner/settings managers)
-- ---------------------------------------------------------------------------
create or replace function public.export_business_data(p_business uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare res jsonb := '{}'; t text; part jsonb;
begin
  perform app.require_perm(p_business, 'settings.manage');
  res := jsonb_build_object('exported_at', now(), 'format_version', 1,
    'business', (select to_jsonb(b) from public.businesses b where id = p_business),
    'settings', (select to_jsonb(s) from public.business_settings s where business_id = p_business));
  foreach t in array array['categories', 'suppliers', 'customers', 'products', 'product_units', 'stock_batches',
    'stock_movements', 'stock_counts', 'stock_count_lines', 'purchases', 'purchase_lines', 'purchase_receipts',
    'purchase_receipt_lines', 'supplier_credits', 'supplier_returns', 'supplier_return_lines', 'sales', 'sale_lines',
    'sale_returns', 'sale_return_lines', 'payments', 'payment_allocations', 'expenses', 'cash_accounts',
    'cash_movements', 'cash_reconciliations', 'cash_reconciliation_lines', 'attachments']::text[] loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from public.%I x where business_id = $1', t)
      into part using p_business;
    res := res || jsonb_build_object(t, part);
  end loop;
  return res;
end $$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.notifications enable row level security;
alter table public.notification_reads enable row level security;
alter table public.support_requests enable row level security;
alter table public.announcements enable row level security;
alter table public.support_access_grants enable row level security;
alter table public.ai_queries enable row level security;
alter table public.rate_limits enable row level security;

create policy notifications_read on public.notifications for select
  using (app.is_member(business_id) and (required_perm is null or app.has_perm(business_id, required_perm)));
create policy notification_reads_read on public.notification_reads for select using (user_id = auth.uid());
create policy support_read on public.support_requests for select
  using (user_id = auth.uid() or app.is_platform_admin());
create policy announcements_read on public.announcements for select
  using ((active and starts_at <= now() and (ends_at is null or ends_at > now())) or app.is_platform_admin());
create policy support_grants_read on public.support_access_grants for select
  using (app.has_perm(business_id, 'settings.manage') or app.is_platform_admin());
create policy ai_queries_read on public.ai_queries for select
  using (user_id = auth.uid() or app.has_perm(business_id, 'settings.manage') or app.is_platform_admin());

-- ===== 20261022000600_analytics.sql =====
-- Analytics and recommendations. Every figure is computed from recorded
-- transactions; nothing is estimated unless explicitly labelled.
-- Date ranges are inclusive local dates in the business's timezone.

create or replace function app.report_guard(bid uuid, feature text default null) returns void
language plpgsql stable as $$
begin
  perform app.require_perm(bid, 'reports.view');
  if feature is not null then perform app.require_feature(bid, feature); end if;
end $$;

-- Clamp the start of a report to the plan's history window.
create or replace function app.report_from(bid uuid, d date) returns date
language sql stable as $$
  select case when app.history_cutoff(bid) = '-infinity'::timestamptz then d
              else greatest(d, (app.history_cutoff(bid) at time zone app.biz_tz(bid))::date) end
$$;

create or replace function app.period_stats(bid uuid, d1 date, d2 date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s timestamptz := app.range_start(bid, d1); e timestamptz := app.range_end(bid, d2);
        sa record; rt record; ex numeric; loss numeric; pu record; cash record; net numeric; cogs numeric;
begin
  select count(*) n, coalesce(sum(total), 0) total, coalesce(sum(tax_total), 0) tax, coalesce(sum(cost_total), 0) cost,
         coalesce(sum(line_discount_total + sale_discount + (list_total - subtotal)), 0) discounts,
         coalesce(sum(total) filter (where customer_id is not null and total > paid_total), 0) credit_sales
    into sa from public.sales where business_id = bid and sold_at >= s and sold_at < e;
  select count(*) n, coalesce(sum(total), 0) total, coalesce(sum(tax_amount), 0) tax, coalesce(sum(cost_amount), 0) cost,
         coalesce(sum(refund_amount), 0) refunded
    into rt from public.sale_returns where business_id = bid and returned_at >= s and returned_at < e;
  select coalesce(sum(amount), 0) into ex from public.expenses
   where business_id = bid and status <> 'voided' and expense_date between d1 and d2;
  select coalesce(-sum(value), 0) into loss from public.stock_movements
   where business_id = bid and movement_type in ('damaged', 'expired', 'missing', 'found', 'correction', 'count')
     and occurred_at >= s and occurred_at < e;
  select count(*) n, coalesce(sum(total), 0) total, coalesce(sum(tax_total), 0) tax into pu from public.purchases
   where business_id = bid and status in ('ordered', 'partially_received', 'received') and purchase_date between d1 and d2;
  select coalesce(sum(amount) filter (where kind in ('sale_payment', 'customer_payment')), 0) received,
         coalesce(sum(amount) filter (where kind = 'customer_refund'), 0) refunds,
         coalesce(sum(amount) filter (where kind = 'supplier_payment'), 0) supplier_paid,
         coalesce(sum(amount) filter (where kind = 'expense_payment'), 0) expenses_paid
    into cash from public.payments where business_id = bid and paid_at >= s and paid_at < e;

  net := (sa.total - sa.tax) - (rt.total - rt.tax);
  cogs := sa.cost - rt.cost;
  return jsonb_build_object(
    'from', d1, 'to', d2,
    'transactions', sa.n,
    'gross_sales', sa.total,
    'discounts', sa.discounts,
    'returns', rt.total,
    'returns_count', rt.n,
    'tax_collected', sa.tax - rt.tax,
    'net_sales', net,
    'cogs', round(cogs, 2),
    'gross_profit', round(net - cogs, 2),
    'gross_margin_pct', case when net > 0 then round((net - cogs) / net * 100, 1) end,
    'operating_expenses', ex,
    'stock_losses', round(loss, 2),
    'operating_profit', round(net - cogs - ex - loss, 2),
    'avg_sale', case when sa.n > 0 then round(sa.total / sa.n, 0) end,
    'credit_sales', sa.credit_sales,
    'purchases_total', pu.total,
    'purchases_count', pu.n,
    'purchase_tax', pu.tax,
    'cash_received', cash.received,
    'refunds_paid', cash.refunds,
    'supplier_payments', cash.supplier_paid,
    'expenses_paid', cash.expenses_paid,
    'units_sold', coalesce((select sum(l.base_quantity) from public.sale_lines l join public.sales x on x.id = l.sale_id
                             where x.business_id = bid and x.sold_at >= s and x.sold_at < e), 0)
                - coalesce((select sum(rl.base_quantity) from public.sale_return_lines rl join public.sale_returns r on r.id = rl.return_id
                             where r.business_id = bid and r.returned_at >= s and r.returned_at < e), 0)
  );
end $$;

create or replace function app.data_quality(bid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'sales_count', (select count(*) from public.sales where business_id = bid),
    'first_sale_at', (select min(sold_at) from public.sales where business_id = bid),
    'history_days', coalesce((select (app.biz_today(bid) - (min(sold_at) at time zone app.biz_tz(bid))::date) + 1
                              from public.sales where business_id = bid), 0),
    'products', (select count(*) from public.products where business_id = bid and status = 'active'),
    'products_with_stock_records', (select count(distinct product_id) from public.stock_movements where business_id = bid),
    'estimated_cost_entries', (select count(*) from public.stock_movements where business_id = bid and cost_estimated),
    'zero_cost_products_sold', (select count(distinct l.product_id) from public.sale_lines l
                                where l.business_id = bid and l.cost_amount = 0 and l.net_amount > 0),
    'purchases_count', (select count(*) from public.purchases where business_id = bid and status <> 'cancelled'),
    'suppliers', (select count(*) from public.suppliers where business_id = bid),
    'expenses_count', (select count(*) from public.expenses where business_id = bid))
$$;

create or replace function app.product_period(bid uuid, d1 date, d2 date)
returns table (product_id uuid, units numeric, revenue numeric, cogs numeric, sale_count bigint, returned_units numeric)
language sql stable security definer set search_path = public as $$
  with s as (
    select l.product_id, sum(l.base_quantity) units, sum(l.net_amount - l.tax_amount) rev, sum(l.cost_amount) cogs,
           count(distinct l.sale_id) cnt
    from public.sale_lines l join public.sales x on x.id = l.sale_id
    where x.business_id = bid and x.sold_at >= app.range_start(bid, d1) and x.sold_at < app.range_end(bid, d2)
    group by l.product_id),
  r as (
    select rl.product_id, sum(rl.base_quantity) units, sum(rl.amount - rl.tax_amount) rev, sum(rl.cost_amount) cogs
    from public.sale_return_lines rl join public.sale_returns rr on rr.id = rl.return_id
    where rr.business_id = bid and rr.returned_at >= app.range_start(bid, d1) and rr.returned_at < app.range_end(bid, d2)
    group by rl.product_id)
  select coalesce(s.product_id, r.product_id),
         coalesce(s.units, 0) - coalesce(r.units, 0),
         coalesce(s.rev, 0) - coalesce(r.rev, 0),
         coalesce(s.cogs, 0) - coalesce(r.cogs, 0),
         coalesce(s.cnt, 0),
         coalesce(r.units, 0)
  from s full join r on r.product_id = s.product_id
$$;

-- ---------------------------------------------------------------------------
-- Dashboard
-- ---------------------------------------------------------------------------
create or replace function public.dashboard_summary(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; len int; prev jsonb; cur jsonb; st public.business_settings; today date;
begin
  perform app.report_guard(p_business);
  d1 := app.report_from(p_business, p_from);
  len := p_to - d1 + 1;
  today := app.biz_today(p_business);
  select * into st from public.business_settings where business_id = p_business;
  cur := app.period_stats(p_business, d1, p_to);
  prev := app.period_stats(p_business, d1 - len, d1 - 1);
  return jsonb_build_object(
    'period', cur,
    'previous', prev,
    'inventory_value', (select coalesce(sum(stock_value), 0) from public.products where business_id = p_business),
    'inventory_value_at_start', (select coalesce(sum(value), 0) from public.stock_movements
                                 where business_id = p_business and occurred_at < app.range_start(p_business, d1)),
    'inventory_units', (select coalesce(sum(qty_on_hand), 0) from public.products where business_id = p_business and status = 'active'),
    'low_stock', (select count(*) from public.products where business_id = p_business and status = 'active'
                  and qty_on_hand > 0 and min_stock > 0 and qty_on_hand <= min_stock),
    'out_of_stock', (select count(*) from public.products p where business_id = p_business and status = 'active'
                     and qty_on_hand <= 0 and exists (select 1 from public.stock_movements m where m.product_id = p.id)),
    'never_stocked', (select count(*) from public.products p where business_id = p_business and status = 'active'
                      and not exists (select 1 from public.stock_movements m where m.product_id = p.id)),
    'expiring_soon', (select count(*) from public.stock_batches where business_id = p_business and remaining_qty > 0
                      and expiry_date <= today + st.expiry_alert_days),
    'slow_moving', (select count(*) from public.products p where p.business_id = p_business and p.status = 'active'
                    and p.qty_on_hand > 0 and p.created_at < now() - make_interval(days => st.slow_moving_days)
                    and not exists (select 1 from public.sale_lines l join public.sales s on s.id = l.sale_id
                                    where l.product_id = p.id and s.sold_at > now() - make_interval(days => st.slow_moving_days))),
    'receivables', (select coalesce(sum(greatest(total - returned_total + refunded_total - paid_total, 0)), 0)
                    from public.sales where business_id = p_business and customer_id is not null),
    'payables', (select coalesce(sum(greatest(total - credited_total - paid_total, 0)), 0) from public.purchases
                 where business_id = p_business and status in ('ordered', 'partially_received', 'received')),
    'today', app.period_stats(p_business, today, today),
    'data_quality', app.data_quality(p_business),
    'history_clamped', d1 > p_from,
    'effective_from', d1);
end $$;

-- Limited summary for cashiers: only what they need at the counter.
create or replace function public.counter_summary(p_business uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := app.biz_today(p_business);
begin
  perform app.require_perm(p_business, 'sales.create');
  return jsonb_build_object(
    'my_sales_today', (select count(*) from public.sales where business_id = p_business and created_by = auth.uid()
                       and sold_at >= app.range_start(p_business, today)),
    'my_total_today', (select coalesce(sum(total), 0) from public.sales where business_id = p_business
                       and created_by = auth.uid() and sold_at >= app.range_start(p_business, today)),
    'low_stock', (select count(*) from public.products where business_id = p_business and status = 'active'
                  and qty_on_hand > 0 and min_stock > 0 and qty_on_hand <= min_stock),
    'out_of_stock', (select count(*) from public.products p where business_id = p_business and status = 'active'
                     and qty_on_hand <= 0 and exists (select 1 from public.stock_movements m where m.product_id = p.id)));
end $$;

create or replace function public.sales_timeseries(p_business uuid, p_from date, p_to date, p_grain text default 'day')
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; g text := case when p_grain in ('day', 'week', 'month') then p_grain else 'day' end; tz text;
begin
  perform app.report_guard(p_business);
  d1 := app.report_from(p_business, p_from);
  tz := app.biz_tz(p_business);
  return coalesce((select jsonb_agg(jsonb_build_object('bucket', b.bucket, 'net_sales', coalesce(x.rev, 0) - coalesce(y.rev, 0),
        'gross_profit', round(coalesce(x.rev, 0) - coalesce(y.rev, 0) - coalesce(x.cogs, 0) + coalesce(y.cogs, 0), 2),
        'transactions', coalesce(x.n, 0)) order by b.bucket)
    from (select generate_series(date_trunc(g, d1::timestamp), date_trunc(g, p_to::timestamp), ('1 ' || g)::interval)::date bucket) b
    left join (select date_trunc(g, sold_at at time zone tz)::date bucket, sum(total - tax_total) rev, sum(cost_total) cogs, count(*) n
               from public.sales where business_id = p_business and sold_at >= app.range_start(p_business, d1)
                 and sold_at < app.range_end(p_business, p_to) group by 1) x on x.bucket = b.bucket
    left join (select date_trunc(g, returned_at at time zone tz)::date bucket, sum(total - tax_amount) rev, sum(cost_amount) cogs
               from public.sale_returns where business_id = p_business and returned_at >= app.range_start(p_business, d1)
                 and returned_at < app.range_end(p_business, p_to) group by 1) y on y.bucket = b.bucket), '[]'::jsonb);
end $$;

create or replace function public.inventory_value_series(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; tz text; base numeric;
begin
  perform app.report_guard(p_business);
  d1 := app.report_from(p_business, p_from);
  tz := app.biz_tz(p_business);
  select coalesce(sum(value), 0) into base from public.stock_movements
   where business_id = p_business and occurred_at < app.range_start(p_business, d1);
  return coalesce((select jsonb_agg(jsonb_build_object('day', t.dt, 'value', round(base + t.cum, 0)) order by t.dt)
    from (select d.dt, coalesce(sum(m.v) over (order by d.dt), 0) as cum
          from (select generate_series(d1, p_to, interval '1 day')::date as dt) d
          left join (select (occurred_at at time zone tz)::date as dt, sum(value) as v from public.stock_movements
                     where business_id = p_business and occurred_at >= app.range_start(p_business, d1)
                       and occurred_at < app.range_end(p_business, p_to) group by 1) m on m.dt = d.dt) t), '[]'::jsonb);
end $$;

create or replace function public.top_products(p_business uuid, p_from date, p_to date, p_limit int default 5)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date;
begin
  perform app.report_guard(p_business);
  d1 := app.report_from(p_business, p_from);
  return coalesce((select jsonb_agg(t) from (
    select p.id, p.name, p.sku, p.base_unit, p.image_path, pp.units, pp.revenue, round(pp.revenue - pp.cogs, 2) gross_profit
    from app.product_period(p_business, d1, p_to) pp join public.products p on p.id = pp.product_id
    where pp.units > 0 order by pp.units desc, pp.revenue desc limit least(p_limit, 50)) t), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- Product & category performance
-- ---------------------------------------------------------------------------
create or replace function public.product_performance(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; days int;
begin
  perform app.report_guard(p_business, 'basic_analytics');
  d1 := app.report_from(p_business, p_from);
  days := p_to - d1 + 1;
  return coalesce((select jsonb_agg(t order by t.revenue desc nulls last, t.name) from (
    select p.id, p.name, p.sku, p.base_unit, p.status, c.name category, p.qty_on_hand, p.stock_value, p.avg_cost,
           p.selling_price, p.min_stock, p.created_at,
           coalesce(pp.units, 0) units, coalesce(pp.revenue, 0) revenue, round(coalesce(pp.cogs, 0), 2) cogs,
           round(coalesce(pp.revenue, 0) - coalesce(pp.cogs, 0), 2) gross_profit,
           case when coalesce(pp.revenue, 0) > 0 then round((pp.revenue - pp.cogs) / pp.revenue * 100, 1) end margin_pct,
           coalesce(pp.sale_count, 0) sale_count, coalesce(pp.returned_units, 0) returned_units,
           round(coalesce(pp.units, 0) / greatest(1, least(days, (p_to - (p.created_at at time zone app.biz_tz(p_business))::date + 1))), 3) units_per_day,
           case when p.selling_price > 0 then round((p.selling_price - p.avg_cost) / p.selling_price * 100, 1) end price_margin_pct,
           (select max(s.sold_at) from public.sale_lines l join public.sales s on s.id = l.sale_id where l.product_id = p.id) last_sold_at
    from public.products p
    left join app.product_period(p_business, d1, p_to) pp on pp.product_id = p.id
    left join public.categories c on c.id = p.category_id
    where p.business_id = p_business and (p.status = 'active' or pp.units <> 0)) t), '[]'::jsonb);
end $$;

create or replace function public.category_performance(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; tot numeric;
begin
  perform app.report_guard(p_business, 'basic_analytics');
  d1 := app.report_from(p_business, p_from);
  select coalesce(sum(revenue), 0) into tot from app.product_period(p_business, d1, p_to);
  return coalesce((select jsonb_agg(t order by t.revenue desc) from (
    select c.id, c.name category,
           coalesce(sum(pp.units), 0) units, coalesce(sum(pp.revenue), 0) revenue,
           round(coalesce(sum(pp.revenue - pp.cogs), 0), 2) gross_profit,
           case when sum(pp.revenue) > 0 then round(sum(pp.revenue - pp.cogs) / sum(pp.revenue) * 100, 1) end margin_pct,
           case when tot > 0 then round(coalesce(sum(pp.revenue), 0) / tot * 100, 1) end revenue_share_pct,
           round(sum(p.stock_value), 0) inventory_value, count(p.id) products
    from public.products p
    left join public.categories c on c.id = p.category_id
    left join app.product_period(p_business, d1, p_to) pp on pp.product_id = p.id
    where p.business_id = p_business
    group by c.id, c.name
    having coalesce(sum(pp.revenue), 0) <> 0 or sum(p.stock_value) > 0) t), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- Restocking recommendations
-- ---------------------------------------------------------------------------
create or replace function public.restock_recommendations(p_business uuid, p_lookback int default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st public.business_settings; today date; lb int := least(greatest(coalesce(p_lookback, 30), 7), 365);
begin
  perform app.report_guard(p_business, 'restock');
  select * into st from public.business_settings where business_id = p_business;
  today := app.biz_today(p_business);
  return coalesce((select jsonb_agg(t order by t.priority_rank, t.days_of_cover nulls last, t.name) from (
    select x.*,
      case when x.recommended_qty > 0 and x.purchase_factor > 1 then ceil(x.recommended_qty / x.purchase_factor) end recommended_purchase_units,
      round(x.recommended_qty * greatest(x.avg_cost, x.purchase_cost), 0) estimated_cost,
      case when x.priority = 'urgent' then 1 when x.priority = 'soon' then 2 else 3 end priority_rank
    from (
      select y.*,
        case when y.target_qty - y.available > 0
             then greatest(ceil(y.target_qty - y.available), coalesce(y.min_order_qty, 0)) else 0 end recommended_qty,
        case when y.qty_on_hand <= 0 and y.avg_daily > 0 then 'urgent'
             when y.avg_daily > 0 and y.qty_on_hand / y.avg_daily < y.lead_days then 'urgent'
             when y.avg_daily > 0 and y.qty_on_hand / y.avg_daily < y.lead_days + st.safety_stock_days then 'soon'
             when y.qty_on_hand <= y.min_stock then 'soon'
             else 'plan' end priority,
        case when y.sales_count < 5 or y.observed_days < 14 then 'low'
             when y.sales_count < 20 then 'medium' else 'high' end confidence
      from (
        select z.*,
          round(z.units / z.observed_days, 3) avg_daily,
          case when z.units > 0 then round(z.qty_on_hand / (z.units / z.observed_days), 1) end days_of_cover,
          round(z.units / z.observed_days * (z.lead_days + st.safety_stock_days), 2) reorder_point,
          greatest(round(z.units / z.observed_days * (z.lead_days + st.safety_stock_days + st.planning_days), 2), z.min_stock) target_qty,
          z.qty_on_hand + z.incoming available
        from (
          select p.id product_id, p.name, p.sku, p.base_unit, p.qty_on_hand, p.min_stock, p.avg_cost, p.purchase_cost,
                 p.min_order_qty, sp.id supplier_id, sp.name supplier_name,
                 coalesce(p.lead_time_days, sp.lead_time_days, st.default_lead_time_days) lead_days,
                 coalesce(pp.units, 0) units, coalesce(pp.sale_count, 0) sales_count,
                 greatest(1, least(lb, today - (p.created_at at time zone app.biz_tz(p_business))::date + 1)) observed_days,
                 coalesce((select sum((pl.qty_ordered - pl.qty_received) * pl.unit_factor) from public.purchase_lines pl
                           join public.purchases pu on pu.id = pl.purchase_id
                           where pl.product_id = p.id and pu.status in ('ordered', 'partially_received')), 0) incoming,
                 coalesce((select pu2.factor from public.product_units pu2 where pu2.product_id = p.id and pu2.is_default_purchase
                           and pu2.active limit 1), 1) purchase_factor,
                 (select pu2.name from public.product_units pu2 where pu2.product_id = p.id and pu2.is_default_purchase
                           and pu2.active limit 1) purchase_unit
          from public.products p
          left join public.suppliers sp on sp.id = p.preferred_supplier_id
          left join app.product_period(p_business, today - lb + 1, today) pp on pp.product_id = p.id
          where p.business_id = p_business and p.status = 'active') z) y
      where (y.avg_daily > 0 or y.min_stock > 0) and y.available <= greatest(y.reorder_point, y.min_stock)) x) t), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- Slow-moving stock and inventory aging
-- ---------------------------------------------------------------------------
create or replace function public.slow_moving_products(p_business uuid, p_days int default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare w int; today date; total_value numeric;
begin
  perform app.report_guard(p_business, 'advanced_analytics');
  select coalesce(p_days, slow_moving_days) into w from public.business_settings where business_id = p_business;
  today := app.biz_today(p_business);
  select coalesce(sum(stock_value), 0) into total_value from public.products where business_id = p_business;
  return coalesce((select jsonb_agg(t order by t.stock_value desc) from (
    select p.id, p.name, p.sku, p.base_unit, p.qty_on_hand, p.stock_value, p.selling_price, p.avg_cost,
      coalesce(pp.units, 0) units_in_window, w window_days,
      case when coalesce(pp.units, 0) = 0 then 'no_sales' else 'slow' end classification,
      case when coalesce(pp.units, 0) > 0 then round(p.qty_on_hand / (pp.units / w), 0) end days_of_cover,
      case when p.selling_price > 0 then round((p.selling_price - p.avg_cost) / p.selling_price * 100, 1) end price_margin_pct,
      case when total_value > 0 then round(p.stock_value / total_value * 100, 1) end inventory_share_pct,
      (select max(s.sold_at) from public.sale_lines l join public.sales s on s.id = l.sale_id where l.product_id = p.id) last_sold_at,
      (select max(m.occurred_at) from public.stock_movements m where m.product_id = p.id
         and m.movement_type in ('purchase_receipt', 'opening')) last_received_at,
      exists (select 1 from public.stock_movements m where m.product_id = p.id and m.qty_after <= 0
              and m.occurred_at > now() - make_interval(days => w)) was_out_of_stock_in_window
    from public.products p
    left join app.product_period(p_business, today - w + 1, today) pp on pp.product_id = p.id
    where p.business_id = p_business and p.status = 'active' and p.qty_on_hand > 0
      and p.created_at < now() - make_interval(days => w)
      and (select min(m.occurred_at) from public.stock_movements m where m.product_id = p.id and m.quantity > 0)
          < now() - make_interval(days => w)
      and (coalesce(pp.units, 0) = 0 or p.qty_on_hand / (pp.units / w) > 90)) t), '[]'::jsonb);
end $$;

create or replace function public.inventory_aging(p_business uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform app.report_guard(p_business, 'advanced_analytics');
  return (with inflows as (
      select m.product_id, m.occurred_at, m.quantity, p.qty_on_hand, p.avg_cost,
             sum(m.quantity) over (partition by m.product_id order by m.occurred_at desc, m.created_at desc, m.id) cum
      from public.stock_movements m join public.products p on p.id = m.product_id
      where m.business_id = p_business and p.qty_on_hand > 0 and m.quantity > 0
        and m.movement_type in ('opening', 'purchase_receipt', 'sale_return', 'found', 'correction', 'count')),
    layers as (
      select product_id, occurred_at, least(quantity, qty_on_hand - (cum - quantity)) qty, avg_cost,
             now()::date - occurred_at::date age_days
      from inflows where cum - quantity < qty_on_hand),
    per_product as (
      select l.product_id, max(l.age_days) oldest_days,
             round(sum(l.qty * l.age_days) / nullif(sum(l.qty), 0), 0) weighted_age_days,
             round(sum(l.qty * l.avg_cost), 0) value
      from layers l group by l.product_id)
    select jsonb_build_object(
      'buckets', (select jsonb_build_object(
          'd0_30', round(coalesce(sum(qty * avg_cost) filter (where age_days <= 30), 0), 0),
          'd31_60', round(coalesce(sum(qty * avg_cost) filter (where age_days between 31 and 60), 0), 0),
          'd61_90', round(coalesce(sum(qty * avg_cost) filter (where age_days between 61 and 90), 0), 0),
          'd90_plus', round(coalesce(sum(qty * avg_cost) filter (where age_days > 90), 0), 0)) from layers),
      'products', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'qty_on_hand', p.qty_on_hand,
           'base_unit', p.base_unit, 'value', pp.value, 'oldest_days', pp.oldest_days,
           'weighted_age_days', pp.weighted_age_days) order by pp.weighted_age_days desc nulls last)
         from per_product pp join public.products p on p.id = pp.product_id), '[]'::jsonb)));
end $$;

-- ---------------------------------------------------------------------------
-- Suppliers, discrepancies, purchasing efficiency, weekday pattern
-- ---------------------------------------------------------------------------
create or replace function public.supplier_comparison(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date;
begin
  perform app.report_guard(p_business, 'advanced_analytics');
  d1 := app.report_from(p_business, p_from);
  return jsonb_build_object(
    'suppliers', coalesce((select jsonb_agg(t order by t.purchased desc) from (
      select s.id, s.name, s.payment_terms_days, s.lead_time_days, s.quality_notes,
        count(pu.id) purchases, coalesce(sum(pu.total), 0) purchased,
        count(pu.id) filter (where pu.expected_date is not null and pu.first_received_at is not null) deliveries_tracked,
        count(pu.id) filter (where pu.expected_date is not null and pu.first_received_at is not null
                             and (pu.first_received_at at time zone app.biz_tz(p_business))::date <= pu.expected_date) on_time,
        round(avg(((pu.first_received_at at time zone app.biz_tz(p_business))::date - pu.purchase_date))
              filter (where pu.first_received_at is not null), 1) avg_lead_days,
        (select count(*) from public.supplier_returns r where r.supplier_id = s.id) returns_count,
        app.supplier_balance(s.id) balance
      from public.suppliers s
      left join public.purchases pu on pu.supplier_id = s.id and pu.status in ('ordered', 'partially_received', 'received')
                                   and pu.purchase_date between d1 and p_to
      where s.business_id = p_business
      group by s.id) t where t.purchases > 0 or t.balance <> 0), '[]'::jsonb),
    'price_comparison', coalesce((select jsonb_agg(t order by t.product_name, t.avg_unit_cost) from (
      select p.id product_id, p.name product_name, p.base_unit, s.id supplier_id, s.name supplier_name,
             round(avg(pl.landed_unit_cost_base), 2) avg_unit_cost, round(min(pl.landed_unit_cost_base), 2) min_unit_cost,
             max(pu.purchase_date) last_purchase, count(*) lines
      from public.purchase_lines pl join public.purchases pu on pu.id = pl.purchase_id
      join public.products p on p.id = pl.product_id join public.suppliers s on s.id = pu.supplier_id
      where pu.business_id = p_business and pl.landed_unit_cost_base is not null
        and pu.purchase_date between d1 and p_to
        and pl.product_id in (select pl2.product_id from public.purchase_lines pl2 join public.purchases pu2 on pu2.id = pl2.purchase_id
                              where pu2.business_id = p_business and pl2.landed_unit_cost_base is not null
                                and pu2.purchase_date between d1 and p_to
                              group by pl2.product_id having count(distinct pu2.supplier_id) > 1)
      group by p.id, s.id) t), '[]'::jsonb));
end $$;

create or replace function public.inventory_discrepancies(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; s timestamptz; e timestamptz;
begin
  perform app.report_guard(p_business, 'advanced_analytics');
  d1 := app.report_from(p_business, p_from);
  s := app.range_start(p_business, d1); e := app.range_end(p_business, p_to);
  return jsonb_build_object(
    'adjustments', coalesce((select jsonb_agg(t order by t.loss_value desc) from (
      select p.id, p.name, p.base_unit, count(*) adjustments,
             count(*) filter (where m.quantity < 0) loss_events,
             sum(m.quantity) net_quantity, round(-sum(m.value), 0) loss_value,
             jsonb_object_agg(m.movement_type, 1) types
      from public.stock_movements m join public.products p on p.id = m.product_id
      where m.business_id = p_business and m.movement_type in ('damaged', 'expired', 'missing', 'found', 'correction', 'count')
        and m.occurred_at >= s and m.occurred_at < e
      group by p.id) t), '[]'::jsonb),
    'negative_stock', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'qty_on_hand', qty_on_hand))
      from public.products where business_id = p_business and qty_on_hand < 0), '[]'::jsonb),
    'count_differences', coalesce((select jsonb_agg(t) from (
      select c.number, c.completed_at, p.name, l.system_qty_at_completion, l.counted_qty, l.difference,
             round(l.value_difference, 0) value_difference, l.reason
      from public.stock_count_lines l join public.stock_counts c on c.id = l.count_id
      join public.products p on p.id = l.product_id
      where c.business_id = p_business and c.status = 'completed' and l.difference <> 0
        and c.completed_at >= s and c.completed_at < e
      order by abs(l.value_difference) desc nulls last limit 100) t), '[]'::jsonb));
end $$;

create or replace function public.purchasing_efficiency(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; s timestamptz; e timestamptz; days int;
begin
  perform app.report_guard(p_business, 'advanced_analytics');
  d1 := app.report_from(p_business, p_from);
  s := app.range_start(p_business, d1); e := app.range_end(p_business, p_to);
  days := p_to - d1 + 1;
  return coalesce((select jsonb_agg(t order by t.received_value desc) from (
    select p.id, p.name, p.base_unit, p.qty_on_hand, rc.qty received_qty, round(rc.val, 0) received_value,
           coalesce(pp.units, 0) sold_qty,
           case when coalesce(pp.units, 0) > 0 then round(rc.qty / pp.units, 2) end bought_to_sold_ratio,
           case when coalesce(pp.units, 0) > 0 then round(p.qty_on_hand / (pp.units / days), 0) end days_of_cover,
           case when coalesce(pp.units, 0) = 0 and rc.qty > 0 then 'no_sales_after_purchase'
                when rc.qty > 1.5 * pp.units and p.qty_on_hand / nullif(pp.units / days, 0) > 60 then 'possible_overbuying'
                when p.qty_on_hand <= 0 and pp.units > 0 then 'stocked_out'
                else 'balanced' end assessment
    from (select m.product_id, sum(m.quantity) qty, sum(m.value) val from public.stock_movements m
          where m.business_id = p_business and m.movement_type = 'purchase_receipt' and m.occurred_at >= s and m.occurred_at < e
          group by m.product_id) rc
    join public.products p on p.id = rc.product_id
    left join app.product_period(p_business, d1, p_to) pp on pp.product_id = p.id) t), '[]'::jsonb);
end $$;

create or replace function public.weekday_pattern(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; tz text;
begin
  perform app.report_guard(p_business, 'basic_analytics');
  d1 := app.report_from(p_business, p_from);
  tz := app.biz_tz(p_business);
  return jsonb_build_object('days', p_to - d1 + 1, 'pattern', coalesce((select jsonb_agg(t order by t.dow) from (
    select extract(isodow from d.dt)::int as dow, count(*) as day_count,
           round(coalesce(sum(x.rev), 0) / count(*), 0) as avg_net_sales,
           round(coalesce(sum(x.n), 0)::numeric / count(*), 1) as avg_transactions
    from (select generate_series(d1, p_to, interval '1 day')::date as dt) d
    left join (select (sold_at at time zone tz)::date as dt, sum(total - tax_total) as rev, count(*) as n from public.sales
               where business_id = p_business and sold_at >= app.range_start(p_business, d1)
                 and sold_at < app.range_end(p_business, p_to) group by 1) x on x.dt = d.dt
    group by 1) t), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- Balances and statements
-- ---------------------------------------------------------------------------
create or replace function public.supplier_balances(p_business uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := app.biz_today(p_business);
begin
  perform app.require_perm(p_business, 'purchases.manage');
  return coalesce((select jsonb_agg(t order by t.balance desc) from (
    select s.id, s.name, s.phone, s.status, app.supplier_balance(s.id) balance,
           (select coalesce(sum(total - credited_total - paid_total), 0) from public.purchases pu where pu.supplier_id = s.id
              and pu.status in ('ordered', 'partially_received', 'received') and pu.due_date < today) overdue,
           (select min(due_date) from public.purchases pu where pu.supplier_id = s.id
              and pu.status in ('ordered', 'partially_received', 'received') and total - credited_total - paid_total > 0) next_due,
           (select max(purchase_date) from public.purchases pu where pu.supplier_id = s.id and pu.status <> 'cancelled') last_purchase,
           (select coalesce(sum(total), 0) from public.purchases pu where pu.supplier_id = s.id
              and pu.status in ('ordered', 'partially_received', 'received')) total_purchased
    from public.suppliers s where s.business_id = p_business) t), '[]'::jsonb);
end $$;

create or replace function public.customer_balances(p_business uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := app.biz_today(p_business);
begin
  perform app.require_perm(p_business, 'customers.manage');
  return coalesce((select jsonb_agg(t order by t.balance desc) from (
    select c.id, c.name, c.phone, c.status, c.credit_limit, app.customer_balance(c.id) balance,
           (select coalesce(sum(total - returned_total + refunded_total - paid_total), 0) from public.sales s
             where s.customer_id = c.id and s.due_date < today) overdue,
           (select min(due_date) from public.sales s where s.customer_id = c.id
              and total - returned_total + refunded_total - paid_total > 0) oldest_due,
           (select max(sold_at) from public.sales s where s.customer_id = c.id) last_sale,
           (select coalesce(sum(total - returned_total), 0) from public.sales s where s.customer_id = c.id) lifetime_sales
    from public.customers c where c.business_id = p_business) t), '[]'::jsonb);
end $$;

create or replace function public.party_statement(p_business uuid, p_kind text, p_party uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if p_kind = 'customer' then
    perform app.require_perm(p_business, 'customers.manage');
    if not exists (select 1 from public.customers where id = p_party and business_id = p_business) then perform app.raise('not_found'); end if;
    return coalesce((select jsonb_agg(t order by t.at, t.ref) from (
      select x.*, sum(x.debit - x.credit) over (order by x.at, x.ref rows unbounded preceding) running_balance from (
        select sold_at at, number ref, 'sale' type, total debit, 0::numeric credit, id from public.sales where customer_id = p_party
        union all select returned_at, number, 'return', 0, total, id from public.sale_returns where customer_id = p_party
        union all select paid_at, coalesce(reference, kind), kind, case when direction = 'out' then amount else 0 end,
                         case when direction = 'in' then amount else 0 end, id
                  from public.payments where customer_id = p_party) x) t), '[]'::jsonb);
  elsif p_kind = 'supplier' then
    perform app.require_perm(p_business, 'purchases.manage');
    if not exists (select 1 from public.suppliers where id = p_party and business_id = p_business) then perform app.raise('not_found'); end if;
    return coalesce((select jsonb_agg(t order by t.at, t.ref) from (
      select x.*, sum(x.credit - x.debit) over (order by x.at, x.ref rows unbounded preceding) running_balance from (
        select (purchase_date::timestamp at time zone app.biz_tz(p_business)) at, number ref, 'purchase' type,
               0::numeric debit, total credit, id
          from public.purchases where supplier_id = p_party and status in ('ordered', 'partially_received', 'received')
        union all select created_at, kind, 'credit_' || kind, amount, 0, id from public.supplier_credits where supplier_id = p_party
        union all select paid_at, coalesce(reference, kind), kind, case when kind = 'supplier_payment' then amount else 0 end,
                         case when kind = 'supplier_refund' then amount else 0 end, id
                  from public.payments where supplier_id = p_party) x) t), '[]'::jsonb);
  end if;
  perform app.raise('invalid_kind');
end $$;

create or replace function public.profit_and_loss(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date;
begin
  perform app.report_guard(p_business, 'basic_analytics');
  d1 := app.report_from(p_business, p_from);
  return app.period_stats(p_business, d1, p_to) || jsonb_build_object(
    'expenses_by_category', coalesce((select jsonb_agg(t order by t.amount desc) from (
      select category, sum(amount) amount, count(*) entries from public.expenses
      where business_id = p_business and status <> 'voided' and expense_date between d1 and p_to group by category) t), '[]'::jsonb),
    'losses_by_type', coalesce((select jsonb_agg(t) from (
      select movement_type, round(-sum(value), 0) value, count(*) entries from public.stock_movements
      where business_id = p_business and movement_type in ('damaged', 'expired', 'missing', 'found', 'correction', 'count')
        and occurred_at >= app.range_start(p_business, d1) and occurred_at < app.range_end(p_business, p_to)
      group by movement_type) t), '[]'::jsonb),
    'data_quality', app.data_quality(p_business),
    'effective_from', d1);
end $$;

-- ---------------------------------------------------------------------------
-- Rule-based insights (work without any AI service)
-- Each insight: code, severity, period, params (evidence numbers), limitations.
-- The client renders title / finding / why / action text from the code.
-- ---------------------------------------------------------------------------
create or replace function public.business_insights(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  d1 date; len int; cur jsonb; prev jsonb; out jsonb := '[]'; st public.business_settings; dq jsonb;
  per jsonb; lim jsonb; r record; j jsonb; inv numeric; v numeric; today date;
begin
  perform app.report_guard(p_business, 'basic_analytics');
  d1 := app.report_from(p_business, p_from);
  len := p_to - d1 + 1;
  today := app.biz_today(p_business);
  select * into st from public.business_settings where business_id = p_business;
  cur := app.period_stats(p_business, d1, p_to);
  prev := app.period_stats(p_business, d1 - len, d1 - 1);
  dq := app.data_quality(p_business);
  per := jsonb_build_object('from', d1, 'to', p_to);
  lim := '[]';
  if (dq ->> 'estimated_cost_entries')::int > 0 then lim := lim || '"estimated_costs"'; end if;
  if (dq ->> 'zero_cost_products_sold')::int > 0 then lim := lim || '"zero_cost_sales"'; end if;
  if (dq ->> 'history_days')::int < 30 then lim := lim || '"short_history"'; end if;
  select coalesce(sum(stock_value), 0) into inv from public.products where business_id = p_business;

  -- Data sufficiency
  if (cur ->> 'transactions')::int < 5 then
    out := out || jsonb_build_object('code', 'insufficient_data', 'severity', 'info', 'period', per,
      'params', jsonb_build_object('transactions', cur -> 'transactions'), 'limitations', lim);
  end if;
  if (dq ->> 'estimated_cost_entries')::int > 0 then
    out := out || jsonb_build_object('code', 'estimated_costs', 'severity', 'info', 'period', per,
      'params', jsonb_build_object('entries', dq -> 'estimated_cost_entries'), 'limitations', '[]'::jsonb);
  end if;

  -- Profit change vs previous period (only when both periods have activity)
  if (cur ->> 'transactions')::int >= 5 and (prev ->> 'transactions')::int >= 5 then
    out := out || jsonb_build_object('code',
        case when (cur ->> 'gross_profit')::numeric < (prev ->> 'gross_profit')::numeric then 'profit_decreased' else 'profit_increased' end,
      'severity', case when (cur ->> 'gross_profit')::numeric < (prev ->> 'gross_profit')::numeric * 0.9 then 'warning' else 'info' end,
      'period', per,
      'params', jsonb_build_object(
        'gross_profit', cur -> 'gross_profit', 'prev_gross_profit', prev -> 'gross_profit',
        'net_sales', cur -> 'net_sales', 'prev_net_sales', prev -> 'net_sales',
        'margin', cur -> 'gross_margin_pct', 'prev_margin', prev -> 'gross_margin_pct',
        'expenses', cur -> 'operating_expenses', 'prev_expenses', prev -> 'operating_expenses',
        'operating_profit', cur -> 'operating_profit', 'prev_operating_profit', prev -> 'operating_profit',
        'losses', cur -> 'stock_losses', 'prev_losses', prev -> 'stock_losses',
        'prev_from', d1 - len, 'prev_to', d1 - 1),
      'limitations', lim);
  end if;

  -- Restock needs (only when the plan includes recommendations)
  if app.has_feature(p_business, 'restock') then
    select coalesce(jsonb_agg(x) filter (where x ->> 'priority' in ('urgent', 'soon')), '[]') into j
      from jsonb_array_elements(public.restock_recommendations(p_business, 30)) x;
    if jsonb_array_length(j) > 0 then
      out := out || jsonb_build_object('code', 'restock_needed',
        'severity', case when exists (select 1 from jsonb_array_elements(j) y where y ->> 'priority' = 'urgent') then 'critical' else 'warning' end,
        'period', jsonb_build_object('from', today - 29, 'to', today),
        'params', jsonb_build_object('count', jsonb_array_length(j), 'items', (
          select jsonb_agg(jsonb_build_object('name', y ->> 'name', 'qty_on_hand', y -> 'qty_on_hand',
                 'avg_daily', y -> 'avg_daily', 'days_of_cover', y -> 'days_of_cover', 'recommended_qty', y -> 'recommended_qty',
                 'unit', y ->> 'base_unit', 'confidence', y ->> 'confidence'))
          from (select y from jsonb_array_elements(j) y limit 5) z)),
        'limitations', lim);
    end if;
  end if;

  -- Selling below cost
  select count(*), coalesce(jsonb_agg(jsonb_build_object('name', name, 'price', selling_price, 'cost', round(avg_cost, 0)))
                          filter (where rn <= 5), '[]') into r
    from (select name, selling_price, avg_cost, row_number() over (order by avg_cost - selling_price desc) rn
          from public.products where business_id = p_business and status = 'active' and qty_on_hand > 0
            and selling_price > 0 and avg_cost > selling_price) t;
  if r.count > 0 then
    out := out || jsonb_build_object('code', 'price_below_cost', 'severity', 'critical', 'period', per,
      'params', jsonb_build_object('count', r.count, 'items', r.coalesce), 'limitations', lim);
  end if;

  -- Weak margins on products that actually sold
  select count(*), coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'margin', round((pp.revenue - pp.cogs) / pp.revenue * 100, 1),
                          'revenue', pp.revenue)) filter (where rn <= 5), '[]') into r
    from (select pp.*, row_number() over (order by pp.revenue desc) rn from app.product_period(p_business, d1, p_to) pp
          where pp.revenue > 0 and (pp.revenue - pp.cogs) / pp.revenue * 100 < st.weak_margin_pct) pp
    join public.products p on p.id = pp.product_id;
  if r.count > 0 then
    out := out || jsonb_build_object('code', 'weak_margin', 'severity', 'warning', 'period', per,
      'params', jsonb_build_object('count', r.count, 'threshold', st.weak_margin_pct, 'items', r.coalesce), 'limitations', lim);
  end if;

  -- Most profitable product vs best seller
  select p.name, pp.revenue - pp.cogs gp, pp.revenue into r from app.product_period(p_business, d1, p_to) pp
    join public.products p on p.id = pp.product_id where pp.revenue > 0 order by pp.revenue - pp.cogs desc limit 1;
  if found and (cur ->> 'gross_profit')::numeric > 0 then
    out := out || jsonb_build_object('code', 'top_profit_product', 'severity', 'success', 'period', per,
      'params', jsonb_build_object('name', r.name, 'gross_profit', round(r.gp, 0),
        'share', round(r.gp / (cur ->> 'gross_profit')::numeric * 100, 1),
        'top_revenue_name', (select p.name from app.product_period(p_business, d1, p_to) pp join public.products p on p.id = pp.product_id
                             order by pp.revenue desc limit 1)),
      'limitations', lim);
  end if;

  -- Leading category
  select x into j from jsonb_array_elements(public.category_performance(p_business, d1, p_to)) x
   where (x ->> 'gross_profit')::numeric > 0 order by (x ->> 'gross_profit')::numeric desc limit 1;
  if j is not null and (cur ->> 'gross_profit')::numeric > 0 then
    out := out || jsonb_build_object('code', 'category_leader', 'severity', 'info', 'period', per,
      'params', jsonb_build_object('category', j ->> 'category', 'gross_profit', j -> 'gross_profit',
        'share', round((j ->> 'gross_profit')::numeric / (cur ->> 'gross_profit')::numeric * 100, 1), 'margin', j -> 'margin_pct'),
      'limitations', lim);
  end if;

  -- Capital tied up in products with no recent sales
  if app.has_feature(p_business, 'advanced_analytics') then
    select coalesce(sum((x ->> 'stock_value')::numeric), 0) val, count(*) cnt,
           coalesce(jsonb_agg(jsonb_build_object('name', x ->> 'name', 'value', round((x ->> 'stock_value')::numeric, 0),
              'margin', x -> 'price_margin_pct', 'last_sold_at', x -> 'last_sold_at')) filter (where x ->> 'classification' = 'no_sales'), '[]') items
      into r from jsonb_array_elements(public.slow_moving_products(p_business, null)) x;
    if r.cnt > 0 then
      out := out || jsonb_build_object('code', 'slow_moving_capital', 'severity', 'warning',
        'period', jsonb_build_object('from', today - st.slow_moving_days + 1, 'to', today),
        'params', jsonb_build_object('count', r.cnt, 'value', round(r.val, 0),
          'share', case when inv > 0 then round(r.val / inv * 100, 1) end, 'window_days', st.slow_moving_days,
          'items', (select jsonb_agg(e) from (select e from jsonb_array_elements(r.items) e limit 5) z)),
        'limitations', lim || '"seasonality_unknown"');
    end if;
  end if;

  -- Expiring stock
  select count(*), coalesce(sum(b.remaining_qty * p.avg_cost), 0) val, min(b.expiry_date) first into r
    from public.stock_batches b join public.products p on p.id = b.product_id
   where b.business_id = p_business and b.remaining_qty > 0 and b.expiry_date <= today + st.expiry_alert_days;
  if r.count > 0 then
    out := out || jsonb_build_object('code', 'expiring_stock', 'severity', 'warning', 'period', per,
      'params', jsonb_build_object('count', r.count, 'value', round(r.val, 0), 'first_expiry', r.first,
                                   'days', st.expiry_alert_days), 'limitations', '[]'::jsonb);
  end if;

  -- Stock losses relative to cost of sales
  v := (cur ->> 'stock_losses')::numeric;
  if v > 0 and (v > 0.02 * greatest((cur ->> 'cogs')::numeric, 1)) then
    out := out || jsonb_build_object('code', 'high_stock_losses', 'severity', 'warning', 'period', per,
      'params', jsonb_build_object('losses', v, 'cogs', cur -> 'cogs',
        'pct', case when (cur ->> 'cogs')::numeric > 0 then round(v / (cur ->> 'cogs')::numeric * 100, 1) end),
      'limitations', lim);
  end if;

  -- Supplier payments due within 7 days
  select count(*), coalesce(sum(total - credited_total - paid_total), 0) amt into r from public.purchases
   where business_id = p_business and status in ('ordered', 'partially_received', 'received')
     and due_date <= today + 7 and total - credited_total - paid_total > 0;
  if r.count > 0 then
    out := out || jsonb_build_object('code', 'supplier_payments_due', 'severity', 'warning', 'period', per,
      'params', jsonb_build_object('count', r.count, 'amount', r.amt), 'limitations', '[]'::jsonb);
  end if;

  -- Overdue customer credit
  select count(*), coalesce(sum(total - returned_total + refunded_total - paid_total), 0) amt into r from public.sales
   where business_id = p_business and customer_id is not null and due_date < today
     and total - returned_total + refunded_total - paid_total > 0;
  if r.count > 0 then
    out := out || jsonb_build_object('code', 'customer_overdue', 'severity', 'warning', 'period', per,
      'params', jsonb_build_object('count', r.count, 'amount', r.amt), 'limitations', '[]'::jsonb);
  end if;

  return out;
end $$;

-- Grounding bundle for the AI Advisor (and its rule-based fallback).
create or replace function public.advisor_context(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; len int; b public.businesses; pp jsonb; adv boolean;
begin
  perform app.report_guard(p_business, 'basic_analytics');
  d1 := app.report_from(p_business, p_from);
  len := p_to - d1 + 1;
  select * into b from public.businesses where id = p_business;
  adv := app.has_feature(p_business, 'advanced_analytics');
  pp := public.product_performance(p_business, d1, p_to);
  return jsonb_build_object(
    'business', jsonb_build_object('name', b.name, 'currency', b.currency, 'category', b.category, 'today', app.biz_today(p_business)),
    'period', jsonb_build_object('from', d1, 'to', p_to, 'days', len),
    'previous_period', jsonb_build_object('from', d1 - len, 'to', d1 - 1),
    'summary', app.period_stats(p_business, d1, p_to),
    'previous_summary', app.period_stats(p_business, d1 - len, d1 - 1),
    'inventory_value', (select coalesce(round(sum(stock_value), 0), 0) from public.products where business_id = p_business),
    'top_by_units', (select coalesce(jsonb_agg(x), '[]') from (select jsonb_build_object('name', x ->> 'name', 'units', x -> 'units',
        'revenue', x -> 'revenue', 'gross_profit', x -> 'gross_profit', 'margin_pct', x -> 'margin_pct') x
        from jsonb_array_elements(pp) x where (x ->> 'units')::numeric > 0
        order by (x ->> 'units')::numeric desc limit 10) t),
    'top_by_profit', (select coalesce(jsonb_agg(x), '[]') from (select jsonb_build_object('name', x ->> 'name', 'gross_profit', x -> 'gross_profit',
        'margin_pct', x -> 'margin_pct', 'revenue', x -> 'revenue') x
        from jsonb_array_elements(pp) x where (x ->> 'revenue')::numeric > 0
        order by (x ->> 'gross_profit')::numeric desc limit 10) t),
    'product_changes', (select coalesce(jsonb_agg(t), '[]') from (
        select p.name, coalesce(c.units, 0) units_now, coalesce(o.units, 0) units_before,
               coalesce(c.revenue, 0) revenue_now, coalesce(o.revenue, 0) revenue_before
        from public.products p
        left join app.product_period(p_business, d1, p_to) c on c.product_id = p.id
        left join app.product_period(p_business, d1 - len, d1 - 1) o on o.product_id = p.id
        where p.business_id = p_business and (coalesce(c.units, 0) <> 0 or coalesce(o.units, 0) <> 0)
        order by abs(coalesce(c.revenue, 0) - coalesce(o.revenue, 0)) desc limit 10) t),
    'categories', public.category_performance(p_business, d1, p_to),
    'restock', case when app.has_feature(p_business, 'restock') then
        (select coalesce(jsonb_agg(x), '[]') from (select x from jsonb_array_elements(public.restock_recommendations(p_business, 30)) x limit 10) t)
        else null end,
    'slow_moving', case when adv then
        (select coalesce(jsonb_agg(x), '[]') from (select jsonb_build_object('name', x ->> 'name', 'stock_value', x -> 'stock_value',
           'classification', x ->> 'classification', 'last_sold_at', x -> 'last_sold_at', 'qty_on_hand', x -> 'qty_on_hand') x
           from jsonb_array_elements(public.slow_moving_products(p_business, null)) x limit 10) t)
        else null end,
    'insights', public.business_insights(p_business, d1, p_to),
    'data_quality', app.data_quality(p_business),
    'definitions', jsonb_build_object(
      'net_sales', 'Sales after discounts, excluding sales tax, minus returns',
      'cogs', 'Weighted-average purchase cost of units sold (captured at time of sale)',
      'gross_profit', 'Net sales minus COGS',
      'operating_profit', 'Gross profit minus recorded operating expenses and net stock losses (estimate)'));
end $$;

-- ===== 20261022000700_storage_grants.sql =====
-- File storage and privilege hardening.

create or replace function app.try_uuid(v text) returns uuid language plpgsql immutable as $$
begin
  return v::uuid;
exception when others then
  return null;
end $$;

-- Private bucket. Object paths: {business_id}/{folder}/{file}
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('business-files', 'business-files', false, 5242880,
        array['image/png', 'image/jpeg', 'image/webp', 'application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function app.storage_can_write(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select case (storage.foldername(object_name))[2]
    when 'logos' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'settings.manage')
    when 'products' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'products.manage')
    when 'purchases' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'purchases.manage')
    when 'suppliers' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'suppliers.manage')
    when 'expenses' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'expenses.manage')
    when 'billing' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'billing.manage')
    when 'stock' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'stock.adjust')
    else false end
$$;

create or replace function app.storage_can_read(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select app.can_read(app.try_uuid((storage.foldername(object_name))[1]))
      or (app.is_platform_admin() and (storage.foldername(object_name))[2] = 'billing')
$$;

create policy "business files read" on storage.objects for select to authenticated
  using (bucket_id = 'business-files' and app.storage_can_read(name));
create policy "business files insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'business-files' and app.storage_can_write(name));
create policy "business files delete" on storage.objects for delete to authenticated
  using (bucket_id = 'business-files' and (storage.foldername(name))[2] in ('logos', 'products')
         and app.storage_can_write(name));

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------
-- Anonymous visitors may only read public catalogue/config rows (RLS still applies).
revoke all on all tables in schema public from anon;
grant select on public.plans, public.countries, public.announcements, public.app_config to anon;

-- No API role may bypass RLS with TRUNCATE etc.
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;

-- RPC exposure: authenticated users only, except the public contact form.
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
grant execute on function public.submit_support_request(jsonb) to anon;

-- Helpers used inside RLS policies must be executable by API roles, but internal
-- mutation helpers are not (they are only reached through SECURITY DEFINER RPCs).
grant execute on all functions in schema app to anon, authenticated, service_role;
revoke execute on function app.apply_movement(uuid, uuid, text, numeric, numeric, text, uuid, text, text, uuid, boolean, uuid, timestamptz, boolean) from anon, authenticated, public;
revoke execute on function app.consume_batches(uuid, numeric) from anon, authenticated, public;
revoke execute on function app.insert_payment(uuid, text, text, numeric, timestamptz, text, text, uuid, uuid, uuid, uuid, uuid, uuid, uuid) from anon, authenticated, public;
revoke execute on function app.rebalance_supplier(uuid) from anon, authenticated, public;
revoke execute on function app.rebalance_customer(uuid, uuid) from anon, authenticated, public;
revoke execute on function app.init_accounts(uuid) from anon, authenticated, public;
revoke execute on function app.init_subscription(uuid) from anon, authenticated, public;
revoke execute on function app.next_number(uuid, text, text) from anon, authenticated, public;
revoke execute on function app.audit(uuid, text, text, text, jsonb) from anon, authenticated, public;
revoke execute on function app.rate_limit(text, int, int) from anon, authenticated, public;
revoke execute on function app.refresh_expense(uuid) from anon, authenticated, public;
revoke execute on function app.bootstrap_platform_admin(text) from anon, authenticated, public;
revoke execute on function app.build_alerts(uuid) from anon, authenticated, public;
revoke execute on function app.generate_all_alerts() from anon, authenticated, public;

-- ===== 20261022000800_guards.sql =====
-- Additional integrity guards: units and base units that are referenced by
-- historical transactions cannot be redefined (history keeps its own copy, but
-- changing the definition would make future records inconsistent with the past).

create or replace function app.product_units_history_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.factor is distinct from old.factor or lower(new.name) is distinct from lower(old.name))
     and (exists (select 1 from public.sale_lines where unit_id = old.id)
          or exists (select 1 from public.purchase_lines where unit_id = old.id)) then
    perform app.raise('unit_in_use');
  end if;
  if new.product_id is distinct from old.product_id or new.business_id is distinct from old.business_id then
    perform app.raise('protected_field');
  end if;
  return new;
end $$;

create trigger product_units_history before update on public.product_units
  for each row execute function app.product_units_history_guard();

create or replace function app.products_base_unit_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.base_unit is distinct from old.base_unit
     and exists (select 1 from public.stock_movements where product_id = old.id) then
    perform app.raise('base_unit_locked');
  end if;
  if new.allow_fraction is distinct from old.allow_fraction and not new.allow_fraction
     and old.qty_on_hand <> trunc(old.qty_on_hand) then
    perform app.raise('fractional_quantity_not_allowed');
  end if;
  return new;
end $$;

create trigger products_base_unit before update on public.products
  for each row execute function app.products_base_unit_guard();

-- Guarantee only one default purchase / sale unit per product.
create unique index product_units_default_purchase on public.product_units (product_id) where is_default_purchase and active;
create unique index product_units_default_sale on public.product_units (product_id) where is_default_sale and active;

grant execute on function app.product_units_history_guard() to authenticated;
grant execute on function app.products_base_unit_guard() to authenticated;

-- ===== 20261024000100_catalog_flexibility.sql =====
-- Flexible catalogue: more business types, two-level categories that owners can rename, reorder,
-- archive and restore, optional category-specific product attributes, server-generated SKUs and
-- product variants created in one step. Additive only: no existing data is changed or removed.

-- ---------------------------------------------------------------------------
-- Business types
-- ---------------------------------------------------------------------------
create or replace function app.business_types() returns text[]
language sql immutable as $$
  select array['grocery', 'supermarket', 'drinks', 'fashion', 'footwear', 'electronics', 'hair_beauty', 'cosmetics',
               'furniture', 'hardware', 'automotive', 'sports', 'toys', 'books', 'stationery', 'jewelry', 'pets',
               'agriculture', 'home_goods', 'gifts', 'general', 'other']
$$;

-- ---------------------------------------------------------------------------
-- Categories: two levels (category → subcategory), ordering, archiving
-- ---------------------------------------------------------------------------
alter table public.categories
  add column if not exists sort_order int not null default 0,
  add column if not exists archived_at timestamptz,
  add column if not exists attribute_set text check (attribute_set ~ '^[a-z_]{2,30}$');

-- Names are unique among top-level categories, and among the subcategories of one category
-- (so "T-shirts" can exist under both "Men" and "Women").
drop index if exists public.categories_name_unique;
create unique index if not exists categories_top_name_unique on public.categories (business_id, lower(name)) where parent_id is null;
create unique index if not exists categories_child_name_unique on public.categories (parent_id, lower(name)) where parent_id is not null;
create index if not exists categories_business_sort on public.categories (business_id, parent_id, sort_order);

create or replace function app.categories_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.name := btrim(new.name);
  if new.parent_id is not null then
    if new.parent_id = new.id then perform app.raise('invalid_category'); end if;
    -- Parent must belong to the same business and be a top-level category (two levels only).
    if not exists (select 1 from public.categories c where c.id = new.parent_id and c.business_id = new.business_id and c.parent_id is null) then
      perform app.raise('invalid_category');
    end if;
    if tg_op = 'UPDATE' and exists (select 1 from public.categories c where c.parent_id = new.id) then
      perform app.raise('invalid_category'); -- a category with subcategories cannot become a subcategory
    end if;
  end if;
  return new;
end $$;
drop trigger if exists categories_guard on public.categories;
create trigger categories_guard before insert or update on public.categories
  for each row execute function app.categories_guard();

-- Adds categories (and their subcategories) that do not exist yet. Existing ones are kept as they
-- are (an archived one is restored). Input: [{"name": "Men", "attribute_set": "clothing",
-- "children": ["T-shirts", "Jeans"]}, ...]. Returns the number of categories added or restored.
create or replace function app.add_categories(p_business uuid, p_categories jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare c jsonb; ch jsonb; pid uuid; nm text; aset text; n int := 0; next_sort int; child_sort int;
begin
  if jsonb_typeof(p_categories) <> 'array' or jsonb_array_length(p_categories) > 80 then perform app.raise('invalid_input'); end if;
  select coalesce(max(sort_order), 0) into next_sort from public.categories where business_id = p_business and parent_id is null;
  for c in select * from jsonb_array_elements(p_categories) loop
    nm := btrim(coalesce(c ->> 'name', ''));
    if nm = '' then continue; end if;
    if length(nm) > 80 then perform app.raise('invalid_input'); end if;
    aset := nullif(c ->> 'attribute_set', '');
    if aset is not null and aset !~ '^[a-z_]{2,30}$' then aset := null; end if;
    select id into pid from public.categories where business_id = p_business and parent_id is null and lower(name) = lower(nm);
    if pid is null then
      next_sort := next_sort + 1;
      insert into public.categories (business_id, name, sort_order, attribute_set) values (p_business, nm, next_sort, aset) returning id into pid;
      n := n + 1;
    else
      update public.categories set archived_at = null, attribute_set = coalesce(attribute_set, aset)
       where id = pid and (archived_at is not null or attribute_set is null);
      if found then n := n + 1; end if;
    end if;
    if jsonb_typeof(c -> 'children') = 'array' then
      if jsonb_array_length(c -> 'children') > 60 then perform app.raise('invalid_input'); end if;
      select coalesce(max(sort_order), 0) into child_sort from public.categories where parent_id = pid;
      for ch in select * from jsonb_array_elements(c -> 'children') loop
        nm := btrim(coalesce(ch #>> '{}', ''));
        if nm = '' or length(nm) > 80 then continue; end if;
        if not exists (select 1 from public.categories where parent_id = pid and lower(name) = lower(nm)) then
          child_sort := child_sort + 1;
          insert into public.categories (business_id, name, parent_id, sort_order) values (p_business, nm, pid, child_sort);
          n := n + 1;
        else
          update public.categories set archived_at = null where parent_id = pid and lower(name) = lower(nm) and archived_at is not null;
          if found then n := n + 1; end if;
        end if;
      end loop;
    end if;
  end loop;
  return n;
end $$;

create or replace function public.apply_category_template(p_business uuid, p_categories jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform app.require_perm(p_business, 'products.manage');
  n := app.add_categories(p_business, p_categories);
  perform app.audit(p_business, 'categories.added', 'category', null, jsonb_build_object('count', n));
  return n;
end $$;

-- Sets the display order of sibling categories to the order of p_ids.
create or replace function public.reorder_categories(p_business uuid, p_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'products.manage');
  if array_length(p_ids, 1) > 200 then perform app.raise('invalid_input'); end if;
  update public.categories c set sort_order = x.ord
    from unnest(p_ids) with ordinality as x(id, ord)
   where c.id = x.id and c.business_id = p_business;
end $$;

-- Renames a category; for a subcategory, products that use it are updated in the same step.
create or replace function public.rename_category(p_business uuid, p_category uuid, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.categories; nm text := btrim(coalesce(p_name, ''));
begin
  perform app.require_perm(p_business, 'products.manage');
  select * into c from public.categories where id = p_category and business_id = p_business for update;
  if not found then perform app.raise('not_found'); end if;
  if nm = '' or length(nm) > 80 then perform app.raise('invalid_input'); end if;
  if nm = c.name then return; end if;
  update public.categories set name = nm where id = c.id;
  if c.parent_id is not null then
    update public.products set subcategory = nm
     where business_id = p_business and category_id = c.parent_id and lower(subcategory) = lower(c.name);
  end if;
  perform app.audit(p_business, 'category.renamed', 'category', c.id::text, jsonb_build_object('from', c.name, 'to', nm));
end $$;

-- ---------------------------------------------------------------------------
-- Products: optional attributes and server-generated SKU
-- ---------------------------------------------------------------------------
alter table public.products
  add column if not exists attributes jsonb not null default '{}'::jsonb;
alter table public.products drop constraint if exists products_attributes_check;
alter table public.products add constraint products_attributes_check
  check (jsonb_typeof(attributes) = 'object' and pg_column_size(attributes) <= 8192);

-- Unique, stable SKU for products saved without one (same counter the CSV import uses).
create or replace function app.generate_sku(p_business uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  loop
    v := app.next_number(p_business, 'sku', 'SKU-');
    exit when not exists (select 1 from public.products where business_id = p_business and lower(sku) = lower(v));
  end loop;
  return v;
end $$;

-- products_guard (runs as the calling user): blank SKU on insert → generated; blank SKU on update →
-- the existing one is kept, so a product's SKU never changes by accident.
create or replace function app.products_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not app.is_internal() then
      new.qty_on_hand := 0;
      new.stock_value := 0;
      new.created_by := auth.uid();
    end if;
    new.avg_cost := coalesce(nullif(new.avg_cost, 0), new.purchase_cost, 0);
    new.sku := nullif(btrim(coalesce(new.sku, '')), '');
    if new.sku is null then new.sku := app.generate_sku(new.business_id); end if;
    new.barcode := nullif(btrim(coalesce(new.barcode, '')), '');
    new.attributes := coalesce(new.attributes, '{}'::jsonb);
    perform app.check_limit(new.business_id, 'max_products');
    return new;
  end if;
  if not app.is_internal() then
    if new.qty_on_hand is distinct from old.qty_on_hand
       or new.stock_value is distinct from old.stock_value
       or new.avg_cost is distinct from old.avg_cost
       or new.business_id is distinct from old.business_id
       or new.import_batch_id is distinct from old.import_batch_id then
      perform app.raise('protected_field');
    end if;
  end if;
  new.sku := coalesce(nullif(btrim(coalesce(new.sku, '')), ''), old.sku);
  new.barcode := nullif(btrim(coalesce(new.barcode, '')), '');
  new.attributes := coalesce(new.attributes, '{}'::jsonb);
  perform app.log_product_change(new, old);
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Variants: create several variants of a product in one step (all or nothing)
-- ---------------------------------------------------------------------------
-- p_variants: [{"label": "M / Red", "selling_price": 5000, "purchase_cost": 3000, "sku": "", "barcode": "",
--               "attributes": {"size": "M", "color": "Red"}, "opening_qty": 10, "opening_cost": 3000}]
create or replace function public.add_product_variants(p_business uuid, p_parent uuid, p_variants jsonb)
returns uuid[] language plpgsql security definer set search_path = public as $$
declare par public.products; v jsonb; lbl text; ids uuid[] := '{}'; vid uuid; q numeric; c numeric; labels text[] := '{}';
begin
  perform app.require_perm(p_business, 'products.manage');
  select * into par from public.products where id = p_parent and business_id = p_business;
  if not found then perform app.raise('invalid_product'); end if;
  if par.variant_of is not null then perform app.raise('invalid_product'); end if;
  if jsonb_typeof(p_variants) <> 'array' or jsonb_array_length(p_variants) = 0 or jsonb_array_length(p_variants) > 100 then
    perform app.raise('invalid_input');
  end if;
  for v in select * from jsonb_array_elements(p_variants) loop
    lbl := btrim(coalesce(v ->> 'label', ''));
    if lbl = '' or length(lbl) > 80 then perform app.raise('variant_label_required'); end if;
    if lower(lbl) = any (labels) or exists (select 1 from public.products where variant_of = p_parent and lower(variant_label) = lower(lbl)) then
      perform app.raise('duplicate_variant', jsonb_build_object('label', lbl));
    end if;
    labels := labels || lower(lbl);
    if jsonb_typeof(coalesce(v -> 'attributes', '{}')) <> 'object' then perform app.raise('invalid_input'); end if;
    insert into public.products (business_id, name, sku, barcode, category_id, subcategory, brand, description, image_path,
      base_unit, allow_fraction, purchase_cost, selling_price, min_stock, lead_time_days, min_order_qty, preferred_supplier_id,
      location, track_expiry, variant_of, variant_label, attributes, created_by)
    values (p_business, par.name, nullif(btrim(coalesce(v ->> 'sku', '')), ''), nullif(btrim(coalesce(v ->> 'barcode', '')), ''),
      par.category_id, par.subcategory, par.brand, par.description, par.image_path, par.base_unit, par.allow_fraction,
      coalesce(app.num_or_null(v ->> 'purchase_cost'), par.purchase_cost), coalesce(app.num_or_null(v ->> 'selling_price'), par.selling_price),
      par.min_stock, par.lead_time_days, par.min_order_qty, par.preferred_supplier_id, par.location, par.track_expiry,
      p_parent, lbl, par.attributes || coalesce(v -> 'attributes', '{}'), auth.uid())
    returning id into vid;
    q := coalesce(app.num_or_null(v ->> 'opening_qty'), 0);
    if q < 0 then perform app.raise('invalid_quantity'); end if;
    if q > 0 then
      c := coalesce(app.num_or_null(v ->> 'opening_cost'), app.num_or_null(v ->> 'purchase_cost'), par.purchase_cost, 0);
      if c < 0 then perform app.raise('invalid_cost'); end if;
      perform app.apply_movement(p_business, vid, 'opening', q, c, 'opening', null, null, 'Opening stock', null, false, null);
    end if;
    ids := ids || vid;
  end loop;
  perform app.audit(p_business, 'product.variants_added', 'product', p_parent::text, jsonb_build_object('count', array_length(ids, 1)));
  return ids;
end $$;

-- ---------------------------------------------------------------------------
-- Onboarding / settings accept the new business types; import works with two-level categories
-- ---------------------------------------------------------------------------
create or replace function public.create_business(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := app.require_auth(); c public.countries; bid uuid; lang text; cat text; nm text;
begin
  perform app.rate_limit('create_business:' || uid, 5, 86400);
  if (select count(*) from public.business_members where user_id = uid and role = 'owner' and active) >= 5 then
    perform app.raise('too_many_businesses');
  end if;
  select * into c from public.countries where code = coalesce(nullif(p ->> 'country_code', ''), 'CM');
  if not found or not c.registration_enabled then perform app.raise('country_not_available'); end if;
  lang := case when p ->> 'language' in ('en', 'fr') then p ->> 'language' else c.default_language end;
  cat := coalesce(nullif(p ->> 'category', ''), 'general');
  if not cat = any (app.business_types()) then
    perform app.raise('invalid_category');
  end if;
  nm := btrim(coalesce(p ->> 'name', ''));
  if length(nm) < 2 then perform app.raise('business_name_required'); end if;

  insert into public.businesses (name, owner_name, email, phone, address, city, country_code, currency,
    currency_decimals, timezone, language, category, reporting_start_date, created_by)
  values (nm, nullif(p ->> 'owner_name', ''), nullif(p ->> 'email', ''), nullif(p ->> 'phone', ''),
    nullif(p ->> 'address', ''), nullif(p ->> 'city', ''), c.code, c.currency, c.currency_decimals, c.timezone,
    lang, cat, coalesce(nullif(p ->> 'reporting_start_date', '')::date, (now() at time zone c.timezone)::date), uid)
  returning id into bid;

  insert into public.business_settings (business_id) values (bid);
  insert into public.business_members (business_id, user_id, role, display_name)
  values (bid, uid, 'owner', nullif(p ->> 'owner_name', ''));
  perform app.init_accounts(bid);
  perform app.init_subscription(bid);
  -- Categories chosen during onboarding (recommended for the business type, all optional);
  -- older clients that send none still get the basic defaults.
  if jsonb_typeof(p -> 'categories') = 'array' then
    perform app.add_categories(bid, p -> 'categories');
  else
    insert into public.categories (business_id, name)
    select bid, x from unnest(app.default_categories(cat, lang)) x on conflict do nothing;
  end if;

  update public.profiles set full_name = coalesce(nullif(p ->> 'owner_name', ''), full_name),
         phone = coalesce(nullif(p ->> 'phone', ''), phone), language = lang
   where id = uid;
  perform app.audit(bid, 'business.created', 'business', bid::text, jsonb_build_object('name', nm, 'category', cat));
  return bid;
end $$;

create or replace function public.update_business(p_business uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'settings.manage');
  if p ? 'name' and length(btrim(p ->> 'name')) < 2 then perform app.raise('business_name_required'); end if;
  update public.businesses set
    name = coalesce(btrim(p ->> 'name'), name),
    owner_name = case when p ? 'owner_name' then nullif(p ->> 'owner_name', '') else owner_name end,
    email = case when p ? 'email' then nullif(p ->> 'email', '') else email end,
    phone = case when p ? 'phone' then nullif(p ->> 'phone', '') else phone end,
    address = case when p ? 'address' then nullif(p ->> 'address', '') else address end,
    city = case when p ? 'city' then nullif(p ->> 'city', '') else city end,
    language = case when p ->> 'language' in ('en', 'fr') then p ->> 'language' else language end,
    category = case when p ->> 'category' = any (app.business_types())
                    then p ->> 'category' else category end,
    logo_path = case when p ? 'logo_path' then nullif(p ->> 'logo_path', '') else logo_path end,
    tax_id = case when p ? 'tax_id' then nullif(p ->> 'tax_id', '') else tax_id end,
    trade_register = case when p ? 'trade_register' then nullif(p ->> 'trade_register', '') else trade_register end,
    reporting_start_date = coalesce(nullif(p ->> 'reporting_start_date', '')::date, reporting_start_date)
  where id = p_business;
  perform app.audit(p_business, 'business.updated', 'business', p_business::text, p);
end $$;

create or replace function public.import_products(p_business uuid, p_rows jsonb, p_file_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pv jsonb; r jsonb; i int := 0; bid uuid; created int := 0; skipped int := 0; v_issues jsonb := '[]';
        pid uuid; cat uuid; sku text; oq numeric; oc numeric; lim numeric; known boolean;
begin
  perform app.require_perm(p_business, 'imports.manage');
  perform app.require_feature(p_business, 'import');
  pv := public.preview_product_import(p_business, p_rows);
  lim := app.plan_limit(p_business, 'max_products');
  if lim is not null and app.usage_count(p_business, 'max_products') + (pv ->> 'valid')::int > lim then
    perform app.raise('plan_limit_reached', jsonb_build_object('limit', 'max_products', 'max', lim,
      'used', app.usage_count(p_business, 'max_products')));
  end if;
  insert into public.import_batches (business_id, kind, file_name, total_rows, created_by)
  values (p_business, 'products', p_file_name, jsonb_array_length(p_rows), auth.uid()) returning id into bid;

  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    if not ((pv -> 'rows' -> (i - 1)) ->> 'ok')::boolean then
      skipped := skipped + 1;
      v_issues := v_issues || jsonb_build_object('row', i, 'errors', (pv -> 'rows' -> (i - 1)) -> 'errors');
      continue;
    end if;
    cat := null;
    if coalesce(btrim(r ->> 'category'), '') <> '' then
      insert into public.categories (business_id, name) values (p_business, btrim(r ->> 'category'))
      on conflict (business_id, lower(name)) where parent_id is null do nothing;
      select id into cat from public.categories where business_id = p_business and parent_id is null
        and lower(name) = lower(btrim(r ->> 'category'));
    end if;
    sku := coalesce(nullif(btrim(r ->> 'sku'), ''), app.next_number(p_business, 'sku', 'SKU-'));
    insert into public.products (business_id, name, sku, barcode, category_id, brand, description, base_unit,
      allow_fraction, purchase_cost, selling_price, min_stock, location, import_batch_id, created_by)
    values (p_business, btrim(r ->> 'name'), sku, nullif(btrim(r ->> 'barcode'), ''), cat, nullif(r ->> 'brand', ''),
      nullif(r ->> 'description', ''), coalesce(nullif(btrim(r ->> 'base_unit'), ''), 'piece'),
      lower(coalesce(r ->> 'allow_fraction', '')) in ('yes', 'true', '1', 'oui'),
      coalesce(app.num_or_null(r ->> 'purchase_cost'), 0), coalesce(app.num_or_null(r ->> 'selling_price'), 0),
      coalesce(app.num_or_null(r ->> 'min_stock'), 0), nullif(r ->> 'location', ''), bid, auth.uid())
    returning id into pid;
    oq := coalesce(app.num_or_null(r ->> 'opening_qty'), 0);
    if oq > 0 then
      oc := app.num_or_null(r ->> 'opening_unit_cost');
      known := oc is not null;
      oc := coalesce(oc, app.num_or_null(r ->> 'purchase_cost'), 0);
      perform app.apply_movement(p_business, pid, 'opening', oq, oc, 'import', bid, null, 'Imported opening stock',
                                 null, not known);
    end if;
    created := created + 1;
  end loop;
  update public.import_batches set created_count = created, skipped_count = skipped, issues = v_issues where id = bid;
  perform app.audit(p_business, 'import.products', 'import_batch', bid::text,
                    jsonb_build_object('created', created, 'skipped', skipped, 'file', p_file_name));
  return jsonb_build_object('batch_id', bid, 'created', created, 'skipped', skipped, 'issues', v_issues);
end $$;

revoke execute on function app.add_categories(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.generate_sku(uuid) to authenticated; -- called by products_guard as the user
grant execute on function public.apply_category_template(uuid, jsonb) to authenticated;
grant execute on function public.reorder_categories(uuid, uuid[]) to authenticated;
grant execute on function public.rename_category(uuid, uuid, text) to authenticated;
revoke execute on function public.rename_category(uuid, uuid, text) from anon;
grant execute on function public.add_product_variants(uuid, uuid, jsonb) to authenticated;
revoke execute on function public.apply_category_template(uuid, jsonb) from anon;
revoke execute on function public.reorder_categories(uuid, uuid[]) from anon;
revoke execute on function public.add_product_variants(uuid, uuid, jsonb) from anon;

-- ===== 20261024000200_store_lock.sql =====
-- Store Lock: a 4-digit PIN that locks the BizPilot dashboard on a device (signed-in session).
--
-- Enforced on the server, per Supabase Auth session (the JWT's session_id):
--   * while a session is locked, every permission and membership check used by the API, RLS
--     policies and storage returns "no access", and RPCs raise 'store_locked';
--   * a new sign-in starts locked (once a PIN exists), so signing out and in again does not skip it;
--   * a session also counts as locked after the user's inactivity period without activity.
-- PINs are stored only as bcrypt hashes (pgcrypto) in schema "app", which the API cannot read.
-- Wrong PINs are counted per user with growing waits. Forgotten PIN: sign in again (fresh login
-- within 10 minutes), then set a new PIN; every session of the user is locked afterwards.
-- Limitation: a 4-digit PIN has 10 000 combinations, so its strength comes from the server-side
-- attempt limits, not from the hash. It complements, never replaces, the account password.

create table app.store_pins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  pin_hash text not null,
  idle_minutes int not null default 15 check (idle_minutes between 1 and 240),
  failed_attempts int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now(),
  pin_changed_at timestamptz not null default now()
);

create table app.store_lock_sessions (
  session_id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  locked boolean not null,
  reason text check (reason in ('new_session', 'manual', 'idle', 'pin_reset', 'pin_changed')),
  locked_at timestamptz,
  unlocked_at timestamptz,
  last_activity timestamptz not null default now()
);
create index store_lock_sessions_user on app.store_lock_sessions (user_id);
revoke all on app.store_pins, app.store_lock_sessions from public, anon, authenticated;

create or replace function app.current_session_id() returns uuid
language sql stable as $$
  select case when coalesce(auth.jwt() ->> 'session_id', '') ~ '^[0-9a-f-]{36}$' then (auth.jwt() ->> 'session_id')::uuid end
$$;

-- True when the calling session must unlock before using business data.
create or replace function app.session_locked() returns boolean
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid(); sid uuid := app.current_session_id(); pin app.store_pins; s app.store_lock_sessions;
begin
  if uid is null or sid is null then return false; end if;           -- service/database calls
  select * into pin from app.store_pins where user_id = uid;
  if not found then return false; end if;                           -- no PIN yet: the app asks for one first
  select * into s from app.store_lock_sessions where session_id = sid and user_id = uid;
  if not found then return true; end if;                            -- a new sign-in starts locked
  return s.locked or s.last_activity < now() - make_interval(mins => pin.idle_minutes);
end $$;

-- Session row for the caller, created locked for a session never seen before.
create or replace function app.lock_session_row(uid uuid, sid uuid) returns app.store_lock_sessions
language plpgsql security definer set search_path = public as $$
declare s app.store_lock_sessions; idle int;
begin
  insert into app.store_lock_sessions (session_id, user_id, locked, reason, locked_at)
  values (sid, uid, true, 'new_session', now())
  on conflict (session_id) do nothing;
  select idle_minutes into idle from app.store_pins where user_id = uid;
  -- Persist an inactivity lock so it is reported (and kept) even if activity resumes.
  update app.store_lock_sessions set locked = true, reason = 'idle', locked_at = now()
   where session_id = sid and not locked and idle is not null and last_activity < now() - make_interval(mins => idle);
  select * into s from app.store_lock_sessions where session_id = sid;
  if s.user_id <> uid then perform app.raise('permission_denied'); end if;
  return s;
end $$;

create or replace function app.valid_pin(p text) returns boolean
language sql immutable as $$
  select p ~ '^[0-9]{4}$'
     and p !~ '^(.)\1{3}$'                                        -- 0000, 1111, …
     and p not in ('0123', '1234', '2345', '3456', '4567', '5678', '6789', '9876', '8765', '7654', '6543', '5432', '4321', '3210')
$$;

create or replace function app.fresh_login(max_age interval default interval '10 minutes') returns boolean
language sql stable as $$
  select coalesce((select max((x ->> 'timestamp')::bigint) from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) x), 0)
         >= extract(epoch from now() - max_age)
$$;

-- Checks a PIN with attempt limits. Never raises for a wrong PIN, so the failure is recorded.
-- 5 wrong PINs → 30 s wait, then 1, 2, 5, 10 min, then 15 min per further mistake.
create or replace function app.check_pin(uid uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pin app.store_pins; ok boolean; wait int;
begin
  select * into pin from app.store_pins where user_id = uid for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'pin_not_set'); end if;
  if pin.locked_until is not null and pin.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'pin_temporarily_locked',
      'retry_after', ceil(extract(epoch from pin.locked_until - now()))::int);
  end if;
  ok := p_pin ~ '^[0-9]{4}$' and extensions.crypt(p_pin, pin.pin_hash) = pin.pin_hash;
  if ok then
    update app.store_pins set failed_attempts = 0, locked_until = null where user_id = uid;
    return jsonb_build_object('ok', true);
  end if;
  wait := case when pin.failed_attempts + 1 < 5 then 0 when pin.failed_attempts + 1 = 5 then 30 when pin.failed_attempts + 1 = 6 then 60
               when pin.failed_attempts + 1 = 7 then 120 when pin.failed_attempts + 1 = 8 then 300 when pin.failed_attempts + 1 = 9 then 600 else 900 end;
  update app.store_pins set failed_attempts = failed_attempts + 1,
         locked_until = case when wait > 0 then now() + make_interval(secs => wait) end
   where user_id = uid;
  if wait > 0 then
    insert into public.audit_logs (user_id, action, entity, entity_id, details)
    values (uid, 'store_lock.too_many_attempts', 'user', uid::text, jsonb_build_object('attempts', pin.failed_attempts + 1, 'wait_seconds', wait));
  end if;
  return jsonb_build_object('ok', false, 'error', case when wait > 0 then 'pin_temporarily_locked' else 'wrong_pin' end,
    'retry_after', wait, 'attempts_left', greatest(0, 4 - pin.failed_attempts));
end $$;

create or replace function app.require_session() returns table (uid uuid, sid uuid)
language plpgsql stable as $$
begin
  uid := auth.uid(); sid := app.current_session_id();
  if uid is null then perform app.raise('not_authenticated'); end if;
  if sid is null then perform app.raise('session_required'); end if;
  return next;
end $$;

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------
create or replace function public.store_lock_status()
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record; pin app.store_pins; s app.store_lock_sessions;
begin
  select * into u from app.require_session();
  select * into pin from app.store_pins where user_id = u.uid;
  if not found then return jsonb_build_object('has_pin', false, 'locked', false); end if;
  s := app.lock_session_row(u.uid, u.sid);
  delete from app.store_lock_sessions where user_id = u.uid and last_activity < now() - interval '60 days' and session_id <> u.sid;
  return jsonb_build_object('has_pin', true, 'locked', s.locked, 'reason', s.reason, 'idle_minutes', pin.idle_minutes,
    'retry_after', case when pin.locked_until > now() then ceil(extract(epoch from pin.locked_until - now()))::int else 0 end,
    'can_reset', app.fresh_login());
end $$;

-- First PIN for this account. The session that sets it stays unlocked.
create or replace function public.set_store_pin(p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record;
begin
  select * into u from app.require_session();
  if exists (select 1 from app.store_pins where user_id = u.uid) then perform app.raise('pin_already_set'); end if;
  if not app.valid_pin(p_pin) then perform app.raise('pin_too_simple'); end if;
  insert into app.store_pins (user_id, pin_hash) values (u.uid, extensions.crypt(p_pin, extensions.gen_salt('bf', 10)));
  insert into app.store_lock_sessions (session_id, user_id, locked, unlocked_at, last_activity)
  values (u.sid, u.uid, false, now(), now())
  on conflict (session_id) do update set locked = false, reason = null, unlocked_at = now(), last_activity = now();
  insert into public.audit_logs (user_id, action, entity, entity_id) values (u.uid, 'store_lock.pin_created', 'user', u.uid::text);
  return public.store_lock_status();
end $$;

create or replace function public.lock_store()
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record;
begin
  select * into u from app.require_session();
  if not exists (select 1 from app.store_pins where user_id = u.uid) then perform app.raise('pin_not_set'); end if;
  perform app.lock_session_row(u.uid, u.sid);
  update app.store_lock_sessions set locked = true, reason = 'manual', locked_at = now() where session_id = u.sid and not locked;
  return public.store_lock_status();
end $$;

create or replace function public.unlock_store(p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record; r jsonb;
begin
  select * into u from app.require_session();
  perform app.rate_limit('pin:' || u.uid, 30, 3600);
  r := app.check_pin(u.uid, p_pin);
  if (r ->> 'ok')::boolean then
    perform app.lock_session_row(u.uid, u.sid);
    update app.store_lock_sessions set locked = false, reason = null, unlocked_at = now(), last_activity = now() where session_id = u.sid;
  end if;
  return r || jsonb_build_object('status', public.store_lock_status());
end $$;

-- Activity from an unlocked session (called by the app while the user is active).
create or replace function public.store_lock_heartbeat()
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record; s app.store_lock_sessions;
begin
  select * into u from app.require_session();
  if not exists (select 1 from app.store_pins where user_id = u.uid) then return jsonb_build_object('has_pin', false, 'locked', false); end if;
  s := app.lock_session_row(u.uid, u.sid);
  if not s.locked then update app.store_lock_sessions set last_activity = now() where session_id = u.sid; end if;
  return jsonb_build_object('has_pin', true, 'locked', s.locked, 'reason', s.reason);
end $$;

-- Change PIN: needs the current PIN (same attempt limits). Other devices are locked.
create or replace function public.change_store_pin(p_current text, p_new text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record; r jsonb;
begin
  select * into u from app.require_session();
  perform app.rate_limit('pin:' || u.uid, 30, 3600);
  if app.session_locked() then perform app.raise('store_locked'); end if;
  if not app.valid_pin(p_new) then perform app.raise('pin_too_simple'); end if;
  r := app.check_pin(u.uid, p_current);
  if not (r ->> 'ok')::boolean then return r; end if;
  update app.store_pins set pin_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)), pin_changed_at = now() where user_id = u.uid;
  update app.store_lock_sessions set locked = true, reason = 'pin_changed', locked_at = now()
   where user_id = u.uid and session_id <> u.sid and not locked;
  insert into public.audit_logs (user_id, action, entity, entity_id) values (u.uid, 'store_lock.pin_changed', 'user', u.uid::text);
  return r;
end $$;

-- Forgotten PIN: allowed within 10 minutes of signing in (password, Google, email link…).
-- Every session of the user — this one included — must then unlock with the new PIN.
create or replace function public.reset_store_pin(p_new text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record;
begin
  select * into u from app.require_session();
  perform app.rate_limit('pin_reset:' || u.uid, 5, 3600);
  if not app.fresh_login() then perform app.raise('fresh_login_required'); end if;
  if not app.valid_pin(p_new) then perform app.raise('pin_too_simple'); end if;
  insert into app.store_pins (user_id, pin_hash) values (u.uid, extensions.crypt(p_new, extensions.gen_salt('bf', 10)))
  on conflict (user_id) do update set pin_hash = excluded.pin_hash, pin_changed_at = now(), failed_attempts = 0, locked_until = null;
  perform app.lock_session_row(u.uid, u.sid);
  update app.store_lock_sessions set locked = true, reason = 'pin_reset', locked_at = now() where user_id = u.uid;
  insert into public.audit_logs (user_id, action, entity, entity_id) values (u.uid, 'store_lock.pin_reset', 'user', u.uid::text);
  return public.store_lock_status();
end $$;

create or replace function public.set_store_lock_timeout(p_minutes int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record;
begin
  select * into u from app.require_session();
  if app.session_locked() then perform app.raise('store_locked'); end if;
  if p_minutes is null or p_minutes < 1 or p_minutes > 240 then perform app.raise('invalid_input'); end if;
  update app.store_pins set idle_minutes = p_minutes where user_id = u.uid;
  if not found then perform app.raise('pin_not_set'); end if;
  update app.store_lock_sessions set last_activity = now() where session_id = u.sid;
  return public.store_lock_status();
end $$;

-- ---------------------------------------------------------------------------
-- Enforcement: the shared access checks refuse a locked session
-- ---------------------------------------------------------------------------
create or replace function app.require_auth() returns uuid language plpgsql stable as $$
declare v uuid := auth.uid();
begin
  if v is null then perform app.raise('not_authenticated'); end if;
  if app.session_locked() then perform app.raise('store_locked'); end if;
  return v;
end $$;

create or replace function app.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select not app.session_locked() and exists (select 1 from public.platform_admins where user_id = auth.uid())
$$;

create or replace function app.my_business_ids() returns uuid[]
language sql stable security definer set search_path = public as $$
  select case when app.session_locked() then '{}'::uuid[] else
    (select coalesce(array_agg(business_id), '{}') from public.business_members where user_id = auth.uid() and active) end
$$;

create or replace function app.is_member(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not app.session_locked() and exists (select 1 from public.business_members
                 where business_id = bid and user_id = auth.uid() and active)
$$;

create or replace function app.can_read(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not app.session_locked() and (app.is_member(bid) or (
    app.is_platform_admin() and exists (
      select 1 from public.support_access_grants g
      where g.business_id = bid and g.revoked_at is null and g.expires_at > now())))
$$;

create or replace function app.has_perm(bid uuid, perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select not app.session_locked() and coalesce((
    select case
      when m.role = 'owner' then true
      when m.permissions ? perm then (m.permissions ->> perm)::boolean
      else perm = any (app.role_permissions(m.role))
    end
    from public.business_members m
    join public.businesses b on b.id = m.business_id and b.status = 'active'
    where m.business_id = bid and m.user_id = auth.uid() and m.active
  ), false)
$$;

create or replace function public.get_my_context()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return null; end if;
  if app.session_locked() then perform app.raise('store_locked'); end if;
  return jsonb_build_object(
    'user_id', uid,
    'email', (select email from auth.users where id = uid),
    'email_confirmed', (select email_confirmed_at is not null from auth.users where id = uid),
    'profile', (select to_jsonb(pr) from public.profiles pr where pr.id = uid),
    'is_platform_admin', app.is_platform_admin(),
    'pending_invites', (select count(*) from public.business_invites i
                        where lower(i.email) = lower((select email from auth.users where id = uid))
                          and i.accepted_at is null and i.revoked_at is null),
    'businesses', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', b.id, 'name', b.name, 'role', m.role, 'status', b.status, 'currency', b.currency,
        'currency_decimals', b.currency_decimals, 'language', b.language, 'timezone', b.timezone,
        'category', b.category, 'logo_path', b.logo_path, 'country_code', b.country_code,
        'permissions', to_jsonb(app.my_permissions(b.id)),
        'subscription', app.subscription_info(b.id),
        'plan', (select jsonb_build_object('code', ep.code, 'name_en', ep.name_en, 'name_fr', ep.name_fr,
                                           'features', ep.features, 'limits', ep.limits)
                 from app.effective_plan(b.id) ep)
      ) order by b.created_at)
      from public.business_members m join public.businesses b on b.id = m.business_id
      where m.user_id = uid and m.active and b.status <> 'closed'), '[]'::jsonb));
end $$;

revoke execute on function app.check_pin(uuid, text) from public, anon, authenticated;
revoke execute on function app.lock_session_row(uuid, uuid) from public, anon, authenticated;
grant execute on function app.session_locked() to anon, authenticated; -- used inside RLS checks
revoke execute on function public.store_lock_status() from public, anon;
revoke execute on function public.set_store_pin(text) from public, anon;
revoke execute on function public.lock_store() from public, anon;
revoke execute on function public.unlock_store(text) from public, anon;
revoke execute on function public.store_lock_heartbeat() from public, anon;
revoke execute on function public.change_store_pin(text, text) from public, anon;
revoke execute on function public.reset_store_pin(text) from public, anon;
revoke execute on function public.set_store_lock_timeout(int) from public, anon;
grant execute on function public.store_lock_status(), public.set_store_pin(text), public.lock_store(), public.unlock_store(text),
  public.store_lock_heartbeat(), public.change_store_pin(text, text), public.reset_store_pin(text), public.set_store_lock_timeout(int)
  to authenticated;

-- ===== 20261025000100_marketplace.sql =====
-- BizPilot Market: every business can open an online store connected to its BizPilot inventory.
--
-- Design (see docs/MARKETPLACE.md):
--   * One store per business (public.stores), published at /s/{slug}.
--   * Listings are the business's own products (products.online_published). Variants are the
--     product's child products; each has its own price and stock.
--   * One seller per order. Prices, delivery fees, discounts and totals are computed on the server.
--   * Placing an order reserves stock (public.stock_reservations). Reserved stock cannot be sold at the
--     counter (app.apply_movement refuses a shop sale that would eat into it), so the shop and the
--     online store share one stock figure without overselling. Delivery turns the order into a normal
--     BizPilot sale (stock movement, cost, payment), so reports and cash stay complete.
--   * Unpaid online orders and unconfirmed cash-on-delivery orders release their stock automatically.
--   * Public data is only reachable through SECURITY DEFINER functions that return safe columns
--     (never costs, stock values, suppliers or customer details).
-- Online payments (Fapshi), settlements, commissions and administration: next migration.

-- ---------------------------------------------------------------------------
-- Permissions: orders and store management
-- ---------------------------------------------------------------------------
create or replace function app.role_permissions(r text) returns text[]
language sql immutable as $$
  select case r
    when 'owner' then array[
      'sales.create', 'sales.view', 'sales.refund', 'sales.discount_large', 'products.view',
      'products.manage', 'inventory.view', 'stock.adjust', 'purchases.manage', 'suppliers.manage',
      'customers.manage', 'customers.credit', 'expenses.manage', 'reports.view', 'cash.manage',
      'imports.manage', 'staff.manage', 'settings.manage', 'billing.manage', 'audit.view',
      'orders.manage', 'store.manage']
    when 'manager' then array[
      'sales.create', 'sales.view', 'sales.refund', 'sales.discount_large', 'products.view',
      'products.manage', 'inventory.view', 'stock.adjust', 'purchases.manage', 'suppliers.manage',
      'customers.manage', 'customers.credit', 'expenses.manage', 'reports.view', 'cash.manage',
      'imports.manage', 'orders.manage', 'store.manage']
    when 'cashier' then array[
      'sales.create', 'sales.view', 'products.view', 'inventory.view', 'customers.manage', 'orders.manage']
    else array[]::text[]
  end
$$;

-- ---------------------------------------------------------------------------
-- Configuration (public: these values are shown to sellers and buyers)
-- ---------------------------------------------------------------------------
insert into public.app_config (key, value, is_public) values
  ('marketplace', '{"enabled": true, "online_payments_enabled": false, "commission_pct": 0, "online_fee_pct": 0,
    "unpaid_order_minutes": 30, "confirm_hours": 48, "max_open_cod_per_phone": 3,
    "policies_en": "", "policies_fr": ""}', true)
on conflict (key) do nothing;

create or replace function app.market_config() returns jsonb
language sql stable security definer set search_path = public as $$
  select '{"enabled": true, "online_payments_enabled": false, "commission_pct": 0, "online_fee_pct": 0,
           "unpaid_order_minutes": 30, "confirm_hours": 48, "max_open_cod_per_phone": 3}'::jsonb
         || coalesce((select value from public.app_config where key = 'marketplace'), '{}'::jsonb)
$$;

-- Plans: storefront limits and premium features (only added where an administrator has not set them).
update public.plans set limits = limits || '{"max_online_products": 20}'::jsonb
 where code = 'free' and not limits ? 'max_online_products';
update public.plans set limits = limits || '{"max_online_products": 300}'::jsonb
 where code = 'starter' and not limits ? 'max_online_products';
update public.plans set limits = limits || '{"max_online_products": null}'::jsonb
 where code = 'business' and not limits ? 'max_online_products';
update public.plans set features = features || array['promotions', 'store_customization']
 where code in ('starter', 'business') and not ('promotions' = any (features));

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
-- Phone numbers are stored as +<country><number>. Cameroon numbers may be typed without +237.
create or replace function app.norm_phone(p text) returns text language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
begin
  if length(d) = 9 and d ~ '^[62]' then return '+237' || d; end if;
  if length(d) = 12 and d like '237%' then return '+' || d; end if;
  if length(d) between 8 and 15 then return '+' || d; end if;
  return null;
end $$;

create or replace function app.valid_email(p text) returns boolean language sql immutable as $$
  select p ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(p) <= 200
$$;

-- Caller IP as seen by the API gateway (used for anonymous rate limits only).
create or replace function app.client_ip() returns text language plpgsql stable as $$
declare h jsonb;
begin
  begin h := current_setting('request.headers', true)::jsonb; exception when others then h := null; end;
  return coalesce(nullif(btrim(split_part(coalesce(h ->> 'x-forwarded-for', ''), ',', 1)), ''), h ->> 'cf-connecting-ip',
                  h ->> 'x-real-ip', 'unknown');
end $$;

create or replace function app.sha256(p text) returns text language sql immutable as $$
  select encode(extensions.digest(convert_to(p, 'UTF8'), 'sha256'), 'hex')
$$;

create or replace function app.like_term(p text) returns text language sql immutable as $$
  select '%' || replace(replace(replace(btrim(p), '\', '\\'), '%', '\%'), '_', '\_') || '%'
$$;

-- ---------------------------------------------------------------------------
-- Stores
-- ---------------------------------------------------------------------------
create table public.stores (
  business_id uuid primary key references public.businesses (id) on delete cascade,
  slug text not null check (slug ~ '^[a-z0-9]([a-z0-9-]{1,38})[a-z0-9]$'),
  name text not null check (length(btrim(name)) between 2 and 80),
  tagline text check (length(tagline) <= 120),
  description text check (length(description) <= 2000),
  logo_path text,
  cover_path text,
  brand_color text check (brand_color ~ '^#[0-9a-fA-F]{6}$'),
  city text check (length(city) <= 80),
  region text check (length(region) <= 80),
  address text check (length(address) <= 200),
  phone text,
  whatsapp text,
  email text,
  show_phone boolean not null default false,
  show_whatsapp boolean not null default true,
  show_email boolean not null default false,
  show_address boolean not null default true,
  facebook_url text check (length(facebook_url) <= 200),
  instagram_url text check (length(instagram_url) <= 200),
  tiktok_url text check (length(tiktok_url) <= 200),
  opening_hours jsonb not null default '{}'::jsonb,
  hours_note text check (length(hours_note) <= 200),
  delivery_note text check (length(delivery_note) <= 1000),
  pickup_enabled boolean not null default false,
  pickup_note text check (length(pickup_note) <= 300),
  cod_enabled boolean not null default true,
  online_payment_enabled boolean not null default false,
  min_order_amount numeric(14, 2) not null default 0 check (min_order_amount >= 0),
  status text not null default 'draft' check (status in ('draft', 'published', 'suspended')),
  suspended_reason text,
  verification text not null default 'unverified' check (verification in ('unverified', 'pending', 'verified', 'rejected')),
  verification_note text,
  rating_avg numeric(3, 2) not null default 0,
  rating_count int not null default 0,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index stores_slug_unique on public.stores (lower(slug));
create index stores_published on public.stores (status, city) where status = 'published';
create trigger stores_touch before update on public.stores for each row execute function app.touch_updated_at();

create table public.store_delivery_zones (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 80),
  fee numeric(14, 2) not null default 0 check (fee >= 0),
  eta text check (length(eta) <= 60),
  active boolean not null default true,
  sort int not null default 0,
  created_at timestamptz not null default now()
);
create index store_delivery_zones_business on public.store_delivery_zones (business_id, sort);

-- ---------------------------------------------------------------------------
-- Listings (columns on the seller's products)
-- ---------------------------------------------------------------------------
alter table public.products
  add column if not exists online_published boolean not null default false,
  add column if not exists online_since timestamptz,
  add column if not exists online_images text[] not null default '{}',
  add column if not exists compare_at_price numeric(14, 2) check (compare_at_price >= 0),
  add column if not exists admin_hidden boolean not null default false,
  add column if not exists admin_hidden_reason text;
create index if not exists products_online on public.products (business_id, online_since)
  where online_published and status = 'active' and variant_of is null;

alter table public.customers
  add column if not exists source text not null default 'shop' check (source in ('shop', 'online')),
  add column if not exists user_id uuid references auth.users (id) on delete set null;
create index if not exists customers_business_phone on public.customers (business_id, phone);

-- Listing rules. Runs as the caller (not SECURITY DEFINER) so app.is_internal() is meaningful.
create or replace function app.products_market_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if not app.is_internal() and tg_op = 'UPDATE'
     and (new.admin_hidden is distinct from old.admin_hidden or new.admin_hidden_reason is distinct from old.admin_hidden_reason) then
    perform app.raise('protected_field');
  end if;
  if not app.is_internal() and tg_op = 'INSERT' and (new.admin_hidden or new.admin_hidden_reason is not null) then
    perform app.raise('protected_field');
  end if;
  if coalesce(array_length(new.online_images, 1), 0) > 8 then perform app.raise('too_many_images'); end if;
  if exists (select 1 from unnest(new.online_images) i where split_part(i, '/', 1) <> new.business_id::text) then
    perform app.raise('invalid_image');
  end if;
  if new.online_published and (tg_op = 'INSERT' or not old.online_published) then
    if new.variant_of is not null then perform app.raise('variant_listed_with_parent'); end if;
    perform app.check_limit(new.business_id, 'max_online_products');
    new.online_since := clock_timestamp();
  end if;
  if not new.online_published then new.online_since := null; end if;
  return new;
end $$;
create trigger products_market_guard before insert or update on public.products
  for each row execute function app.products_market_guard();

-- Plan usage counts (adds online listings).
create or replace function app.usage_count(bid uuid, k text) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare v numeric;
begin
  if k = 'max_products' then
    select count(*) into v from public.products where business_id = bid and status = 'active';
  elsif k = 'max_online_products' then
    select count(*) into v from public.products where business_id = bid and status = 'active'
      and online_published and variant_of is null;
  elsif k = 'max_sales_per_month' then
    select count(*) into v from public.sales where business_id = bid
      and sold_at >= app.range_start(bid, date_trunc('month', app.biz_today(bid))::date);
  elsif k = 'max_staff' then
    select (select count(*) from public.business_members where business_id = bid and active)
         + (select count(*) from public.business_invites where business_id = bid
              and accepted_at is null and revoked_at is null) into v;
  elsif k = 'ai_queries_per_month' then
    select count(*) into v from public.ai_queries where business_id = bid
      and created_at >= date_trunc('month', now()) and status in ('started', 'completed');
  else
    v := 0;
  end if;
  return v;
end $$;

-- A listing stays visible within the seller's current plan limit (oldest listings first), so an
-- expired paid plan hides the listings above the free limit instead of deleting anything.
create or replace function app.listing_within_limit(bid uuid, since timestamptz, pid uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare lim numeric := app.plan_limit(bid, 'max_online_products');
begin
  if lim is null then return true; end if;
  return (select count(*) from public.products p where p.business_id = bid and p.online_published
            and p.status = 'active' and p.variant_of is null and (p.online_since, p.id) < (since, pid)) < lim;
end $$;

-- ---------------------------------------------------------------------------
-- Promotions, orders, reservations, reviews, reports, customer data
-- ---------------------------------------------------------------------------
create table public.market_promotions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  code text not null check (code ~ '^[A-Z0-9_-]{3,20}$'),
  description text check (length(description) <= 200),
  kind text not null check (kind in ('percent', 'fixed')),
  value numeric(14, 2) not null check (value > 0),
  min_order numeric(14, 2) not null default 0 check (min_order >= 0),
  starts_at timestamptz,
  ends_at timestamptz,
  max_uses int check (max_uses > 0),
  used_count int not null default 0,
  active boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now(),
  check (kind <> 'percent' or value <= 90),
  check (ends_at is null or starts_at is null or ends_at > starts_at)
);
create unique index market_promotions_code on public.market_promotions (business_id, code);

create table public.market_orders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  number text not null,
  client_ref uuid not null unique,
  customer_user_id uuid references auth.users (id) on delete set null,
  access_token_hash text,
  customer_id uuid references public.customers (id),
  customer_name text not null,
  customer_phone text not null,
  customer_email text,
  delivery_method text not null check (delivery_method in ('delivery', 'pickup')),
  zone_id uuid references public.store_delivery_zones (id) on delete set null,
  zone_name text,
  delivery_eta text,
  address jsonb,
  notes text check (length(notes) <= 500),
  subtotal numeric(14, 2) not null,
  discount numeric(14, 2) not null default 0,
  delivery_fee numeric(14, 2) not null default 0,
  total numeric(14, 2) not null,
  currency text not null default 'XAF',
  promo_id uuid references public.market_promotions (id) on delete set null,
  promo_code text,
  payment_method text not null check (payment_method in ('cod', 'online')),
  payment_status text not null check (payment_status in ('awaiting_payment', 'paid', 'failed', 'cod_pending',
    'cod_collected', 'refund_pending', 'refunded', 'void')),
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'processing', 'dispatched',
    'delivered', 'cancelled', 'refunded')),
  commission_pct numeric(5, 2) not null default 0,
  commission_amount numeric(14, 2) not null default 0,
  online_fee_pct numeric(5, 2) not null default 0,
  online_fee_amount numeric(14, 2) not null default 0,
  sale_id uuid references public.sales (id),
  cod_collected_amount numeric(14, 2),
  cod_method text check (cod_method in ('cash', 'mtn_momo', 'orange_money')),
  cod_collected_at timestamptz,
  cod_collected_by uuid,
  confirmed_at timestamptz,
  dispatched_at timestamptz,
  delivered_at timestamptz,
  delivered_by uuid,
  delivery_proof_path text,
  delivery_proof_note text check (length(delivery_proof_note) <= 300),
  received_by text check (length(received_by) <= 80),
  cancelled_at timestamptz,
  cancel_reason text,
  cancelled_by text check (cancelled_by in ('customer', 'seller', 'system', 'admin')),
  refunded_at timestamptz,
  refund_amount numeric(14, 2),
  refund_reference text,
  expires_at timestamptz,
  flagged boolean not null default false,
  flag_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, number),
  check (customer_user_id is not null or access_token_hash is not null)
);
create index market_orders_business on public.market_orders (business_id, created_at desc);
create index market_orders_customer on public.market_orders (customer_user_id, created_at desc) where customer_user_id is not null;
create index market_orders_expiring on public.market_orders (expires_at) where status = 'pending';
create index market_orders_phone on public.market_orders (business_id, customer_phone) where status in ('pending', 'confirmed', 'processing', 'dispatched');
create index market_orders_attention on public.market_orders (created_at) where flagged or payment_status = 'refund_pending';
create trigger market_orders_touch before update on public.market_orders for each row execute function app.touch_updated_at();

create table public.market_order_lines (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.market_orders (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id),
  listing_id uuid references public.products (id),
  name text not null,
  variant_label text,
  sku text,
  image_path text,
  unit_price numeric(14, 2) not null check (unit_price >= 0),
  quantity numeric(14, 3) not null check (quantity > 0),
  line_total numeric(14, 2) not null check (line_total >= 0),
  sort int not null default 0
);
create index market_order_lines_order on public.market_order_lines (order_id);
create index market_order_lines_product on public.market_order_lines (product_id);

create table public.market_order_events (
  id bigserial primary key,
  order_id uuid not null references public.market_orders (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  kind text not null check (kind in ('status', 'message', 'payment', 'note', 'dispute')),
  status text,
  message text check (length(message) <= 1000),
  actor text not null check (actor in ('customer', 'seller', 'system', 'admin')),
  actor_user uuid,
  visible_to_customer boolean not null default true,
  created_at timestamptz not null default now()
);
create index market_order_events_order on public.market_order_events (order_id, created_at);

create table public.stock_reservations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id),
  order_id uuid not null references public.market_orders (id) on delete cascade,
  quantity numeric(14, 3) not null check (quantity > 0),
  expires_at timestamptz,
  released_at timestamptz,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
create index stock_reservations_active on public.stock_reservations (product_id)
  where released_at is null and consumed_at is null;
create index stock_reservations_order on public.stock_reservations (order_id);

create table public.market_reviews (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  order_id uuid not null references public.market_orders (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  listing_id uuid references public.products (id) on delete cascade,
  user_id uuid references auth.users (id) on delete set null,
  author_name text not null,
  rating int not null check (rating between 1 and 5),
  comment text check (length(comment) <= 1000),
  seller_reply text check (length(seller_reply) <= 1000),
  replied_at timestamptz,
  status text not null default 'visible' check (status in ('visible', 'hidden')),
  hidden_reason text,
  created_at timestamptz not null default now(),
  unique (order_id, product_id)
);
create index market_reviews_listing on public.market_reviews (listing_id, created_at desc) where status = 'visible';
create index market_reviews_business on public.market_reviews (business_id, created_at desc);

create table public.market_reports (
  id uuid primary key default gen_random_uuid(),
  kind text not null default 'report' check (kind in ('report', 'dispute')),
  target_type text not null check (target_type in ('product', 'store', 'order')),
  target_id uuid not null,
  business_id uuid references public.businesses (id) on delete cascade,
  order_id uuid references public.market_orders (id) on delete set null,
  reason text not null check (reason in ('counterfeit', 'prohibited', 'misleading', 'scam', 'not_delivered',
    'wrong_item', 'damaged', 'payment_problem', 'refund_problem', 'harassment', 'other')),
  details text check (length(details) <= 2000),
  reporter_user_id uuid references auth.users (id) on delete set null,
  reporter_contact text check (length(reporter_contact) <= 120),
  status text not null default 'open' check (status in ('open', 'reviewing', 'resolved', 'dismissed')),
  resolution text check (length(resolution) <= 2000),
  handled_by uuid,
  handled_at timestamptz,
  created_at timestamptz not null default now()
);
create index market_reports_open on public.market_reports (created_at desc) where status in ('open', 'reviewing');
create index market_reports_business on public.market_reports (business_id);

create table public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  label text check (length(label) <= 40),
  recipient_name text not null check (length(btrim(recipient_name)) between 2 and 80),
  phone text not null check (length(phone) <= 20),
  city text not null check (length(btrim(city)) between 2 and 80),
  area text check (length(area) <= 80),
  line text check (length(line) <= 200),
  landmark text check (length(landmark) <= 200),
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);
create index customer_addresses_user on public.customer_addresses (user_id);

create table public.market_favorites (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, product_id)
);

create table public.market_store_follows (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, business_id)
);

-- Fraud control: contacts blocked from ordering (managed by platform administrators).
create table public.market_blocklist (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('phone', 'email', 'user')),
  value text not null,
  reason text not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (kind, value)
);

create or replace function app.customer_addresses_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and (select count(*) from public.customer_addresses where user_id = new.user_id) >= 10 then
    perform app.raise('too_many_addresses');
  end if;
  new.phone := coalesce(app.norm_phone(new.phone), new.phone);
  if new.is_default then
    update public.customer_addresses set is_default = false where user_id = new.user_id and id <> new.id and is_default;
  end if;
  return new;
end $$;
create trigger customer_addresses_guard before insert or update on public.customer_addresses
  for each row execute function app.customer_addresses_guard();

-- ---------------------------------------------------------------------------
-- Stock reservations
-- ---------------------------------------------------------------------------
create or replace function app.reserved_qty(p_product uuid, p_exclude_order uuid default null) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(quantity), 0) from public.stock_reservations
   where product_id = p_product and released_at is null and consumed_at is null
     and (expires_at is null or expires_at > now())
     and (p_exclude_order is null or order_id <> p_exclude_order)
$$;

-- Stock movement routine, unchanged except that a shop sale may not use stock reserved for online
-- orders (unless the business allows negative stock).
create or replace function app.apply_movement(
  p_business uuid,
  p_product uuid,
  p_type text,
  p_qty numeric,
  p_unit_cost numeric,
  p_ref_type text default null,
  p_ref_id uuid default null,
  p_ref_number text default null,
  p_reason text default null,
  p_batch uuid default null,
  p_cost_estimated boolean default false,
  p_client_ref uuid default null,
  p_occurred_at timestamptz default now(),
  p_allow_negative boolean default null
) returns public.stock_movements
language plpgsql security definer set search_path = public as $$
declare
  pr public.products;
  allow_neg boolean;
  v_cost numeric(18, 4);
  v_value numeric(18, 4);
  new_qty numeric(14, 3);
  new_value numeric(18, 4);
  new_avg numeric(18, 4);
  reserved numeric;
  mv public.stock_movements;
begin
  if p_qty is null or p_qty = 0 then perform app.raise('invalid_quantity'); end if;

  select * into pr from public.products where id = p_product and business_id = p_business for update;
  if not found then perform app.raise('invalid_product'); end if;

  if not pr.allow_fraction and p_qty <> trunc(p_qty) then
    perform app.raise('fractional_quantity_not_allowed', jsonb_build_object('product', pr.name));
  end if;

  new_qty := pr.qty_on_hand + p_qty;

  if p_qty > 0 then
    v_cost := coalesce(p_unit_cost, pr.avg_cost);
    if v_cost < 0 then perform app.raise('invalid_cost'); end if;
    v_value := round(p_qty * v_cost, 4);
    if pr.qty_on_hand <= 0 then
      new_value := round(new_qty * v_cost, 4);
      new_avg := v_cost;
    else
      new_value := pr.stock_value + v_value;
      new_avg := round(new_value / new_qty, 4);
    end if;
  else
    select allow_negative_stock into allow_neg from public.business_settings where business_id = p_business;
    allow_neg := coalesce(p_allow_negative, allow_neg, false);
    if new_qty < 0 and not allow_neg then
      perform app.raise('insufficient_stock', jsonb_build_object(
        'product', pr.name, 'available', pr.qty_on_hand, 'requested', -p_qty, 'unit', pr.base_unit));
    end if;
    if p_type = 'sale' and not allow_neg then
      reserved := app.reserved_qty(p_product);
      if reserved > 0 and new_qty < reserved then
        perform app.raise('insufficient_stock', jsonb_build_object(
          'product', pr.name, 'available', greatest(pr.qty_on_hand - reserved, 0), 'requested', -p_qty,
          'unit', pr.base_unit, 'reserved', reserved));
      end if;
    end if;
    v_cost := pr.avg_cost;
    if new_qty = 0 then
      v_value := -pr.stock_value;
      new_value := 0;
    else
      v_value := round(p_qty * v_cost, 4);
      new_value := case when new_qty < 0 then round(new_qty * v_cost, 4) else pr.stock_value + v_value end;
    end if;
    new_avg := pr.avg_cost;
  end if;

  update public.products
     set qty_on_hand = new_qty, stock_value = new_value, avg_cost = new_avg
   where id = p_product;

  insert into public.stock_movements (business_id, product_id, movement_type, quantity, unit_cost, value,
    qty_after, avg_cost_after, stock_value_after, batch_id, ref_type, ref_id, ref_number, reason,
    cost_estimated, client_ref, created_by, occurred_at)
  values (p_business, p_product, p_type, p_qty, v_cost, v_value, new_qty, new_avg, new_value, p_batch,
    p_ref_type, p_ref_id, p_ref_number, p_reason, p_cost_estimated, p_client_ref, auth.uid(),
    coalesce(p_occurred_at, now()))
  returning * into mv;
  return mv;
end $$;

-- ---------------------------------------------------------------------------
-- Public read model
-- ---------------------------------------------------------------------------
create or replace function app.store_is_live(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.stores s join public.businesses b on b.id = s.business_id
                 where s.business_id = bid and s.status = 'published' and b.status = 'active')
$$;

-- The top-level listing a purchasable product belongs to (itself, or its parent for a variant),
-- when it is publicly listed.
create or replace function app.listing_of(p_product uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select l.id from public.products p
    join public.products l on l.id = coalesce(p.variant_of, p.id)
   where p.id = p_product and p.status = 'active' and not p.admin_hidden
     and l.online_published and l.status = 'active' and not l.admin_hidden and l.variant_of is null
     and app.store_is_live(l.business_id) and app.listing_within_limit(l.business_id, l.online_since, l.id)
$$;

create or replace function app.listing_public(p_product uuid) returns boolean
language sql stable as $$ select app.listing_of(p_product) = p_product $$;

-- Purchasable options of a listing: its active variants, or the product itself when it has none.
create or replace function app.listing_options(p_listing uuid)
returns table (id uuid, label text, price numeric, compare_at numeric, available numeric, attributes jsonb, sku text, allow_fraction boolean)
language sql stable security definer set search_path = public as $$
  with kids as (
    select c.* from public.products c where c.variant_of = p_listing and c.status = 'active' and not c.admin_hidden)
  select k.id, coalesce(k.variant_label, k.name), k.selling_price, k.compare_at_price,
         greatest(k.qty_on_hand - app.reserved_qty(k.id), 0), k.attributes, k.sku, k.allow_fraction
    from kids k
  union all
  select p.id, null, p.selling_price, p.compare_at_price, greatest(p.qty_on_hand - app.reserved_qty(p.id), 0),
         p.attributes, p.sku, p.allow_fraction
    from public.products p where p.id = p_listing and not exists (select 1 from kids)
$$;

create or replace function app.store_card(bid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('business_id', s.business_id, 'slug', s.slug, 'name', s.name, 'tagline', s.tagline,
    'logo_path', s.logo_path, 'city', s.city, 'verified', s.verification = 'verified',
    'rating_avg', s.rating_avg, 'rating_count', s.rating_count, 'business_type', b.category,
    'cover_path', case when app.has_feature(s.business_id, 'store_customization') then s.cover_path end,
    'brand_color', case when app.has_feature(s.business_id, 'store_customization') then s.brand_color end,
    'products', (select count(*) from public.products p where p.business_id = s.business_id and p.online_published
                  and p.status = 'active' and not p.admin_hidden and p.variant_of is null))
  from public.stores s join public.businesses b on b.id = s.business_id where s.business_id = bid
$$;

create or replace function app.product_card(p_listing uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', p.id, 'name', p.name, 'brand', p.brand,
    'image', p.online_images[1], 'unit', p.base_unit,
    'price', o.min_price, 'max_price', o.max_price, 'compare_at_price',
      case when p.compare_at_price > o.min_price then p.compare_at_price end,
    'available', least(o.available, 99), 'options', o.n,
    'category', c.name, 'subcategory', p.subcategory,
    'rating_avg', r.avg, 'rating_count', coalesce(r.n, 0),
    'store', jsonb_build_object('slug', s.slug, 'name', s.name, 'city', s.city, 'verified', s.verification = 'verified',
                                'logo_path', s.logo_path))
  from public.products p
  join public.stores s on s.business_id = p.business_id
  left join public.categories c on c.id = p.category_id
  cross join lateral (select min(x.price) min_price, max(x.price) max_price, sum(x.available) available, count(*) n
                        from app.listing_options(p.id) x) o
  left join lateral (select round(avg(rating), 1) avg, count(*) n from public.market_reviews
                      where listing_id = p.id and status = 'visible') r on true
  where p.id = p_listing
$$;

create or replace function public.market_config_public() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('enabled', coalesce((c ->> 'enabled')::boolean, true),
    'online_payments_enabled', coalesce((c ->> 'online_payments_enabled')::boolean, false),
    'commission_pct', coalesce((c ->> 'commission_pct')::numeric, 0),
    'online_fee_pct', coalesce((c ->> 'online_fee_pct')::numeric, 0),
    'unpaid_order_minutes', (c ->> 'unpaid_order_minutes')::int,
    'policies_en', c ->> 'policies_en', 'policies_fr', c ->> 'policies_fr')
  from (select app.market_config() c) t
$$;

-- Search and browse. p: {q, type (business type), category, store, city, min_price, max_price,
-- in_stock, sort: relevance|newest|price_asc|price_desc|rating, page, page_size}
create or replace function public.market_search(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  q text := nullif(btrim(coalesce(p ->> 'q', '')), '');
  v_type text := nullif(p ->> 'type', '');
  v_cat text := nullif(btrim(coalesce(p ->> 'category', '')), '');
  v_store text := nullif(lower(p ->> 'store'), '');
  v_city text := nullif(btrim(coalesce(p ->> 'city', '')), '');
  minp numeric := nullif(p ->> 'min_price', '')::numeric;
  maxp numeric := nullif(p ->> 'max_price', '')::numeric;
  instock boolean := coalesce((p ->> 'in_stock')::boolean, false);
  v_sort text := coalesce(nullif(p ->> 'sort', ''), 'relevance');
  size int := least(greatest(coalesce((p ->> 'page_size')::int, 24), 1), 60);
  pg int := greatest(coalesce((p ->> 'page')::int, 1), 1);
  res jsonb;
begin
  if q is not null and length(q) > 80 then q := left(q, 80); end if;
  with base as (
    select pr.id, pr.name, pr.online_since, o.min_price, o.available,
           coalesce(r.avg, 0) rating,
           case when q is null then 0
                when lower(pr.name) = lower(q) then 3
                when pr.name ilike app.like_term(q) then 2 else 1 end rel
      from public.products pr
      join public.stores s on s.business_id = pr.business_id and s.status = 'published'
      join public.businesses b on b.id = pr.business_id and b.status = 'active'
      left join public.categories c on c.id = pr.category_id
      cross join lateral (select min(x.price) min_price, sum(x.available) available from app.listing_options(pr.id) x) o
      left join lateral (select avg(rating) avg from public.market_reviews mr where mr.listing_id = pr.id and mr.status = 'visible') r on true
     where pr.online_published and pr.status = 'active' and not pr.admin_hidden and pr.variant_of is null
       and app.listing_within_limit(pr.business_id, pr.online_since, pr.id)
       and (q is null or pr.name ilike app.like_term(q) or pr.brand ilike app.like_term(q)
            or pr.description ilike app.like_term(q) or c.name ilike app.like_term(q)
            or pr.subcategory ilike app.like_term(q) or s.name ilike app.like_term(q))
       and (v_type is null or b.category = v_type)
       and (v_cat is null or lower(c.name) = lower(v_cat) or lower(pr.subcategory) = lower(v_cat))
       and (v_store is null or lower(s.slug) = v_store)
       and (v_city is null or s.city ilike app.like_term(v_city))
       and (minp is null or o.min_price >= minp)
       and (maxp is null or o.min_price <= maxp)
       and (not instock or o.available > 0)
  ), ranked as (
    select id, row_number() over (
             order by case when v_sort = 'relevance' then rel end desc nulls last,
                      case when v_sort = 'price_asc' then min_price end asc nulls last,
                      case when v_sort = 'price_desc' then min_price end desc nulls last,
                      case when v_sort = 'rating' then rating end desc nulls last,
                      (available > 0) desc, online_since desc, id) ord
      from base
  )
  select jsonb_build_object(
    'total', (select count(*) from base),
    'page', pg, 'page_size', size,
    'items', coalesce((select jsonb_agg(app.product_card(r.id) order by r.ord) from ranked r
                        where r.ord > (pg - 1) * size and r.ord <= pg * size), '[]'::jsonb))
    into res;
  return res;
end $$;

create or replace function public.market_home(p_city text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  return jsonb_build_object(
    'types', coalesce((select jsonb_agg(jsonb_build_object('type', t.category, 'products', t.n) order by t.n desc)
                       from (select b.category, count(*) n from public.products pr
                               join public.stores s on s.business_id = pr.business_id and s.status = 'published'
                               join public.businesses b on b.id = pr.business_id and b.status = 'active'
                              where pr.online_published and pr.status = 'active' and not pr.admin_hidden and pr.variant_of is null
                              group by b.category) t), '[]'::jsonb),
    'stores', coalesce((select jsonb_agg(app.store_card(x.business_id)) from (
                         select s.business_id from public.stores s join public.businesses b on b.id = s.business_id
                          where s.status = 'published' and b.status = 'active'
                            and (p_city is null or s.city ilike app.like_term(p_city))
                          order by (s.verification = 'verified') desc, s.rating_count desc, s.published_at desc limit 12) x), '[]'::jsonb),
    'cities', coalesce((select jsonb_agg(c order by n desc) from (
                         select initcap(btrim(s.city)) c, count(*) n from public.stores s join public.businesses b on b.id = s.business_id
                          where s.status = 'published' and b.status = 'active' and coalesce(btrim(s.city), '') <> ''
                          group by initcap(btrim(s.city)) limit 20) x), '[]'::jsonb),
    'latest', (public.market_search(jsonb_build_object('sort', 'newest', 'page_size', 12, 'city', p_city)) -> 'items'));
end $$;

create or replace function public.market_store(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.stores; b public.businesses; cfg jsonb := app.market_config(); custom boolean;
begin
  select * into s from public.stores where lower(slug) = lower(btrim(p_slug));
  if not found then return null; end if;
  select * into b from public.businesses where id = s.business_id;
  if s.status <> 'published' or b.status <> 'active' then
    return jsonb_build_object('slug', s.slug, 'name', s.name, 'unavailable', true);
  end if;
  custom := app.has_feature(s.business_id, 'store_customization');
  return jsonb_build_object(
    'business_id', s.business_id, 'slug', s.slug, 'name', s.name, 'tagline', s.tagline, 'description', s.description,
    'logo_path', s.logo_path, 'cover_path', case when custom then s.cover_path end,
    'brand_color', case when custom then s.brand_color end,
    'business_type', b.category, 'city', s.city, 'region', s.region,
    'address', case when s.show_address then s.address end,
    'phone', case when s.show_phone then s.phone end,
    'whatsapp', case when s.show_whatsapp then s.whatsapp end,
    'email', case when s.show_email then s.email end,
    'facebook_url', s.facebook_url, 'instagram_url', s.instagram_url, 'tiktok_url', s.tiktok_url,
    'opening_hours', s.opening_hours, 'hours_note', s.hours_note, 'delivery_note', s.delivery_note,
    'pickup_enabled', s.pickup_enabled, 'pickup_note', s.pickup_note, 'cod_enabled', s.cod_enabled,
    'online_payment_enabled', s.online_payment_enabled and coalesce((cfg ->> 'online_payments_enabled')::boolean, false),
    'min_order_amount', s.min_order_amount, 'currency', b.currency,
    'verified', s.verification = 'verified', 'rating_avg', s.rating_avg, 'rating_count', s.rating_count,
    'joined', s.published_at,
    'zones', coalesce((select jsonb_agg(jsonb_build_object('id', z.id, 'name', z.name, 'fee', z.fee, 'eta', z.eta) order by z.sort, z.name)
                       from public.store_delivery_zones z where z.business_id = s.business_id and z.active), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'products', t.n) order by t.sort, t.name) from (
                     select c.name, min(c.sort_order) sort, count(*) n from public.products pr join public.categories c on c.id = pr.category_id
                      where pr.business_id = s.business_id and pr.online_published and pr.status = 'active' and not pr.admin_hidden
                        and pr.variant_of is null group by c.name) t), '[]'::jsonb),
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('rating', r.rating, 'comment', r.comment, 'author', r.author_name,
                     'product', pr.name, 'reply', r.seller_reply, 'created_at', r.created_at) order by r.created_at desc)
                   from (select * from public.market_reviews where business_id = s.business_id and status = 'visible'
                          order by created_at desc limit 10) r join public.products pr on pr.id = r.product_id), '[]'::jsonb));
end $$;

create or replace function public.market_product(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare pr public.products; lid uuid;
begin
  lid := app.listing_of(p_id);
  if lid is null then return null; end if;
  select * into pr from public.products where id = lid;
  return app.product_card(lid) || jsonb_build_object(
    'description', pr.description, 'images', to_jsonb(pr.online_images), 'attributes', pr.attributes,
    'business_type', (select category from public.businesses where id = pr.business_id),
    'store_id', pr.business_id,
    'options', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label, 'price', o.price,
                          'compare_at_price', case when o.compare_at > o.price then o.compare_at end,
                          'available', least(o.available, 99), 'attributes', o.attributes, 'allow_fraction', o.allow_fraction)
                          order by o.label nulls first) from app.listing_options(lid) o), '[]'::jsonb),
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('rating', r.rating, 'comment', r.comment, 'author', r.author_name,
                          'reply', r.seller_reply, 'created_at', r.created_at) order by r.created_at desc)
                         from (select * from public.market_reviews where listing_id = lid and status = 'visible'
                                order by created_at desc limit 20) r), '[]'::jsonb),
    'related', coalesce((select jsonb_agg(app.product_card(x.id)) from (
                          select p2.id from public.products p2 where p2.business_id = pr.business_id and p2.id <> lid
                             and p2.online_published and p2.status = 'active' and not p2.admin_hidden and p2.variant_of is null
                           order by (p2.category_id is not distinct from pr.category_id) desc, p2.online_since desc limit 8) x), '[]'::jsonb));
end $$;

create or replace function public.market_products_by_ids(p_ids uuid[]) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(app.product_card(x)), '[]'::jsonb)
    from (select distinct app.listing_of(i) x from unnest(p_ids[1:100]) i) t where x is not null
$$;

create or replace function public.market_store_cards(p_ids uuid[]) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(app.store_card(i)), '[]'::jsonb) from unnest(p_ids[1:100]) i where app.store_is_live(i)
$$;

-- ---------------------------------------------------------------------------
-- Checkout
-- ---------------------------------------------------------------------------
-- Prices a cart for one seller. Returns lines, totals and a list of problems (empty when the cart can
-- be ordered). p: {items: [{product_id, quantity}], delivery_method, zone_id, promo_code}
create or replace function app.market_price(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  it jsonb; pr public.products; lst public.products; s public.stores; bid uuid; lid uuid;
  qty numeric; avail numeric; price numeric; lines jsonb := '[]'::jsonb; errs jsonb := '[]'::jsonb;
  sub numeric := 0; disc numeric := 0; fee numeric := 0; z public.store_delivery_zones; pm public.market_promotions;
  method text := coalesce(nullif(p ->> 'delivery_method', ''), 'delivery'); v_code text; n int := 0;
  merged jsonb;
begin
  if jsonb_typeof(p -> 'items') <> 'array' or jsonb_array_length(p -> 'items') = 0 then
    return jsonb_build_object('errors', jsonb_build_array(jsonb_build_object('code', 'cart_empty')));
  end if;
  if jsonb_array_length(p -> 'items') > 50 then perform app.raise('too_many_items'); end if;
  -- Merge repeated products.
  select jsonb_agg(jsonb_build_object('product_id', pid, 'quantity', q)) into merged from (
    select (x ->> 'product_id')::uuid pid, sum(coalesce((x ->> 'quantity')::numeric, 0)) q
      from jsonb_array_elements(p -> 'items') x group by 1 order by 1) t;

  for it in select * from jsonb_array_elements(merged) loop
    n := n + 1;
    select * into pr from public.products where id = (it ->> 'product_id')::uuid;
    lid := app.listing_of(pr.id);
    if pr.id is null or lid is null then
      errs := errs || jsonb_build_object('code', 'product_unavailable', 'product_id', it ->> 'product_id');
      continue;
    end if;
    if bid is null then bid := pr.business_id;
    elsif bid <> pr.business_id then perform app.raise('one_seller_per_order'); end if;
    if exists (select 1 from public.products c where c.variant_of = pr.id and c.status = 'active' and not c.admin_hidden) then
      errs := errs || jsonb_build_object('code', 'choose_option', 'product_id', pr.id, 'name', pr.name);
      continue;
    end if;
    select * into lst from public.products where id = lid;
    qty := (it ->> 'quantity')::numeric;
    if qty is null or qty <= 0 or qty > 999 or (not pr.allow_fraction and qty <> trunc(qty)) then
      errs := errs || jsonb_build_object('code', 'invalid_quantity', 'product_id', pr.id, 'name', pr.name);
      continue;
    end if;
    avail := greatest(pr.qty_on_hand - app.reserved_qty(pr.id), 0);
    if qty > avail then
      errs := errs || jsonb_build_object('code', 'insufficient_stock', 'product_id', pr.id, 'name', pr.name,
                                         'available', avail);
    end if;
    price := pr.selling_price;
    lines := lines || jsonb_build_object('product_id', pr.id, 'listing_id', lid, 'name', lst.name,
      'variant_label', case when pr.id <> lid then coalesce(pr.variant_label, pr.name) end, 'sku', pr.sku,
      'image_path', coalesce(pr.online_images[1], lst.online_images[1]), 'unit_price', price, 'quantity', qty,
      'unit', pr.base_unit, 'available', avail, 'line_total', app.money(pr.business_id, qty * price), 'sort', n);
    sub := sub + app.money(pr.business_id, qty * price);
  end loop;

  if bid is null then
    return jsonb_build_object('lines', lines, 'errors', errs);
  end if;
  select * into s from public.stores where business_id = bid;

  if method = 'pickup' then
    if not s.pickup_enabled then errs := errs || jsonb_build_object('code', 'pickup_not_available'); end if;
  elsif method = 'delivery' then
    if nullif(p ->> 'zone_id', '') is null then
      if exists (select 1 from public.store_delivery_zones where business_id = bid and active) then
        errs := errs || jsonb_build_object('code', 'zone_required');
      else
        errs := errs || jsonb_build_object('code', 'delivery_not_available');
      end if;
    else
      select * into z from public.store_delivery_zones where id = (p ->> 'zone_id')::uuid and business_id = bid and active;
      if not found then errs := errs || jsonb_build_object('code', 'zone_required');
      else fee := z.fee; end if;
    end if;
  else
    errs := errs || jsonb_build_object('code', 'invalid_delivery_method');
  end if;

  v_code := upper(nullif(btrim(coalesce(p ->> 'promo_code', '')), ''));
  if v_code is not null then
    select * into pm from public.market_promotions
     where business_id = bid and code = v_code and active
       and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now())
       and (max_uses is null or used_count < max_uses);
    if not found or not app.has_feature(bid, 'promotions') then
      errs := errs || jsonb_build_object('code', 'promo_invalid');
    elsif sub < pm.min_order then
      errs := errs || jsonb_build_object('code', 'promo_min_order', 'min_order', pm.min_order);
    else
      disc := case when pm.kind = 'percent' then app.money(bid, sub * pm.value / 100) else least(pm.value, sub) end;
    end if;
  end if;

  if sub < s.min_order_amount then
    errs := errs || jsonb_build_object('code', 'below_minimum_order', 'min_order', s.min_order_amount);
  end if;

  return jsonb_build_object('business_id', bid, 'store', app.store_card(bid), 'lines', lines,
    'subtotal', sub, 'discount', disc, 'delivery_fee', fee, 'total', sub - disc + fee,
    'promo_id', pm.id, 'promo_code', pm.code, 'zone_name', z.name, 'delivery_eta', z.eta,
    'delivery_method', method, 'errors', errs);
end $$;

create or replace function public.market_quote(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  return app.market_price(p);
end $$;

-- Cancels an order: releases reserved stock, returns the promo use and records who cancelled it.
create or replace function app.market_cancel(p_order uuid, p_actor text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.market_orders;
begin
  select * into o from public.market_orders where id = p_order for update;
  if o.status not in ('pending', 'confirmed', 'processing', 'dispatched') then perform app.raise('order_not_cancellable'); end if;
  update public.stock_reservations set released_at = now()
   where order_id = o.id and released_at is null and consumed_at is null;
  if o.promo_id is not null then
    update public.market_promotions set used_count = greatest(used_count - 1, 0) where id = o.promo_id;
  end if;
  update public.market_orders set status = 'cancelled', cancelled_at = now(), cancelled_by = p_actor,
         cancel_reason = p_reason, expires_at = null,
         payment_status = case when payment_status = 'paid' then 'refund_pending'
                               when payment_status in ('awaiting_payment', 'failed', 'cod_pending') then 'void'
                               else payment_status end,
         flagged = flagged or payment_status = 'paid',
         flag_reason = case when payment_status = 'paid' then 'refund_after_cancellation' else flag_reason end
   where id = o.id;
  insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
  values (o.id, o.business_id, 'status', 'cancelled', p_reason, p_actor, auth.uid());
  if p_actor <> 'seller' and not (o.payment_method = 'online' and o.payment_status <> 'paid') then
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (o.business_id, 'market_order_cancelled', 'warning',
            jsonb_build_object('number', o.number, 'reason', p_reason), '/app/orders/' || o.id, 'orders.manage');
  end if;
end $$;

-- Releases stock held by unpaid online orders and by cash-on-delivery orders the seller never confirmed.
create or replace function app.market_expire() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select id, payment_method from public.market_orders
            where status = 'pending' and expires_at < now()
              and payment_status in ('awaiting_payment', 'failed', 'cod_pending')
            order by expires_at limit 50 for update skip locked loop
    perform app.market_cancel(r.id, 'system',
      case when r.payment_method = 'online' then 'payment_not_completed' else 'not_confirmed_in_time' end);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Places an order. p: {client_ref, access_token (guests; kept by the browser, stored hashed),
--   items, delivery_method, zone_id, promo_code, payment_method: cod|online,
--   customer: {name, phone, email}, address: {city, area, line, landmark}, notes, save_address}
create or replace function public.market_place_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); cfg jsonb := app.market_config(); q jsonb; e jsonb; s public.stores; b public.businesses;
  cref uuid := nullif(p ->> 'client_ref', '')::uuid; tok text := nullif(p ->> 'access_token', '');
  existing public.market_orders; oid uuid; num text; cname text; cphone text; cemail text; addr jsonb;
  pay text := p ->> 'payment_method'; cid uuid; l jsonb; exp timestamptz; comm numeric; fee numeric;
begin
  if cref is null then perform app.raise('invalid_request'); end if;
  if uid is null and (tok is null or length(tok) < 32 or length(tok) > 128) then perform app.raise('invalid_request'); end if;
  select * into existing from public.market_orders where client_ref = cref;
  if found then
    if existing.customer_user_id is distinct from uid and existing.access_token_hash is distinct from app.sha256(coalesce(tok, '')) then
      perform app.raise('invalid_request');
    end if;
    return jsonb_build_object('order_id', existing.id, 'number', existing.number, 'total', existing.total,
      'payment_method', existing.payment_method, 'payment_status', existing.payment_status, 'duplicate', true);
  end if;
  if not coalesce((cfg ->> 'enabled')::boolean, true) then perform app.raise('marketplace_closed'); end if;
  -- Mobile networks share IP addresses between many customers: the IP limit is generous, the
  -- per-phone limit (below) is what stops repeated fake orders.
  perform app.rate_limit('order_ip:' || app.client_ip(), 120, 3600);
  if uid is not null then perform app.rate_limit('order_user:' || uid, 20, 3600); end if;
  perform app.market_expire();

  cname := btrim(coalesce(p #>> '{customer,name}', ''));
  cphone := app.norm_phone(p #>> '{customer,phone}');
  cemail := nullif(lower(btrim(coalesce(p #>> '{customer,email}', ''))), '');
  if length(cname) < 2 or length(cname) > 80 then perform app.raise('customer_name_required'); end if;
  if cphone is null then perform app.raise('invalid_phone'); end if;
  perform app.rate_limit('order_phone:' || cphone, 10, 3600);
  if cemail is not null and not app.valid_email(cemail) then perform app.raise('invalid_email'); end if;
  if exists (select 1 from public.market_blocklist where (kind = 'phone' and value = cphone)
             or (kind = 'email' and value = cemail) or (kind = 'user' and value = uid::text)) then
    perform app.raise('checkout_blocked');
  end if;
  if pay not in ('cod', 'online') then perform app.raise('invalid_payment_method'); end if;

  -- Lock the products, then price the cart again under the lock.
  perform 1 from public.products where id in (select (x ->> 'product_id')::uuid from jsonb_array_elements(p -> 'items') x)
   order by id for update;
  q := app.market_price(p);
  if uid is not null and nullif(q ->> 'business_id', '') is not null and app.is_member((q ->> 'business_id')::uuid) then
    perform app.raise('cannot_order_from_own_store');
  end if;
  if jsonb_array_length(q -> 'errors') > 0 then
    perform app.raise('checkout_invalid', jsonb_build_object('errors', q -> 'errors'));
  end if;
  select * into s from public.stores where business_id = (q ->> 'business_id')::uuid;
  select * into b from public.businesses where id = s.business_id;

  if pay = 'cod' then
    if not s.cod_enabled then perform app.raise('payment_method_not_available'); end if;
    if (select count(*) from public.market_orders where business_id = s.business_id and customer_phone = cphone
         and payment_method = 'cod' and status in ('pending', 'confirmed', 'processing', 'dispatched'))
       >= coalesce((cfg ->> 'max_open_cod_per_phone')::int, 3) then
      perform app.raise('too_many_open_orders');
    end if;
  else
    if not (s.online_payment_enabled and coalesce((cfg ->> 'online_payments_enabled')::boolean, false)) then
      perform app.raise('payment_method_not_available');
    end if;
    if (q ->> 'total')::numeric < 100 then perform app.raise('online_minimum_amount', jsonb_build_object('min', 100)); end if;
  end if;

  if q ->> 'delivery_method' = 'delivery' then
    addr := jsonb_build_object('city', btrim(coalesce(p #>> '{address,city}', '')), 'area', nullif(btrim(coalesce(p #>> '{address,area}', '')), ''),
      'line', nullif(btrim(coalesce(p #>> '{address,line}', '')), ''), 'landmark', nullif(btrim(coalesce(p #>> '{address,landmark}', '')), ''));
    if length(addr ->> 'city') < 2 or coalesce(addr ->> 'line', addr ->> 'area', '') = '' then perform app.raise('address_required'); end if;
    if length(addr::text) > 800 then perform app.raise('invalid_request'); end if;
  end if;

  exp := now() + case when pay = 'online' then make_interval(mins => coalesce((cfg ->> 'unpaid_order_minutes')::int, 30))
                      else make_interval(hours => coalesce((cfg ->> 'confirm_hours')::int, 48)) end;
  comm := coalesce((cfg ->> 'commission_pct')::numeric, 0);
  fee := case when pay = 'online' then coalesce((cfg ->> 'online_fee_pct')::numeric, 0) else 0 end;

  -- The seller's customer record (matched by phone) so online buyers appear under Customers.
  select id into cid from public.customers where business_id = s.business_id and phone = cphone and status = 'active' limit 1;
  if cid is null then
    insert into public.customers (business_id, name, phone, email, address, source, user_id, created_by)
    values (s.business_id, cname, cphone, cemail, nullif(concat_ws(', ', addr ->> 'line', addr ->> 'area', addr ->> 'city'), ''),
            'online', uid, uid)
    returning id into cid;
  else
    update public.customers set email = coalesce(email, cemail), user_id = coalesce(user_id, uid) where id = cid;
  end if;

  num := app.next_number(s.business_id, 'order', 'ORD-');
  insert into public.market_orders (business_id, number, client_ref, customer_user_id, access_token_hash, customer_id,
    customer_name, customer_phone, customer_email, delivery_method, zone_id, zone_name, delivery_eta, address, notes,
    subtotal, discount, delivery_fee, total, currency, promo_id, promo_code, payment_method, payment_status,
    commission_pct, commission_amount, online_fee_pct, online_fee_amount, expires_at)
  values (s.business_id, num, cref, uid, case when tok is not null then app.sha256(tok) end, cid,
    cname, cphone, cemail, q ->> 'delivery_method', nullif(p ->> 'zone_id', '')::uuid, q ->> 'zone_name', q ->> 'delivery_eta',
    addr, nullif(left(btrim(coalesce(p ->> 'notes', '')), 500), ''),
    (q ->> 'subtotal')::numeric, (q ->> 'discount')::numeric, (q ->> 'delivery_fee')::numeric, (q ->> 'total')::numeric,
    b.currency, nullif(q ->> 'promo_id', '')::uuid, q ->> 'promo_code', pay,
    case when pay = 'online' then 'awaiting_payment' else 'cod_pending' end,
    comm, app.money(s.business_id, ((q ->> 'subtotal')::numeric - (q ->> 'discount')::numeric) * comm / 100),
    fee, app.money(s.business_id, (q ->> 'total')::numeric * fee / 100), exp)
  returning id into oid;

  for l in select * from jsonb_array_elements(q -> 'lines') loop
    insert into public.market_order_lines (order_id, business_id, product_id, listing_id, name, variant_label, sku, image_path,
      unit_price, quantity, line_total, sort)
    values (oid, s.business_id, (l ->> 'product_id')::uuid, (l ->> 'listing_id')::uuid, l ->> 'name', l ->> 'variant_label',
      l ->> 'sku', l ->> 'image_path', (l ->> 'unit_price')::numeric, (l ->> 'quantity')::numeric,
      (l ->> 'line_total')::numeric, (l ->> 'sort')::int);
    insert into public.stock_reservations (business_id, product_id, order_id, quantity, expires_at)
    values (s.business_id, (l ->> 'product_id')::uuid, oid, (l ->> 'quantity')::numeric, exp);
  end loop;
  if nullif(q ->> 'promo_id', '') is not null then
    update public.market_promotions set used_count = used_count + 1 where id = (q ->> 'promo_id')::uuid;
  end if;

  insert into public.market_order_events (order_id, business_id, kind, status, actor, actor_user)
  values (oid, s.business_id, 'status', 'pending', 'customer', uid);
  if pay = 'cod' then
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (s.business_id, 'market_order_new', 'info',
            jsonb_build_object('number', num, 'amount', (q ->> 'total')::numeric, 'customer', cname), '/app/orders/' || oid, 'orders.manage');
  end if;

  if uid is not null and coalesce((p ->> 'save_address')::boolean, false) and addr is not null
     and (select count(*) from public.customer_addresses where user_id = uid) < 10
     and not exists (select 1 from public.customer_addresses where user_id = uid and lower(city) = lower(addr ->> 'city')
                     and coalesce(lower(line), '') = coalesce(lower(addr ->> 'line'), '')) then
    insert into public.customer_addresses (user_id, recipient_name, phone, city, area, line, landmark, is_default)
    values (uid, cname, cphone, addr ->> 'city', addr ->> 'area', addr ->> 'line', addr ->> 'landmark',
            not exists (select 1 from public.customer_addresses where user_id = uid));
  end if;

  return jsonb_build_object('order_id', oid, 'number', num, 'total', (q ->> 'total')::numeric,
    'payment_method', pay, 'payment_status', case when pay = 'online' then 'awaiting_payment' else 'cod_pending' end,
    'duplicate', false);
end $$;

-- ---------------------------------------------------------------------------
-- Customer side: tracking, cancelling, messages, reviews, reports
-- ---------------------------------------------------------------------------
create or replace function app.order_for_customer(p_order uuid, p_token text, p_lock boolean default false)
returns public.market_orders language plpgsql security definer set search_path = public as $$
declare o public.market_orders;
begin
  if p_lock then select * into o from public.market_orders where id = p_order for update;
  else select * into o from public.market_orders where id = p_order; end if;
  if not found or not ((auth.uid() is not null and o.customer_user_id = auth.uid())
                       or (coalesce(p_token, '') <> '' and o.access_token_hash = app.sha256(p_token))) then
    perform app.raise('not_found');
  end if;
  return o;
end $$;

create or replace function public.market_order_view(p_order uuid, p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.market_orders; s public.stores;
begin
  perform app.market_expire();
  o := app.order_for_customer(p_order, p_token);
  select * into s from public.stores where business_id = o.business_id;
  return jsonb_build_object(
    'id', o.id, 'number', o.number, 'status', o.status, 'payment_method', o.payment_method, 'payment_status', o.payment_status,
    'created_at', o.created_at, 'confirmed_at', o.confirmed_at, 'dispatched_at', o.dispatched_at, 'delivered_at', o.delivered_at,
    'cancelled_at', o.cancelled_at, 'cancel_reason', o.cancel_reason, 'cancelled_by', o.cancelled_by,
    'expires_at', case when o.status = 'pending' and o.payment_method = 'online' then o.expires_at end,
    'customer_name', o.customer_name, 'customer_phone', o.customer_phone, 'customer_email', o.customer_email,
    'delivery_method', o.delivery_method, 'zone_name', o.zone_name, 'delivery_eta', o.delivery_eta, 'address', o.address,
    'notes', o.notes, 'subtotal', o.subtotal, 'discount', o.discount, 'delivery_fee', o.delivery_fee, 'total', o.total,
    'currency', o.currency, 'promo_code', o.promo_code, 'refund_amount', o.refund_amount, 'refunded_at', o.refunded_at,
    'store', jsonb_build_object('slug', s.slug, 'name', s.name, 'logo_path', s.logo_path, 'city', s.city,
       'phone', case when s.show_phone then s.phone end, 'whatsapp', case when s.show_whatsapp then s.whatsapp end,
       'email', case when s.show_email then s.email end,
       'address', case when o.delivery_method = 'pickup' or s.show_address then s.address end,
       'pickup_note', case when o.delivery_method = 'pickup' then s.pickup_note end),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('product_id', l.product_id, 'listing_id', l.listing_id, 'name', l.name,
       'variant_label', l.variant_label, 'image_path', l.image_path, 'unit_price', l.unit_price, 'quantity', l.quantity,
       'line_total', l.line_total,
       'reviewed', exists (select 1 from public.market_reviews r where r.order_id = o.id and r.product_id = l.product_id))
       order by l.sort) from public.market_order_lines l where l.order_id = o.id), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'status', e.status, 'message', e.message,
       'actor', e.actor, 'created_at', e.created_at) order by e.created_at, e.id)
       from public.market_order_events e where e.order_id = o.id and e.visible_to_customer), '[]'::jsonb),
    'can_cancel', o.status = 'pending',
    'can_pay', o.payment_method = 'online' and o.status = 'pending' and o.payment_status in ('awaiting_payment', 'failed'),
    'can_review', o.status = 'delivered',
    'signed_in_owner', auth.uid() is not null and o.customer_user_id = auth.uid());
end $$;

create or replace function public.market_my_orders(p_limit int default 30, p_offset int default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  perform app.market_expire();
  return coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'number', o.number, 'status', o.status,
      'payment_method', o.payment_method, 'payment_status', o.payment_status, 'total', o.total, 'created_at', o.created_at,
      'store', jsonb_build_object('slug', s.slug, 'name', s.name, 'logo_path', s.logo_path),
      'items', (select count(*) from public.market_order_lines l where l.order_id = o.id),
      'first_image', (select l.image_path from public.market_order_lines l where l.order_id = o.id order by l.sort limit 1))
      order by o.created_at desc)
    from (select * from public.market_orders where customer_user_id = uid order by created_at desc
           limit least(p_limit, 100) offset greatest(p_offset, 0)) o
    join public.stores s on s.business_id = o.business_id), '[]'::jsonb);
end $$;

-- Lets a signed-in customer keep guest orders placed on this device under their account.
create or replace function public.market_claim_orders(p_orders jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); x jsonb; n int := 0;
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  if jsonb_typeof(p_orders) <> 'array' or jsonb_array_length(p_orders) > 50 then perform app.raise('invalid_request'); end if;
  for x in select * from jsonb_array_elements(p_orders) loop
    update public.market_orders set customer_user_id = uid
     where id = (x ->> 'id')::uuid and customer_user_id is null and access_token_hash = app.sha256(coalesce(x ->> 'token', ''));
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;

create or replace function public.market_order_customer_action(p_order uuid, p_token text, p_action text, p_text text default null)
returns void language plpgsql security definer set search_path = public as $$
declare o public.market_orders; msg text := nullif(left(btrim(coalesce(p_text, '')), 1000), '');
begin
  o := app.order_for_customer(p_order, p_token, true);
  perform app.rate_limit('order_msg:' || o.id, 30, 3600);
  if p_action = 'cancel' then
    if o.status <> 'pending' then perform app.raise('order_not_cancellable'); end if;
    perform app.market_cancel(o.id, 'customer', coalesce(msg, 'cancelled_by_customer'));
  elsif p_action = 'message' then
    if msg is null then perform app.raise('message_required'); end if;
    insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user)
    values (o.id, o.business_id, 'message', msg, 'customer', auth.uid());
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (o.business_id, 'market_message', 'info', jsonb_build_object('number', o.number), '/app/orders/' || o.id,
            'orders.manage', 'market_message:' || o.id || ':' || date_trunc('hour', now())) on conflict do nothing;
  else
    perform app.raise('invalid_action');
  end if;
end $$;

create or replace function app.refresh_store_rating(bid uuid) returns void
language sql security definer set search_path = public as $$
  update public.stores set
    rating_avg = coalesce((select round(avg(rating), 2) from public.market_reviews where business_id = bid and status = 'visible'), 0),
    rating_count = (select count(*) from public.market_reviews where business_id = bid and status = 'visible')
  where business_id = bid
$$;

-- Verified-purchase reviews: only for products of a delivered order, once per product.
create or replace function public.market_submit_review(p_order uuid, p_token text, p_product uuid, p_rating int, p_comment text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.market_orders; l public.market_order_lines; rid uuid;
begin
  o := app.order_for_customer(p_order, p_token);
  if o.status <> 'delivered' then perform app.raise('review_requires_delivery'); end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then perform app.raise('invalid_rating'); end if;
  select * into l from public.market_order_lines where order_id = o.id and product_id = p_product limit 1;
  if not found then perform app.raise('not_found'); end if;
  begin
    insert into public.market_reviews (business_id, order_id, product_id, listing_id, user_id, author_name, rating, comment)
    values (o.business_id, o.id, p_product, coalesce(l.listing_id, p_product), auth.uid(),
            split_part(o.customer_name, ' ', 1), p_rating, nullif(left(btrim(coalesce(p_comment, '')), 1000), ''))
    returning id into rid;
  exception when unique_violation then
    perform app.raise('already_reviewed');
  end;
  perform app.refresh_store_rating(o.business_id);
  return rid;
end $$;

-- Reports about a listing, a store or an order (an order report opens a dispute).
create or replace function public.market_report(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare tt text := p ->> 'target_type'; tid uuid := nullif(p ->> 'target_id', '')::uuid; bid uuid; o public.market_orders;
        rid uuid; k text := 'report'; contact text := nullif(left(btrim(coalesce(p ->> 'contact', '')), 120), '');
begin
  perform app.rate_limit('report_ip:' || app.client_ip(), 10, 3600);
  if tt = 'product' then select business_id into bid from public.products where id = app.listing_of(tid);
  elsif tt = 'store' then select business_id into bid from public.stores where business_id = tid;
  elsif tt = 'order' then
    o := app.order_for_customer(tid, p ->> 'token');
    bid := o.business_id; k := 'dispute';
  else perform app.raise('invalid_request'); end if;
  if bid is null then perform app.raise('not_found'); end if;
  if auth.uid() is null and contact is null and tt <> 'order' then perform app.raise('contact_required'); end if;
  insert into public.market_reports (kind, target_type, target_id, business_id, order_id, reason, details, reporter_user_id, reporter_contact)
  values (k, tt, tid, bid, o.id, p ->> 'reason', nullif(left(btrim(coalesce(p ->> 'details', '')), 2000), ''), auth.uid(), contact)
  returning id into rid;
  if k = 'dispute' then
    insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user)
    values (o.id, o.business_id, 'dispute', p ->> 'reason', 'customer', auth.uid());
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (o.business_id, 'market_dispute', 'critical', jsonb_build_object('number', o.number, 'reason', p ->> 'reason'),
            '/app/orders/' || o.id, 'orders.manage');
  end if;
  return rid;
end $$;

-- ---------------------------------------------------------------------------
-- Seller side: store, delivery zones, listings, promotions
-- ---------------------------------------------------------------------------
create or replace function app.reserved_slug(s text) returns boolean language sql immutable as $$
  select lower(s) = any (array['admin', 'app', 'api', 'market', 'marketplace', 's', 'login', 'signup', 'account', 'cart',
    'checkout', 'order', 'orders', 'help', 'support', 'bizpilot', 'store', 'stores', 'pay', 'auth', 'www', 'shop'])
$$;

create or replace function public.store_slug_available(p_slug text, p_business uuid default null) returns boolean
language sql stable security definer set search_path = public as $$
  select lower(btrim(p_slug)) ~ '^[a-z0-9]([a-z0-9-]{1,38})[a-z0-9]$' and not app.reserved_slug(btrim(p_slug))
     and not exists (select 1 from public.stores where lower(slug) = lower(btrim(p_slug))
                     and (p_business is null or business_id <> p_business))
$$;

-- Creates or updates the store profile. Only keys present in p are changed.
create or replace function public.store_save(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.stores; b public.businesses; v_slug text; custom boolean;
begin
  perform app.require_perm(p_business, 'store.manage');
  select * into b from public.businesses where id = p_business;
  select * into s from public.stores where business_id = p_business for update;
  custom := app.has_feature(p_business, 'store_customization');
  if p ? 'slug' or s.business_id is null then
    v_slug := lower(btrim(coalesce(p ->> 'slug', '')));
    if v_slug = '' then
      v_slug := trim(both '-' from left(regexp_replace(lower(b.name), '[^a-z0-9]+', '-', 'g'), 36));
      if length(v_slug) < 3 then v_slug := 'store-' || left(replace(p_business::text, '-', ''), 6); end if;
      while not public.store_slug_available(v_slug, p_business) loop
        v_slug := left(v_slug, 33) || '-' || substr(md5(random()::text), 1, 4);
      end loop;
    end if;
    if not public.store_slug_available(v_slug, p_business) then perform app.raise('slug_unavailable'); end if;
  end if;
  if (p ? 'cover_path' and nullif(p ->> 'cover_path', '') is not null or p ? 'brand_color' and nullif(p ->> 'brand_color', '') is not null)
     and not custom then
    perform app.raise('feature_not_in_plan', jsonb_build_object('feature', 'store_customization'));
  end if;
  if p ? 'name' and length(btrim(coalesce(p ->> 'name', ''))) < 2 then perform app.raise('store_name_required'); end if;
  if p ? 'phone' and nullif(p ->> 'phone', '') is not null and app.norm_phone(p ->> 'phone') is null then perform app.raise('invalid_phone'); end if;
  if p ? 'whatsapp' and nullif(p ->> 'whatsapp', '') is not null and app.norm_phone(p ->> 'whatsapp') is null then perform app.raise('invalid_phone'); end if;
  if p ? 'email' and nullif(p ->> 'email', '') is not null and not app.valid_email(p ->> 'email') then perform app.raise('invalid_email'); end if;
  if (p ? 'logo_path' and split_part(coalesce(p ->> 'logo_path', p_business::text), '/', 1) <> p_business::text)
     or (p ? 'cover_path' and split_part(coalesce(p ->> 'cover_path', p_business::text), '/', 1) <> p_business::text) then
    perform app.raise('invalid_image');
  end if;
  if p ? 'online_payment_enabled' and (p ->> 'online_payment_enabled')::boolean
     and not coalesce((app.market_config() ->> 'online_payments_enabled')::boolean, false) then
    perform app.raise('online_payments_not_available');
  end if;
  if s.business_id is null then
    insert into public.stores (business_id, slug, name, city, phone, whatsapp, email, address)
    values (p_business, v_slug, coalesce(nullif(btrim(p ->> 'name'), ''), b.name), coalesce(nullif(p ->> 'city', ''), b.city),
            app.norm_phone(coalesce(nullif(p ->> 'phone', ''), b.phone)), app.norm_phone(coalesce(nullif(p ->> 'whatsapp', ''), b.phone)),
            coalesce(nullif(p ->> 'email', ''), b.email), coalesce(nullif(p ->> 'address', ''), b.address))
    returning * into s;
    perform app.audit(p_business, 'store.created', 'store', p_business::text, jsonb_build_object('slug', v_slug));
  end if;
  update public.stores set
    slug = coalesce(v_slug, slug),
    name = case when p ? 'name' then btrim(p ->> 'name') else name end,
    tagline = case when p ? 'tagline' then nullif(btrim(p ->> 'tagline'), '') else tagline end,
    description = case when p ? 'description' then nullif(btrim(p ->> 'description'), '') else description end,
    logo_path = case when p ? 'logo_path' then nullif(p ->> 'logo_path', '') else logo_path end,
    cover_path = case when p ? 'cover_path' then nullif(p ->> 'cover_path', '') else cover_path end,
    brand_color = case when p ? 'brand_color' then nullif(p ->> 'brand_color', '') else brand_color end,
    city = case when p ? 'city' then nullif(btrim(p ->> 'city'), '') else city end,
    region = case when p ? 'region' then nullif(btrim(p ->> 'region'), '') else region end,
    address = case when p ? 'address' then nullif(btrim(p ->> 'address'), '') else address end,
    phone = case when p ? 'phone' then app.norm_phone(p ->> 'phone') else phone end,
    whatsapp = case when p ? 'whatsapp' then app.norm_phone(p ->> 'whatsapp') else whatsapp end,
    email = case when p ? 'email' then nullif(lower(btrim(p ->> 'email')), '') else email end,
    show_phone = coalesce((p ->> 'show_phone')::boolean, show_phone),
    show_whatsapp = coalesce((p ->> 'show_whatsapp')::boolean, show_whatsapp),
    show_email = coalesce((p ->> 'show_email')::boolean, show_email),
    show_address = coalesce((p ->> 'show_address')::boolean, show_address),
    facebook_url = case when p ? 'facebook_url' then nullif(btrim(p ->> 'facebook_url'), '') else facebook_url end,
    instagram_url = case when p ? 'instagram_url' then nullif(btrim(p ->> 'instagram_url'), '') else instagram_url end,
    tiktok_url = case when p ? 'tiktok_url' then nullif(btrim(p ->> 'tiktok_url'), '') else tiktok_url end,
    opening_hours = case when jsonb_typeof(p -> 'opening_hours') = 'object' and length((p -> 'opening_hours')::text) < 2000
                         then p -> 'opening_hours' else opening_hours end,
    hours_note = case when p ? 'hours_note' then nullif(btrim(p ->> 'hours_note'), '') else hours_note end,
    delivery_note = case when p ? 'delivery_note' then nullif(btrim(p ->> 'delivery_note'), '') else delivery_note end,
    pickup_enabled = coalesce((p ->> 'pickup_enabled')::boolean, pickup_enabled),
    pickup_note = case when p ? 'pickup_note' then nullif(btrim(p ->> 'pickup_note'), '') else pickup_note end,
    cod_enabled = coalesce((p ->> 'cod_enabled')::boolean, cod_enabled),
    online_payment_enabled = coalesce((p ->> 'online_payment_enabled')::boolean, online_payment_enabled),
    min_order_amount = coalesce(nullif(p ->> 'min_order_amount', '')::numeric, min_order_amount)
  where business_id = p_business returning * into s;
  if s.status = 'published' and not (s.cod_enabled or s.online_payment_enabled) then
    perform app.raise('payment_method_required');
  end if;
  perform app.audit(p_business, 'store.updated', 'store', p_business::text, p - 'description' - 'opening_hours');
  return to_jsonb(s);
end $$;

create or replace function public.store_save_zones(p_business uuid, p_zones jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare z jsonb; keep uuid[] := '{}'; zid uuid; n int := 0;
begin
  perform app.require_perm(p_business, 'store.manage');
  if jsonb_typeof(p_zones) <> 'array' or jsonb_array_length(p_zones) > 40 then perform app.raise('invalid_request'); end if;
  for z in select * from jsonb_array_elements(p_zones) loop
    n := n + 1;
    if coalesce(btrim(z ->> 'name'), '') = '' then perform app.raise('zone_name_required'); end if;
    if coalesce((z ->> 'fee')::numeric, 0) < 0 then perform app.raise('invalid_amount'); end if;
    zid := nullif(z ->> 'id', '')::uuid;
    if zid is not null and exists (select 1 from public.store_delivery_zones where id = zid and business_id = p_business) then
      update public.store_delivery_zones set name = btrim(z ->> 'name'), fee = app.money(p_business, coalesce((z ->> 'fee')::numeric, 0)),
             eta = nullif(btrim(coalesce(z ->> 'eta', '')), ''), active = coalesce((z ->> 'active')::boolean, true), sort = n
       where id = zid;
    else
      insert into public.store_delivery_zones (business_id, name, fee, eta, active, sort)
      values (p_business, btrim(z ->> 'name'), app.money(p_business, coalesce((z ->> 'fee')::numeric, 0)),
              nullif(btrim(coalesce(z ->> 'eta', '')), ''), coalesce((z ->> 'active')::boolean, true), n)
      returning id into zid;
    end if;
    keep := keep || zid;
  end loop;
  delete from public.store_delivery_zones where business_id = p_business and not (id = any (keep));
  perform app.audit(p_business, 'store.zones_updated', 'store', p_business::text, jsonb_build_object('zones', n));
  return n;
end $$;

-- What a store still needs before it can be published.
create or replace function public.store_readiness(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.stores; listed int; zones int;
begin
  if not app.can_read(p_business) then perform app.raise('permission_denied'); end if;
  select * into s from public.stores where business_id = p_business;
  select count(*) into listed from public.products where business_id = p_business and online_published and status = 'active' and variant_of is null;
  select count(*) into zones from public.store_delivery_zones where business_id = p_business and active;
  return jsonb_build_object(
    'store_created', s.business_id is not null,
    'profile', coalesce(s.business_id is not null and s.name is not null and (s.phone is not null or s.whatsapp is not null), false),
    'logo', s.logo_path is not null,
    'products', listed > 0, 'listed', listed,
    'payment', coalesce(s.cod_enabled or s.online_payment_enabled, false),
    'delivery', coalesce(s.pickup_enabled, false) or zones > 0,
    'published', coalesce(s.status = 'published', false), 'status', s.status, 'slug', s.slug,
    'verification', s.verification, 'suspended_reason', s.suspended_reason);
end $$;

create or replace function public.store_set_published(p_business uuid, p_publish boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.stores; r jsonb;
begin
  perform app.require_perm(p_business, 'store.manage');
  select * into s from public.stores where business_id = p_business for update;
  if not found then perform app.raise('store_not_created'); end if;
  if s.status = 'suspended' then perform app.raise('store_suspended', jsonb_build_object('reason', s.suspended_reason)); end if;
  if p_publish then
    r := public.store_readiness(p_business);
    if not ((r ->> 'profile')::boolean and (r ->> 'products')::boolean and (r ->> 'payment')::boolean and (r ->> 'delivery')::boolean) then
      perform app.raise('store_not_ready', r);
    end if;
    update public.stores set status = 'published', published_at = coalesce(published_at, now()) where business_id = p_business;
  else
    update public.stores set status = 'draft' where business_id = p_business;
  end if;
  perform app.audit(p_business, case when p_publish then 'store.published' else 'store.unpublished' end, 'store', p_business::text);
  return public.store_readiness(p_business);
end $$;

create or replace function public.store_request_verification(p_business uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'store.manage');
  update public.stores set verification = 'pending', verification_note = nullif(left(btrim(coalesce(p_note, '')), 500), '')
   where business_id = p_business and verification in ('unverified', 'rejected');
  if not found then perform app.raise('verification_not_available'); end if;
  perform app.audit(p_business, 'store.verification_requested', 'store', p_business::text);
end $$;

-- Publish or unpublish listings in bulk (variants follow their parent product).
create or replace function public.products_set_online(p_business uuid, p_ids uuid[], p_online boolean) returns int
language plpgsql security definer set search_path = public as $$
declare i uuid; n int := 0;
begin
  perform app.require_perm(p_business, 'products.manage');
  if coalesce(array_length(p_ids, 1), 0) > 500 then perform app.raise('invalid_request'); end if;
  foreach i in array p_ids loop
    update public.products set online_published = p_online
     where id = i and business_id = p_business and variant_of is null and status = 'active' and online_published <> p_online;
    if found then n := n + 1; end if;
  end loop;
  perform app.audit(p_business, case when p_online then 'listing.published' else 'listing.unpublished' end, 'product', null,
                    jsonb_build_object('count', n));
  return n;
end $$;

create or replace function public.promo_save(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare pid uuid := nullif(p ->> 'id', '')::uuid; v_code text := upper(btrim(coalesce(p ->> 'code', '')));
begin
  perform app.require_perm(p_business, 'store.manage');
  perform app.require_feature(p_business, 'promotions');
  if v_code !~ '^[A-Z0-9_-]{3,20}$' then perform app.raise('invalid_promo_code'); end if;
  if coalesce(p ->> 'kind', '') not in ('percent', 'fixed') or coalesce(nullif(p ->> 'value', '')::numeric, 0) <= 0
     or (p ->> 'kind' = 'percent' and (p ->> 'value')::numeric > 90) then
    perform app.raise('invalid_amount');
  end if;
  if pid is null then
    begin
      insert into public.market_promotions (business_id, code, description, kind, value, min_order, starts_at, ends_at, max_uses, active, created_by)
      values (p_business, v_code, nullif(btrim(coalesce(p ->> 'description', '')), ''), p ->> 'kind', (p ->> 'value')::numeric,
              coalesce(nullif(p ->> 'min_order', '')::numeric, 0), nullif(p ->> 'starts_at', '')::timestamptz,
              nullif(p ->> 'ends_at', '')::timestamptz, nullif(p ->> 'max_uses', '')::int, coalesce((p ->> 'active')::boolean, true), auth.uid())
      returning id into pid;
    exception when unique_violation then perform app.raise('promo_code_exists'); end;
  else
    update public.market_promotions set description = nullif(btrim(coalesce(p ->> 'description', '')), ''), kind = p ->> 'kind',
           value = (p ->> 'value')::numeric, min_order = coalesce(nullif(p ->> 'min_order', '')::numeric, 0),
           starts_at = nullif(p ->> 'starts_at', '')::timestamptz, ends_at = nullif(p ->> 'ends_at', '')::timestamptz,
           max_uses = nullif(p ->> 'max_uses', '')::int, active = coalesce((p ->> 'active')::boolean, true)
     where id = pid and business_id = p_business;
    if not found then perform app.raise('not_found'); end if;
  end if;
  perform app.audit(p_business, 'promotion.saved', 'promotion', pid::text, p);
  return pid;
end $$;

create or replace function public.market_review_reply(p_review uuid, p_reply text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.market_reviews;
begin
  select * into r from public.market_reviews where id = p_review;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(r.business_id, 'store.manage');
  update public.market_reviews set seller_reply = nullif(left(btrim(coalesce(p_reply, '')), 1000), ''), replied_at = now() where id = p_review;
end $$;

-- ---------------------------------------------------------------------------
-- Seller side: order handling
-- ---------------------------------------------------------------------------
-- Turns a delivered order into a BizPilot sale: stock leaves through the normal ledger at the
-- current average cost, and the payment lands in the matching cash account.
create or replace function app.market_order_to_sale(p_order uuid, p_method text, p_reference text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  o public.market_orders; st public.business_settings; sid uuid; num text; l record; mv public.stock_movements;
  net_sum numeric; goods numeric; alloc numeric; alloc_left numeric; n int; i int := 0; v_net numeric; tax numeric;
  tax_sum numeric := 0; cost_sum numeric := 0;
begin
  select * into o from public.market_orders where id = p_order;
  select * into st from public.business_settings where business_id = o.business_id;
  update public.stock_reservations set consumed_at = now() where order_id = o.id and released_at is null and consumed_at is null;
  num := app.next_number(o.business_id, 'sale', 'S-');
  insert into public.sales (business_id, number, client_ref, customer_id, sold_at, notes, created_by)
  values (o.business_id, num, o.id, o.customer_id, now(), 'Online order ' || o.number, auth.uid())
  returning id into sid;
  perform 1 from public.products where id in (select product_id from public.market_order_lines where order_id = o.id) order by id for update;
  select coalesce(sum(line_total), 0), count(*) into net_sum, n from public.market_order_lines where order_id = o.id;
  goods := net_sum - o.discount;
  alloc_left := o.discount;
  for l in select * from public.market_order_lines where order_id = o.id order by sort, id loop
    i := i + 1;
    if i = n then alloc := alloc_left;
    elsif net_sum > 0 then alloc := least(alloc_left, app.money(o.business_id, o.discount * l.line_total / net_sum));
    else alloc := 0; end if;
    alloc_left := alloc_left - alloc;
    v_net := l.line_total - alloc;
    tax := case when st.tax_enabled then app.money(o.business_id, v_net * st.tax_rate / (100 + st.tax_rate)) else 0 end;
    perform app.consume_batches(l.product_id, l.quantity);
    mv := app.apply_movement(o.business_id, l.product_id, 'sale', -l.quantity, null, 'sale', sid, num, 'Online order ' || o.number);
    insert into public.sale_lines (sale_id, business_id, product_id, unit_id, unit_name, unit_factor, quantity, base_quantity,
      list_price, unit_price, line_discount, sale_discount_alloc, net_amount, tax_amount, cost_unit_base, cost_amount, sort)
    values (sid, o.business_id, l.product_id, null, (select base_unit from public.products where id = l.product_id), 1,
      l.quantity, l.quantity, l.unit_price, l.unit_price, 0, alloc, v_net, tax, mv.unit_cost, -mv.value, i);
    tax_sum := tax_sum + tax;
    cost_sum := cost_sum - mv.value;
  end loop;
  update public.sales set subtotal = net_sum, list_total = net_sum, line_discount_total = 0, sale_discount = o.discount,
         total = goods, tax_total = tax_sum, cost_total = cost_sum where id = sid;
  if goods > 0 then
    perform app.insert_payment(o.business_id, 'sale_payment', p_method, goods, now(), p_reference, 'Online order ' || o.number,
                               null, o.customer_id, null, sid);
  end if;
  perform app.rebalance_customer(o.customer_id, sid);
  perform app.audit(o.business_id, 'sale.created', 'sale', sid::text,
    jsonb_build_object('number', num, 'total', goods, 'paid', goods, 'online_order', o.number));
  return sid;
end $$;

-- Seller actions on an order. p: {reason, message, cod_method, proof_note, proof_path, received_by, restock}
create or replace function public.market_order_action(p_order uuid, p_action text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o public.market_orders; msg text := nullif(left(btrim(coalesce(p ->> 'message', '')), 1000), '');
  reason text := nullif(left(btrim(coalesce(p ->> 'reason', '')), 300), ''); sid uuid; rid uuid;
  goods numeric; refund numeric;
begin
  select * into o from public.market_orders where id = p_order for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(o.business_id, 'orders.manage');

  if p_action = 'confirm' then
    if o.status <> 'pending' then perform app.raise('invalid_order_status'); end if;
    if o.payment_method = 'online' and o.payment_status <> 'paid' then perform app.raise('order_not_paid'); end if;
    update public.market_orders set status = 'confirmed', confirmed_at = now(), expires_at = null where id = o.id;
    update public.stock_reservations set expires_at = null where order_id = o.id and released_at is null and consumed_at is null;
  elsif p_action = 'processing' then
    if o.status <> 'confirmed' then perform app.raise('invalid_order_status'); end if;
    update public.market_orders set status = 'processing' where id = o.id;
  elsif p_action = 'dispatch' then
    if o.status not in ('confirmed', 'processing') then perform app.raise('invalid_order_status'); end if;
    update public.market_orders set status = 'dispatched', dispatched_at = now() where id = o.id;
  elsif p_action = 'deliver' then
    if o.status not in ('confirmed', 'processing', 'dispatched') then perform app.raise('invalid_order_status'); end if;
    if o.payment_method = 'cod' then
      if coalesce(p ->> 'cod_method', '') not in ('cash', 'mtn_momo', 'orange_money') then perform app.raise('payment_method_required'); end if;
      sid := app.market_order_to_sale(o.id, p ->> 'cod_method', 'COD ' || o.number);
      if o.delivery_fee > 0 then
        -- The delivery fee was collected with the goods: it goes into the same cash account.
        insert into public.cash_movements (business_id, kind, to_account_id, amount, note, client_ref, created_by)
        values (o.business_id, 'deposit', app.account_for_method(o.business_id, p ->> 'cod_method'), o.delivery_fee,
                'Delivery fee ' || o.number, null, auth.uid());
      end if;
      update public.market_orders set payment_status = 'cod_collected', cod_collected_amount = o.total, cod_method = p ->> 'cod_method',
             cod_collected_at = now(), cod_collected_by = auth.uid() where id = o.id;
      if o.commission_amount > 0 then
        insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
        values (o.business_id, o.id, 'commission', -o.commission_amount, 'Commission ' || o.number, auth.uid());
      end if;
    else
      if o.payment_status <> 'paid' then perform app.raise('order_not_paid'); end if;
      sid := app.market_order_to_sale(o.id, 'other', 'BizPilot Market ' || o.number);
      insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
      values (o.business_id, o.id, 'order_payment', o.total, 'Online payment ' || o.number, auth.uid());
      if o.commission_amount > 0 then
        insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
        values (o.business_id, o.id, 'commission', -o.commission_amount, 'Commission ' || o.number, auth.uid());
      end if;
      if o.online_fee_amount > 0 then
        insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
        values (o.business_id, o.id, 'processing_fee', -o.online_fee_amount, 'Payment processing ' || o.number, auth.uid());
      end if;
    end if;
    update public.market_orders set status = 'delivered', delivered_at = now(), delivered_by = auth.uid(), sale_id = sid,
           delivery_proof_note = nullif(left(btrim(coalesce(p ->> 'proof_note', '')), 300), ''),
           delivery_proof_path = case when split_part(coalesce(p ->> 'proof_path', ''), '/', 1) = o.business_id::text then p ->> 'proof_path' end,
           received_by = nullif(left(btrim(coalesce(p ->> 'received_by', '')), 80), ''), expires_at = null
     where id = o.id;
  elsif p_action in ('reject', 'cancel') then
    if reason is null then perform app.raise('reason_required'); end if;
    perform app.market_cancel(o.id, 'seller', reason);
  elsif p_action = 'refund' then
    -- After delivery: the goods come back (optionally to stock) through a normal sale return.
    if o.status <> 'delivered' then perform app.raise('invalid_order_status'); end if;
    if reason is null then perform app.raise('reason_required'); end if;
    perform app.require_perm(o.business_id, 'sales.refund');
    goods := (select total - returned_total from public.sales where id = o.sale_id);
    refund := goods;
    rid := public.create_sale_return(o.sale_id, jsonb_build_object('reason', reason,
      'restock', coalesce((p ->> 'restock')::boolean, true),
      'lines', (select jsonb_agg(jsonb_build_object('sale_line_id', sl.id, 'base_quantity', sl.base_quantity - sl.returned_base_qty))
                  from public.sale_lines sl where sl.sale_id = o.sale_id and sl.base_quantity > sl.returned_base_qty),
      'refund', jsonb_build_object('amount', refund, 'method', case when o.payment_method = 'cod' then o.cod_method else 'other' end,
                                   'reference', 'Refund ' || o.number)));
    if o.payment_method = 'online' then
      -- BizPilot holds online payments, so it refunds the buyer and takes the amount back from the seller balance.
      insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
      values (o.business_id, o.id, 'refund', -(refund + o.delivery_fee) + o.commission_amount + o.online_fee_amount,
              'Refund ' || o.number, auth.uid());
      update public.market_orders set status = 'refunded', payment_status = 'refund_pending', refund_amount = refund + o.delivery_fee,
             flagged = true, flag_reason = 'refund_after_delivery' where id = o.id;
    else
      if o.commission_amount > 0 then
        insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
        values (o.business_id, o.id, 'commission', o.commission_amount, 'Commission reversed ' || o.number, auth.uid());
      end if;
      update public.market_orders set status = 'refunded', payment_status = 'refunded', refund_amount = refund,
             refunded_at = now(), refund_reference = 'Refund ' || o.number where id = o.id;
    end if;
  elsif p_action in ('message', 'note') then
    if msg is null then perform app.raise('message_required'); end if;
  else
    perform app.raise('invalid_action');
  end if;

  if p_action in ('message', 'note') then
    insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user, visible_to_customer)
    values (o.id, o.business_id, p_action, msg, 'seller', auth.uid(), p_action = 'message');
  elsif p_action not in ('reject', 'cancel') then
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
    values (o.id, o.business_id, 'status', (select status from public.market_orders where id = o.id), coalesce(msg, reason), 'seller', auth.uid());
  end if;
  perform app.audit(o.business_id, 'order.' || p_action, 'market_order', o.id::text,
                    jsonb_build_object('number', o.number, 'reason', reason));
  return (select to_jsonb(x) from public.market_orders x where x.id = o.id);
end $$;

-- Dashboard summary for the seller.
create or replace function public.seller_market_summary(p_business uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare tz_start timestamptz := app.range_start(p_business, app.biz_today(p_business));
begin
  if not app.has_perm(p_business, 'orders.manage') then perform app.raise('permission_denied'); end if;
  perform app.market_expire();
  return jsonb_build_object(
    'readiness', public.store_readiness(p_business),
    'to_confirm', (select count(*) from public.market_orders where business_id = p_business and status = 'pending'
                    and (payment_method = 'cod' or payment_status = 'paid')),
    'awaiting_payment', (select count(*) from public.market_orders where business_id = p_business and status = 'pending'
                          and payment_method = 'online' and payment_status in ('awaiting_payment', 'failed')),
    'to_deliver', (select count(*) from public.market_orders where business_id = p_business and status in ('confirmed', 'processing', 'dispatched')),
    'disputes', (select count(*) from public.market_reports where business_id = p_business and kind = 'dispute' and status in ('open', 'reviewing')),
    'today_orders', (select count(*) from public.market_orders where business_id = p_business and created_at >= tz_start),
    'today_delivered_total', (select coalesce(sum(total), 0) from public.market_orders where business_id = p_business
                               and status = 'delivered' and delivered_at >= tz_start),
    'balance', case when app.has_perm(p_business, 'cash.manage')
                    then (select coalesce(sum(amount), 0) from public.market_ledger where business_id = p_business) end,
    'recent', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'number', number, 'status', status, 'payment_method', payment_method,
                  'payment_status', payment_status, 'total', total, 'customer_name', customer_name, 'created_at', created_at) order by created_at desc)
                from (select * from public.market_orders where business_id = p_business order by created_at desc limit 6) r), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.stores enable row level security;
alter table public.store_delivery_zones enable row level security;
alter table public.market_promotions enable row level security;
alter table public.market_orders enable row level security;
alter table public.market_order_lines enable row level security;
alter table public.market_order_events enable row level security;
alter table public.stock_reservations enable row level security;
alter table public.market_reviews enable row level security;
alter table public.market_reports enable row level security;
alter table public.customer_addresses enable row level security;
alter table public.market_favorites enable row level security;
alter table public.market_store_follows enable row level security;
alter table public.market_blocklist enable row level security;

create policy stores_read on public.stores for select using (app.can_read(business_id) or app.is_platform_admin());
create policy zones_read on public.store_delivery_zones for select using (app.can_read(business_id));
create policy promotions_read on public.market_promotions for select using (app.has_perm(business_id, 'store.manage'));
create policy market_orders_read on public.market_orders for select
  using (app.has_perm(business_id, 'orders.manage') or app.is_platform_admin());
create policy market_order_lines_read on public.market_order_lines for select
  using (app.has_perm(business_id, 'orders.manage') or app.is_platform_admin());
create policy market_order_events_read on public.market_order_events for select
  using (app.has_perm(business_id, 'orders.manage') or app.is_platform_admin());
create policy reservations_read on public.stock_reservations for select using (app.can_read(business_id));
create policy reviews_read on public.market_reviews for select using (app.can_read(business_id) or app.is_platform_admin());
create policy reports_read on public.market_reports for select
  using (app.is_platform_admin() or (reporter_user_id is not null and reporter_user_id = auth.uid()));
create policy blocklist_read on public.market_blocklist for select using (app.is_platform_admin());

create policy addresses_own_read on public.customer_addresses for select using (user_id = auth.uid());
create policy addresses_own_insert on public.customer_addresses for insert with check (user_id = auth.uid());
create policy addresses_own_update on public.customer_addresses for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy addresses_own_delete on public.customer_addresses for delete using (user_id = auth.uid());
create policy favorites_own_read on public.market_favorites for select using (user_id = auth.uid());
create policy favorites_own_insert on public.market_favorites for insert with check (user_id = auth.uid() and app.listing_public(product_id));
create policy favorites_own_delete on public.market_favorites for delete using (user_id = auth.uid());
create policy follows_own_read on public.market_store_follows for select using (user_id = auth.uid());
create policy follows_own_insert on public.market_store_follows for insert with check (user_id = auth.uid() and app.store_is_live(business_id));
create policy follows_own_delete on public.market_store_follows for delete using (user_id = auth.uid());

grant select, insert, update, delete on public.customer_addresses to authenticated;
grant select, insert, delete on public.market_favorites, public.market_store_follows to authenticated;

-- ---------------------------------------------------------------------------
-- Storage: public bucket for storefront images; delivery proofs stay in the private bucket
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('storefront', 'storefront', true, 5242880, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function app.storefront_can_write(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select case (storage.foldername(object_name))[2]
    when 'store' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'store.manage')
    when 'products' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'products.manage')
    else false end
$$;

create policy "storefront insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'storefront' and app.storefront_can_write(name));
create policy "storefront delete" on storage.objects for delete to authenticated
  using (bucket_id = 'storefront' and app.storefront_can_write(name));

create or replace function app.storage_can_write(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select case (storage.foldername(object_name))[2]
    when 'logos' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'settings.manage')
    when 'products' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'products.manage')
    when 'purchases' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'purchases.manage')
    when 'suppliers' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'suppliers.manage')
    when 'expenses' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'expenses.manage')
    when 'billing' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'billing.manage')
    when 'stock' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'stock.adjust')
    when 'orders' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'orders.manage')
    else false end
$$;

-- ===== 20261025000200_marketplace_payments_admin.sql =====
-- BizPilot Market: online payments (Fapshi), seller settlements, marketplace administration.
--
-- Online payments: BizPilot collects with its own Fapshi service (hosted checkout, initiate-pay).
-- Fapshi offers no split payments, no automatic recurring charges and no refund endpoint, so:
--   * the money of an online order is held by BizPilot and recorded in the seller's ledger once the
--     order is delivered (minus any configured commission / processing fee);
--   * BizPilot pays sellers out (mobile money / bank) and records each payout in the ledger;
--   * refunds to buyers are sent by BizPilot and recorded by an administrator;
--   * subscriptions are paid one period at a time (no automatic renewal).
-- A payment is marked successful only by the server: the edge function asks Fapshi for the
-- transaction status (after a webhook carrying the shared secret, or when the buyer returns) and
-- passes the answer to public.fapshi_apply(), which only the service role may call. A browser
-- redirect or a screenshot never changes a payment.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.market_ledger (
  id bigserial primary key,
  business_id uuid not null references public.businesses (id) on delete cascade,
  order_id uuid references public.market_orders (id) on delete set null,
  kind text not null check (kind in ('order_payment', 'commission', 'processing_fee', 'refund', 'payout', 'adjustment')),
  amount numeric(14, 2) not null,           -- positive: BizPilot owes the seller; negative: deducted / paid out
  method text,
  reference text check (length(reference) <= 120),
  note text check (length(note) <= 300),
  created_by uuid,
  created_at timestamptz not null default now()
);
create index market_ledger_business on public.market_ledger (business_id, created_at desc);

create table public.online_payments (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('order', 'subscription')),
  business_id uuid not null references public.businesses (id) on delete cascade,
  order_id uuid references public.market_orders (id) on delete set null,
  plan_code text references public.plans (code),
  billing_period text check (billing_period in ('monthly', 'annual')),
  billing_payment_id uuid references public.billing_payments (id),
  amount numeric(14, 0) not null check (amount >= 100),
  currency text not null default 'XAF',
  provider text not null default 'fapshi',
  trans_id text unique check (trans_id ~ '^[A-Za-z0-9_-]{4,64}$'),
  link text,
  status text not null default 'created' check (status in ('created', 'pending', 'successful', 'failed', 'expired', 'error')),
  provider_status text,
  medium text,
  payer_name text,
  financial_trans_id text,
  revenue numeric(14, 0),
  amount_received numeric(14, 0),
  mismatch boolean not null default false,
  needs_refund boolean not null default false,
  refunded_at timestamptz,
  refund_reference text,
  resolution_note text,
  check_count int not null default 0,
  last_checked_at timestamptz,
  verified_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index online_payments_order on public.online_payments (order_id);
create index online_payments_business on public.online_payments (business_id, created_at desc);
create index online_payments_attention on public.online_payments (created_at) where mismatch or needs_refund;
create trigger online_payments_touch before update on public.online_payments for each row execute function app.touch_updated_at();

alter table public.billing_payments drop constraint if exists billing_payments_method_check;
alter table public.billing_payments add constraint billing_payments_method_check
  check (method in ('mtn_momo', 'orange_money', 'bank_transfer', 'cash', 'other', 'fapshi'));

-- ---------------------------------------------------------------------------
-- Starting a payment (called by the edge function with the buyer's / seller's own credentials)
-- ---------------------------------------------------------------------------
create or replace function app.online_payments_on() returns boolean
language sql stable as $$ select coalesce((app.market_config() ->> 'online_payments_enabled')::boolean, false) $$;

-- Re-reserves the stock of an order cancelled for non-payment. Returns false when stock is gone.
create or replace function app.market_try_reopen(p_order uuid, p_expires timestamptz) returns boolean
language plpgsql security definer set search_path = public as $$
declare o public.market_orders; l record;
begin
  select * into o from public.market_orders where id = p_order;
  perform 1 from public.products where id in (select product_id from public.market_order_lines where order_id = o.id) order by id for update;
  for l in select product_id, sum(quantity) q from public.market_order_lines where order_id = o.id group by product_id loop
    if (select qty_on_hand from public.products where id = l.product_id) - app.reserved_qty(l.product_id) < l.q then
      return false;
    end if;
  end loop;
  insert into public.stock_reservations (business_id, product_id, order_id, quantity, expires_at)
  select o.business_id, product_id, o.id, quantity, p_expires from public.market_order_lines where order_id = o.id;
  if o.promo_id is not null then
    update public.market_promotions set used_count = used_count + 1 where id = o.promo_id;
  end if;
  update public.market_orders set status = 'pending', cancelled_at = null, cancelled_by = null, cancel_reason = null,
         expires_at = p_expires where id = o.id;
  return true;
end $$;

create or replace function public.market_payment_begin(p_order uuid, p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.market_orders; exp timestamptz; pid uuid; prev jsonb;
begin
  if not app.online_payments_on() then perform app.raise('online_payments_not_available'); end if;
  o := app.order_for_customer(p_order, p_token, true);
  perform app.rate_limit('pay_begin:' || o.id, 10, 3600);
  if o.payment_method <> 'online' then perform app.raise('invalid_payment_method'); end if;
  if o.payment_status = 'paid' then perform app.raise('already_paid'); end if;
  if o.total <> round(o.total) or o.total < 100 then perform app.raise('online_minimum_amount', jsonb_build_object('min', 100)); end if;
  exp := now() + make_interval(mins => coalesce((app.market_config() ->> 'unpaid_order_minutes')::int, 30));
  if o.status = 'cancelled' and o.cancel_reason = 'payment_not_completed' and o.cancelled_at > now() - interval '12 hours' then
    if not app.market_try_reopen(o.id, exp) then perform app.raise('insufficient_stock'); end if;
    update public.market_orders set payment_status = 'awaiting_payment' where id = o.id;
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
    values (o.id, o.business_id, 'status', 'pending', 'reopened_for_payment', 'customer', auth.uid());
  elsif o.status <> 'pending' then
    perform app.raise('order_not_payable');
  else
    update public.market_orders set expires_at = exp, payment_status = 'awaiting_payment' where id = o.id;
    update public.stock_reservations set expires_at = exp where order_id = o.id and released_at is null and consumed_at is null;
  end if;
  select coalesce(jsonb_agg(trans_id), '[]'::jsonb) into prev from public.online_payments
   where order_id = o.id and status in ('created', 'pending') and trans_id is not null;
  insert into public.online_payments (kind, business_id, order_id, amount, created_by)
  values ('order', o.business_id, o.id, o.total, auth.uid()) returning id into pid;
  return jsonb_build_object('payment_id', pid, 'amount', o.total, 'email', o.customer_email,
    'user_id', replace(coalesce(o.customer_user_id, o.id)::text, '-', ''), 'message', 'BizPilot ' || o.number,
    'previous', prev, 'return_path', '/pay/return?p=' || pid);
end $$;

create or replace function public.billing_fapshi_begin(p_business uuid, p_plan text, p_period text default 'monthly') returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl public.plans; amt numeric; pid uuid;
begin
  perform app.require_perm(p_business, 'billing.manage');
  if not app.online_payments_on() then perform app.raise('online_payments_not_available'); end if;
  perform app.rate_limit('billing_pay:' || p_business, 10, 86400);
  select * into pl from public.plans where code = p_plan and active and price_monthly > 0;
  if not found then perform app.raise('invalid_plan'); end if;
  if p_period not in ('monthly', 'annual') then perform app.raise('invalid_billing_period'); end if;
  amt := case when p_period = 'annual' then coalesce(pl.price_annual, pl.price_monthly * 12) else pl.price_monthly end;
  insert into public.online_payments (kind, business_id, plan_code, billing_period, amount, created_by)
  values ('subscription', p_business, pl.code, p_period, amt, auth.uid()) returning id into pid;
  perform app.audit(p_business, 'billing.online_payment_started', 'online_payment', pid::text,
                    jsonb_build_object('plan', pl.code, 'period', p_period, 'amount', amt));
  return jsonb_build_object('payment_id', pid, 'amount', amt, 'email', (select email from auth.users where id = auth.uid()),
    'user_id', replace(p_business::text, '-', ''), 'message', 'BizPilot ' || pl.name_en || ' (' || p_period || ')',
    'previous', '[]'::jsonb, 'return_path', '/pay/return?p=' || pid);
end $$;

-- ---------------------------------------------------------------------------
-- Service-role functions used only by the Fapshi edge function
-- ---------------------------------------------------------------------------
create or replace function public.fapshi_attach(p_payment uuid, p_trans_id text, p_link text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.online_payments set trans_id = p_trans_id, link = left(p_link, 500)
   where id = p_payment and trans_id is null;
  if not found then perform app.raise('not_found'); end if;
end $$;

create or replace function public.fapshi_payment_lookup(p_payment uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pay public.online_payments;
begin
  select * into pay from public.online_payments where id = p_payment for update;
  if not found then return null; end if;
  -- At most one status check every 10 seconds per payment (Fapshi allows 6 per minute).
  if pay.last_checked_at > now() - interval '10 seconds' then
    return jsonb_build_object('id', pay.id, 'trans_id', pay.trans_id, 'status', pay.status, 'kind', pay.kind,
                              'order_id', pay.order_id, 'throttled', true);
  end if;
  update public.online_payments set last_checked_at = now(), check_count = check_count + 1 where id = pay.id;
  return jsonb_build_object('id', pay.id, 'trans_id', pay.trans_id, 'status', pay.status, 'kind', pay.kind,
                            'order_id', pay.order_id, 'throttled', false);
end $$;

-- Extends the subscription paid by a verified Fapshi payment (same rules as an approved manual payment).
create or replace function app.activate_fapshi_subscription(p_payment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare pay public.online_payments; bp uuid; s public.business_subscriptions; start_at timestamptz; end_at timestamptz;
begin
  select * into pay from public.online_payments where id = p_payment;
  if pay.billing_payment_id is not null then return; end if;
  insert into public.billing_payments (business_id, plan_code, billing_period, amount, expected_amount, method, transaction_ref,
    payer_name, note, status, submitted_by, submitted_at, reviewed_at, review_note)
  values (pay.business_id, pay.plan_code, pay.billing_period, coalesce(pay.amount_received, pay.amount), pay.amount, 'fapshi',
    pay.trans_id, pay.payer_name, 'Fapshi ' || coalesce(pay.medium, ''), 'pending', pay.created_by, pay.created_at, null, null)
  returning id into bp;
  select * into s from public.business_subscriptions where business_id = pay.business_id for update;
  start_at := case when s.status in ('active', 'cancelled') and s.plan_code = pay.plan_code
                        and s.current_period_end > now() then s.current_period_end else now() end;
  end_at := start_at + case when pay.billing_period = 'annual' then interval '1 year' else interval '1 month' end;
  insert into public.business_subscriptions (business_id, plan_code, status, billing_period, current_period_start,
                                             current_period_end, cancel_at_period_end)
  values (pay.business_id, pay.plan_code, 'active', pay.billing_period, start_at, end_at, false)
  on conflict (business_id) do update set plan_code = excluded.plan_code, status = 'active',
    billing_period = excluded.billing_period, current_period_start = excluded.current_period_start,
    current_period_end = excluded.current_period_end, cancel_at_period_end = false, suspended_reason = null;
  update public.billing_payments set status = 'verified', reviewed_at = now(), review_note = 'Verified with Fapshi',
         period_start = start_at, period_end = end_at where id = bp;
  update public.online_payments set billing_payment_id = bp where id = pay.id;
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (pay.business_id, 'billing_payment_verified', 'success',
          jsonb_build_object('plan', pay.plan_code, 'period_end', end_at), '/app/billing', 'billing.manage');
  insert into public.audit_logs (business_id, user_id, action, entity, entity_id, details)
  values (pay.business_id, null, 'billing.payment_verified', 'billing_payment', bp::text,
          jsonb_build_object('provider', 'fapshi', 'trans_id', pay.trans_id, 'amount', pay.amount_received));
end $$;

-- Applies a transaction status fetched from the Fapshi API (never from the browser). Idempotent:
-- repeated or out-of-order notifications cannot pay an order twice or undo a successful payment.
create or replace function public.fapshi_apply(p_trans_id text, p_tx jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pay public.online_payments; o public.market_orders; st text := upper(coalesce(p_tx ->> 'status', ''));
  amt numeric := nullif(p_tx ->> 'amount', '')::numeric; ext text := nullif(p_tx ->> 'externalId', ''); mism boolean;
begin
  select * into pay from public.online_payments where trans_id = p_trans_id for update;
  if not found then return jsonb_build_object('ignored', 'unknown_transaction'); end if;
  if st not in ('CREATED', 'PENDING', 'SUCCESSFUL', 'FAILED', 'EXPIRED') then
    return jsonb_build_object('ignored', 'unknown_status', 'payment_id', pay.id);
  end if;
  update public.online_payments set provider_status = st, last_checked_at = now(),
         medium = coalesce(nullif(p_tx ->> 'medium', ''), medium), payer_name = coalesce(nullif(left(p_tx ->> 'payerName', 120), ''), payer_name),
         financial_trans_id = coalesce(nullif(left(p_tx ->> 'financialTransId', 120), ''), financial_trans_id),
         revenue = coalesce(nullif(p_tx ->> 'revenue', '')::numeric, revenue)
   where id = pay.id;
  if pay.status = 'successful' then
    return jsonb_build_object('payment_id', pay.id, 'status', 'successful', 'kind', pay.kind, 'order_id', pay.order_id, 'duplicate', true);
  end if;

  if st in ('CREATED', 'PENDING') then
    update public.online_payments set status = lower(st) where id = pay.id;
    return jsonb_build_object('payment_id', pay.id, 'status', lower(st), 'kind', pay.kind, 'order_id', pay.order_id);
  end if;

  if st in ('FAILED', 'EXPIRED') then
    update public.online_payments set status = lower(st) where id = pay.id;
    if pay.kind = 'order' and pay.status not in ('failed', 'expired') then
      update public.market_orders set payment_status = 'failed'
       where id = pay.order_id and payment_status = 'awaiting_payment'
         and not exists (select 1 from public.online_payments x where x.order_id = pay.order_id and x.id <> pay.id
                         and x.status in ('created', 'pending'));
      if found then
        insert into public.market_order_events (order_id, business_id, kind, status, message, actor)
        values (pay.order_id, pay.business_id, 'payment', 'failed', lower(st), 'system');
      end if;
    end if;
    return jsonb_build_object('payment_id', pay.id, 'status', lower(st), 'kind', pay.kind, 'order_id', pay.order_id);
  end if;

  -- SUCCESSFUL
  mism := amt is distinct from pay.amount or (ext is not null and ext <> pay.id::text);
  update public.online_payments set status = 'successful', verified_at = now(), amount_received = amt, mismatch = mism where id = pay.id;
  if pay.kind = 'subscription' then
    if not mism then perform app.activate_fapshi_subscription(pay.id); end if;
    return jsonb_build_object('payment_id', pay.id, 'status', 'successful', 'kind', 'subscription', 'mismatch', mism);
  end if;

  select * into o from public.market_orders where id = pay.order_id for update;
  if mism then
    update public.market_orders set flagged = true, flag_reason = 'payment_amount_mismatch' where id = o.id;
    insert into public.market_order_events (order_id, business_id, kind, message, actor, visible_to_customer)
    values (o.id, o.business_id, 'payment', 'amount_mismatch', 'system', false);
  elsif o.payment_status in ('paid', 'refund_pending', 'refunded') then
    -- A second successful payment for the same order: refund it.
    update public.online_payments set needs_refund = true where id = pay.id;
    update public.market_orders set flagged = true, flag_reason = 'duplicate_payment' where id = o.id;
  elsif o.status = 'pending' then
    update public.market_orders set payment_status = 'paid', expires_at = null where id = o.id;
    update public.stock_reservations set expires_at = null where order_id = o.id and released_at is null and consumed_at is null;
  elsif o.status = 'cancelled' and o.cancel_reason = 'payment_not_completed' and app.market_try_reopen(o.id, null) then
    update public.market_orders set payment_status = 'paid', expires_at = null where id = o.id;
  else
    -- Paid after the order was cancelled and the stock is gone (or the seller cancelled): refund.
    update public.online_payments set needs_refund = true where id = pay.id;
    update public.market_orders set payment_status = 'refund_pending', flagged = true, flag_reason = 'paid_after_cancellation'
     where id = o.id;
  end if;
  select * into o from public.market_orders where id = pay.order_id;
  if not mism then
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor)
    values (o.id, o.business_id, 'payment', o.payment_status, 'online_payment_verified', 'system');
  end if;
  if o.payment_status = 'paid' and o.status = 'pending' then
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (o.business_id, 'market_order_paid', 'success',
            jsonb_build_object('number', o.number, 'amount', o.total, 'customer', o.customer_name), '/app/orders/' || o.id, 'orders.manage');
  end if;
  return jsonb_build_object('payment_id', pay.id, 'status', 'successful', 'kind', 'order', 'order_id', o.id,
                            'order_payment_status', o.payment_status, 'mismatch', mism);
end $$;

-- Payment state a browser may see (for the "checking your payment" page). Contains no secrets.
create or replace function public.online_payment_status(p_payment uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', p.id, 'kind', p.kind, 'status', p.status, 'order_id', p.order_id, 'amount', p.amount,
                            'order_payment_status', o.payment_status, 'order_status', o.status)
    from public.online_payments p left join public.market_orders o on o.id = p.order_id where p.id = p_payment
$$;

-- ---------------------------------------------------------------------------
-- Seller: payments and settlements
-- ---------------------------------------------------------------------------
create or replace function public.seller_payments_summary(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare since timestamptz := now() - interval '30 days';
begin
  perform app.require_perm(p_business, 'cash.manage');
  return jsonb_build_object(
    'balance', (select coalesce(sum(amount), 0) from public.market_ledger where business_id = p_business),
    'held_undelivered', (select coalesce(sum(total), 0) from public.market_orders where business_id = p_business
                          and payment_method = 'online' and payment_status = 'paid' and status in ('pending', 'confirmed', 'processing', 'dispatched')),
    'paid_out_total', (select coalesce(-sum(amount), 0) from public.market_ledger where business_id = p_business and kind = 'payout'),
    'online_delivered_30d', (select coalesce(sum(total), 0) from public.market_orders where business_id = p_business
                              and payment_method = 'online' and status in ('delivered', 'refunded') and delivered_at >= since),
    'cod_collected_30d', (select coalesce(sum(cod_collected_amount), 0) from public.market_orders where business_id = p_business
                           and cod_collected_at >= since),
    'delivery_fees_30d', (select coalesce(sum(delivery_fee), 0) from public.market_orders where business_id = p_business
                           and status = 'delivered' and delivered_at >= since),
    'commission_30d', (select coalesce(-sum(amount), 0) from public.market_ledger where business_id = p_business
                        and kind in ('commission', 'processing_fee') and created_at >= since),
    'refund_pending', (select count(*) from public.market_orders where business_id = p_business and payment_status = 'refund_pending'),
    'config', public.market_config_public());
end $$;

-- ---------------------------------------------------------------------------
-- Administration
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_config(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if p_key not in ('trial', 'grace_days', 'renewal_notice_days', 'payment_instructions', 'support_contact', 'ai', 'marketplace') then
    perform app.raise('invalid_config_key');
  end if;
  if p_key = 'marketplace' then
    if jsonb_typeof(p_value) <> 'object'
       or coalesce((p_value ->> 'commission_pct')::numeric, 0) not between 0 and 50
       or coalesce((p_value ->> 'online_fee_pct')::numeric, 0) not between 0 and 20
       or coalesce((p_value ->> 'unpaid_order_minutes')::int, 30) not between 10 and 1440
       or coalesce((p_value ->> 'confirm_hours')::int, 48) not between 1 and 240
       or coalesce((p_value ->> 'max_open_cod_per_phone')::int, 3) not between 1 and 50 then
      perform app.raise('invalid_config_value');
    end if;
    insert into public.app_config (key, value, is_public) values ('marketplace', p_value, true)
    on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  else
    update public.app_config set value = p_value, updated_at = now(), updated_by = auth.uid() where key = p_key;
  end if;
  insert into public.audit_logs (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'admin.config_changed', 'config', p_key, p_value);
end $$;

create or replace function app.admin_audit(act text, ent text, ent_id text, bid uuid, det jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.audit_logs (business_id, user_id, action, entity, entity_id, details) values (bid, auth.uid(), act, ent, ent_id, det)
$$;

create or replace function public.admin_market_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return jsonb_build_object(
    'stores_published', (select count(*) from public.stores where status = 'published'),
    'stores_total', (select count(*) from public.stores),
    'stores_pending_verification', (select count(*) from public.stores where verification = 'pending'),
    'stores_suspended', (select count(*) from public.stores where status = 'suspended'),
    'listings', (select count(*) from public.products where online_published and status = 'active' and variant_of is null),
    'listings_hidden', (select count(*) from public.products where admin_hidden),
    'orders_30d', (select count(*) from public.market_orders where created_at > now() - interval '30 days'),
    'gmv_30d', (select coalesce(sum(total), 0) from public.market_orders where status = 'delivered' and delivered_at > now() - interval '30 days'),
    'open_reports', (select count(*) from public.market_reports where status in ('open', 'reviewing') and kind = 'report'),
    'open_disputes', (select count(*) from public.market_reports where status in ('open', 'reviewing') and kind = 'dispute'),
    'refund_pending', (select count(*) from public.market_orders where payment_status = 'refund_pending'),
    'flagged_orders', (select count(*) from public.market_orders where flagged),
    'payment_issues', (select count(*) from public.online_payments where (mismatch or needs_refund) and refunded_at is null and resolution_note is null),
    'owed_to_sellers', (select coalesce(sum(b), 0) from (select sum(amount) b from public.market_ledger group by business_id) t where b > 0),
    'owed_by_sellers', (select coalesce(-sum(b), 0) from (select sum(amount) b from public.market_ledger group by business_id) t where b < 0));
end $$;

create or replace function public.admin_market_stores(p_search text default null, p_status text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select s.business_id, s.slug, s.name, s.city, s.status, s.verification, s.verification_note, s.suspended_reason,
           s.rating_avg, s.rating_count, s.published_at, s.created_at, b.name business_name, b.status business_status,
           (select u.email from public.business_members m join auth.users u on u.id = m.user_id
             where m.business_id = b.id and m.role = 'owner' and m.active) owner_email,
           (select count(*) from public.products p where p.business_id = s.business_id and p.online_published and p.variant_of is null) listings,
           (select count(*) from public.market_orders o where o.business_id = s.business_id and o.created_at > now() - interval '30 days') orders_30d,
           (select count(*) from public.market_reports r where r.business_id = s.business_id and r.status in ('open', 'reviewing')) open_reports,
           (select coalesce(sum(amount), 0) from public.market_ledger l where l.business_id = s.business_id) balance
      from public.stores s join public.businesses b on b.id = s.business_id
     where (p_status is null or s.status = p_status or (p_status = 'pending_verification' and s.verification = 'pending'))
       and (p_search is null or s.name ilike app.like_term(p_search) or s.slug ilike app.like_term(p_search) or b.name ilike app.like_term(p_search))
     order by (s.verification = 'pending') desc, s.created_at desc limit 200) t), '[]'::jsonb);
end $$;

create or replace function public.admin_market_store_update(p_business uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare s public.stores; reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  perform app.require_platform_admin();
  select * into s from public.stores where business_id = p_business for update;
  if not found then perform app.raise('not_found'); end if;
  if p ? 'status' then
    if p ->> 'status' not in ('draft', 'published', 'suspended') then perform app.raise('invalid_request'); end if;
    if p ->> 'status' = 'suspended' and reason is null then perform app.raise('reason_required'); end if;
    update public.stores set status = p ->> 'status',
           suspended_reason = case when p ->> 'status' = 'suspended' then reason end,
           published_at = case when p ->> 'status' = 'published' then coalesce(published_at, now()) else published_at end
     where business_id = p_business;
  end if;
  if p ? 'verification' then
    if p ->> 'verification' not in ('unverified', 'pending', 'verified', 'rejected') then perform app.raise('invalid_request'); end if;
    if p ->> 'verification' = 'rejected' and reason is null then perform app.raise('reason_required'); end if;
    update public.stores set verification = p ->> 'verification', verification_note = coalesce(reason, verification_note)
     where business_id = p_business;
  end if;
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (p_business, 'market_store_status', case when p ->> 'status' = 'suspended' or p ->> 'verification' = 'rejected' then 'critical' else 'info' end,
          jsonb_build_object('status', coalesce(p ->> 'status', s.status), 'verification', coalesce(p ->> 'verification', s.verification),
                             'reason', reason), '/app/store', 'store.manage');
  perform app.admin_audit('admin.store_updated', 'store', p_business::text, p_business, p);
end $$;

create or replace function public.admin_market_listings(p_search text default null, p_hidden_only boolean default false,
  p_limit int default 100, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select p.id, p.name, p.brand, p.selling_price, p.online_images[1] image, p.admin_hidden, p.admin_hidden_reason, p.online_since,
           s.name store_name, s.slug store_slug, s.business_id,
           (select count(*) from public.market_reports r where r.target_type = 'product' and r.target_id = p.id and r.status in ('open', 'reviewing')) open_reports
      from public.products p join public.stores s on s.business_id = p.business_id
     where p.variant_of is null and (p.online_published or p.admin_hidden)
       and (not p_hidden_only or p.admin_hidden)
       and (p_search is null or p.name ilike app.like_term(p_search) or s.name ilike app.like_term(p_search))
     order by p.online_since desc nulls last limit least(p_limit, 200) offset greatest(p_offset, 0)) t), '[]'::jsonb);
end $$;

create or replace function public.admin_market_hide_product(p_product uuid, p_hidden boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare pr public.products;
begin
  perform app.require_platform_admin();
  if p_hidden and coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  update public.products set admin_hidden = p_hidden, admin_hidden_reason = case when p_hidden then btrim(p_reason) end
   where id = p_product returning * into pr;
  if not found then perform app.raise('not_found'); end if;
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (pr.business_id, case when p_hidden then 'market_listing_hidden' else 'market_listing_restored' end,
          case when p_hidden then 'critical' else 'info' end,
          jsonb_build_object('product', pr.name, 'reason', p_reason), '/app/products/' || pr.id, 'products.manage');
  perform app.admin_audit(case when p_hidden then 'admin.listing_hidden' else 'admin.listing_restored' end, 'product', p_product::text,
                          pr.business_id, jsonb_build_object('name', pr.name, 'reason', p_reason));
end $$;

create or replace function public.admin_market_reports(p_status text default 'open') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select r.*, s.name store_name, s.slug store_slug,
           case r.target_type when 'product' then (select name from public.products where id = r.target_id)
                              when 'store' then s.name
                              when 'order' then (select number from public.market_orders where id = r.target_id) end target_name,
           (select email from auth.users where id = r.reporter_user_id) reporter_email
      from public.market_reports r left join public.stores s on s.business_id = r.business_id
     where p_status is null or r.status = p_status or (p_status = 'open' and r.status = 'reviewing')
     order by r.created_at desc limit 200) t), '[]'::jsonb);
end $$;

create or replace function public.admin_market_report_update(p_report uuid, p_status text, p_resolution text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.market_reports;
begin
  perform app.require_platform_admin();
  if p_status not in ('open', 'reviewing', 'resolved', 'dismissed') then perform app.raise('invalid_request'); end if;
  update public.market_reports set status = p_status, resolution = coalesce(nullif(btrim(coalesce(p_resolution, '')), ''), resolution),
         handled_by = auth.uid(), handled_at = now() where id = p_report returning * into r;
  if not found then perform app.raise('not_found'); end if;
  if r.kind = 'dispute' and r.order_id is not null and p_status in ('resolved', 'dismissed') then
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
    values (r.order_id, r.business_id, 'dispute', p_status, r.resolution, 'admin', auth.uid());
  end if;
  perform app.admin_audit('admin.report_' || p_status, 'market_report', p_report::text, r.business_id,
                          jsonb_build_object('resolution', p_resolution));
end $$;

create or replace function public.admin_market_orders(p_filter text default 'attention', p_search text default null,
  p_limit int default 100, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select o.id, o.number, o.status, o.payment_method, o.payment_status, o.total, o.created_at, o.customer_name, o.customer_phone,
           o.flagged, o.flag_reason, s.name store_name, s.slug store_slug, o.business_id,
           exists (select 1 from public.market_reports r where r.order_id = o.id and r.status in ('open', 'reviewing')) open_dispute
      from public.market_orders o join public.stores s on s.business_id = o.business_id
     where (p_filter = 'all'
            or (p_filter = 'attention' and (o.flagged or o.payment_status = 'refund_pending'
                 or exists (select 1 from public.market_reports r where r.order_id = o.id and r.status in ('open', 'reviewing'))))
            or (p_filter = 'online' and o.payment_method = 'online')
            or (p_filter = 'refund_pending' and o.payment_status = 'refund_pending'))
       and (p_search is null or o.number ilike app.like_term(p_search) or o.customer_phone ilike app.like_term(p_search)
            or o.customer_name ilike app.like_term(p_search) or s.name ilike app.like_term(p_search))
     order by o.created_at desc limit least(p_limit, 200) offset greatest(p_offset, 0)) t), '[]'::jsonb);
end $$;

create or replace function public.admin_market_order(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.market_orders;
begin
  perform app.require_platform_admin();
  select * into o from public.market_orders where id = p_order;
  if not found then perform app.raise('not_found'); end if;
  return to_jsonb(o) - 'access_token_hash' || jsonb_build_object(
    'store', app.store_card(o.business_id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) order by l.sort), '[]'::jsonb) from public.market_order_lines l where l.order_id = o.id),
    'events', (select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at, e.id), '[]'::jsonb) from public.market_order_events e where e.order_id = o.id),
    'payments', (select coalesce(jsonb_agg(to_jsonb(p) - 'link' order by p.created_at), '[]'::jsonb) from public.online_payments p where p.order_id = o.id),
    'reports', (select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at), '[]'::jsonb) from public.market_reports r where r.order_id = o.id));
end $$;

create or replace function public.admin_market_order_action(p_order uuid, p_action text, p jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare o public.market_orders; msg text := nullif(left(btrim(coalesce(p ->> 'message', '')), 1000), '');
        ref text := nullif(left(btrim(coalesce(p ->> 'reference', '')), 120), '');
begin
  perform app.require_platform_admin();
  select * into o from public.market_orders where id = p_order for update;
  if not found then perform app.raise('not_found'); end if;
  if p_action = 'note' then
    if msg is null then perform app.raise('message_required'); end if;
    insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user, visible_to_customer)
    values (o.id, o.business_id, 'message', msg, 'admin', auth.uid(), coalesce((p ->> 'visible')::boolean, true));
  elsif p_action = 'cancel' then
    if msg is null then perform app.raise('reason_required'); end if;
    perform app.market_cancel(o.id, 'admin', msg);
  elsif p_action = 'refund_done' then
    -- BizPilot sent the money back to the buyer (outside Fapshi, which has no refund API).
    if o.payment_status <> 'refund_pending' then perform app.raise('invalid_order_status'); end if;
    if ref is null then perform app.raise('reference_required'); end if;
    update public.market_orders set payment_status = 'refunded', refunded_at = now(), refund_reference = ref,
           refund_amount = coalesce(refund_amount, total), flagged = false, flag_reason = null where id = o.id;
    update public.online_payments set needs_refund = false, refunded_at = now(), refund_reference = ref
     where order_id = o.id and status = 'successful' and refunded_at is null and (needs_refund or not mismatch);
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
    values (o.id, o.business_id, 'payment', 'refunded', 'refund_sent', 'admin', auth.uid());
  elsif p_action = 'clear_flag' then
    update public.market_orders set flagged = false, flag_reason = null where id = o.id;
  else
    perform app.raise('invalid_action');
  end if;
  perform app.admin_audit('admin.order_' || p_action, 'market_order', o.id::text, o.business_id,
                          jsonb_build_object('number', o.number, 'message', msg, 'reference', ref));
end $$;

create or replace function public.admin_market_payments(p_filter text default 'attention') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select p.id, p.kind, p.status, p.amount, p.amount_received, p.trans_id, p.medium, p.payer_name, p.mismatch, p.needs_refund,
           p.refunded_at, p.refund_reference, p.resolution_note, p.created_at, p.verified_at, p.plan_code, p.billing_period,
           o.number order_number, o.id order_id, b.name business_name
      from public.online_payments p join public.businesses b on b.id = p.business_id
      left join public.market_orders o on o.id = p.order_id
     where p_filter = 'all' or (p_filter = 'attention' and (p.mismatch or p.needs_refund) and p.refunded_at is null and p.resolution_note is null)
     order by p.created_at desc limit 200) t), '[]'::jsonb);
end $$;

-- Resolves a payment flagged for review: 'accept' (the amount is fine, apply it) or 'refunded'.
create or replace function public.admin_market_payment_resolve(p_payment uuid, p_action text, p_note text, p_reference text default null)
returns void language plpgsql security definer set search_path = public as $$
declare pay public.online_payments; o public.market_orders;
begin
  perform app.require_platform_admin();
  if coalesce(btrim(p_note), '') = '' then perform app.raise('reason_required'); end if;
  select * into pay from public.online_payments where id = p_payment for update;
  if not found or pay.status <> 'successful' then perform app.raise('not_found'); end if;
  if p_action = 'accept' and pay.mismatch then
    update public.online_payments set mismatch = false, resolution_note = p_note where id = pay.id;
    if pay.kind = 'subscription' then
      perform app.activate_fapshi_subscription(pay.id);
    else
      select * into o from public.market_orders where id = pay.order_id for update;
      if o.status = 'pending' and o.payment_status in ('awaiting_payment', 'failed') then
        update public.market_orders set payment_status = 'paid', expires_at = null, flagged = false, flag_reason = null where id = o.id;
        update public.stock_reservations set expires_at = null where order_id = o.id and released_at is null and consumed_at is null;
      else
        update public.online_payments set needs_refund = true where id = pay.id;
      end if;
    end if;
  elsif p_action = 'refunded' then
    if coalesce(btrim(p_reference), '') = '' then perform app.raise('reference_required'); end if;
    update public.online_payments set needs_refund = false, refunded_at = now(), refund_reference = btrim(p_reference),
           resolution_note = p_note where id = pay.id;
  else
    perform app.raise('invalid_action');
  end if;
  perform app.admin_audit('admin.payment_' || p_action, 'online_payment', pay.id::text, pay.business_id,
                          jsonb_build_object('note', p_note, 'reference', p_reference, 'trans_id', pay.trans_id));
end $$;

create or replace function public.admin_market_balances() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t order by t.balance desc) from (
    select s.business_id, s.name store_name, s.slug, s.phone, s.whatsapp,
           coalesce((select sum(amount) from public.market_ledger l where l.business_id = s.business_id), 0) balance,
           (select coalesce(sum(total), 0) from public.market_orders o where o.business_id = s.business_id and o.payment_method = 'online'
             and o.payment_status = 'paid' and o.status in ('pending', 'confirmed', 'processing', 'dispatched')) held_undelivered,
           (select max(created_at) from public.market_ledger l where l.business_id = s.business_id and l.kind = 'payout') last_payout_at
      from public.stores s
     where exists (select 1 from public.market_ledger l where l.business_id = s.business_id)
        or exists (select 1 from public.market_orders o where o.business_id = s.business_id and o.payment_method = 'online')) t), '[]'::jsonb);
end $$;

create or replace function public.admin_market_ledger(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object('order_number', o.number) order by l.created_at desc)
    from (select * from public.market_ledger where business_id = p_business order by created_at desc limit 300) l
    left join public.market_orders o on o.id = l.order_id), '[]'::jsonb);
end $$;

-- Records money BizPilot sent to a seller (positive amount), or a correction (kind 'adjustment', signed).
create or replace function public.admin_market_record_payout(p_business uuid, p_amount numeric, p_method text, p_reference text,
  p_note text default null, p_kind text default 'payout') returns bigint
language plpgsql security definer set search_path = public as $$
declare lid bigint;
begin
  perform app.require_platform_admin();
  if p_kind not in ('payout', 'adjustment') then perform app.raise('invalid_request'); end if;
  if p_amount is null or p_amount = 0 or (p_kind = 'payout' and p_amount < 0) then perform app.raise('invalid_amount'); end if;
  if coalesce(btrim(p_reference), '') = '' then perform app.raise('reference_required'); end if;
  if p_kind = 'adjustment' and coalesce(btrim(p_note), '') = '' then perform app.raise('reason_required'); end if;
  if not exists (select 1 from public.stores where business_id = p_business) then perform app.raise('not_found'); end if;
  insert into public.market_ledger (business_id, kind, amount, method, reference, note, created_by)
  values (p_business, p_kind, case when p_kind = 'payout' then -abs(p_amount) else p_amount end, nullif(p_method, ''),
          btrim(p_reference), nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into lid;
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (p_business, 'market_payout', 'success', jsonb_build_object('amount', abs(p_amount), 'reference', p_reference, 'kind', p_kind),
          '/app/payments', 'cash.manage');
  perform app.admin_audit('admin.' || p_kind || '_recorded', 'market_ledger', lid::text, p_business,
                          jsonb_build_object('amount', p_amount, 'method', p_method, 'reference', p_reference, 'note', p_note));
  return lid;
end $$;

create or replace function public.admin_market_block(p_kind text, p_value text, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v text; bid uuid;
begin
  perform app.require_platform_admin();
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  v := case p_kind when 'phone' then app.norm_phone(p_value) when 'email' then lower(btrim(p_value))
                   when 'user' then app.try_uuid(p_value)::text end;
  if v is null then perform app.raise('invalid_request'); end if;
  insert into public.market_blocklist (kind, value, reason, created_by) values (p_kind, v, btrim(p_reason), auth.uid())
  on conflict (kind, value) do update set reason = excluded.reason returning id into bid;
  perform app.admin_audit('admin.contact_blocked', 'market_blocklist', bid::text, null, jsonb_build_object('kind', p_kind, 'reason', p_reason));
  return bid;
end $$;

create or replace function public.admin_market_unblock(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  delete from public.market_blocklist where id = p_id;
  perform app.admin_audit('admin.contact_unblocked', 'market_blocklist', p_id::text, null, null);
end $$;

create or replace function public.admin_market_hide_review(p_review uuid, p_hidden boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.market_reviews;
begin
  perform app.require_platform_admin();
  update public.market_reviews set status = case when p_hidden then 'hidden' else 'visible' end,
         hidden_reason = case when p_hidden then p_reason end where id = p_review returning * into r;
  if not found then perform app.raise('not_found'); end if;
  perform app.refresh_store_rating(r.business_id);
  perform app.admin_audit(case when p_hidden then 'admin.review_hidden' else 'admin.review_restored' end, 'market_review',
                          p_review::text, r.business_id, jsonb_build_object('reason', p_reason));
end $$;

create or replace function public.admin_market_reviews(p_search text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select r.id, r.rating, r.comment, r.author_name, r.status, r.hidden_reason, r.created_at, p.name product_name, s.name store_name
      from public.market_reviews r join public.products p on p.id = r.product_id join public.stores s on s.business_id = r.business_id
     where p_search is null or r.comment ilike app.like_term(p_search) or s.name ilike app.like_term(p_search) or p.name ilike app.like_term(p_search)
     order by r.created_at desc limit 200) t), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.market_ledger enable row level security;
alter table public.online_payments enable row level security;
create policy market_ledger_read on public.market_ledger for select
  using (app.has_perm(business_id, 'cash.manage') or app.is_platform_admin());
create policy online_payments_read on public.online_payments for select
  using ((kind = 'order' and (app.has_perm(business_id, 'orders.manage') or app.has_perm(business_id, 'cash.manage')))
         or (kind = 'subscription' and app.has_perm(business_id, 'billing.manage'))
         or app.is_platform_admin());

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------
-- Tables: anonymous visitors never read marketplace tables directly (only through the functions above).
revoke all on public.stores, public.store_delivery_zones, public.market_promotions, public.market_orders,
  public.market_order_lines, public.market_order_events, public.stock_reservations, public.market_reviews,
  public.market_reports, public.customer_addresses, public.market_favorites, public.market_store_follows,
  public.market_blocklist, public.market_ledger, public.online_payments from anon;
revoke insert, update, delete, truncate, references, trigger on public.stores, public.store_delivery_zones,
  public.market_promotions, public.market_orders, public.market_order_lines, public.market_order_events,
  public.stock_reservations, public.market_reviews, public.market_reports, public.market_blocklist,
  public.market_ledger, public.online_payments from authenticated;
grant select on public.stores, public.store_delivery_zones, public.market_promotions, public.market_orders,
  public.market_order_lines, public.market_order_events, public.stock_reservations, public.market_reviews,
  public.market_reports, public.market_blocklist, public.market_ledger, public.online_payments to authenticated;

-- Internal helpers: not callable through the API.
revoke execute on function app.market_cancel(uuid, text, text) from public, anon, authenticated;
revoke execute on function app.market_expire() from public, anon, authenticated;
revoke execute on function app.market_order_to_sale(uuid, text, text) from public, anon, authenticated;
revoke execute on function app.market_try_reopen(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function app.activate_fapshi_subscription(uuid) from public, anon, authenticated;
revoke execute on function app.refresh_store_rating(uuid) from public, anon, authenticated;
revoke execute on function app.admin_audit(text, text, text, uuid, jsonb) from public, anon, authenticated;
revoke execute on function app.order_for_customer(uuid, text, boolean) from public, anon, authenticated;
-- Helpers used inside RLS policies, triggers and public functions.
grant execute on function app.listing_public(uuid), app.listing_of(uuid), app.store_is_live(uuid), app.reserved_qty(uuid, uuid),
  app.listing_within_limit(uuid, timestamptz, uuid), app.market_config(), app.norm_phone(text), app.products_market_guard(),
  app.customer_addresses_guard(), app.storefront_can_write(text), app.storage_can_write(text), app.usage_count(uuid, text)
  to anon, authenticated;

-- Public (anonymous) marketplace functions.
revoke execute on function public.market_config_public(), public.market_search(jsonb), public.market_home(text),
  public.market_store(text), public.market_product(uuid), public.market_products_by_ids(uuid[]), public.market_store_cards(uuid[]),
  public.market_quote(jsonb), public.market_place_order(jsonb), public.market_order_view(uuid, text),
  public.market_order_customer_action(uuid, text, text, text), public.market_submit_review(uuid, text, uuid, int, text),
  public.market_report(jsonb), public.market_payment_begin(uuid, text), public.online_payment_status(uuid),
  public.store_slug_available(text, uuid) from public;
grant execute on function public.market_config_public(), public.market_search(jsonb), public.market_home(text),
  public.market_store(text), public.market_product(uuid), public.market_products_by_ids(uuid[]), public.market_store_cards(uuid[]),
  public.market_quote(jsonb), public.market_place_order(jsonb), public.market_order_view(uuid, text),
  public.market_order_customer_action(uuid, text, text, text), public.market_submit_review(uuid, text, uuid, int, text),
  public.market_report(jsonb), public.market_payment_begin(uuid, text), public.online_payment_status(uuid),
  public.store_slug_available(text, uuid) to anon, authenticated;

-- Signed-in functions (sellers, customers, administrators).
revoke execute on function public.market_my_orders(int, int), public.market_claim_orders(jsonb),
  public.store_save(uuid, jsonb), public.store_save_zones(uuid, jsonb), public.store_readiness(uuid),
  public.store_set_published(uuid, boolean), public.store_request_verification(uuid, text),
  public.products_set_online(uuid, uuid[], boolean), public.promo_save(uuid, jsonb), public.market_review_reply(uuid, text),
  public.market_order_action(uuid, text, jsonb), public.seller_market_summary(uuid), public.seller_payments_summary(uuid),
  public.billing_fapshi_begin(uuid, text, text), public.admin_set_config(text, jsonb), public.admin_market_overview(),
  public.admin_market_stores(text, text), public.admin_market_store_update(uuid, jsonb),
  public.admin_market_listings(text, boolean, int, int), public.admin_market_hide_product(uuid, boolean, text),
  public.admin_market_reports(text), public.admin_market_report_update(uuid, text, text),
  public.admin_market_orders(text, text, int, int), public.admin_market_order(uuid),
  public.admin_market_order_action(uuid, text, jsonb), public.admin_market_payments(text),
  public.admin_market_payment_resolve(uuid, text, text, text), public.admin_market_balances(), public.admin_market_ledger(uuid),
  public.admin_market_record_payout(uuid, numeric, text, text, text, text), public.admin_market_block(text, text, text),
  public.admin_market_unblock(uuid), public.admin_market_hide_review(uuid, boolean, text), public.admin_market_reviews(text)
  from public, anon;
grant execute on function public.market_my_orders(int, int), public.market_claim_orders(jsonb),
  public.store_save(uuid, jsonb), public.store_save_zones(uuid, jsonb), public.store_readiness(uuid),
  public.store_set_published(uuid, boolean), public.store_request_verification(uuid, text),
  public.products_set_online(uuid, uuid[], boolean), public.promo_save(uuid, jsonb), public.market_review_reply(uuid, text),
  public.market_order_action(uuid, text, jsonb), public.seller_market_summary(uuid), public.seller_payments_summary(uuid),
  public.billing_fapshi_begin(uuid, text, text), public.admin_set_config(text, jsonb), public.admin_market_overview(),
  public.admin_market_stores(text, text), public.admin_market_store_update(uuid, jsonb),
  public.admin_market_listings(text, boolean, int, int), public.admin_market_hide_product(uuid, boolean, text),
  public.admin_market_reports(text), public.admin_market_report_update(uuid, text, text),
  public.admin_market_orders(text, text, int, int), public.admin_market_order(uuid),
  public.admin_market_order_action(uuid, text, jsonb), public.admin_market_payments(text),
  public.admin_market_payment_resolve(uuid, text, text, text), public.admin_market_balances(), public.admin_market_ledger(uuid),
  public.admin_market_record_payout(uuid, numeric, text, text, text, text), public.admin_market_block(text, text, text),
  public.admin_market_unblock(uuid), public.admin_market_hide_review(uuid, boolean, text), public.admin_market_reviews(text)
  to authenticated;

-- Service role only (the Fapshi edge function).
revoke execute on function public.fapshi_attach(uuid, text, text), public.fapshi_payment_lookup(uuid),
  public.fapshi_apply(text, jsonb) from public, anon, authenticated;
grant execute on function public.fapshi_attach(uuid, text, text), public.fapshi_payment_lookup(uuid),
  public.fapshi_apply(text, jsonb) to service_role;

commit;
