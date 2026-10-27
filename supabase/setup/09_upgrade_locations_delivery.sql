-- BizPilot upgrade: check_before_09 20261027000500_locations_delivery 
-- Paste into Supabase Dashboard -> SQL Editor -> New query, then Run. Run it ONCE.
-- Adds features only: existing businesses, products, sales and users are not changed.
begin;

-- ===== check_before_09.sql =====
do $$
begin
  if to_regprocedure('app.city_key(text)') is null or to_regprocedure('public.market_store(text)') is null
     or to_regclass('public.store_delivery_zones') is null or to_regclass('public.profiles') is null then
    raise exception 'Run 07_upgrade_storefront_chat.sql (and 08_upgrade_profile_photos.sql) first, then run this file again.';
  end if;
end $$;

-- ===== 20261027000500_locations_delivery.sql =====
create table if not exists public.cameroon_regions (
  code text primary key check (code ~ '^[a-z_]+$'),
  name_en text not null,
  name_fr text not null,
  sort int not null
);
insert into public.cameroon_regions (code, name_en, name_fr, sort) values
  ('adamawa', 'Adamawa', 'Adamaoua', 1),
  ('centre', 'Centre', 'Centre', 2),
  ('east', 'East', 'Est', 3),
  ('far_north', 'Far North', 'Extrême-Nord', 4),
  ('littoral', 'Littoral', 'Littoral', 5),
  ('north', 'North', 'Nord', 6),
  ('northwest', 'Northwest', 'Nord-Ouest', 7),
  ('south', 'South', 'Sud', 8),
  ('southwest', 'Southwest', 'Sud-Ouest', 9),
  ('west', 'West', 'Ouest', 10)
on conflict (code) do update set name_en = excluded.name_en, name_fr = excluded.name_fr, sort = excluded.sort;
create table if not exists public.cameroon_localities (
  id uuid primary key default gen_random_uuid(),
  region_code text not null references public.cameroon_regions (code),
  name text not null check (length(btrim(name)) between 2 and 80),
  key text generated always as (app.city_key(name)) stored,
  active boolean not null default true,
  sort int not null default 0,
  unique (region_code, key)
);
create index if not exists cameroon_localities_key on public.cameroon_localities (key);
insert into public.cameroon_localities (region_code, name, sort) values
  ('adamawa', 'Ngaoundéré', 1),
  ('adamawa', 'Meiganga', 2),
  ('adamawa', 'Tibati', 3),
  ('adamawa', 'Ngaoundal', 4),
  ('centre', 'Akonolinga', 1),
  ('centre', 'Ayos', 2),
  ('centre', 'Bafia', 3),
  ('centre', 'Mbalmayo', 4),
  ('centre', 'Eseka', 5),
  ('centre', 'Yaoundé', 6),
  ('east', 'Abong-Mbang', 1),
  ('east', 'Batouri', 2),
  ('east', 'Bélabo', 3),
  ('east', 'Bertoua', 4),
  ('east', 'Garoua-Boulaï', 5),
  ('east', 'Yokadouma', 6),
  ('far_north', 'Kousséri', 1),
  ('far_north', 'Mokolo', 2),
  ('far_north', 'Yagoua', 3),
  ('littoral', 'Douala', 1),
  ('littoral', 'Edéa', 2),
  ('littoral', 'Loum', 3),
  ('littoral', 'Mbanga', 4),
  ('littoral', 'Melong', 5),
  ('littoral', 'Nkongsamba', 6),
  ('littoral', 'Penja', 7),
  ('north', 'Garoua', 1),
  ('north', 'Guider', 2),
  ('northwest', 'Bafut', 1),
  ('northwest', 'Bamenda', 2),
  ('northwest', 'Kumbo', 3),
  ('northwest', 'Ndop', 4),
  ('northwest', 'Nkambé', 5),
  ('northwest', 'Wum', 6),
  ('south', 'Ebolowa', 1),
  ('south', 'Kribi', 2),
  ('south', 'Sangmélima', 3),
  ('southwest', 'Buea', 1),
  ('southwest', 'Kumba', 2),
  ('southwest', 'Limbé', 3),
  ('southwest', 'Mamfe', 4),
  ('southwest', 'Muyuka', 5),
  ('southwest', 'Tiko', 6),
  ('southwest', 'Victoria', 7),
  ('west', 'Bafang', 1),
  ('west', 'Bafoussam', 2),
  ('west', 'Bangangté', 3),
  ('west', 'Dschang', 4),
  ('west', 'Foumban', 5),
  ('west', 'Foumbot', 6),
  ('west', 'Mbouda', 7)
on conflict (region_code, key) do nothing;
alter table public.cameroon_regions enable row level security;
alter table public.cameroon_localities enable row level security;
drop policy if exists cameroon_regions_read on public.cameroon_regions;
create policy cameroon_regions_read on public.cameroon_regions for select to anon, authenticated using (true);
drop policy if exists cameroon_localities_read on public.cameroon_localities;
create policy cameroon_localities_read on public.cameroon_localities for select to anon, authenticated using (active);
revoke all on public.cameroon_regions, public.cameroon_localities from anon, authenticated;
grant select on public.cameroon_regions, public.cameroon_localities to anon, authenticated;
alter table public.store_delivery_zones
  add column if not exists regions text[] not null default '{}',
  add column if not exists localities text[] not null default '{}';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'store_delivery_zones_regions_valid') then
    alter table public.store_delivery_zones add constraint store_delivery_zones_regions_valid
      check (regions <@ array['adamawa', 'centre', 'east', 'far_north', 'littoral', 'north', 'northwest', 'south', 'southwest', 'west']::text[] and cardinality(regions) <= 10 and cardinality(localities) <= 200);
  end if;
end $$;
create or replace function app.zone_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if cardinality(new.localities) > 0 and exists (
    select 1 from unnest(new.localities) k
    where not exists (select 1 from public.cameroon_localities l where l.key = k and l.active)
  ) then
    perform app.raise('zone_locality_unknown');
  end if;
  return new;
end $$;
drop trigger if exists store_delivery_zones_guard on public.store_delivery_zones;
create trigger store_delivery_zones_guard before insert or update of localities on public.store_delivery_zones
  for each row execute function app.zone_guard();
create or replace function public.market_locations() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'regions', coalesce((select jsonb_agg(jsonb_build_object('code', r.code, 'name_en', r.name_en, 'name_fr', r.name_fr) order by r.sort)
                         from public.cameroon_regions r), '[]'::jsonb),
    'localities', coalesce((select jsonb_agg(jsonb_build_object('region', l.region_code, 'name', l.name, 'key', l.key) order by l.region_code, l.sort, l.name)
                            from public.cameroon_localities l where l.active), '[]'::jsonb))
$$;
revoke all on function public.market_locations() from public;
grant execute on function public.market_locations() to anon, authenticated;
create or replace function public.market_place_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); cfg jsonb := app.market_config(); q jsonb; s public.stores; b public.businesses;
  cref uuid := nullif(p ->> 'client_ref', '')::uuid; tok text := nullif(p ->> 'access_token', '');
  existing public.market_orders; oid uuid; num text; cname text; cphone text; cemail text; addr jsonb;
  pay text := p ->> 'payment_method'; cid uuid; l jsonb; exp timestamptz; comm numeric; zone public.store_delivery_zones;
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
  if pay is null or pay not in ('cod', 'momo_direct') then perform app.raise('invalid_payment_method'); end if;
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
  if pay = 'cod' and not s.cod_enabled then perform app.raise('payment_method_not_available'); end if;
  if pay = 'momo_direct' and not (s.momo_direct_enabled and coalesce(s.momo_mtn_number, s.momo_orange_number) is not null) then
    perform app.raise('payment_method_not_available');
  end if;
  if (select count(*) from public.market_orders where business_id = s.business_id and customer_phone = cphone
       and payment_method in ('cod', 'momo_direct') and status in ('pending', 'confirmed', 'processing', 'dispatched'))
     >= coalesce((cfg ->> 'max_open_cod_per_phone')::int, 3) then
    perform app.raise('too_many_open_orders');
  end if;
  if q ->> 'delivery_method' = 'delivery' then
    addr := jsonb_build_object('region', nullif(btrim(coalesce(p #>> '{address,region}', '')), ''),
      'city', btrim(coalesce(p #>> '{address,city}', '')), 'area', nullif(btrim(coalesce(p #>> '{address,area}', '')), ''),
      'line', nullif(btrim(coalesce(p #>> '{address,line}', '')), ''), 'landmark', nullif(btrim(coalesce(p #>> '{address,landmark}', '')), ''));
    if length(addr ->> 'city') < 2 or coalesce(addr ->> 'line', addr ->> 'area', '') = '' then perform app.raise('address_required'); end if;
    if length(addr::text) > 800 then perform app.raise('invalid_request'); end if;
    if addr ->> 'region' is null or not exists (select 1 from public.cameroon_regions where code = addr ->> 'region') then
      perform app.raise('region_required');
    end if;
    select * into zone from public.store_delivery_zones where id = nullif(p ->> 'zone_id', '')::uuid;
    if found and (cardinality(zone.regions) > 0 or cardinality(zone.localities) > 0)
       and not ((addr ->> 'region') = any (zone.regions) or app.city_key(addr ->> 'city') = any (zone.localities)) then
      perform app.raise('zone_not_serving_location');
    end if;
  end if;
  exp := now() + make_interval(hours => coalesce((cfg ->> 'confirm_hours')::int, 48));
  comm := coalesce((cfg ->> 'commission_pct')::numeric, 0);
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
    b.currency, nullif(q ->> 'promo_id', '')::uuid, q ->> 'promo_code', pay, 'cod_pending',
    comm, app.money(s.business_id, ((q ->> 'subtotal')::numeric - (q ->> 'discount')::numeric) * comm / 100),
    0, 0, exp)
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
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (s.business_id, 'market_order_new', 'info',
          jsonb_build_object('number', num, 'amount', (q ->> 'total')::numeric, 'customer', cname), '/app/orders/' || oid, 'orders.manage');
  if uid is not null and coalesce((p ->> 'save_address')::boolean, false) and addr is not null
     and (select count(*) from public.customer_addresses where user_id = uid) < 10
     and not exists (select 1 from public.customer_addresses where user_id = uid and lower(city) = lower(addr ->> 'city')
                     and coalesce(lower(line), '') = coalesce(lower(addr ->> 'line'), '')) then
    insert into public.customer_addresses (user_id, recipient_name, phone, city, area, line, landmark, is_default)
    values (uid, cname, cphone, addr ->> 'city', addr ->> 'area', addr ->> 'line', addr ->> 'landmark',
            not exists (select 1 from public.customer_addresses where user_id = uid));
  end if;
  return jsonb_build_object('order_id', oid, 'number', num, 'total', (q ->> 'total')::numeric,
    'payment_method', pay, 'payment_status', 'cod_pending', 'duplicate', false);
end $$;
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
    'verified', s.verification = 'verified', 'rating_avg', s.rating_avg, 'rating_count', s.rating_count,
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
create or replace function public.store_save_zones(p_business uuid, p_zones jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare z jsonb; keep uuid[] := '{}'; zid uuid; n int := 0; areas_regions text[]; areas_localities text[];
begin
  perform app.require_perm(p_business, 'store.manage');
  if jsonb_typeof(p_zones) <> 'array' or jsonb_array_length(p_zones) > 40 then perform app.raise('invalid_request'); end if;
  for z in select * from jsonb_array_elements(p_zones) loop
    n := n + 1;
    if coalesce(btrim(z ->> 'name'), '') = '' then perform app.raise('zone_name_required'); end if;
    if coalesce((z ->> 'fee')::numeric, 0) < 0 then perform app.raise('invalid_amount'); end if;
    zid := nullif(z ->> 'id', '')::uuid;
    areas_regions := case when z ? 'regions' then coalesce(array(select jsonb_array_elements_text(z -> 'regions')), '{}'::text[]) end;
    areas_localities := case when z ? 'localities' then coalesce(array(select jsonb_array_elements_text(z -> 'localities')), '{}'::text[]) end;
    if zid is not null and exists (select 1 from public.store_delivery_zones where id = zid and business_id = p_business) then
      update public.store_delivery_zones set name = btrim(z ->> 'name'), fee = app.money(p_business, coalesce((z ->> 'fee')::numeric, 0)),
             eta = nullif(btrim(coalesce(z ->> 'eta', '')), ''), active = coalesce((z ->> 'active')::boolean, true), sort = n,
             regions = coalesce(areas_regions, regions), localities = coalesce(areas_localities, localities)
       where id = zid;
    else
      insert into public.store_delivery_zones (business_id, name, fee, eta, active, sort, regions, localities)
      values (p_business, btrim(z ->> 'name'), app.money(p_business, coalesce((z ->> 'fee')::numeric, 0)),
              nullif(btrim(coalesce(z ->> 'eta', '')), ''), coalesce((z ->> 'active')::boolean, true), n,
              coalesce(areas_regions, '{}'::text[]), coalesce(areas_localities, '{}'::text[]))
      returning id into zid;
    end if;
    keep := keep || zid;
  end loop;
  delete from public.store_delivery_zones where business_id = p_business and not (id = any (keep));
  perform app.audit(p_business, 'store.zones_updated', 'store', p_business::text, jsonb_build_object('zones', n));
  return n;
end $$;

commit;
