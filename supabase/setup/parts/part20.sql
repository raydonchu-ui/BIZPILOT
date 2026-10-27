-- BizPilot setup PART 20 of 24. Run parts in order.
begin;
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
alter table public.profiles add column if not exists avatar_path text check (length(avatar_path) <= 300);
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_avatar_in_own_folder') then
    alter table public.profiles add constraint profiles_avatar_in_own_folder
      check (avatar_path is null or avatar_path like 'users/' || id::text || '/%');
  end if;
end $$;
create table if not exists public.stored_images (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) on delete cascade,
  bucket text not null check (bucket in ('storefront')),
  path text not null unique check (length(path) <= 300),
  kind text not null check (kind in ('avatar', 'logo', 'cover', 'thumb')),
  bytes integer not null check (bytes > 0),
  created_at timestamptz not null default now()
);
create index if not exists stored_images_owner on public.stored_images (owner_id, created_at desc);
alter table public.stored_images enable row level security;
drop policy if exists stored_images_read on public.stored_images;
create policy stored_images_read on public.stored_images for select to authenticated using (owner_id = auth.uid());
drop policy if exists stored_images_add on public.stored_images;
create policy stored_images_add on public.stored_images for insert to authenticated with check (owner_id = auth.uid());
drop policy if exists stored_images_remove on public.stored_images;
create policy stored_images_remove on public.stored_images for delete to authenticated using (owner_id = auth.uid());
revoke all on public.stored_images from anon, authenticated;
grant select, insert, delete on public.stored_images to authenticated;
create or replace function app.storefront_can_write(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when (storage.foldername(object_name))[1] = 'users' then (storage.foldername(object_name))[2] = auth.uid()::text
    else case (storage.foldername(object_name))[2]
      when 'store' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'store.manage')
      when 'products' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'products.manage')
      else false end
  end
$$;
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
        case when c.buyer_id = uid then s.logo_path else (select pr.avatar_path from public.profiles pr where pr.id = c.buyer_id) end as counterpart_image,
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
      'counterpart_image', case when v_side = 'buyer' then s.logo_path else (select pr.avatar_path from public.profiles pr where pr.id = c.buyer_id) end,
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
drop policy if exists "storefront select own" on storage.objects;
create policy "storefront select own" on storage.objects for select to authenticated
  using (bucket_id = 'storefront' and app.storefront_can_write(name));
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
commit;
