-- Shopper upgrade: cities. Every city filter compares a normalised city key, so "Yaounde",
-- "yaoundé" and "YAOUNDÉ" select the same shops and products. A buyer's city choice filters shops,
-- products and categories in the marketplace, the shop list and the shopper dashboard.

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


-- Marketplace home for a chosen city (null = all of Cameroon). Shop and product counts come from the
-- database, so the banner and category counts always match what the buyer will see.
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

-- Shop list (cards), filtered by city, business type and name. Same paging rules as market_search.
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

-- The shopper's own numbers for the dashboard: orders by stage, favourites and followed shops.
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
