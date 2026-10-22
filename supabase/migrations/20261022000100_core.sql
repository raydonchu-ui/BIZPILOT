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
