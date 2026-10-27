-- Profile photos for every account, and a record of stored pictures.
--
-- A profile photo lives in the public storefront bucket under users/<account id>/, so it can be shown on
-- storefronts, reviews, messages and notifications. The database and storage rules let each account write only
-- inside its own folder, and a profile can only point at a picture in that folder.
-- Store logos and covers keep their existing paths under <business id>/store/ and their existing rules.

alter table public.profiles add column if not exists avatar_path text check (length(avatar_path) <= 300);
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_avatar_in_own_folder') then
    alter table public.profiles add constraint profiles_avatar_in_own_folder
      check (avatar_path is null or avatar_path like 'users/' || id::text || '/%');
  end if;
end $$;

-- Every stored picture is recorded once, with its owner, size and kind (for storage reports and cleanup).
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

-- Storage rule: a user may write to users/<own id>/ only; the store folders keep their existing rules.
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

-- Conversations show the other side's picture: the store logo for a shopper, the shopper's photo for a store.
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

-- Removing a picture first looks the object up, so the writer must be able to see its own objects. Public reads
-- of the storefront bucket still go through the public URL; this only lets an account see objects it may write.
drop policy if exists "storefront select own" on storage.objects;
create policy "storefront select own" on storage.objects for select to authenticated
  using (bucket_id = 'storefront' and app.storefront_can_write(name));
