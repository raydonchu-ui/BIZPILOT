-- BizPilot setup PART 10 of 24. Run parts in order.
begin;
create or replace function app.try_uuid(v text) returns uuid language plpgsql immutable as $$
begin
  return v::uuid;
exception when others then
  return null;
end $$;
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
revoke all on all tables in schema public from anon;
grant select on public.plans, public.countries, public.announcements, public.app_config to anon;
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
grant execute on function public.submit_support_request(jsonb) to anon;
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
revoke execute on function app.build_alerts(uuid) from anon, authenticated, public;
revoke execute on function app.generate_all_alerts() from anon, authenticated, public;
create or replace function app.product_units_history_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.factor is distinct from old.factor or lower(new.name) is distinct from lower(old.name))
     and (exists (select 1 from public.sale_lines where unit_id = old.id)
          or exists (select 1 from public.purchase_lines where unit_id = old.id)) then
    perform app.raise('unit_in_use');
  end if;
  if new.product_id is distinct from old.product_id or new.business_id is distinct from old.business_id then
    perform app.raise('protected_field');
  end if;
  return new;
end $$;
create trigger product_units_history before update on public.product_units
  for each row execute function app.product_units_history_guard();
create or replace function app.products_base_unit_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.base_unit is distinct from old.base_unit
     and exists (select 1 from public.stock_movements where product_id = old.id) then
    perform app.raise('base_unit_locked');
  end if;
  if new.allow_fraction is distinct from old.allow_fraction and not new.allow_fraction
     and old.qty_on_hand <> trunc(old.qty_on_hand) then
    perform app.raise('fractional_quantity_not_allowed');
  end if;
  return new;
end $$;
create trigger products_base_unit before update on public.products
  for each row execute function app.products_base_unit_guard();
create unique index product_units_default_purchase on public.product_units (product_id) where is_default_purchase and active;
create unique index product_units_default_sale on public.product_units (product_id) where is_default_sale and active;
grant execute on function app.product_units_history_guard() to authenticated;
grant execute on function app.products_base_unit_guard() to authenticated;
create or replace function app.business_types() returns text[]
language sql immutable as $$
  select array['grocery', 'supermarket', 'drinks', 'fashion', 'footwear', 'electronics', 'hair_beauty', 'cosmetics',
               'furniture', 'hardware', 'automotive', 'sports', 'toys', 'books', 'stationery', 'jewelry', 'pets',
               'agriculture', 'home_goods', 'gifts', 'general', 'other']
$$;
alter table public.categories
  add column if not exists sort_order int not null default 0,
  add column if not exists archived_at timestamptz,
  add column if not exists attribute_set text check (attribute_set ~ '^[a-z_]{2,30}$');
drop index if exists public.categories_name_unique;
create unique index if not exists categories_top_name_unique on public.categories (business_id, lower(name)) where parent_id is null;
create unique index if not exists categories_child_name_unique on public.categories (parent_id, lower(name)) where parent_id is not null;
create index if not exists categories_business_sort on public.categories (business_id, parent_id, sort_order);
create or replace function app.categories_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.name := btrim(new.name);
  if new.parent_id is not null then
    if new.parent_id = new.id then perform app.raise('invalid_category'); end if;
    if not exists (select 1 from public.categories c where c.id = new.parent_id and c.business_id = new.business_id and c.parent_id is null) then
      perform app.raise('invalid_category');
    end if;
    if tg_op = 'UPDATE' and exists (select 1 from public.categories c where c.parent_id = new.id) then
      perform app.raise('invalid_category'); -- a category with subcategories cannot become a subcategory
    end if;
  end if;
  return new;
end $$;
drop trigger if exists categories_guard on public.categories;
create trigger categories_guard before insert or update on public.categories
  for each row execute function app.categories_guard();
create or replace function app.add_categories(p_business uuid, p_categories jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare c jsonb; ch jsonb; pid uuid; nm text; aset text; n int := 0; next_sort int; child_sort int;
begin
  if jsonb_typeof(p_categories) <> 'array' or jsonb_array_length(p_categories) > 80 then perform app.raise('invalid_input'); end if;
  select coalesce(max(sort_order), 0) into next_sort from public.categories where business_id = p_business and parent_id is null;
  for c in select * from jsonb_array_elements(p_categories) loop
    nm := btrim(coalesce(c ->> 'name', ''));
    if nm = '' then continue; end if;
    if length(nm) > 80 then perform app.raise('invalid_input'); end if;
    aset := nullif(c ->> 'attribute_set', '');
    if aset is not null and aset !~ '^[a-z_]{2,30}$' then aset := null; end if;
    select id into pid from public.categories where business_id = p_business and parent_id is null and lower(name) = lower(nm);
    if pid is null then
      next_sort := next_sort + 1;
      insert into public.categories (business_id, name, sort_order, attribute_set) values (p_business, nm, next_sort, aset) returning id into pid;
      n := n + 1;
    else
      update public.categories set archived_at = null, attribute_set = coalesce(attribute_set, aset)
       where id = pid and (archived_at is not null or attribute_set is null);
      if found then n := n + 1; end if;
    end if;
    if jsonb_typeof(c -> 'children') = 'array' then
      if jsonb_array_length(c -> 'children') > 60 then perform app.raise('invalid_input'); end if;
      select coalesce(max(sort_order), 0) into child_sort from public.categories where parent_id = pid;
      for ch in select * from jsonb_array_elements(c -> 'children') loop
        nm := btrim(coalesce(ch #>> '{}', ''));
        if nm = '' or length(nm) > 80 then continue; end if;
        if not exists (select 1 from public.categories where parent_id = pid and lower(name) = lower(nm)) then
          child_sort := child_sort + 1;
          insert into public.categories (business_id, name, parent_id, sort_order) values (p_business, nm, pid, child_sort);
          n := n + 1;
        else
          update public.categories set archived_at = null where parent_id = pid and lower(name) = lower(nm) and archived_at is not null;
          if found then n := n + 1; end if;
        end if;
      end loop;
    end if;
  end loop;
  return n;
end $$;
create or replace function public.apply_category_template(p_business uuid, p_categories jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform app.require_perm(p_business, 'products.manage');
  n := app.add_categories(p_business, p_categories);
  perform app.audit(p_business, 'categories.added', 'category', null, jsonb_build_object('count', n));
  return n;
end $$;
create or replace function public.reorder_categories(p_business uuid, p_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'products.manage');
  if array_length(p_ids, 1) > 200 then perform app.raise('invalid_input'); end if;
  update public.categories c set sort_order = x.ord
    from unnest(p_ids) with ordinality as x(id, ord)
   where c.id = x.id and c.business_id = p_business;
end $$;
create or replace function public.rename_category(p_business uuid, p_category uuid, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.categories; nm text := btrim(coalesce(p_name, ''));
begin
  perform app.require_perm(p_business, 'products.manage');
  select * into c from public.categories where id = p_category and business_id = p_business for update;
  if not found then perform app.raise('not_found'); end if;
  if nm = '' or length(nm) > 80 then perform app.raise('invalid_input'); end if;
  if nm = c.name then return; end if;
  update public.categories set name = nm where id = c.id;
  if c.parent_id is not null then
    update public.products set subcategory = nm
     where business_id = p_business and category_id = c.parent_id and lower(subcategory) = lower(c.name);
  end if;
  perform app.audit(p_business, 'category.renamed', 'category', c.id::text, jsonb_build_object('from', c.name, 'to', nm));
end $$;
alter table public.products
  add column if not exists attributes jsonb not null default '{}'::jsonb;
alter table public.products drop constraint if exists products_attributes_check;
alter table public.products add constraint products_attributes_check
  check (jsonb_typeof(attributes) = 'object' and pg_column_size(attributes) <= 8192);
create or replace function app.generate_sku(p_business uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  loop
    v := app.next_number(p_business, 'sku', 'SKU-');
    exit when not exists (select 1 from public.products where business_id = p_business and lower(sku) = lower(v));
  end loop;
  return v;
end $$;
create or replace function app.products_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not app.is_internal() then
      new.qty_on_hand := 0;
      new.stock_value := 0;
      new.created_by := auth.uid();
    end if;
    new.avg_cost := coalesce(nullif(new.avg_cost, 0), new.purchase_cost, 0);
    new.sku := nullif(btrim(coalesce(new.sku, '')), '');
    if new.sku is null then new.sku := app.generate_sku(new.business_id); end if;
    new.barcode := nullif(btrim(coalesce(new.barcode, '')), '');
    new.attributes := coalesce(new.attributes, '{}'::jsonb);
    perform app.check_limit(new.business_id, 'max_products');
    return new;
  end if;
  if not app.is_internal() then
    if new.qty_on_hand is distinct from old.qty_on_hand
       or new.stock_value is distinct from old.stock_value
       or new.avg_cost is distinct from old.avg_cost
       or new.business_id is distinct from old.business_id
       or new.import_batch_id is distinct from old.import_batch_id then
      perform app.raise('protected_field');
    end if;
  end if;
  new.sku := coalesce(nullif(btrim(coalesce(new.sku, '')), ''), old.sku);
  new.barcode := nullif(btrim(coalesce(new.barcode, '')), '');
  new.attributes := coalesce(new.attributes, '{}'::jsonb);
  perform app.log_product_change(new, old);
  return new;
end $$;
create or replace function public.add_product_variants(p_business uuid, p_parent uuid, p_variants jsonb)
returns uuid[] language plpgsql security definer set search_path = public as $$
declare par public.products; v jsonb; lbl text; ids uuid[] := '{}'; vid uuid; q numeric; c numeric; labels text[] := '{}';
begin
  perform app.require_perm(p_business, 'products.manage');
  select * into par from public.products where id = p_parent and business_id = p_business;
  if not found then perform app.raise('invalid_product'); end if;
  if par.variant_of is not null then perform app.raise('invalid_product'); end if;
  if jsonb_typeof(p_variants) <> 'array' or jsonb_array_length(p_variants) = 0 or jsonb_array_length(p_variants) > 100 then
    perform app.raise('invalid_input');
  end if;
  for v in select * from jsonb_array_elements(p_variants) loop
    lbl := btrim(coalesce(v ->> 'label', ''));
    if lbl = '' or length(lbl) > 80 then perform app.raise('variant_label_required'); end if;
    if lower(lbl) = any (labels) or exists (select 1 from public.products where variant_of = p_parent and lower(variant_label) = lower(lbl)) then
      perform app.raise('duplicate_variant', jsonb_build_object('label', lbl));
    end if;
    labels := labels || lower(lbl);
    if jsonb_typeof(coalesce(v -> 'attributes', '{}')) <> 'object' then perform app.raise('invalid_input'); end if;
    insert into public.products (business_id, name, sku, barcode, category_id, subcategory, brand, description, image_path,
      base_unit, allow_fraction, purchase_cost, selling_price, min_stock, lead_time_days, min_order_qty, preferred_supplier_id,
      location, track_expiry, variant_of, variant_label, attributes, created_by)
    values (p_business, par.name, nullif(btrim(coalesce(v ->> 'sku', '')), ''), nullif(btrim(coalesce(v ->> 'barcode', '')), ''),
      par.category_id, par.subcategory, par.brand, par.description, par.image_path, par.base_unit, par.allow_fraction,
      coalesce(app.num_or_null(v ->> 'purchase_cost'), par.purchase_cost), coalesce(app.num_or_null(v ->> 'selling_price'), par.selling_price),
      par.min_stock, par.lead_time_days, par.min_order_qty, par.preferred_supplier_id, par.location, par.track_expiry,
      p_parent, lbl, par.attributes || coalesce(v -> 'attributes', '{}'), auth.uid())
    returning id into vid;
    q := coalesce(app.num_or_null(v ->> 'opening_qty'), 0);
    if q < 0 then perform app.raise('invalid_quantity'); end if;
    if q > 0 then
      c := coalesce(app.num_or_null(v ->> 'opening_cost'), app.num_or_null(v ->> 'purchase_cost'), par.purchase_cost, 0);
      if c < 0 then perform app.raise('invalid_cost'); end if;
      perform app.apply_movement(p_business, vid, 'opening', q, c, 'opening', null, null, 'Opening stock', null, false, null);
    end if;
    ids := ids || vid;
  end loop;
  perform app.audit(p_business, 'product.variants_added', 'product', p_parent::text, jsonb_build_object('count', array_length(ids, 1)));
  return ids;
end $$;
create or replace function public.create_business(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := app.require_auth(); c public.countries; bid uuid; lang text; cat text; nm text;
begin
  perform app.rate_limit('create_business:' || uid, 5, 86400);
  if (select count(*) from public.business_members where user_id = uid and role = 'owner' and active) >= 5 then
    perform app.raise('too_many_businesses');
  end if;
  select * into c from public.countries where code = coalesce(nullif(p ->> 'country_code', ''), 'CM');
  if not found or not c.registration_enabled then perform app.raise('country_not_available'); end if;
  lang := case when p ->> 'language' in ('en', 'fr') then p ->> 'language' else c.default_language end;
  cat := coalesce(nullif(p ->> 'category', ''), 'general');
  if not cat = any (app.business_types()) then
    perform app.raise('invalid_category');
  end if;
  nm := btrim(coalesce(p ->> 'name', ''));
  if length(nm) < 2 then perform app.raise('business_name_required'); end if;
  insert into public.businesses (name, owner_name, email, phone, address, city, country_code, currency,
    currency_decimals, timezone, language, category, reporting_start_date, created_by)
  values (nm, nullif(p ->> 'owner_name', ''), nullif(p ->> 'email', ''), nullif(p ->> 'phone', ''),
    nullif(p ->> 'address', ''), nullif(p ->> 'city', ''), c.code, c.currency, c.currency_decimals, c.timezone,
    lang, cat, coalesce(nullif(p ->> 'reporting_start_date', '')::date, (now() at time zone c.timezone)::date), uid)
  returning id into bid;
  insert into public.business_settings (business_id) values (bid);
  insert into public.business_members (business_id, user_id, role, display_name)
  values (bid, uid, 'owner', nullif(p ->> 'owner_name', ''));
  perform app.init_accounts(bid);
  perform app.init_subscription(bid);
  if jsonb_typeof(p -> 'categories') = 'array' then
    perform app.add_categories(bid, p -> 'categories');
  else
    insert into public.categories (business_id, name)
    select bid, x from unnest(app.default_categories(cat, lang)) x on conflict do nothing;
  end if;
  update public.profiles set full_name = coalesce(nullif(p ->> 'owner_name', ''), full_name),
         phone = coalesce(nullif(p ->> 'phone', ''), phone), language = lang
   where id = uid;
  perform app.audit(bid, 'business.created', 'business', bid::text, jsonb_build_object('name', nm, 'category', cat));
  return bid;
end $$;
create or replace function public.update_business(p_business uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'settings.manage');
  if p ? 'name' and length(btrim(p ->> 'name')) < 2 then perform app.raise('business_name_required'); end if;
  update public.businesses set
    name = coalesce(btrim(p ->> 'name'), name),
    owner_name = case when p ? 'owner_name' then nullif(p ->> 'owner_name', '') else owner_name end,
    email = case when p ? 'email' then nullif(p ->> 'email', '') else email end,
    phone = case when p ? 'phone' then nullif(p ->> 'phone', '') else phone end,
    address = case when p ? 'address' then nullif(p ->> 'address', '') else address end,
    city = case when p ? 'city' then nullif(p ->> 'city', '') else city end,
    language = case when p ->> 'language' in ('en', 'fr') then p ->> 'language' else language end,
    category = case when p ->> 'category' = any (app.business_types())
                    then p ->> 'category' else category end,
    logo_path = case when p ? 'logo_path' then nullif(p ->> 'logo_path', '') else logo_path end,
    tax_id = case when p ? 'tax_id' then nullif(p ->> 'tax_id', '') else tax_id end,
    trade_register = case when p ? 'trade_register' then nullif(p ->> 'trade_register', '') else trade_register end,
    reporting_start_date = coalesce(nullif(p ->> 'reporting_start_date', '')::date, reporting_start_date)
  where id = p_business;
  perform app.audit(p_business, 'business.updated', 'business', p_business::text, p);
end $$;
create or replace function public.import_products(p_business uuid, p_rows jsonb, p_file_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pv jsonb; r jsonb; i int := 0; bid uuid; created int := 0; skipped int := 0; v_issues jsonb := '[]';
        pid uuid; cat uuid; sku text; oq numeric; oc numeric; lim numeric; known boolean;
begin
  perform app.require_perm(p_business, 'imports.manage');
  perform app.require_feature(p_business, 'import');
  pv := public.preview_product_import(p_business, p_rows);
  lim := app.plan_limit(p_business, 'max_products');
  if lim is not null and app.usage_count(p_business, 'max_products') + (pv ->> 'valid')::int > lim then
    perform app.raise('plan_limit_reached', jsonb_build_object('limit', 'max_products', 'max', lim,
      'used', app.usage_count(p_business, 'max_products')));
  end if;
  insert into public.import_batches (business_id, kind, file_name, total_rows, created_by)
  values (p_business, 'products', p_file_name, jsonb_array_length(p_rows), auth.uid()) returning id into bid;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    if not ((pv -> 'rows' -> (i - 1)) ->> 'ok')::boolean then
      skipped := skipped + 1;
      v_issues := v_issues || jsonb_build_object('row', i, 'errors', (pv -> 'rows' -> (i - 1)) -> 'errors');
      continue;
    end if;
    cat := null;
    if coalesce(btrim(r ->> 'category'), '') <> '' then
      insert into public.categories (business_id, name) values (p_business, btrim(r ->> 'category'))
      on conflict (business_id, lower(name)) where parent_id is null do nothing;
      select id into cat from public.categories where business_id = p_business and parent_id is null
        and lower(name) = lower(btrim(r ->> 'category'));
    end if;
    sku := coalesce(nullif(btrim(r ->> 'sku'), ''), app.next_number(p_business, 'sku', 'SKU-'));
    insert into public.products (business_id, name, sku, barcode, category_id, brand, description, base_unit,
      allow_fraction, purchase_cost, selling_price, min_stock, location, import_batch_id, created_by)
    values (p_business, btrim(r ->> 'name'), sku, nullif(btrim(r ->> 'barcode'), ''), cat, nullif(r ->> 'brand', ''),
      nullif(r ->> 'description', ''), coalesce(nullif(btrim(r ->> 'base_unit'), ''), 'piece'),
      lower(coalesce(r ->> 'allow_fraction', '')) in ('yes', 'true', '1', 'oui'),
      coalesce(app.num_or_null(r ->> 'purchase_cost'), 0), coalesce(app.num_or_null(r ->> 'selling_price'), 0),
      coalesce(app.num_or_null(r ->> 'min_stock'), 0), nullif(r ->> 'location', ''), bid, auth.uid())
    returning id into pid;
    oq := coalesce(app.num_or_null(r ->> 'opening_qty'), 0);
    if oq > 0 then
      oc := app.num_or_null(r ->> 'opening_unit_cost');
      known := oc is not null;
      oc := coalesce(oc, app.num_or_null(r ->> 'purchase_cost'), 0);
      perform app.apply_movement(p_business, pid, 'opening', oq, oc, 'import', bid, null, 'Imported opening stock',
                                 null, not known);
    end if;
    created := created + 1;
  end loop;
  update public.import_batches set created_count = created, skipped_count = skipped, issues = v_issues where id = bid;
  perform app.audit(p_business, 'import.products', 'import_batch', bid::text,
                    jsonb_build_object('created', created, 'skipped', skipped, 'file', p_file_name));
  return jsonb_build_object('batch_id', bid, 'created', created, 'skipped', skipped, 'issues', v_issues);
end $$;
revoke execute on function app.add_categories(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.generate_sku(uuid) to authenticated; -- called by products_guard as the user
grant execute on function public.apply_category_template(uuid, jsonb) to authenticated;
grant execute on function public.reorder_categories(uuid, uuid[]) to authenticated;
grant execute on function public.rename_category(uuid, uuid, text) to authenticated;
revoke execute on function public.rename_category(uuid, uuid, text) from anon;
grant execute on function public.add_product_variants(uuid, uuid, jsonb) to authenticated;
revoke execute on function public.apply_category_template(uuid, jsonb) from anon;
commit;
