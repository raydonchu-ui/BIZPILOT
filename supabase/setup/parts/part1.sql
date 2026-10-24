-- BizPilot setup PART 1 of 11. Run parts in order.
begin;
create schema if not exists app;
grant usage on schema app to anon, authenticated, service_role;
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
commit;
