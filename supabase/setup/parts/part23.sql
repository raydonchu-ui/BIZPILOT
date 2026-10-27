-- BizPilot setup PART 23 of 23. Run parts in order.
begin;
create or replace function public.market_store(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.stores; b public.businesses; custom boolean;
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
    'business_type', b.category, 'city', s.city, 'region', s.region, 'neighborhood', s.neighborhood, 'service_area', s.service_area,
    'address', case when s.show_address then s.address end,
    'phone', case when s.show_phone then s.phone end,
    'whatsapp', case when s.show_whatsapp then s.whatsapp end,
    'email', case when s.show_email then s.email end,
    'facebook_url', s.facebook_url, 'instagram_url', s.instagram_url, 'tiktok_url', s.tiktok_url,
    'opening_hours', s.opening_hours, 'hours_note', s.hours_note, 'delivery_note', s.delivery_note,
    'pickup_enabled', s.pickup_enabled, 'pickup_note', s.pickup_note, 'cod_enabled', s.cod_enabled,
    'online_payment_enabled', false,
    'momo_direct_enabled', s.momo_direct_enabled and coalesce(s.momo_mtn_number, s.momo_orange_number) is not null,
    'momo_networks', array_remove(array[case when s.momo_direct_enabled and s.momo_mtn_number is not null then 'mtn' end,
                                        case when s.momo_direct_enabled and s.momo_orange_number is not null then 'orange' end], null),
    'payment_note', s.payment_note, 'return_policy', s.return_policy,
    'min_order_amount', s.min_order_amount, 'currency', b.currency,
    'verified', app.blue_tick(s.business_id), 'rating_avg', s.rating_avg, 'rating_count', s.rating_count,
    'joined', s.published_at,
    'zones', coalesce((select jsonb_agg(jsonb_build_object('id', z.id, 'name', z.name, 'fee', z.fee, 'eta', z.eta, 'regions', z.regions, 'localities', z.localities) order by z.sort, z.name)
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
    select business_id, row_number() over (order by app.blue_tick(business_id) desc, rating_count desc, published_at desc, name) ord
      from base
  )
  select jsonb_build_object(
    'total', (select count(*) from base), 'page', pg, 'page_size', size,
    'items', coalesce((select jsonb_agg(app.store_card(r.business_id) order by r.ord) from ranked r
                        where r.ord > (pg - 1) * size and r.ord <= pg * size), '[]'::jsonb))
    into res;
  return res;
end $$;
commit;
