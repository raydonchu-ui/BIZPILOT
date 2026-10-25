-- BizPilot setup PART 3 of 19. Run parts in order.
begin;
alter table public.categories enable row level security;
alter table public.import_batches enable row level security;
alter table public.suppliers enable row level security;
alter table public.products enable row level security;
alter table public.product_units enable row level security;
alter table public.product_price_history enable row level security;
alter table public.stock_batches enable row level security;
alter table public.stock_movements enable row level security;
alter table public.stock_counts enable row level security;
alter table public.stock_count_lines enable row level security;
alter table public.attachments enable row level security;
create policy categories_read on public.categories for select using (app.can_read(business_id));
create policy categories_write on public.categories for insert with check (app.has_perm(business_id, 'products.manage'));
create policy categories_update on public.categories for update using (app.has_perm(business_id, 'products.manage'))
  with check (app.has_perm(business_id, 'products.manage'));
create policy categories_delete on public.categories for delete using (app.has_perm(business_id, 'products.manage'));
create policy import_batches_read on public.import_batches for select using (app.has_perm(business_id, 'imports.manage'));
create policy suppliers_read on public.suppliers for select using (app.can_read(business_id));
create policy suppliers_insert on public.suppliers for insert with check (
  app.has_perm(business_id, 'suppliers.manage') and app.has_feature(business_id, 'suppliers'));
create policy suppliers_update on public.suppliers for update using (app.has_perm(business_id, 'suppliers.manage'))
  with check (app.has_perm(business_id, 'suppliers.manage'));
create policy products_read on public.products for select using (app.can_read(business_id));
create policy products_insert on public.products for insert with check (app.has_perm(business_id, 'products.manage'));
create policy products_update on public.products for update using (app.has_perm(business_id, 'products.manage'))
  with check (app.has_perm(business_id, 'products.manage'));
create policy product_units_read on public.product_units for select using (app.can_read(business_id));
create policy product_units_insert on public.product_units for insert with check (app.has_perm(business_id, 'products.manage'));
create policy product_units_update on public.product_units for update using (app.has_perm(business_id, 'products.manage'))
  with check (app.has_perm(business_id, 'products.manage'));
create policy price_history_read on public.product_price_history for select using (app.has_perm(business_id, 'products.manage'));
create policy batches_read on public.stock_batches for select using (app.can_read(business_id));
create policy movements_read on public.stock_movements for select
  using (app.can_read(business_id) and occurred_at >= app.history_cutoff(business_id));
create policy counts_read on public.stock_counts for select using (app.can_read(business_id));
create policy count_lines_read on public.stock_count_lines for select using (app.can_read(business_id));
create policy attachments_read on public.attachments for select using (app.can_read(business_id));
create policy attachments_insert on public.attachments for insert with check (
  app.is_member(business_id) and uploaded_by = auth.uid()
  and split_part(path, '/', 1) = business_id::text);
create table public.customers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 120),
  phone text,
  email text,
  address text,
  credit_limit numeric(14, 2) check (credit_limit >= 0),
  notes text,
  status text not null default 'active' check (status in ('active', 'archived')),
  import_batch_id uuid references public.import_batches (id) on delete set null,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index customers_business on public.customers (business_id, name);
create trigger customers_touch before update on public.customers
  for each row execute function app.touch_updated_at();
create table public.cash_accounts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null,
  kind text not null check (kind in ('cash', 'mtn_momo', 'orange_money', 'bank', 'other')),
  opening_balance numeric(14, 2) not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (business_id, kind)
);
create or replace function app.init_accounts(bid uuid) returns void
language sql security definer set search_path = public as $$
  insert into public.cash_accounts (business_id, name, kind) values
    (bid, 'Cash', 'cash'), (bid, 'MTN Mobile Money', 'mtn_momo'), (bid, 'Orange Money', 'orange_money'),
    (bid, 'Bank', 'bank'), (bid, 'Other', 'other')
  on conflict do nothing
$$;
create or replace function app.account_for_method(bid uuid, m text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare k text; aid uuid;
begin
  if m not in ('cash', 'mtn_momo', 'orange_money', 'bank_transfer', 'card', 'other') then
    perform app.raise('invalid_payment_method');
  end if;
  k := case m when 'bank_transfer' then 'bank' when 'card' then 'bank' else m end;
  select id into aid from public.cash_accounts where business_id = bid and kind = k;
  return aid;
end $$;
create table public.purchases (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  number text not null,
  client_ref uuid,
  supplier_id uuid not null references public.suppliers (id),
  invoice_number text,
  purchase_date date not null,
  expected_date date,
  due_date date,
  status text not null default 'draft' check (status in ('draft', 'ordered', 'partially_received', 'received', 'cancelled')),
  subtotal numeric(14, 2) not null default 0,
  discount_amount numeric(14, 2) not null default 0 check (discount_amount >= 0),
  tax_total numeric(14, 2) not null default 0,
  transport_cost numeric(14, 2) not null default 0 check (transport_cost >= 0),
  other_costs numeric(14, 2) not null default 0 check (other_costs >= 0),
  total numeric(14, 2) not null default 0 check (total >= 0),
  received_value numeric(18, 4) not null default 0,
  credited_total numeric(14, 2) not null default 0,
  paid_total numeric(14, 2) not null default 0,
  closed_short boolean not null default false,
  notes text,
  first_received_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index purchases_client_ref on public.purchases (business_id, client_ref) where client_ref is not null;
create unique index purchases_number on public.purchases (business_id, number);
create index purchases_business_date on public.purchases (business_id, purchase_date desc);
create index purchases_supplier on public.purchases (supplier_id, purchase_date);
create trigger purchases_touch before update on public.purchases
  for each row execute function app.touch_updated_at();
create table public.purchase_lines (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.purchases (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id),
  unit_id uuid references public.product_units (id),
  unit_name text not null,
  unit_factor numeric(14, 4) not null check (unit_factor > 0),
  qty_ordered numeric(14, 3) not null check (qty_ordered > 0),
  qty_received numeric(14, 3) not null default 0 check (qty_received >= 0),
  qty_returned numeric(14, 3) not null default 0 check (qty_returned >= 0),   -- base units
  unit_cost numeric(14, 2) not null check (unit_cost >= 0),                   -- per purchase unit
  discount_amount numeric(14, 2) not null default 0 check (discount_amount >= 0),
  tax_amount numeric(14, 2) not null default 0 check (tax_amount >= 0),
  line_total numeric(14, 2) not null check (line_total >= 0),
  landed_unit_cost_base numeric(18, 4),   -- fixed at first receipt, includes allocated transport/other costs
  sort int not null default 0,
  check (qty_received <= qty_ordered)
);
create index purchase_lines_purchase on public.purchase_lines (purchase_id);
create index purchase_lines_product on public.purchase_lines (product_id);
create table public.purchase_receipts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  purchase_id uuid not null references public.purchases (id),
  number text not null,
  received_at timestamptz not null default now(),
  received_by uuid,
  notes text,
  value numeric(18, 4) not null default 0,
  client_ref uuid
);
create unique index purchase_receipts_client_ref on public.purchase_receipts (business_id, client_ref) where client_ref is not null;
create index purchase_receipts_purchase on public.purchase_receipts (purchase_id);
create table public.purchase_receipt_lines (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references public.purchase_receipts (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  purchase_line_id uuid not null references public.purchase_lines (id),
  product_id uuid not null references public.products (id),
  quantity numeric(14, 3) not null check (quantity > 0),   -- purchase units
  base_quantity numeric(14, 3) not null,
  unit_cost_base numeric(18, 4) not null,
  value numeric(18, 4) not null,
  batch_id uuid references public.stock_batches (id),
  movement_id uuid references public.stock_movements (id)
);
create table public.supplier_credits (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  supplier_id uuid not null references public.suppliers (id),
  purchase_id uuid references public.purchases (id),
  kind text not null check (kind in ('return', 'short_shipment', 'adjustment')),
  amount numeric(14, 2) not null check (amount > 0),
  reason text not null,
  reference_id uuid,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index supplier_credits_supplier on public.supplier_credits (supplier_id);
create table public.supplier_returns (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  number text not null,
  purchase_id uuid not null references public.purchases (id),
  supplier_id uuid not null references public.suppliers (id),
  reason text not null,
  credit_amount numeric(14, 2) not null,
  stock_value numeric(18, 4) not null,
  client_ref uuid,
  created_by uuid,
  created_at timestamptz not null default now()
);
create unique index supplier_returns_client_ref on public.supplier_returns (business_id, client_ref) where client_ref is not null;
create table public.supplier_return_lines (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references public.supplier_returns (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  purchase_line_id uuid not null references public.purchase_lines (id),
  product_id uuid not null references public.products (id),
  base_quantity numeric(14, 3) not null check (base_quantity > 0),
  credit_amount numeric(14, 2) not null,
  stock_value numeric(18, 4) not null
);
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  direction text not null check (direction in ('in', 'out')),
  kind text not null check (kind in ('sale_payment', 'customer_payment', 'customer_refund',
                                     'supplier_payment', 'supplier_refund', 'expense_payment', 'expense_refund')),
  method text not null check (method in ('cash', 'mtn_momo', 'orange_money', 'bank_transfer', 'card', 'other')),
  account_id uuid references public.cash_accounts (id),
  amount numeric(14, 2) not null check (amount > 0),
  customer_id uuid references public.customers (id),
  supplier_id uuid references public.suppliers (id),
  sale_id uuid,
  sale_return_id uuid,
  purchase_id uuid references public.purchases (id),
  expense_id uuid,
  reference text,
  notes text,
  paid_at timestamptz not null default now(),
  client_ref uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  check ((direction = 'in') = (kind in ('sale_payment', 'customer_payment', 'supplier_refund', 'expense_refund')))
);
create unique index payments_client_ref on public.payments (business_id, client_ref) where client_ref is not null;
create index payments_business_date on public.payments (business_id, paid_at desc);
create index payments_customer on public.payments (customer_id) where customer_id is not null;
create index payments_supplier on public.payments (supplier_id) where supplier_id is not null;
create index payments_sale on public.payments (sale_id) where sale_id is not null;
create table public.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  payment_id uuid not null references public.payments (id) on delete cascade,
  sale_id uuid,
  purchase_id uuid references public.purchases (id),
  expense_id uuid,
  amount numeric(14, 2) not null check (amount > 0),
  created_at timestamptz not null default now(),
  check (num_nonnulls(sale_id, purchase_id, expense_id) = 1)
);
create index payment_allocations_payment on public.payment_allocations (payment_id);
create index payment_allocations_purchase on public.payment_allocations (purchase_id) where purchase_id is not null;
create index payment_allocations_sale on public.payment_allocations (sale_id) where sale_id is not null;
create or replace function app.supplier_balance(p_supplier uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(total) from public.purchases where supplier_id = p_supplier
                     and status in ('ordered', 'partially_received', 'received')), 0)
       - coalesce((select sum(amount) from public.supplier_credits where supplier_id = p_supplier), 0)
       - coalesce((select sum(amount) from public.payments where supplier_id = p_supplier and kind = 'supplier_payment'), 0)
       + coalesce((select sum(amount) from public.payments where supplier_id = p_supplier and kind = 'supplier_refund'), 0)
$$;
create or replace function app.rebalance_supplier(p_supplier uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  pay record; pur record; refunds numeric; avail numeric; take numeric; outstanding numeric;
begin
  delete from public.payment_allocations a using public.payments p
   where a.payment_id = p.id and p.supplier_id = p_supplier and p.kind = 'supplier_payment';
  create temp table if not exists _avail (payment_id uuid primary key, purchase_id uuid, paid_at timestamptz, amount numeric) on commit drop;
  delete from _avail where true;
  insert into _avail select id, purchase_id, paid_at, amount from public.payments
   where supplier_id = p_supplier and kind = 'supplier_payment';
  select coalesce(sum(amount), 0) into refunds from public.payments
   where supplier_id = p_supplier and kind = 'supplier_refund';
  for pay in select * from _avail order by paid_at desc, payment_id loop
    exit when refunds <= 0;
    take := least(pay.amount, refunds);
    update _avail set amount = amount - take where payment_id = pay.payment_id;
    refunds := refunds - take;
  end loop;
  create temp table if not exists _owed (purchase_id uuid primary key, pdate date, created timestamptz, owed numeric) on commit drop;
  delete from _owed where true;
  insert into _owed select id, purchase_date, created_at, total - credited_total
    from public.purchases where supplier_id = p_supplier
     and status in ('ordered', 'partially_received', 'received') and total - credited_total > 0;
  for pay in select * from _avail where purchase_id is not null and amount > 0 order by paid_at, payment_id loop
    select owed into outstanding from _owed where purchase_id = pay.purchase_id;
    if coalesce(outstanding, 0) > 0 then
      take := least(pay.amount, outstanding);
      insert into public.payment_allocations (business_id, payment_id, purchase_id, amount)
      select business_id, pay.payment_id, pay.purchase_id, take from public.payments where id = pay.payment_id;
      update _owed set owed = owed - take where purchase_id = pay.purchase_id;
      update _avail set amount = amount - take where payment_id = pay.payment_id;
    end if;
  end loop;
  for pay in select * from _avail where amount > 0 order by paid_at, payment_id loop
    avail := pay.amount;
    for pur in select * from _owed where owed > 0 order by pdate, created, purchase_id loop
      exit when avail <= 0;
      take := least(avail, pur.owed);
      insert into public.payment_allocations (business_id, payment_id, purchase_id, amount)
      select business_id, pay.payment_id, pur.purchase_id, take from public.payments where id = pay.payment_id;
      update _owed set owed = owed - take where purchase_id = pur.purchase_id;
      avail := avail - take;
    end loop;
  end loop;
  update public.purchases pu set paid_total = coalesce((
      select sum(a.amount) from public.payment_allocations a where a.purchase_id = pu.id), 0)
   where pu.supplier_id = p_supplier;
end $$;
create or replace function app.purchase_feature_check(bid uuid) returns void
language plpgsql stable as $$
begin
  perform app.require_perm(bid, 'purchases.manage');
  perform app.require_feature(bid, 'purchases');
end $$;
create or replace function app.insert_payment(
  p_business uuid, p_kind text, p_method text, p_amount numeric, p_paid_at timestamptz,
  p_reference text, p_notes text, p_client_ref uuid,
  p_customer uuid default null, p_supplier uuid default null, p_sale uuid default null,
  p_purchase uuid default null, p_expense uuid default null, p_return uuid default null)
returns public.payments language plpgsql security definer set search_path = public as $$
declare r public.payments;
begin
  if p_amount is null or p_amount <= 0 then perform app.raise('invalid_amount'); end if;
  insert into public.payments (business_id, direction, kind, method, account_id, amount, customer_id, supplier_id,
    sale_id, purchase_id, expense_id, sale_return_id, reference, notes, paid_at, client_ref, created_by)
  values (p_business,
    case when p_kind in ('sale_payment', 'customer_payment', 'supplier_refund', 'expense_refund') then 'in' else 'out' end,
    p_kind, p_method, app.account_for_method(p_business, p_method), app.money(p_business, p_amount),
    p_customer, p_supplier, p_sale, p_purchase, p_expense, p_return,
    nullif(btrim(coalesce(p_reference, '')), ''), p_notes, coalesce(p_paid_at, now()), p_client_ref, auth.uid())
  returning * into r;
  return r;
end $$;
create or replace function public.save_purchase(p_business uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  pid uuid := nullif(p ->> 'id', '')::uuid;
  cref uuid := nullif(p ->> 'client_ref', '')::uuid;
  cur public.purchases;
  sup public.suppliers;
  l jsonb; u record; i int := 0;
  v_qty numeric; v_cost numeric; v_disc numeric; v_tax numeric; v_total numeric;
  sub numeric := 0; taxes numeric := 0; hdr_disc numeric; transport numeric; other numeric; grand numeric;
  st text := coalesce(p ->> 'status', 'draft');
  pdate date := coalesce(nullif(p ->> 'purchase_date', '')::date, app.biz_today(p_business));
  due date := nullif(p ->> 'due_date', '')::date;
begin
  perform app.purchase_feature_check(p_business);
  if st not in ('draft', 'ordered') then perform app.raise('invalid_status'); end if;
  if pid is null and cref is not null then
    select id into pid from public.purchases where business_id = p_business and client_ref = cref;
    if found then return pid; end if;   -- idempotent retry
  end if;
  select * into sup from public.suppliers where id = (p ->> 'supplier_id')::uuid and business_id = p_business;
  if not found then perform app.raise('invalid_supplier'); end if;
  if jsonb_typeof(p -> 'lines') <> 'array' or jsonb_array_length(p -> 'lines') = 0 then
    perform app.raise('lines_required');
  end if;
  hdr_disc := coalesce((p ->> 'discount_amount')::numeric, 0);
  transport := coalesce((p ->> 'transport_cost')::numeric, 0);
  other := coalesce((p ->> 'other_costs')::numeric, 0);
  if hdr_disc < 0 or transport < 0 or other < 0 then perform app.raise('invalid_amount'); end if;
  if due is null and sup.payment_terms_days is not null then due := pdate + sup.payment_terms_days; end if;
  if pid is not null then
    select * into cur from public.purchases where id = pid and business_id = p_business for update;
    if not found then perform app.raise('not_found'); end if;
    if cur.status not in ('draft', 'ordered') or exists (
         select 1 from public.purchase_lines where purchase_id = pid and qty_received > 0) then
      perform app.raise('purchase_locked');
    end if;
    delete from public.purchase_lines where purchase_id = pid;
    update public.purchases set supplier_id = sup.id, invoice_number = nullif(p ->> 'invoice_number', ''),
      purchase_date = pdate, expected_date = nullif(p ->> 'expected_date', '')::date, due_date = due,
      status = st, discount_amount = hdr_disc, transport_cost = transport, other_costs = other,
      notes = nullif(p ->> 'notes', '')
     where id = pid;
  else
    insert into public.purchases (business_id, number, client_ref, supplier_id, invoice_number, purchase_date,
      expected_date, due_date, status, discount_amount, transport_cost, other_costs, notes, created_by)
    values (p_business, app.next_number(p_business, 'purchase', 'PO-'), cref, sup.id,
      nullif(p ->> 'invoice_number', ''), pdate, nullif(p ->> 'expected_date', '')::date, due, st,
      hdr_disc, transport, other, nullif(p ->> 'notes', ''), auth.uid())
    returning id into pid;
  end if;
  for l in select * from jsonb_array_elements(p -> 'lines') loop
    i := i + 1;
    if not exists (select 1 from public.products where id = (l ->> 'product_id')::uuid and business_id = p_business) then
      perform app.raise('invalid_product');
    end if;
    select * into u from app.resolve_unit((l ->> 'product_id')::uuid, nullif(l ->> 'unit_id', '')::uuid);
    v_qty := (l ->> 'quantity')::numeric;
    v_cost := coalesce((l ->> 'unit_cost')::numeric, 0);
    v_disc := coalesce((l ->> 'discount_amount')::numeric, 0);
    v_tax := coalesce((l ->> 'tax_amount')::numeric, 0);
    if v_qty is null or v_qty <= 0 then perform app.raise('invalid_quantity'); end if;
    if v_cost < 0 or v_disc < 0 or v_tax < 0 then perform app.raise('invalid_amount'); end if;
    v_total := app.money(p_business, v_qty * v_cost - v_disc + v_tax);
    if v_total < 0 then perform app.raise('discount_exceeds_line'); end if;
    insert into public.purchase_lines (purchase_id, business_id, product_id, unit_id, unit_name, unit_factor,
      qty_ordered, unit_cost, discount_amount, tax_amount, line_total, sort)
    values (pid, p_business, (l ->> 'product_id')::uuid, u.unit_id, u.unit_name, u.factor,
      v_qty, v_cost, v_disc, v_tax, v_total, i);
    sub := sub + v_total;
    taxes := taxes + v_tax;
  end loop;
  grand := sub + transport + other - hdr_disc;
  if grand < 0 then perform app.raise('discount_exceeds_total'); end if;
  update public.purchases set subtotal = sub, tax_total = taxes, total = grand where id = pid;
  perform app.audit(p_business, case when cur.id is null then 'purchase.created' else 'purchase.updated' end,
    'purchase', pid::text, jsonb_build_object('status', st, 'total', grand));
  if st = 'ordered' and coalesce((p #>> '{payment,amount}')::numeric, 0) > 0 then
    perform public.record_supplier_payment(p_business, sup.id, (p #>> '{payment,amount}')::numeric,
      coalesce(p #>> '{payment,method}', 'cash'), p #>> '{payment,reference}', null, pid, null,
      nullif(p #>> '{payment,client_ref}', '')::uuid);
  end if;
  if coalesce((p ->> 'receive_now')::boolean, false) then
    if st <> 'ordered' then perform app.raise('invalid_status'); end if;
    perform public.receive_purchase(pid, (
      select jsonb_agg(jsonb_build_object('line_id', pl.id, 'quantity', pl.qty_ordered,
                                          'batch_code', ln ->> 'batch_code', 'expiry_date', ln ->> 'expiry_date'))
      from public.purchase_lines pl
      left join lateral (select x as ln from jsonb_array_elements(p -> 'lines') with ordinality t(x, n)
                         where n = pl.sort) q on true
      where pl.purchase_id = pid), null, null);
  end if;
  perform app.rebalance_supplier(sup.id);
  return pid;
end $$;
create or replace function public.mark_purchase_ordered(p_purchase uuid)
returns void language plpgsql security definer set search_path = public as $$
declare pu public.purchases;
begin
  select * into pu from public.purchases where id = p_purchase for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.purchase_feature_check(pu.business_id);
  if pu.status <> 'draft' then perform app.raise('invalid_status'); end if;
  update public.purchases set status = 'ordered' where id = p_purchase;
  perform app.audit(pu.business_id, 'purchase.ordered', 'purchase', p_purchase::text);
  perform app.rebalance_supplier(pu.supplier_id);
end $$;
create or replace function public.receive_purchase(
  p_purchase uuid, p_lines jsonb, p_client_ref uuid default null, p_notes text default null,
  p_received_at timestamptz default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  pu public.purchases; pl public.purchase_lines; pr public.products;
  rid uuid; l jsonb; f numeric; qty numeric; base numeric; landed numeric; batch uuid; mv public.stock_movements;
  total_value numeric := 0; at timestamptz := coalesce(p_received_at, now());
begin
  select * into pu from public.purchases where id = p_purchase for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.purchase_feature_check(pu.business_id);
  if p_client_ref is not null then
    select id into rid from public.purchase_receipts where business_id = pu.business_id and client_ref = p_client_ref;
    if found then return rid; end if;
  end if;
  if pu.status not in ('draft', 'ordered', 'partially_received') then perform app.raise('invalid_status'); end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then perform app.raise('lines_required'); end if;
  f := case when pu.subtotal > 0 then (pu.transport_cost + pu.other_costs - pu.discount_amount) / pu.subtotal else 0 end;
  insert into public.purchase_receipts (business_id, purchase_id, number, received_at, received_by, notes, client_ref)
  values (pu.business_id, pu.id, app.next_number(pu.business_id, 'receipt', 'GRN-'), at, auth.uid(), p_notes, p_client_ref)
  returning id into rid;
  for l in select * from jsonb_array_elements(p_lines) order by (value ->> 'line_id') loop
    qty := coalesce((l ->> 'quantity')::numeric, 0);
    continue when qty = 0;
    if qty < 0 then perform app.raise('invalid_quantity'); end if;
    select * into pl from public.purchase_lines where id = (l ->> 'line_id')::uuid and purchase_id = pu.id for update;
    if not found then perform app.raise('invalid_line'); end if;
    if pl.qty_received + qty > pl.qty_ordered then
      perform app.raise('over_receipt', jsonb_build_object('ordered', pl.qty_ordered, 'received', pl.qty_received,
                                                            'requested', qty));
    end if;
    landed := coalesce(pl.landed_unit_cost_base,
                       round(pl.line_total * (1 + f) / (pl.qty_ordered * pl.unit_factor), 4));
    base := qty * pl.unit_factor;
    select * into pr from public.products where id = pl.product_id;
    batch := null;
    if pr.track_expiry then
      insert into public.stock_batches (business_id, product_id, batch_code, expiry_date, received_qty, remaining_qty,
                                        supplier_id, purchase_id)
      values (pu.business_id, pl.product_id, nullif(l ->> 'batch_code', ''), nullif(l ->> 'expiry_date', '')::date,
              base, base, pu.supplier_id, pu.id)
      returning id into batch;
    end if;
    mv := app.apply_movement(pu.business_id, pl.product_id, 'purchase_receipt', base, landed, 'purchase', pu.id,
                             pu.number, null, batch, false, null, at);
    insert into public.purchase_receipt_lines (receipt_id, business_id, purchase_line_id, product_id, quantity,
      base_quantity, unit_cost_base, value, batch_id, movement_id)
    values (rid, pu.business_id, pl.id, pl.product_id, qty, base, landed, mv.value, batch, mv.id);
    update public.purchase_lines set qty_received = qty_received + qty, landed_unit_cost_base = landed where id = pl.id;
    update public.products set purchase_cost = landed,
           preferred_supplier_id = coalesce(preferred_supplier_id, pu.supplier_id)
     where id = pl.product_id;
    total_value := total_value + mv.value;
  end loop;
  if total_value = 0 and not exists (select 1 from public.purchase_receipt_lines where receipt_id = rid) then
    perform app.raise('nothing_to_receive');
  end if;
  update public.purchase_receipts set value = total_value where id = rid;
  update public.purchases set
    received_value = received_value + total_value,
    first_received_at = coalesce(first_received_at, at),
    status = case when exists (select 1 from public.purchase_lines where purchase_id = pu.id and qty_received < qty_ordered)
                  then 'partially_received' else 'received' end
   where id = pu.id;
  perform app.audit(pu.business_id, 'purchase.received', 'purchase', pu.id::text,
                    jsonb_build_object('receipt_id', rid, 'value', total_value));
  if pu.status = 'draft' then perform app.rebalance_supplier(pu.supplier_id); end if;
  return rid;
end $$;
commit;
