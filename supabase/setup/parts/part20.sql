-- BizPilot setup PART 20 of 20. Run parts in order.
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
commit;
