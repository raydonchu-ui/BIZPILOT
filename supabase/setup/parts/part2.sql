-- BizPilot setup PART 2 of 24. Run parts in order.
begin;
create table public.categories (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 80),
  parent_id uuid references public.categories (id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index categories_name_unique on public.categories (business_id, lower(name));
create table public.import_batches (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  kind text not null check (kind in ('products', 'suppliers', 'customers')),
  file_name text,
  total_rows int not null default 0,
  created_count int not null default 0,
  skipped_count int not null default 0,
  issues jsonb not null default '[]'::jsonb,
  status text not null default 'completed' check (status in ('completed', 'rolled_back')),
  created_by uuid,
  created_at timestamptz not null default now(),
  rolled_back_at timestamptz,
  rolled_back_by uuid
);
create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 120),
  contact_person text,
  phone text,
  email text,
  address text,
  reference text,
  payment_terms_days int check (payment_terms_days between 0 and 365),
  lead_time_days int check (lead_time_days between 0 and 365),
  quality_notes text,
  notes text,
  status text not null default 'active' check (status in ('active', 'archived')),
  import_batch_id uuid references public.import_batches (id) on delete set null,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index suppliers_business on public.suppliers (business_id, name);
create table public.products (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 160),
  sku text not null check (length(btrim(sku)) between 1 and 64),
  barcode text,
  category_id uuid references public.categories (id) on delete set null,
  subcategory text,
  brand text,
  description text,
  image_path text,
  base_unit text not null default 'piece' check (length(btrim(base_unit)) between 1 and 30),
  allow_fraction boolean not null default false,
  purchase_cost numeric(18, 4) not null default 0 check (purchase_cost >= 0),
  selling_price numeric(14, 2) not null default 0 check (selling_price >= 0),
  qty_on_hand numeric(14, 3) not null default 0,
  stock_value numeric(18, 4) not null default 0,
  avg_cost numeric(18, 4) not null default 0,
  min_stock numeric(14, 3) not null default 0 check (min_stock >= 0),
  lead_time_days int check (lead_time_days between 0 and 365),
  min_order_qty numeric(14, 3) check (min_order_qty >= 0),
  preferred_supplier_id uuid references public.suppliers (id) on delete set null,
  location text,
  track_expiry boolean not null default false,
  variant_of uuid references public.products (id) on delete set null,
  variant_label text,
  status text not null default 'active' check (status in ('active', 'archived')),
  import_batch_id uuid references public.import_batches (id) on delete set null,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index products_sku_unique on public.products (business_id, lower(sku));
create unique index products_barcode_unique on public.products (business_id, barcode)
  where barcode is not null and barcode <> '';
create index products_business_name on public.products (business_id, status, name);
create index products_category on public.products (category_id);
create table public.product_units (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 30),
  factor numeric(14, 4) not null check (factor > 0),
  barcode text,
  selling_price numeric(14, 2) check (selling_price >= 0),
  is_default_purchase boolean not null default false,
  is_default_sale boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index product_units_name on public.product_units (product_id, lower(name));
create table public.product_price_history (
  id bigserial primary key,
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  old_purchase_cost numeric(18, 4),
  new_purchase_cost numeric(18, 4),
  old_selling_price numeric(14, 2),
  new_selling_price numeric(14, 2),
  changed_by uuid,
  changed_at timestamptz not null default now()
);
create index product_price_history_product on public.product_price_history (product_id, changed_at desc);
create table public.stock_batches (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  batch_code text,
  expiry_date date,
  received_qty numeric(14, 3) not null default 0,
  remaining_qty numeric(14, 3) not null default 0 check (remaining_qty >= 0),
  supplier_id uuid references public.suppliers (id) on delete set null,
  purchase_id uuid,
  created_at timestamptz not null default now()
);
create index stock_batches_product on public.stock_batches (product_id, expiry_date) where remaining_qty > 0;
create index stock_batches_expiry on public.stock_batches (business_id, expiry_date) where remaining_qty > 0;
create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id),
  movement_type text not null check (movement_type in (
    'opening', 'purchase_receipt', 'sale', 'sale_return', 'supplier_return',
    'damaged', 'expired', 'missing', 'found', 'correction', 'count', 'import_rollback')),
  quantity numeric(14, 3) not null check (quantity <> 0),   -- signed, base units
  unit_cost numeric(18, 4) not null,                         -- cost per base unit used
  value numeric(18, 4) not null,                             -- signed inventory value change
  qty_after numeric(14, 3) not null,
  avg_cost_after numeric(18, 4) not null,
  stock_value_after numeric(18, 4) not null,
  batch_id uuid references public.stock_batches (id) on delete set null,
  ref_type text,
  ref_id uuid,
  ref_number text,
  reason text,
  cost_estimated boolean not null default false,
  client_ref uuid,
  created_by uuid,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index stock_movements_product on public.stock_movements (product_id, occurred_at desc);
create index stock_movements_business on public.stock_movements (business_id, occurred_at desc);
create index stock_movements_ref on public.stock_movements (ref_type, ref_id);
create unique index stock_movements_client_ref on public.stock_movements (business_id, client_ref)
  where client_ref is not null;
create table public.stock_counts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  number text not null,
  status text not null default 'draft' check (status in ('draft', 'completed', 'cancelled')),
  scope text,
  notes text,
  created_by uuid,
  created_at timestamptz not null default now(),
  completed_by uuid,
  completed_at timestamptz,
  adjustment_value numeric(18, 4)
);
create table public.stock_count_lines (
  id uuid primary key default gen_random_uuid(),
  count_id uuid not null references public.stock_counts (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id),
  expected_qty numeric(14, 3) not null,      -- system quantity when the count was opened
  counted_qty numeric(14, 3),
  system_qty_at_completion numeric(14, 3),
  difference numeric(14, 3),
  value_difference numeric(18, 4),
  reason text,
  unique (count_id, product_id)
);
create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  entity_type text not null check (entity_type in ('purchase', 'expense', 'supplier', 'sale', 'customer', 'product', 'stock_count')),
  entity_id uuid not null,
  path text not null,
  file_name text,
  mime_type text,
  size_bytes int,
  uploaded_by uuid,
  created_at timestamptz not null default now()
);
create index attachments_entity on public.attachments (entity_type, entity_id);
create trigger suppliers_touch before update on public.suppliers
  for each row execute function app.touch_updated_at();
create trigger products_touch before update on public.products
  for each row execute function app.touch_updated_at();
create or replace function app.log_product_change(p_new public.products, p_old public.products) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_new.purchase_cost is distinct from p_old.purchase_cost
     or p_new.selling_price is distinct from p_old.selling_price then
    insert into public.product_price_history (business_id, product_id, old_purchase_cost,
      new_purchase_cost, old_selling_price, new_selling_price, changed_by)
    values (p_new.business_id, p_new.id, p_old.purchase_cost, p_new.purchase_cost,
            p_old.selling_price, p_new.selling_price, auth.uid());
  end if;
  if p_new.status = 'archived' and p_old.status <> 'archived' then
    perform app.audit(p_new.business_id, 'product.archived', 'product', p_new.id::text,
                      jsonb_build_object('name', p_new.name));
  end if;
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
    new.sku := btrim(new.sku);
    new.barcode := nullif(btrim(coalesce(new.barcode, '')), '');
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
  new.sku := btrim(new.sku);
  new.barcode := nullif(btrim(coalesce(new.barcode, '')), '');
  perform app.log_product_change(new, old);
  return new;
end $$;
create trigger products_guard before insert or update on public.products
  for each row execute function app.products_guard();
create or replace function app.same_business_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.products p where p.id = new.product_id and p.business_id = new.business_id) then
    perform app.raise('invalid_product');
  end if;
  return new;
end $$;
create trigger product_units_business before insert or update on public.product_units
  for each row execute function app.same_business_guard();
create or replace function app.product_refs_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.category_id is not null and not exists (
    select 1 from public.categories c where c.id = new.category_id and c.business_id = new.business_id) then
    perform app.raise('invalid_category');
  end if;
  if new.preferred_supplier_id is not null and not exists (
    select 1 from public.suppliers s where s.id = new.preferred_supplier_id and s.business_id = new.business_id) then
    perform app.raise('invalid_supplier');
  end if;
  if new.variant_of is not null and not exists (
    select 1 from public.products p where p.id = new.variant_of and p.business_id = new.business_id) then
    perform app.raise('invalid_product');
  end if;
  return new;
end $$;
create trigger products_refs before insert or update on public.products
  for each row execute function app.product_refs_guard();
create or replace function app.apply_movement(
  p_business uuid,
  p_product uuid,
  p_type text,
  p_qty numeric,              -- signed quantity in base units
  p_unit_cost numeric,        -- acquisition cost per base unit for inflows; null = current average
  p_ref_type text default null,
  p_ref_id uuid default null,
  p_ref_number text default null,
  p_reason text default null,
  p_batch uuid default null,
  p_cost_estimated boolean default false,
  p_client_ref uuid default null,
  p_occurred_at timestamptz default now(),
  p_allow_negative boolean default null
) returns public.stock_movements
language plpgsql security definer set search_path = public as $$
declare
  pr public.products;
  allow_neg boolean;
  v_cost numeric(18, 4);
  v_value numeric(18, 4);
  new_qty numeric(14, 3);
  new_value numeric(18, 4);
  new_avg numeric(18, 4);
  mv public.stock_movements;
begin
  if p_qty is null or p_qty = 0 then perform app.raise('invalid_quantity'); end if;
  select * into pr from public.products where id = p_product and business_id = p_business for update;
  if not found then perform app.raise('invalid_product'); end if;
  if not pr.allow_fraction and p_qty <> trunc(p_qty) then
    perform app.raise('fractional_quantity_not_allowed', jsonb_build_object('product', pr.name));
  end if;
  new_qty := pr.qty_on_hand + p_qty;
  if p_qty > 0 then
    v_cost := coalesce(p_unit_cost, pr.avg_cost);
    if v_cost < 0 then perform app.raise('invalid_cost'); end if;
    v_value := round(p_qty * v_cost, 4);
    if pr.qty_on_hand <= 0 then
      new_value := round(new_qty * v_cost, 4);
      new_avg := v_cost;
    else
      new_value := pr.stock_value + v_value;
      new_avg := round(new_value / new_qty, 4);
    end if;
  else
    select allow_negative_stock into allow_neg from public.business_settings where business_id = p_business;
    allow_neg := coalesce(p_allow_negative, allow_neg, false);
    if new_qty < 0 and not allow_neg then
      perform app.raise('insufficient_stock', jsonb_build_object(
        'product', pr.name, 'available', pr.qty_on_hand, 'requested', -p_qty, 'unit', pr.base_unit));
    end if;
    v_cost := pr.avg_cost;
    if new_qty = 0 then
      v_value := -pr.stock_value;              -- remove the full remaining value: no rounding residue
      new_value := 0;
    else
      v_value := round(p_qty * v_cost, 4);
      new_value := case when new_qty < 0 then round(new_qty * v_cost, 4) else pr.stock_value + v_value end;
    end if;
    new_avg := pr.avg_cost;
  end if;
  update public.products
     set qty_on_hand = new_qty, stock_value = new_value, avg_cost = new_avg
   where id = p_product;
  insert into public.stock_movements (business_id, product_id, movement_type, quantity, unit_cost, value,
    qty_after, avg_cost_after, stock_value_after, batch_id, ref_type, ref_id, ref_number, reason,
    cost_estimated, client_ref, created_by, occurred_at)
  values (p_business, p_product, p_type, p_qty, v_cost, v_value, new_qty, new_avg, new_value, p_batch,
    p_ref_type, p_ref_id, p_ref_number, p_reason, p_cost_estimated, p_client_ref, auth.uid(),
    coalesce(p_occurred_at, now()))
  returning * into mv;
  return mv;
end $$;
create or replace function app.consume_batches(p_product uuid, p_qty numeric) returns void
language plpgsql security definer set search_path = public as $$
declare b record; remaining numeric := p_qty; take numeric;
begin
  for b in select id, remaining_qty from public.stock_batches
           where product_id = p_product and remaining_qty > 0
           order by expiry_date nulls last, created_at for update loop
    exit when remaining <= 0;
    take := least(b.remaining_qty, remaining);
    update public.stock_batches set remaining_qty = remaining_qty - take where id = b.id;
    remaining := remaining - take;
  end loop;
end $$;
create or replace function app.resolve_unit(p_product uuid, p_unit uuid, out unit_id uuid, out unit_name text, out factor numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if p_unit is null then
    select null, base_unit, 1 into unit_id, unit_name, factor from public.products where id = p_product;
  else
    select id, name, product_units.factor into unit_id, unit_name, factor
    from public.product_units where id = p_unit and product_id = p_product and active;
    if not found then perform app.raise('invalid_unit'); end if;
  end if;
end $$;
create or replace function public.record_opening_stock(
  p_business uuid, p_product uuid, p_quantity numeric, p_unit_cost numeric,
  p_cost_known boolean default true, p_unit uuid default null,
  p_batch_code text default null, p_expiry date default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare u record; mv public.stock_movements; bid uuid; existing uuid; batch uuid; cost numeric;
begin
  perform app.require_perm(p_business, 'products.manage');
  if p_client_ref is not null then
    select id into existing from public.stock_movements where business_id = p_business and client_ref = p_client_ref;
    if found then return existing; end if;
  end if;
  if p_quantity is null or p_quantity <= 0 then perform app.raise('invalid_quantity'); end if;
  select * into u from app.resolve_unit(p_product, p_unit);
  cost := coalesce(p_unit_cost, 0);
  if cost < 0 then perform app.raise('invalid_cost'); end if;
  if not coalesce(p_cost_known, true) and cost = 0 then
    select purchase_cost into cost from public.products where id = p_product;
    cost := cost * u.factor;
  end if;
  if exists (select 1 from public.products where id = p_product and track_expiry)
     and (p_batch_code is not null or p_expiry is not null) then
    insert into public.stock_batches (business_id, product_id, batch_code, expiry_date, received_qty, remaining_qty)
    values (p_business, p_product, p_batch_code, p_expiry, p_quantity * u.factor, p_quantity * u.factor)
    returning id into batch;
  end if;
  mv := app.apply_movement(p_business, p_product, 'opening', p_quantity * u.factor, cost / u.factor,
    'opening', null, null, 'Opening stock', batch, not coalesce(p_cost_known, true), p_client_ref);
  perform app.audit(p_business, 'stock.opening', 'product', p_product::text,
    jsonb_build_object('quantity', p_quantity * u.factor, 'unit_cost', cost / u.factor, 'cost_known', p_cost_known));
  return mv.id;
end $$;
create or replace function public.adjust_stock(
  p_business uuid, p_product uuid, p_kind text, p_quantity numeric, p_reason text,
  p_batch uuid default null, p_unit_cost numeric default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare signed numeric; mv public.stock_movements; existing uuid;
begin
  perform app.require_perm(p_business, 'stock.adjust');
  if p_client_ref is not null then
    select id into existing from public.stock_movements where business_id = p_business and client_ref = p_client_ref;
    if found then return existing; end if;
  end if;
  if p_kind not in ('damaged', 'expired', 'missing', 'found', 'correction') then
    perform app.raise('invalid_adjustment_type');
  end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  if p_quantity is null or p_quantity = 0 then perform app.raise('invalid_quantity'); end if;
  signed := case
    when p_kind in ('damaged', 'expired', 'missing') then -abs(p_quantity)
    when p_kind = 'found' then abs(p_quantity)
    else p_quantity end;
  if p_batch is not null then
    if not exists (select 1 from public.stock_batches where id = p_batch and product_id = p_product) then
      perform app.raise('invalid_batch');
    end if;
    if signed < 0 then
      update public.stock_batches set remaining_qty = remaining_qty + signed
       where id = p_batch and remaining_qty + signed >= 0;
      if not found then perform app.raise('insufficient_batch_quantity'); end if;
    else
      update public.stock_batches set remaining_qty = remaining_qty + signed where id = p_batch;
    end if;
  elsif signed < 0 then
    perform app.consume_batches(p_product, -signed);
  end if;
  mv := app.apply_movement(p_business, p_product, p_kind, signed, p_unit_cost, 'adjustment', null, null,
    btrim(p_reason), p_batch, false, p_client_ref, now(), false);
  perform app.audit(p_business, 'stock.adjusted', 'product', p_product::text,
    jsonb_build_object('kind', p_kind, 'quantity', signed, 'reason', p_reason, 'value', mv.value));
  return mv.id;
end $$;
create or replace function public.create_stock_count(
  p_business uuid, p_product_ids uuid[] default null, p_category uuid default null, p_notes text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; n int;
begin
  perform app.require_perm(p_business, 'stock.adjust');
  insert into public.stock_counts (business_id, number, scope, notes, created_by)
  values (p_business, app.next_number(p_business, 'count', 'CNT-'),
          case when p_product_ids is not null then 'selected'
               when p_category is not null then 'category' else 'all' end,
          p_notes, auth.uid())
  returning id into cid;
  insert into public.stock_count_lines (count_id, business_id, product_id, expected_qty)
  select cid, p_business, p.id, p.qty_on_hand from public.products p
  where p.business_id = p_business and p.status = 'active'
    and (p_product_ids is null or p.id = any (p_product_ids))
    and (p_category is null or p.category_id = p_category);
  get diagnostics n = row_count;
  if n = 0 then perform app.raise('no_products_selected'); end if;
  perform app.audit(p_business, 'stock_count.created', 'stock_count', cid::text, jsonb_build_object('lines', n));
  return cid;
end $$;
create or replace function public.save_stock_count_lines(p_count uuid, p_lines jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare c public.stock_counts; l jsonb;
begin
  select * into c from public.stock_counts where id = p_count;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(c.business_id, 'stock.adjust');
  if c.status <> 'draft' then perform app.raise('count_not_editable'); end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    if (l ->> 'counted_qty') is not null and (l ->> 'counted_qty')::numeric < 0 then
      perform app.raise('invalid_quantity');
    end if;
    update public.stock_count_lines
       set counted_qty = (l ->> 'counted_qty')::numeric, reason = nullif(l ->> 'reason', '')
     where count_id = p_count and product_id = (l ->> 'product_id')::uuid;
  end loop;
end $$;
create or replace function public.complete_stock_count(p_count uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.stock_counts; l record; diff numeric; mv public.stock_movements; total numeric := 0; adjusted int := 0;
begin
  select * into c from public.stock_counts where id = p_count for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(c.business_id, 'stock.adjust');
  if c.status <> 'draft' then perform app.raise('count_not_editable'); end if;
  for l in select cl.*, p.qty_on_hand from public.stock_count_lines cl
           join public.products p on p.id = cl.product_id
           where cl.count_id = p_count and cl.counted_qty is not null
           order by cl.product_id loop
    diff := l.counted_qty - l.qty_on_hand;
    if diff <> 0 and coalesce(btrim(l.reason), '') = '' then
      perform app.raise('reason_required_for_discrepancy');
    end if;
    update public.stock_count_lines set system_qty_at_completion = l.qty_on_hand, difference = diff
     where id = l.id;
    if diff <> 0 then
      if diff < 0 then perform app.consume_batches(l.product_id, -diff); end if;
      mv := app.apply_movement(c.business_id, l.product_id, 'count', diff, null, 'stock_count', c.id, c.number,
        l.reason, null, false, null, now(), true);
      update public.stock_count_lines set value_difference = mv.value where id = l.id;
      total := total + mv.value;
      adjusted := adjusted + 1;
    end if;
  end loop;
  update public.stock_counts set status = 'completed', completed_by = auth.uid(), completed_at = now(),
         adjustment_value = total where id = p_count;
  perform app.audit(c.business_id, 'stock_count.completed', 'stock_count', p_count::text,
    jsonb_build_object('adjusted_lines', adjusted, 'value', total));
  return jsonb_build_object('adjusted_lines', adjusted, 'value_difference', total);
end $$;
create or replace function public.cancel_stock_count(p_count uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c public.stock_counts;
begin
  select * into c from public.stock_counts where id = p_count for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(c.business_id, 'stock.adjust');
  if c.status <> 'draft' then perform app.raise('count_not_editable'); end if;
  update public.stock_counts set status = 'cancelled' where id = p_count;
  perform app.audit(c.business_id, 'stock_count.cancelled', 'stock_count', p_count::text);
end $$;
commit;
