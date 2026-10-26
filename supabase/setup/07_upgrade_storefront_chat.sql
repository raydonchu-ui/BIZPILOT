-- BizPilot upgrade: check_before_07 20261027000100_storefront 20261027000200_shopper_cities 20261027000300_messaging 
-- Paste into Supabase Dashboard -> SQL Editor -> New query, then Run. Run it ONCE.
-- Adds features only: existing businesses, products, sales and users are not changed.
begin;

-- ===== check_before_07.sql =====
do $$
begin
  if to_regclass('public.stores') is null or to_regclass('public.business_members') is null
     or to_regprocedure('app.has_perm(uuid,text)') is null or to_regprocedure('app.rate_limit(text,integer,integer)') is null then
    raise exception 'Run 06_upgrade_direct_trade.sql (and the earlier upgrades) first, then run this file again.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'products' and column_name = 'online_published') then
    raise exception 'The online store (products.online_published) is missing. Run 05_upgrade_marketplace.sql first.';
  end if;
end $$;

-- ===== 20261027000100_storefront.sql =====
create or replace function app.product_card(p_listing uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', p.id, 'name', p.name, 'brand', p.brand,
    'image', p.online_images[1], 'unit', p.base_unit,
    'price', o.min_price, 'max_price', o.max_price, 'compare_at_price',
      case when p.compare_at_price > o.min_price then p.compare_at_price end,
    'available', least(o.available, 99), 'options', o.n,
    'stock', case when coalesce(o.available, 0) <= 0 then 'out'
                  when coalesce(p.min_stock, 0) > 0 and o.available <= p.min_stock then 'low'
                  else 'in' end,
    'category', c.name, 'subcategory', p.subcategory,
    'condition', p.condition, 'sold', p.single_item and coalesce(o.available, 0) <= 0,
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

-- ===== 20261027000200_shopper_cities.sql =====
create or replace function app.city_key(p text) returns text
language sql immutable as $$
  select regexp_replace(lower(translate(coalesce(p, ''),
    'ÀÂÄàâäÇçÉÈÊËéèêëÎÏîïÔÖôöÙÛÜùûüŸÿ', 'AAAaaaCcEEEEeeeeIIiiOOooUUUuuuYy')), '[^a-z0-9]', '', 'g')
$$;
create index if not exists stores_city_key on public.stores (app.city_key(city));
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
  minr numeric := nullif(p ->> 'min_rating', '')::numeric;
  instock boolean := coalesce((p ->> 'in_stock')::boolean, false);
  v_delivery boolean := coalesce((p ->> 'delivery')::boolean, false);
  v_cond text := nullif(p ->> 'condition', '');
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
       and not (pr.single_item and coalesce(o.available, 0) <= 0)
       and (q is null or pr.name ilike app.like_term(q) or pr.brand ilike app.like_term(q)
            or pr.description ilike app.like_term(q) or c.name ilike app.like_term(q)
            or pr.subcategory ilike app.like_term(q) or s.name ilike app.like_term(q))
       and (v_type is null or b.category = v_type)
       and (v_cat is null or lower(c.name) = lower(v_cat) or lower(pr.subcategory) = lower(v_cat))
       and (v_store is null or lower(s.slug) = v_store)
       and (v_city is null or app.city_key(s.city) = app.city_key(v_city) or app.city_key(s.region) = app.city_key(v_city))
       and (minp is null or o.min_price >= minp)
       and (maxp is null or o.min_price <= maxp)
       and (minr is null or coalesce(r.avg, 0) >= minr)
       and (not instock or o.available > 0)
       and (not v_delivery or exists (select 1 from public.store_delivery_zones z where z.business_id = s.business_id and z.active))
       and (v_cond is null or pr.condition = v_cond)
  ), ranked as (
    select id, row_number() over (
             order by case when v_sort = 'relevance' then rel end desc nulls last,
                      case when v_sort = 'price_asc' then min_price end asc nulls last,
                      case when v_sort = 'price_desc' then min_price end desc nulls last,
                      case when v_sort = 'rating' then rating end desc nulls last,
                      case when v_sort = 'newest' then online_since end desc nulls last,
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
declare ck text := app.city_key(p_city);
begin
  return jsonb_build_object(
    'types', coalesce((select jsonb_agg(jsonb_build_object('type', t.category, 'products', t.n) order by t.n desc) from (
                  select b.category, count(*) n from public.products pr
                    join public.stores s on s.business_id = pr.business_id and s.status = 'published'
                    join public.businesses b on b.id = pr.business_id and b.status = 'active'
                   where pr.online_published and pr.status = 'active' and not pr.admin_hidden and pr.variant_of is null
                     and (p_city is null or app.city_key(s.city) = ck or app.city_key(s.region) = ck)
                   group by b.category) t), '[]'::jsonb),
    'stores', coalesce((select jsonb_agg(app.store_card(x.business_id)) from (
                  select s.business_id from public.stores s join public.businesses b on b.id = s.business_id
                   where s.status = 'published' and b.status = 'active'
                     and (p_city is null or app.city_key(s.city) = ck or app.city_key(s.region) = ck)
                   order by (s.verification = 'verified') desc, s.rating_count desc, s.published_at desc limit 12) x), '[]'::jsonb),
    'cities', coalesce((select jsonb_agg(jsonb_build_object('city', x.c, 'shops', x.n) order by x.n desc, x.c) from (
                  select min(btrim(s.city)) c, count(*) n from public.stores s join public.businesses b on b.id = s.business_id
                   where s.status = 'published' and b.status = 'active' and coalesce(btrim(s.city), '') <> ''
                   group by app.city_key(s.city)) x), '[]'::jsonb),
    'city_shops', (select count(*) from public.stores s join public.businesses b on b.id = s.business_id
                    where s.status = 'published' and b.status = 'active'
                      and (p_city is null or app.city_key(s.city) = ck or app.city_key(s.region) = ck)),
    'city_products', (select count(*) from public.products pr
                        join public.stores s on s.business_id = pr.business_id and s.status = 'published'
                        join public.businesses b on b.id = pr.business_id and b.status = 'active'
                       where pr.online_published and pr.status = 'active' and not pr.admin_hidden and pr.variant_of is null
                         and (p_city is null or app.city_key(s.city) = ck or app.city_key(s.region) = ck)),
    'latest', (public.market_search(jsonb_build_object('sort', 'newest', 'page_size', 12, 'city', p_city)) -> 'items'));
end $$;
create or replace function public.market_shops(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_city text := nullif(btrim(coalesce(p ->> 'city', '')), '');
  v_type text := nullif(p ->> 'type', '');
  v_q text := nullif(btrim(coalesce(p ->> 'q', '')), '');
  size int := least(greatest(coalesce((p ->> 'page_size')::int, 24), 1), 60);
  pg int := greatest(coalesce((p ->> 'page')::int, 1), 1);
  res jsonb;
begin
  with base as (
    select s.business_id, s.name, s.verification, s.rating_count, s.published_at
      from public.stores s join public.businesses b on b.id = s.business_id
     where s.status = 'published' and b.status = 'active'
       and (v_city is null or app.city_key(s.city) = app.city_key(v_city) or app.city_key(s.region) = app.city_key(v_city))
       and (v_type is null or b.category = v_type)
       and (v_q is null or s.name ilike app.like_term(v_q) or s.tagline ilike app.like_term(v_q))
  ), ranked as (
    select business_id, row_number() over (order by (verification = 'verified') desc, rating_count desc, published_at desc, name) ord
      from base
  )
  select jsonb_build_object(
    'total', (select count(*) from base), 'page', pg, 'page_size', size,
    'items', coalesce((select jsonb_agg(app.store_card(r.business_id) order by r.ord) from ranked r
                        where r.ord > (pg - 1) * size and r.ord <= pg * size), '[]'::jsonb))
    into res;
  return res;
end $$;
create or replace function public.buyer_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  return jsonb_build_object(
    'orders', (select jsonb_build_object(
        'pending', count(*) filter (where status = 'pending'),
        'processing', count(*) filter (where status in ('confirmed', 'processing')),
        'shipped', count(*) filter (where status = 'dispatched'),
        'delivered', count(*) filter (where status = 'delivered'))
      from public.market_orders where customer_user_id = uid),
    'favorites', (select count(*) from public.market_favorites where user_id = uid),
    'followed_shops', (select count(*) from public.market_store_follows where user_id = uid));
end $$;
revoke all on function public.market_shops(jsonb), public.buyer_dashboard() from public;
grant execute on function public.market_shops(jsonb) to anon, authenticated;
grant execute on function public.buyer_dashboard() to authenticated;
revoke all on function app.city_key(text) from public;
grant execute on function app.city_key(text) to anon, authenticated;

-- ===== 20261027000300_messaging.sql =====
create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  buyer_id uuid not null references auth.users (id) on delete cascade,
  product_id uuid references public.products (id) on delete set null,
  product_name text,
  buyer_name text not null default 'Customer' check (length(buyer_name) <= 120),
  buyer_read_at timestamptz not null default now(),
  seller_read_at timestamptz not null default '-infinity',
  last_message_at timestamptz not null default now(),
  last_message_preview text,
  created_at timestamptz not null default now()
);
create unique index conversations_thread on public.conversations (buyer_id, business_id,
  (coalesce(product_id, '00000000-0000-0000-0000-000000000000'::uuid)));
create index conversations_business on public.conversations (business_id, last_message_at desc);
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  sender_id uuid not null references auth.users (id) on delete cascade,
  side text not null check (side in ('buyer', 'seller')),
  body text not null check (length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index messages_thread on public.messages (conversation_id, created_at);
create table public.inbox_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null default 'message' check (kind in ('message')),
  conversation_id uuid references public.conversations (id) on delete cascade,
  message_id uuid references public.messages (id) on delete cascade,
  from_name text not null check (length(from_name) <= 120),
  preview text not null check (length(preview) <= 140),
  image_path text,
  link text not null check (length(link) <= 200),
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index inbox_user on public.inbox_notifications (user_id, created_at desc);
create index inbox_unread on public.inbox_notifications (user_id) where read_at is null;
create table public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  endpoint text not null unique check (length(endpoint) <= 2000),
  p256dh text not null check (length(p256dh) <= 200),
  auth text not null check (length(auth) <= 100),
  created_at timestamptz not null default now()
);
create index push_subscriptions_user on public.push_subscriptions (user_id);
alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.inbox_notifications enable row level security;
alter table public.push_subscriptions enable row level security;
create policy conversations_read on public.conversations for select to authenticated
  using (buyer_id = auth.uid() or app.has_perm(business_id, 'orders.manage'));
create policy messages_read on public.messages for select to authenticated
  using (exists (select 1 from public.conversations c where c.id = messages.conversation_id
    and (c.buyer_id = auth.uid() or app.has_perm(c.business_id, 'orders.manage'))));
create policy inbox_read on public.inbox_notifications for select to authenticated
  using (user_id = auth.uid());
create policy push_read on public.push_subscriptions for select to authenticated
  using (user_id = auth.uid());
create policy push_add on public.push_subscriptions for insert to authenticated
  with check (user_id = auth.uid());
create policy push_remove on public.push_subscriptions for delete to authenticated
  using (user_id = auth.uid());
revoke all on public.conversations, public.messages, public.inbox_notifications, public.push_subscriptions from anon, authenticated;
grant select on public.conversations, public.messages, public.inbox_notifications to authenticated;
grant select, insert, delete on public.push_subscriptions to authenticated;
create or replace function app.conversation_side(p_conv uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when c.buyer_id = auth.uid() then 'buyer'
              when app.has_perm(c.business_id, 'orders.manage') then 'seller' end
  from public.conversations c where c.id = p_conv
$$;
create or replace function app.msg_post(p_conv uuid, p_side text, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  c public.conversations;
  v_msg uuid;
  v_uid uuid := auth.uid();
  v_preview text := left(p_body, 140);
  v_image text;
  v_store text;
begin
  select * into c from public.conversations where id = p_conv for update;
  insert into public.messages (conversation_id, sender_id, side, body) values (p_conv, v_uid, p_side, p_body)
    returning id into v_msg;
  update public.conversations set last_message_at = now(), last_message_preview = v_preview,
    buyer_read_at = case when p_side = 'buyer' then now() else buyer_read_at end,
    seller_read_at = case when p_side = 'seller' then now() else seller_read_at end
  where id = p_conv;
  select online_images[1] into v_image from public.products where id = c.product_id;
  if p_side = 'buyer' then
    insert into public.inbox_notifications (user_id, conversation_id, message_id, from_name, preview, image_path, link)
    select m.user_id, p_conv, v_msg, c.buyer_name, v_preview, v_image, '/messages/' || p_conv
    from public.business_members m
    where m.business_id = c.business_id and m.active and m.user_id <> v_uid;
  else
    select coalesce(s.name, b.name) into v_store from public.businesses b
      left join public.stores s on s.business_id = b.id where b.id = c.business_id;
    insert into public.inbox_notifications (user_id, conversation_id, message_id, from_name, preview, image_path, link)
    select c.buyer_id, p_conv, v_msg, coalesce(v_store, 'BizPilot'), v_preview, v_image, '/messages/' || p_conv
    where c.buyer_id <> v_uid;
  end if;
  return v_msg;
end $$;
create or replace function public.msg_start(p_store text, p_product uuid default null, p_body text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  v_biz uuid;
  v_pname text;
  v_name text;
  v_conv uuid;
  v_body text := btrim(coalesce(p_body, ''));
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  perform app.rate_limit('msg:' || uid::text, 60, 600);
  if length(v_body) = 0 then perform app.raise('message_empty'); end if;
  if length(v_body) > 2000 then perform app.raise('message_too_long'); end if;
  select s.business_id into v_biz from public.stores s where s.slug = p_store and s.status = 'published';
  if v_biz is null then perform app.raise('store_not_found'); end if;
  if exists (select 1 from public.business_members m where m.business_id = v_biz and m.user_id = uid) then
    perform app.raise('own_store');
  end if;
  if p_product is not null then
    select p.name into v_pname from public.products p
      where p.id = p_product and p.business_id = v_biz and p.online_published and p.status = 'active';
    if v_pname is null then perform app.raise('product_unavailable'); end if;
  end if;
  select coalesce((select nullif(btrim(pr.full_name), '') from public.profiles pr where pr.id = uid), 'Customer')
    into v_name;
  select c.id into v_conv from public.conversations c
    where c.buyer_id = uid and c.business_id = v_biz and c.product_id is not distinct from p_product;
  if v_conv is null then
    insert into public.conversations (business_id, buyer_id, product_id, product_name, buyer_name, seller_read_at)
      values (v_biz, uid, p_product, v_pname, left(v_name, 120), '-infinity')
      returning id into v_conv;
  end if;
  return jsonb_build_object('conversation_id', v_conv, 'message_id', app.msg_post(v_conv, 'buyer', v_body));
end $$;
create or replace function public.msg_send(p_conversation uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  v_side text;
  v_body text := btrim(coalesce(p_body, ''));
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  perform app.rate_limit('msg:' || uid::text, 60, 600);
  v_side := app.conversation_side(p_conversation);
  if v_side is null then perform app.raise('not_found'); end if;
  if length(v_body) = 0 then perform app.raise('message_empty'); end if;
  if length(v_body) > 2000 then perform app.raise('message_too_long'); end if;
  return jsonb_build_object('conversation_id', p_conversation, 'message_id', app.msg_post(p_conversation, v_side, v_body));
end $$;
create or replace function public.msg_mark_read(p_conversation uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_side text := app.conversation_side(p_conversation);
begin
  if auth.uid() is null then perform app.raise('not_authenticated'); end if;
  if v_side is null then perform app.raise('not_found'); end if;
  update public.conversations set
    buyer_read_at = case when v_side = 'buyer' then now() else buyer_read_at end,
    seller_read_at = case when v_side = 'seller' then now() else seller_read_at end
  where id = p_conversation;
  update public.inbox_notifications set read_at = now()
    where user_id = auth.uid() and conversation_id = p_conversation and read_at is null;
end $$;
create or replace function public.msg_list(p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  return coalesce((
    select jsonb_agg(x order by x.last_message_at desc) from (
      select c.id, c.business_id, s.slug as store_slug, coalesce(s.name, b.name) as store_name, c.buyer_name,
        c.product_id, c.product_name, c.last_message_at, c.last_message_preview,
        case when c.buyer_id = uid then 'buyer' else 'seller' end as side,
        (select count(*)::int from public.messages m where m.conversation_id = c.id
           and m.side <> (case when c.buyer_id = uid then 'buyer' else 'seller' end)
           and m.created_at > (case when c.buyer_id = uid then c.buyer_read_at else c.seller_read_at end)) as unread
      from public.conversations c
      join public.businesses b on b.id = c.business_id
      left join public.stores s on s.business_id = c.business_id
      where c.buyer_id = uid or app.has_perm(c.business_id, 'orders.manage')
      order by c.last_message_at desc
      limit least(greatest(coalesce(p_limit, 50), 1), 100)
    ) x
  ), '[]'::jsonb);
end $$;
create or replace function public.msg_thread(p_conversation uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  v_side text := app.conversation_side(p_conversation);
  r jsonb;
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  if v_side is null then perform app.raise('not_found'); end if;
  select jsonb_build_object('id', c.id, 'side', v_side,
      'store_name', coalesce(s.name, b.name), 'store_slug', s.slug, 'buyer_name', c.buyer_name,
      'counterpart', case when v_side = 'buyer' then coalesce(s.name, b.name) else c.buyer_name end,
      'product', case when p.id is null then null else jsonb_build_object('id', p.id, 'name', p.name,
        'image', p.online_images[1], 'price', (app.product_card(p.id) ->> 'price')::numeric) end)
    into r
    from public.conversations c
    join public.businesses b on b.id = c.business_id
    left join public.stores s on s.business_id = c.business_id
    left join public.products p on p.id = c.product_id
    where c.id = p_conversation;
  return r;
end $$;
create or replace function public.msg_unread() returns int
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then 0 else (
    select count(*)::int from public.conversations c
    where (c.buyer_id = auth.uid() and exists (select 1 from public.messages m
             where m.conversation_id = c.id and m.side = 'seller' and m.created_at > c.buyer_read_at))
       or (c.buyer_id <> auth.uid() and app.has_perm(c.business_id, 'orders.manage')
             and exists (select 1 from public.messages m
             where m.conversation_id = c.id and m.side = 'buyer' and m.created_at > c.seller_read_at)))
  end
$$;
create or replace function public.inbox_mark_read(p_ids uuid[] default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then perform app.raise('not_authenticated'); end if;
  update public.inbox_notifications set read_at = now()
    where user_id = auth.uid() and read_at is null and (p_ids is null or id = any(p_ids));
end $$;
revoke all on function app.conversation_side(uuid), app.msg_post(uuid, text, text) from public;
revoke all on function public.msg_start(text, uuid, text), public.msg_send(uuid, text), public.msg_mark_read(uuid),
  public.msg_list(int), public.msg_thread(uuid), public.msg_unread(), public.inbox_mark_read(uuid[]) from public, anon;
grant execute on function public.msg_start(text, uuid, text), public.msg_send(uuid, text), public.msg_mark_read(uuid),
  public.msg_list(int), public.msg_thread(uuid), public.msg_unread(), public.inbox_mark_read(uuid[]) to authenticated;
do $$
begin
  alter publication supabase_realtime add table public.messages, public.inbox_notifications;
exception
  when duplicate_object then null;
  when undefined_object then null;
end $$;

commit;
