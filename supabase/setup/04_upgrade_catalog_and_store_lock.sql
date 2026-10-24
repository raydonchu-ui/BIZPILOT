-- BizPilot upgrade: 20261024000100_catalog_flexibility 20261024000200_store_lock 
-- Paste into Supabase Dashboard -> SQL Editor -> New query, then Run. Run it ONCE.
-- Adds features only: existing businesses, products, sales and users are not changed.
begin;

-- ===== 20261024000100_catalog_flexibility.sql =====
-- Flexible catalogue: more business types, two-level categories that owners can rename, reorder,
-- archive and restore, optional category-specific product attributes, server-generated SKUs and
-- product variants created in one step. Additive only: no existing data is changed or removed.

-- ---------------------------------------------------------------------------
-- Business types
-- ---------------------------------------------------------------------------
create or replace function app.business_types() returns text[]
language sql immutable as $$
  select array['grocery', 'supermarket', 'drinks', 'fashion', 'footwear', 'electronics', 'hair_beauty', 'cosmetics',
               'furniture', 'hardware', 'automotive', 'sports', 'toys', 'books', 'stationery', 'jewelry', 'pets',
               'agriculture', 'home_goods', 'gifts', 'general', 'other']
$$;

-- ---------------------------------------------------------------------------
-- Categories: two levels (category → subcategory), ordering, archiving
-- ---------------------------------------------------------------------------
alter table public.categories
  add column if not exists sort_order int not null default 0,
  add column if not exists archived_at timestamptz,
  add column if not exists attribute_set text check (attribute_set ~ '^[a-z_]{2,30}$');

-- Names are unique among top-level categories, and among the subcategories of one category
-- (so "T-shirts" can exist under both "Men" and "Women").
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
    -- Parent must belong to the same business and be a top-level category (two levels only).
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

-- Adds categories (and their subcategories) that do not exist yet. Existing ones are kept as they
-- are (an archived one is restored). Input: [{"name": "Men", "attribute_set": "clothing",
-- "children": ["T-shirts", "Jeans"]}, ...]. Returns the number of categories added or restored.
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

-- Sets the display order of sibling categories to the order of p_ids.
create or replace function public.reorder_categories(p_business uuid, p_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'products.manage');
  if array_length(p_ids, 1) > 200 then perform app.raise('invalid_input'); end if;
  update public.categories c set sort_order = x.ord
    from unnest(p_ids) with ordinality as x(id, ord)
   where c.id = x.id and c.business_id = p_business;
end $$;

-- Renames a category; for a subcategory, products that use it are updated in the same step.
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

-- ---------------------------------------------------------------------------
-- Products: optional attributes and server-generated SKU
-- ---------------------------------------------------------------------------
alter table public.products
  add column if not exists attributes jsonb not null default '{}'::jsonb;
alter table public.products drop constraint if exists products_attributes_check;
alter table public.products add constraint products_attributes_check
  check (jsonb_typeof(attributes) = 'object' and pg_column_size(attributes) <= 8192);

-- Unique, stable SKU for products saved without one (same counter the CSV import uses).
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

-- products_guard (runs as the calling user): blank SKU on insert → generated; blank SKU on update →
-- the existing one is kept, so a product's SKU never changes by accident.
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

-- ---------------------------------------------------------------------------
-- Variants: create several variants of a product in one step (all or nothing)
-- ---------------------------------------------------------------------------
-- p_variants: [{"label": "M / Red", "selling_price": 5000, "purchase_cost": 3000, "sku": "", "barcode": "",
--               "attributes": {"size": "M", "color": "Red"}, "opening_qty": 10, "opening_cost": 3000}]
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

-- ---------------------------------------------------------------------------
-- Onboarding / settings accept the new business types; import works with two-level categories
-- ---------------------------------------------------------------------------
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
  -- Categories chosen during onboarding (recommended for the business type, all optional);
  -- older clients that send none still get the basic defaults.
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
revoke execute on function public.reorder_categories(uuid, uuid[]) from anon;
revoke execute on function public.add_product_variants(uuid, uuid, jsonb) from anon;

-- ===== 20261024000200_store_lock.sql =====
-- Store Lock: a 4-digit PIN that locks the BizPilot dashboard on a device (signed-in session).
--
-- Enforced on the server, per Supabase Auth session (the JWT's session_id):
--   * while a session is locked, every permission and membership check used by the API, RLS
--     policies and storage returns "no access", and RPCs raise 'store_locked';
--   * a new sign-in starts locked (once a PIN exists), so signing out and in again does not skip it;
--   * a session also counts as locked after the user's inactivity period without activity.
-- PINs are stored only as bcrypt hashes (pgcrypto) in schema "app", which the API cannot read.
-- Wrong PINs are counted per user with growing waits. Forgotten PIN: sign in again (fresh login
-- within 10 minutes), then set a new PIN; every session of the user is locked afterwards.
-- Limitation: a 4-digit PIN has 10 000 combinations, so its strength comes from the server-side
-- attempt limits, not from the hash. It complements, never replaces, the account password.

create table app.store_pins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  pin_hash text not null,
  idle_minutes int not null default 15 check (idle_minutes between 1 and 240),
  failed_attempts int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now(),
  pin_changed_at timestamptz not null default now()
);

create table app.store_lock_sessions (
  session_id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  locked boolean not null,
  reason text check (reason in ('new_session', 'manual', 'idle', 'pin_reset', 'pin_changed')),
  locked_at timestamptz,
  unlocked_at timestamptz,
  last_activity timestamptz not null default now()
);
create index store_lock_sessions_user on app.store_lock_sessions (user_id);
revoke all on app.store_pins, app.store_lock_sessions from public, anon, authenticated;

create or replace function app.current_session_id() returns uuid
language sql stable as $$
  select case when coalesce(auth.jwt() ->> 'session_id', '') ~ '^[0-9a-f-]{36}$' then (auth.jwt() ->> 'session_id')::uuid end
$$;

-- True when the calling session must unlock before using business data.
create or replace function app.session_locked() returns boolean
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid(); sid uuid := app.current_session_id(); pin app.store_pins; s app.store_lock_sessions;
begin
  if uid is null or sid is null then return false; end if;           -- service/database calls
  select * into pin from app.store_pins where user_id = uid;
  if not found then return false; end if;                           -- no PIN yet: the app asks for one first
  select * into s from app.store_lock_sessions where session_id = sid and user_id = uid;
  if not found then return true; end if;                            -- a new sign-in starts locked
  return s.locked or s.last_activity < now() - make_interval(mins => pin.idle_minutes);
end $$;

-- Session row for the caller, created locked for a session never seen before.
create or replace function app.lock_session_row(uid uuid, sid uuid) returns app.store_lock_sessions
language plpgsql security definer set search_path = public as $$
declare s app.store_lock_sessions; idle int;
begin
  insert into app.store_lock_sessions (session_id, user_id, locked, reason, locked_at)
  values (sid, uid, true, 'new_session', now())
  on conflict (session_id) do nothing;
  select idle_minutes into idle from app.store_pins where user_id = uid;
  -- Persist an inactivity lock so it is reported (and kept) even if activity resumes.
  update app.store_lock_sessions set locked = true, reason = 'idle', locked_at = now()
   where session_id = sid and not locked and idle is not null and last_activity < now() - make_interval(mins => idle);
  select * into s from app.store_lock_sessions where session_id = sid;
  if s.user_id <> uid then perform app.raise('permission_denied'); end if;
  return s;
end $$;

create or replace function app.valid_pin(p text) returns boolean
language sql immutable as $$
  select p ~ '^[0-9]{4}$'
     and p !~ '^(.)\1{3}$'                                        -- 0000, 1111, …
     and p not in ('0123', '1234', '2345', '3456', '4567', '5678', '6789', '9876', '8765', '7654', '6543', '5432', '4321', '3210')
$$;

create or replace function app.fresh_login(max_age interval default interval '10 minutes') returns boolean
language sql stable as $$
  select coalesce((select max((x ->> 'timestamp')::bigint) from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) x), 0)
         >= extract(epoch from now() - max_age)
$$;

-- Checks a PIN with attempt limits. Never raises for a wrong PIN, so the failure is recorded.
-- 5 wrong PINs → 30 s wait, then 1, 2, 5, 10 min, then 15 min per further mistake.
create or replace function app.check_pin(uid uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pin app.store_pins; ok boolean; wait int;
begin
  select * into pin from app.store_pins where user_id = uid for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'pin_not_set'); end if;
  if pin.locked_until is not null and pin.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'pin_temporarily_locked',
      'retry_after', ceil(extract(epoch from pin.locked_until - now()))::int);
  end if;
  ok := p_pin ~ '^[0-9]{4}$' and extensions.crypt(p_pin, pin.pin_hash) = pin.pin_hash;
  if ok then
    update app.store_pins set failed_attempts = 0, locked_until = null where user_id = uid;
    return jsonb_build_object('ok', true);
  end if;
  wait := case when pin.failed_attempts + 1 < 5 then 0 when pin.failed_attempts + 1 = 5 then 30 when pin.failed_attempts + 1 = 6 then 60
               when pin.failed_attempts + 1 = 7 then 120 when pin.failed_attempts + 1 = 8 then 300 when pin.failed_attempts + 1 = 9 then 600 else 900 end;
  update app.store_pins set failed_attempts = failed_attempts + 1,
         locked_until = case when wait > 0 then now() + make_interval(secs => wait) end
   where user_id = uid;
  if wait > 0 then
    insert into public.audit_logs (user_id, action, entity, entity_id, details)
    values (uid, 'store_lock.too_many_attempts', 'user', uid::text, jsonb_build_object('attempts', pin.failed_attempts + 1, 'wait_seconds', wait));
  end if;
  return jsonb_build_object('ok', false, 'error', case when wait > 0 then 'pin_temporarily_locked' else 'wrong_pin' end,
    'retry_after', wait, 'attempts_left', greatest(0, 4 - pin.failed_attempts));
end $$;

create or replace function app.require_session() returns table (uid uuid, sid uuid)
language plpgsql stable as $$
begin
  uid := auth.uid(); sid := app.current_session_id();
  if uid is null then perform app.raise('not_authenticated'); end if;
  if sid is null then perform app.raise('session_required'); end if;
  return next;
end $$;

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------
create or replace function public.store_lock_status()
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record; pin app.store_pins; s app.store_lock_sessions;
begin
  select * into u from app.require_session();
  select * into pin from app.store_pins where user_id = u.uid;
  if not found then return jsonb_build_object('has_pin', false, 'locked', false); end if;
  s := app.lock_session_row(u.uid, u.sid);
  delete from app.store_lock_sessions where user_id = u.uid and last_activity < now() - interval '60 days' and session_id <> u.sid;
  return jsonb_build_object('has_pin', true, 'locked', s.locked, 'reason', s.reason, 'idle_minutes', pin.idle_minutes,
    'retry_after', case when pin.locked_until > now() then ceil(extract(epoch from pin.locked_until - now()))::int else 0 end,
    'can_reset', app.fresh_login());
end $$;

-- First PIN for this account. The session that sets it stays unlocked.
create or replace function public.set_store_pin(p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record;
begin
  select * into u from app.require_session();
  if exists (select 1 from app.store_pins where user_id = u.uid) then perform app.raise('pin_already_set'); end if;
  if not app.valid_pin(p_pin) then perform app.raise('pin_too_simple'); end if;
  insert into app.store_pins (user_id, pin_hash) values (u.uid, extensions.crypt(p_pin, extensions.gen_salt('bf', 10)));
  insert into app.store_lock_sessions (session_id, user_id, locked, unlocked_at, last_activity)
  values (u.sid, u.uid, false, now(), now())
  on conflict (session_id) do update set locked = false, reason = null, unlocked_at = now(), last_activity = now();
  insert into public.audit_logs (user_id, action, entity, entity_id) values (u.uid, 'store_lock.pin_created', 'user', u.uid::text);
  return public.store_lock_status();
end $$;

create or replace function public.lock_store()
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record;
begin
  select * into u from app.require_session();
  if not exists (select 1 from app.store_pins where user_id = u.uid) then perform app.raise('pin_not_set'); end if;
  perform app.lock_session_row(u.uid, u.sid);
  update app.store_lock_sessions set locked = true, reason = 'manual', locked_at = now() where session_id = u.sid and not locked;
  return public.store_lock_status();
end $$;

create or replace function public.unlock_store(p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record; r jsonb;
begin
  select * into u from app.require_session();
  perform app.rate_limit('pin:' || u.uid, 30, 3600);
  r := app.check_pin(u.uid, p_pin);
  if (r ->> 'ok')::boolean then
    perform app.lock_session_row(u.uid, u.sid);
    update app.store_lock_sessions set locked = false, reason = null, unlocked_at = now(), last_activity = now() where session_id = u.sid;
  end if;
  return r || jsonb_build_object('status', public.store_lock_status());
end $$;

-- Activity from an unlocked session (called by the app while the user is active).
create or replace function public.store_lock_heartbeat()
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record; s app.store_lock_sessions;
begin
  select * into u from app.require_session();
  if not exists (select 1 from app.store_pins where user_id = u.uid) then return jsonb_build_object('has_pin', false, 'locked', false); end if;
  s := app.lock_session_row(u.uid, u.sid);
  if not s.locked then update app.store_lock_sessions set last_activity = now() where session_id = u.sid; end if;
  return jsonb_build_object('has_pin', true, 'locked', s.locked, 'reason', s.reason);
end $$;

-- Change PIN: needs the current PIN (same attempt limits). Other devices are locked.
create or replace function public.change_store_pin(p_current text, p_new text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record; r jsonb;
begin
  select * into u from app.require_session();
  perform app.rate_limit('pin:' || u.uid, 30, 3600);
  if app.session_locked() then perform app.raise('store_locked'); end if;
  if not app.valid_pin(p_new) then perform app.raise('pin_too_simple'); end if;
  r := app.check_pin(u.uid, p_current);
  if not (r ->> 'ok')::boolean then return r; end if;
  update app.store_pins set pin_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)), pin_changed_at = now() where user_id = u.uid;
  update app.store_lock_sessions set locked = true, reason = 'pin_changed', locked_at = now()
   where user_id = u.uid and session_id <> u.sid and not locked;
  insert into public.audit_logs (user_id, action, entity, entity_id) values (u.uid, 'store_lock.pin_changed', 'user', u.uid::text);
  return r;
end $$;

-- Forgotten PIN: allowed within 10 minutes of signing in (password, Google, email link…).
-- Every session of the user — this one included — must then unlock with the new PIN.
create or replace function public.reset_store_pin(p_new text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record;
begin
  select * into u from app.require_session();
  perform app.rate_limit('pin_reset:' || u.uid, 5, 3600);
  if not app.fresh_login() then perform app.raise('fresh_login_required'); end if;
  if not app.valid_pin(p_new) then perform app.raise('pin_too_simple'); end if;
  insert into app.store_pins (user_id, pin_hash) values (u.uid, extensions.crypt(p_new, extensions.gen_salt('bf', 10)))
  on conflict (user_id) do update set pin_hash = excluded.pin_hash, pin_changed_at = now(), failed_attempts = 0, locked_until = null;
  perform app.lock_session_row(u.uid, u.sid);
  update app.store_lock_sessions set locked = true, reason = 'pin_reset', locked_at = now() where user_id = u.uid;
  insert into public.audit_logs (user_id, action, entity, entity_id) values (u.uid, 'store_lock.pin_reset', 'user', u.uid::text);
  return public.store_lock_status();
end $$;

create or replace function public.set_store_lock_timeout(p_minutes int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record;
begin
  select * into u from app.require_session();
  if app.session_locked() then perform app.raise('store_locked'); end if;
  if p_minutes is null or p_minutes < 1 or p_minutes > 240 then perform app.raise('invalid_input'); end if;
  update app.store_pins set idle_minutes = p_minutes where user_id = u.uid;
  if not found then perform app.raise('pin_not_set'); end if;
  update app.store_lock_sessions set last_activity = now() where session_id = u.sid;
  return public.store_lock_status();
end $$;

-- ---------------------------------------------------------------------------
-- Enforcement: the shared access checks refuse a locked session
-- ---------------------------------------------------------------------------
create or replace function app.require_auth() returns uuid language plpgsql stable as $$
declare v uuid := auth.uid();
begin
  if v is null then perform app.raise('not_authenticated'); end if;
  if app.session_locked() then perform app.raise('store_locked'); end if;
  return v;
end $$;

create or replace function app.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select not app.session_locked() and exists (select 1 from public.platform_admins where user_id = auth.uid())
$$;

create or replace function app.my_business_ids() returns uuid[]
language sql stable security definer set search_path = public as $$
  select case when app.session_locked() then '{}'::uuid[] else
    (select coalesce(array_agg(business_id), '{}') from public.business_members where user_id = auth.uid() and active) end
$$;

create or replace function app.is_member(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not app.session_locked() and exists (select 1 from public.business_members
                 where business_id = bid and user_id = auth.uid() and active)
$$;

create or replace function app.can_read(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not app.session_locked() and (app.is_member(bid) or (
    app.is_platform_admin() and exists (
      select 1 from public.support_access_grants g
      where g.business_id = bid and g.revoked_at is null and g.expires_at > now())))
$$;

create or replace function app.has_perm(bid uuid, perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select not app.session_locked() and coalesce((
    select case
      when m.role = 'owner' then true
      when m.permissions ? perm then (m.permissions ->> perm)::boolean
      else perm = any (app.role_permissions(m.role))
    end
    from public.business_members m
    join public.businesses b on b.id = m.business_id and b.status = 'active'
    where m.business_id = bid and m.user_id = auth.uid() and m.active
  ), false)
$$;

create or replace function public.get_my_context()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return null; end if;
  if app.session_locked() then perform app.raise('store_locked'); end if;
  return jsonb_build_object(
    'user_id', uid,
    'email', (select email from auth.users where id = uid),
    'email_confirmed', (select email_confirmed_at is not null from auth.users where id = uid),
    'profile', (select to_jsonb(pr) from public.profiles pr where pr.id = uid),
    'is_platform_admin', app.is_platform_admin(),
    'pending_invites', (select count(*) from public.business_invites i
                        where lower(i.email) = lower((select email from auth.users where id = uid))
                          and i.accepted_at is null and i.revoked_at is null),
    'businesses', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', b.id, 'name', b.name, 'role', m.role, 'status', b.status, 'currency', b.currency,
        'currency_decimals', b.currency_decimals, 'language', b.language, 'timezone', b.timezone,
        'category', b.category, 'logo_path', b.logo_path, 'country_code', b.country_code,
        'permissions', to_jsonb(app.my_permissions(b.id)),
        'subscription', app.subscription_info(b.id),
        'plan', (select jsonb_build_object('code', ep.code, 'name_en', ep.name_en, 'name_fr', ep.name_fr,
                                           'features', ep.features, 'limits', ep.limits)
                 from app.effective_plan(b.id) ep)
      ) order by b.created_at)
      from public.business_members m join public.businesses b on b.id = m.business_id
      where m.user_id = uid and m.active and b.status <> 'closed'), '[]'::jsonb));
end $$;

revoke execute on function app.check_pin(uuid, text) from public, anon, authenticated;
revoke execute on function app.lock_session_row(uuid, uuid) from public, anon, authenticated;
grant execute on function app.session_locked() to anon, authenticated; -- used inside RLS checks
revoke execute on function public.store_lock_status() from public, anon;
revoke execute on function public.set_store_pin(text) from public, anon;
revoke execute on function public.lock_store() from public, anon;
revoke execute on function public.unlock_store(text) from public, anon;
revoke execute on function public.store_lock_heartbeat() from public, anon;
revoke execute on function public.change_store_pin(text, text) from public, anon;
revoke execute on function public.reset_store_pin(text) from public, anon;
revoke execute on function public.set_store_lock_timeout(int) from public, anon;
grant execute on function public.store_lock_status(), public.set_store_pin(text), public.lock_store(), public.unlock_store(text),
  public.store_lock_heartbeat(), public.change_store_pin(text, text), public.reset_store_pin(text), public.set_store_lock_timeout(int)
  to authenticated;

commit;
