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
