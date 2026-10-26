-- BizPilot setup PART 19 of 20. Run parts in order.
begin;
alter table public.business_settings add column if not exists alert_settings jsonb not null default '{}'::jsonb;
alter table public.business_settings drop constraint if exists business_settings_alert_settings_check;
alter table public.business_settings add constraint business_settings_alert_settings_check
  check (jsonb_typeof(alert_settings) = 'object' and pg_column_size(alert_settings) <= 2048);
create or replace function public.save_alert_settings(p_business uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  perform app.require_perm(p_business, 'settings.manage');
  v := jsonb_build_object(
    'fast_selling_days', least(greatest(coalesce((p ->> 'fast_selling_days')::int, 7), 3), 60),
    'large_adjustment_value', greatest(coalesce((p ->> 'large_adjustment_value')::numeric, 50000), 0),
    'order_wait_hours', least(greatest(coalesce((p ->> 'order_wait_hours')::int, 2), 1), 72),
    'disabled', coalesce((select jsonb_agg(x) from jsonb_array_elements_text(coalesce(p -> 'disabled', '[]'::jsonb)) x
                           where x in ('out_of_stock', 'low_stock', 'expiring_soon', 'fast_selling', 'customer_overdue',
                                       'orders_waiting', 'payment_to_confirm', 'large_adjustment', 'possible_duplicate_sale')), '[]'::jsonb));
  update public.business_settings set alert_settings = v, updated_at = now() where business_id = p_business;
  perform app.audit(p_business, 'settings.alerts', 'business', p_business::text, v);
  return v;
end $$;
create or replace function app.build_alerts(p_business uuid)
returns int language plpgsql security definer set search_path = public as $$
declare today date; n int := 0; c int; st public.business_settings; sub jsonb; r record; added int;
        al jsonb; off jsonb; fast int; big numeric; wait_h int;
begin
  today := app.biz_today(p_business);
  select * into st from public.business_settings where business_id = p_business;
  al := coalesce(st.alert_settings, '{}'::jsonb);
  off := coalesce(al -> 'disabled', '[]'::jsonb);
  fast := coalesce((al ->> 'fast_selling_days')::int, 7);
  big := coalesce((al ->> 'large_adjustment_value')::numeric, 50000);
  wait_h := coalesce((al ->> 'order_wait_hours')::int, 2);
  if not off ? 'out_of_stock' then
    select count(*) into c from public.products where business_id = p_business and status = 'active'
       and qty_on_hand <= 0 and exists (select 1 from public.stock_movements m where m.product_id = products.id);
    if c > 0 then
      insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
      values (p_business, 'out_of_stock', 'critical', jsonb_build_object('count', c), '/app/inventory?filter=out',
              'out_of_stock:' || today) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;
  if not off ? 'low_stock' then
    select count(*) into c from public.products where business_id = p_business and status = 'active'
       and qty_on_hand > 0 and qty_on_hand <= greatest(min_stock, 0) and min_stock > 0;
    if c > 0 then
      insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
      values (p_business, 'low_stock', 'warning', jsonb_build_object('count', c), '/app/inventory?filter=low',
              'low_stock:' || today) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;
  if not off ? 'fast_selling' then
    select count(*) into c from (
      select pr.id from public.products pr
        join public.stock_movements m on m.product_id = pr.id and m.movement_type = 'sale'
         and m.occurred_at >= now() - interval '14 days'
       where pr.business_id = p_business and pr.status = 'active' and pr.qty_on_hand > 0
       group by pr.id, pr.qty_on_hand
      having pr.qty_on_hand / nullif(-sum(m.quantity) / 14.0, 0) < fast) t;
    if c > 0 then
      insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
      values (p_business, 'fast_selling', 'warning', jsonb_build_object('count', c, 'days', fast), '/app/reports?tab=restock',
              'fast_selling:' || today) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;
  if not off ? 'expiring_soon' then
    select count(*), min(expiry_date) into r from public.stock_batches
     where business_id = p_business and remaining_qty > 0 and expiry_date <= today + st.expiry_alert_days;
    if r.count > 0 then
      insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
      values (p_business, 'expiring_soon', 'warning', jsonb_build_object('count', r.count, 'first_expiry', r.min),
              '/app/inventory?tab=expiry', 'expiring:' || today) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
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
  if not off ? 'customer_overdue' then
    select count(*), coalesce(sum(s.total - s.returned_total + s.refunded_total - s.paid_total), 0) into r
      from public.sales s where s.business_id = p_business and s.customer_id is not null
       and s.due_date is not null and s.due_date < today and s.total - s.returned_total + s.refunded_total - s.paid_total > 0;
    if r.count > 0 then
      insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
      values (p_business, 'customer_overdue', 'warning', jsonb_build_object('count', r.count, 'amount', r.coalesce),
              '/app/customers?filter=overdue', 'customers.credit', 'customer_overdue:' || today) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;
  if not off ? 'orders_waiting' then
    select count(*) into c from public.market_orders where business_id = p_business
       and ((status = 'pending' and created_at < now() - make_interval(hours => wait_h))
            or (status in ('confirmed', 'processing') and coalesce(confirmed_at, created_at) < now() - interval '24 hours'));
    if c > 0 then
      insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
      values (p_business, 'orders_waiting', 'warning', jsonb_build_object('count', c), '/app/orders', 'orders.manage',
              'orders_waiting:' || today || ':' || c) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;
  if not off ? 'payment_to_confirm' then
    select count(*) into c from public.market_orders where business_id = p_business and payment_method = 'momo_direct'
       and payment_status = 'cod_pending' and buyer_payment_reported_at is not null
       and status in ('pending', 'confirmed', 'processing', 'dispatched');
    if c > 0 then
      insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
      values (p_business, 'payment_to_confirm', 'warning', jsonb_build_object('count', c), '/app/orders', 'orders.manage',
              'payment_to_confirm:' || today || ':' || c) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;
  if not off ? 'large_adjustment' and big > 0 then
    select count(*) into c from public.stock_movements where business_id = p_business
       and movement_type in ('damaged', 'expired', 'missing', 'found', 'correction', 'count')
       and occurred_at >= now() - interval '24 hours' and abs(value) >= big;
    if c > 0 then
      insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
      values (p_business, 'large_adjustment', 'warning', jsonb_build_object('count', c, 'threshold', big),
              '/app/inventory?tab=movements', 'stock.adjust', 'large_adjustment:' || today) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;
  if not off ? 'possible_duplicate_sale' then
    select count(*) into c from public.sales a join public.sales b2 on b2.business_id = a.business_id and b2.id > a.id
       and b2.total = a.total and b2.customer_id is not distinct from a.customer_id
       and abs(extract(epoch from b2.sold_at - a.sold_at)) <= 180
       and b2.cancelled_at is null and a.cancelled_at is null
       and (select array_agg(product_id order by product_id) from public.sale_lines where sale_id = a.id)
           = (select array_agg(product_id order by product_id) from public.sale_lines where sale_id = b2.id)
     where a.business_id = p_business and a.sold_at >= now() - interval '24 hours';
    if c > 0 then
      insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
      values (p_business, 'possible_duplicate_sale', 'warning', jsonb_build_object('count', c), '/app/sales', 'sales.view',
              'dup_sale:' || today || ':' || c) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
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
revoke all on function app.build_alerts(uuid) from public, anon, authenticated;
revoke all on function public.record_sale(uuid, jsonb), public.cancel_sale(uuid, text, boolean, text, uuid),
  public.sales_by_channel(uuid, date, date), public.store_save_payments(uuid, jsonb), public.save_alert_settings(uuid, jsonb),
  public.market_order_report_payment(uuid, text, text)
  from public, anon;
grant execute on function public.record_sale(uuid, jsonb), public.cancel_sale(uuid, text, boolean, text, uuid),
  public.sales_by_channel(uuid, date, date), public.store_save_payments(uuid, jsonb), public.save_alert_settings(uuid, jsonb)
  to authenticated;
grant execute on function public.market_order_report_payment(uuid, text, text) to anon, authenticated;
revoke all on function app.sales_channel_default() from public, anon, authenticated;
revoke all on function app.stores_no_online_payment() from public, anon, authenticated;
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
commit;
