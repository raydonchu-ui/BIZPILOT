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
