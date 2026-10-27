-- BizPilot setup PART 12 of 21. Run parts in order.
begin;
create or replace function app.listing_within_limit(bid uuid, since timestamptz, pid uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare lim numeric := app.plan_limit(bid, 'max_online_products');
begin
  if lim is null then return true; end if;
  return (select count(*) from public.products p where p.business_id = bid and p.online_published
            and p.status = 'active' and p.variant_of is null and (p.online_since, p.id) < (since, pid)) < lim;
end $$;
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
create or replace function app.reserved_qty(p_product uuid, p_exclude_order uuid default null) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(quantity), 0) from public.stock_reservations
   where product_id = p_product and released_at is null and consumed_at is null
     and (expires_at is null or expires_at > now())
     and (p_exclude_order is null or order_id <> p_exclude_order)
$$;
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
create or replace function app.store_is_live(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.stores s join public.businesses b on b.id = s.business_id
                 where s.business_id = bid and s.status = 'published' and b.status = 'active')
$$;
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
commit;
