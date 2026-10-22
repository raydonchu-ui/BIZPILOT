-- File storage and privilege hardening.

create or replace function app.try_uuid(v text) returns uuid language plpgsql immutable as $$
begin
  return v::uuid;
exception when others then
  return null;
end $$;

-- Private bucket. Object paths: {business_id}/{folder}/{file}
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('business-files', 'business-files', false, 5242880,
        array['image/png', 'image/jpeg', 'image/webp', 'application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function app.storage_can_write(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select case (storage.foldername(object_name))[2]
    when 'logos' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'settings.manage')
    when 'products' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'products.manage')
    when 'purchases' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'purchases.manage')
    when 'suppliers' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'suppliers.manage')
    when 'expenses' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'expenses.manage')
    when 'billing' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'billing.manage')
    when 'stock' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'stock.adjust')
    else false end
$$;

create or replace function app.storage_can_read(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select app.can_read(app.try_uuid((storage.foldername(object_name))[1]))
      or (app.is_platform_admin() and (storage.foldername(object_name))[2] = 'billing')
$$;

create policy "business files read" on storage.objects for select to authenticated
  using (bucket_id = 'business-files' and app.storage_can_read(name));
create policy "business files insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'business-files' and app.storage_can_write(name));
create policy "business files delete" on storage.objects for delete to authenticated
  using (bucket_id = 'business-files' and (storage.foldername(name))[2] in ('logos', 'products')
         and app.storage_can_write(name));

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------
-- Anonymous visitors may only read public catalogue/config rows (RLS still applies).
revoke all on all tables in schema public from anon;
grant select on public.plans, public.countries, public.announcements, public.app_config to anon;

-- No API role may bypass RLS with TRUNCATE etc.
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;

-- RPC exposure: authenticated users only, except the public contact form.
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
grant execute on function public.submit_support_request(jsonb) to anon;

-- Helpers used inside RLS policies must be executable by API roles, but internal
-- mutation helpers are not (they are only reached through SECURITY DEFINER RPCs).
grant execute on all functions in schema app to anon, authenticated, service_role;
revoke execute on function app.apply_movement(uuid, uuid, text, numeric, numeric, text, uuid, text, text, uuid, boolean, uuid, timestamptz, boolean) from anon, authenticated, public;
revoke execute on function app.consume_batches(uuid, numeric) from anon, authenticated, public;
revoke execute on function app.insert_payment(uuid, text, text, numeric, timestamptz, text, text, uuid, uuid, uuid, uuid, uuid, uuid, uuid) from anon, authenticated, public;
revoke execute on function app.rebalance_supplier(uuid) from anon, authenticated, public;
revoke execute on function app.rebalance_customer(uuid, uuid) from anon, authenticated, public;
revoke execute on function app.init_accounts(uuid) from anon, authenticated, public;
revoke execute on function app.init_subscription(uuid) from anon, authenticated, public;
revoke execute on function app.next_number(uuid, text, text) from anon, authenticated, public;
revoke execute on function app.audit(uuid, text, text, text, jsonb) from anon, authenticated, public;
revoke execute on function app.rate_limit(text, int, int) from anon, authenticated, public;
revoke execute on function app.refresh_expense(uuid) from anon, authenticated, public;
revoke execute on function app.bootstrap_platform_admin(text) from anon, authenticated, public;
