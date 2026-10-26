-- Buyer and seller messaging: product-linked conversations, unread counts, an in-app inbox for each
-- user, and web push subscriptions.
--
-- A conversation links one shopper (the buyer) with one published store, optionally about one product.
-- Members of the store who may manage orders (owner, manager, cashier) answer for the store.
-- Every write goes through a security definer function that checks who is asking; row level security
-- lets each user read only their own conversations, messages and inbox rows.

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

-- One row per recipient: the bell, the notification list and the in-app pop-up read from here.
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

-- Web push endpoints of the devices where a user turned notifications on.
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

-- Which side the signed-in user speaks for in a conversation: the buyer, a store member, or null.
create or replace function app.conversation_side(p_conv uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when c.buyer_id = auth.uid() then 'buyer'
              when app.has_perm(c.business_id, 'orders.manage') then 'seller' end
  from public.conversations c where c.id = p_conv
$$;

-- Stores one message and tells the other side: store members for a shopper's message, the shopper
-- for a store's reply. Called only by the functions below, which have already checked the sender.
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

-- A shopper starts (or continues) a conversation with a published store, optionally about a product
-- listed in that store, and sends the first message.
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

-- Sends a message in a conversation the caller takes part in (as the buyer or as a store member).
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

-- Marks a conversation read for the caller and clears their inbox rows for it.
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

-- The caller's conversations, newest first, with the unread count of each.
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

-- One conversation's details for its header: who the caller is talking to, and the product it is about.
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

-- How many conversations hold a message the caller has not read yet (the Messages tab badge).
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

-- Marks the caller's inbox rows read: all of them, or the listed ones.
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

-- New messages and inbox rows are pushed to the open app in real time (row level security still applies).
do $$
begin
  alter publication supabase_realtime add table public.messages, public.inbox_notifications;
exception
  when duplicate_object then null;
  when undefined_object then null;
end $$;
