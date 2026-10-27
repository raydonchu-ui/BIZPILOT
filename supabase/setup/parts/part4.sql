-- BizPilot setup PART 4 of 27. Run parts in order.
begin;
create or replace function public.cancel_purchase(p_purchase uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare pu public.purchases;
begin
  select * into pu from public.purchases where id = p_purchase for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.purchase_feature_check(pu.business_id);
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  if pu.status not in ('draft', 'ordered') or exists (
      select 1 from public.purchase_lines where purchase_id = pu.id and qty_received > 0) then
    perform app.raise('purchase_has_receipts');
  end if;
  update public.purchases set status = 'cancelled', cancelled_at = now(), cancel_reason = btrim(p_reason)
   where id = pu.id;
  perform app.audit(pu.business_id, 'purchase.cancelled', 'purchase', pu.id::text,
                    jsonb_build_object('reason', p_reason, 'total', pu.total, 'paid', pu.paid_total));
  perform app.rebalance_supplier(pu.supplier_id);   -- payments become a supplier advance
end $$;
create or replace function public.close_purchase_short(p_purchase uuid, p_reason text)
returns numeric language plpgsql security definer set search_path = public as $$
declare pu public.purchases; f numeric; credit numeric;
begin
  select * into pu from public.purchases where id = p_purchase for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.purchase_feature_check(pu.business_id);
  if pu.status <> 'partially_received' then perform app.raise('invalid_status'); end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  f := case when pu.subtotal > 0 then (pu.transport_cost + pu.other_costs - pu.discount_amount) / pu.subtotal else 0 end;
  select app.money(pu.business_id, sum((qty_ordered - qty_received) / qty_ordered * line_total * (1 + f)))
    into credit from public.purchase_lines where purchase_id = pu.id;
  if credit > 0 then
    insert into public.supplier_credits (business_id, supplier_id, purchase_id, kind, amount, reason, created_by)
    values (pu.business_id, pu.supplier_id, pu.id, 'short_shipment', credit, btrim(p_reason), auth.uid());
  end if;
  update public.purchases set status = 'received', closed_short = true,
         credited_total = credited_total + coalesce(credit, 0) where id = pu.id;
  perform app.audit(pu.business_id, 'purchase.closed_short', 'purchase', pu.id::text,
                    jsonb_build_object('credit', credit, 'reason', p_reason));
  perform app.rebalance_supplier(pu.supplier_id);
  return coalesce(credit, 0);
end $$;
create or replace function public.return_to_supplier(p_purchase uuid, p_lines jsonb, p_reason text, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare pu public.purchases; pl public.purchase_lines; rid uuid; l jsonb; q numeric; credit numeric;
        tot_credit numeric := 0; tot_value numeric := 0; mv public.stock_movements; num text;
begin
  select * into pu from public.purchases where id = p_purchase for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.purchase_feature_check(pu.business_id);
  if p_client_ref is not null then
    select id into rid from public.supplier_returns where business_id = pu.business_id and client_ref = p_client_ref;
    if found then return rid; end if;
  end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  num := app.next_number(pu.business_id, 'supplier_return', 'SR-');
  insert into public.supplier_returns (business_id, number, purchase_id, supplier_id, reason, credit_amount, stock_value,
                                       client_ref, created_by)
  values (pu.business_id, num, pu.id, pu.supplier_id, btrim(p_reason), 0, 0, p_client_ref, auth.uid())
  returning id into rid;
  for l in select * from jsonb_array_elements(p_lines) loop
    q := coalesce((l ->> 'base_quantity')::numeric, 0);
    continue when q = 0;
    if q < 0 then perform app.raise('invalid_quantity'); end if;
    select * into pl from public.purchase_lines where id = (l ->> 'line_id')::uuid and purchase_id = pu.id for update;
    if not found then perform app.raise('invalid_line'); end if;
    if pl.qty_returned + q > pl.qty_received * pl.unit_factor then perform app.raise('return_exceeds_received'); end if;
    perform app.consume_batches(pl.product_id, q);
    mv := app.apply_movement(pu.business_id, pl.product_id, 'supplier_return', -q, null, 'supplier_return', rid, num,
                             p_reason);
    credit := app.money(pu.business_id, q * pl.landed_unit_cost_base);
    insert into public.supplier_return_lines (return_id, business_id, purchase_line_id, product_id, base_quantity,
                                              credit_amount, stock_value)
    values (rid, pu.business_id, pl.id, pl.product_id, q, credit, -mv.value);
    update public.purchase_lines set qty_returned = qty_returned + q where id = pl.id;
    tot_credit := tot_credit + credit;
    tot_value := tot_value - mv.value;
  end loop;
  if tot_credit = 0 and tot_value = 0 then perform app.raise('lines_required'); end if;
  update public.supplier_returns set credit_amount = tot_credit, stock_value = tot_value where id = rid;
  if tot_credit > 0 then
    insert into public.supplier_credits (business_id, supplier_id, purchase_id, kind, amount, reason, reference_id, created_by)
    values (pu.business_id, pu.supplier_id, pu.id, 'return', tot_credit, btrim(p_reason), rid, auth.uid());
    update public.purchases set credited_total = credited_total + tot_credit where id = pu.id;
  end if;
  perform app.audit(pu.business_id, 'purchase.returned', 'purchase', pu.id::text,
                    jsonb_build_object('return_id', rid, 'credit', tot_credit, 'stock_value', tot_value));
  perform app.rebalance_supplier(pu.supplier_id);
  return rid;
end $$;
create or replace function public.record_supplier_payment(
  p_business uuid, p_supplier uuid, p_amount numeric, p_method text, p_reference text default null,
  p_paid_at timestamptz default null, p_purchase uuid default null, p_notes text default null,
  p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.payments; existing uuid;
begin
  perform app.purchase_feature_check(p_business);
  if p_client_ref is not null then
    select id into existing from public.payments where business_id = p_business and client_ref = p_client_ref;
    if found then return existing; end if;
  end if;
  if not exists (select 1 from public.suppliers where id = p_supplier and business_id = p_business) then
    perform app.raise('invalid_supplier');
  end if;
  if p_purchase is not null and not exists (
      select 1 from public.purchases where id = p_purchase and supplier_id = p_supplier) then
    perform app.raise('invalid_purchase');
  end if;
  r := app.insert_payment(p_business, 'supplier_payment', p_method, p_amount, p_paid_at, p_reference, p_notes,
                          p_client_ref, null, p_supplier, null, p_purchase);
  perform app.audit(p_business, 'supplier.payment', 'supplier', p_supplier::text,
                    jsonb_build_object('payment_id', r.id, 'amount', r.amount, 'method', p_method));
  perform app.rebalance_supplier(p_supplier);
  return r.id;
end $$;
create or replace function public.record_supplier_refund(
  p_business uuid, p_supplier uuid, p_amount numeric, p_method text, p_reference text default null,
  p_notes text default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.payments; existing uuid;
begin
  perform app.purchase_feature_check(p_business);
  if p_client_ref is not null then
    select id into existing from public.payments where business_id = p_business and client_ref = p_client_ref;
    if found then return existing; end if;
  end if;
  if not exists (select 1 from public.suppliers where id = p_supplier and business_id = p_business) then
    perform app.raise('invalid_supplier');
  end if;
  if app.supplier_balance(p_supplier) + p_amount > 0 then perform app.raise('refund_exceeds_credit'); end if;
  r := app.insert_payment(p_business, 'supplier_refund', p_method, p_amount, null, p_reference, p_notes,
                          p_client_ref, null, p_supplier);
  perform app.audit(p_business, 'supplier.refund', 'supplier', p_supplier::text,
                    jsonb_build_object('payment_id', r.id, 'amount', r.amount));
  perform app.rebalance_supplier(p_supplier);
  return r.id;
end $$;
create or replace function public.record_supplier_credit(
  p_business uuid, p_supplier uuid, p_amount numeric, p_reason text, p_purchase uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  perform app.purchase_feature_check(p_business);
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  if p_amount is null or p_amount <= 0 then perform app.raise('invalid_amount'); end if;
  if not exists (select 1 from public.suppliers where id = p_supplier and business_id = p_business) then
    perform app.raise('invalid_supplier');
  end if;
  if p_purchase is not null and not exists (select 1 from public.purchases where id = p_purchase and supplier_id = p_supplier) then
    perform app.raise('invalid_purchase');
  end if;
  insert into public.supplier_credits (business_id, supplier_id, purchase_id, kind, amount, reason, created_by)
  values (p_business, p_supplier, p_purchase, 'adjustment', app.money(p_business, p_amount), btrim(p_reason), auth.uid())
  returning id into cid;
  if p_purchase is not null then
    update public.purchases set credited_total = credited_total + app.money(p_business, p_amount) where id = p_purchase;
  end if;
  perform app.audit(p_business, 'supplier.credit', 'supplier', p_supplier::text,
                    jsonb_build_object('amount', p_amount, 'reason', p_reason));
  perform app.rebalance_supplier(p_supplier);
  return cid;
end $$;
alter table public.customers enable row level security;
alter table public.cash_accounts enable row level security;
alter table public.purchases enable row level security;
alter table public.purchase_lines enable row level security;
alter table public.purchase_receipts enable row level security;
alter table public.purchase_receipt_lines enable row level security;
alter table public.supplier_credits enable row level security;
alter table public.supplier_returns enable row level security;
alter table public.supplier_return_lines enable row level security;
alter table public.payments enable row level security;
alter table public.payment_allocations enable row level security;
create policy customers_read on public.customers for select using (app.can_read(business_id));
create policy customers_insert on public.customers for insert with check (app.has_perm(business_id, 'customers.manage'));
create policy customers_update on public.customers for update using (app.has_perm(business_id, 'customers.manage'))
  with check (app.has_perm(business_id, 'customers.manage'));
create policy cash_accounts_read on public.cash_accounts for select using (app.can_read(business_id));
create policy cash_accounts_update on public.cash_accounts for update using (app.has_perm(business_id, 'cash.manage'))
  with check (app.has_perm(business_id, 'cash.manage'));
create policy purchases_read on public.purchases for select
  using (app.has_perm(business_id, 'purchases.manage') and created_at >= app.history_cutoff(business_id)
         or app.can_read(business_id) and not app.is_member(business_id));
create policy purchase_lines_read on public.purchase_lines for select using (app.has_perm(business_id, 'purchases.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy purchase_receipts_read on public.purchase_receipts for select using (app.has_perm(business_id, 'purchases.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy purchase_receipt_lines_read on public.purchase_receipt_lines for select using (app.has_perm(business_id, 'purchases.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy supplier_credits_read on public.supplier_credits for select using (app.has_perm(business_id, 'purchases.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy supplier_returns_read on public.supplier_returns for select using (app.has_perm(business_id, 'purchases.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy supplier_return_lines_read on public.supplier_return_lines for select using (app.has_perm(business_id, 'purchases.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy payments_read on public.payments for select using (
  (app.has_perm(business_id, 'cash.manage') or app.has_perm(business_id, 'reports.view')
   or (app.has_perm(business_id, 'sales.view') and kind in ('sale_payment', 'customer_payment', 'customer_refund')))
  and paid_at >= app.history_cutoff(business_id)
  or app.can_read(business_id) and not app.is_member(business_id));
create policy payment_allocations_read on public.payment_allocations for select using (app.can_read(business_id));
create table public.sales (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  number text not null,
  client_ref uuid not null,
  customer_id uuid references public.customers (id),
  sold_at timestamptz not null default now(),
  status text not null default 'completed' check (status in ('completed')),
  subtotal numeric(14, 2) not null default 0,         -- sum of qty * unit price
  list_total numeric(14, 2) not null default 0,       -- sum of qty * catalogue price (for discount control)
  line_discount_total numeric(14, 2) not null default 0,
  sale_discount numeric(14, 2) not null default 0,
  total numeric(14, 2) not null default 0,             -- amount charged, tax inclusive
  tax_total numeric(14, 2) not null default 0,
  cost_total numeric(18, 4) not null default 0,
  paid_total numeric(14, 2) not null default 0,        -- allocated customer payments
  returned_total numeric(14, 2) not null default 0,
  returned_tax numeric(14, 2) not null default 0,
  returned_cost numeric(18, 4) not null default 0,
  refunded_total numeric(14, 2) not null default 0,
  due_date date,
  notes text,
  offline boolean not null default false,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (business_id, client_ref)
);
create unique index sales_number on public.sales (business_id, number);
create index sales_business_date on public.sales (business_id, sold_at desc);
create index sales_customer on public.sales (customer_id, sold_at) where customer_id is not null;
create table public.sale_lines (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid not null references public.products (id),
  unit_id uuid references public.product_units (id),
  unit_name text not null,
  unit_factor numeric(14, 4) not null check (unit_factor > 0),
  quantity numeric(14, 3) not null check (quantity > 0),
  base_quantity numeric(14, 3) not null check (base_quantity > 0),
  list_price numeric(14, 2) not null,
  unit_price numeric(14, 2) not null check (unit_price >= 0),
  line_discount numeric(14, 2) not null default 0 check (line_discount >= 0),
  sale_discount_alloc numeric(14, 2) not null default 0,
  net_amount numeric(14, 2) not null check (net_amount >= 0),   -- charged, tax inclusive
  tax_amount numeric(14, 2) not null default 0,
  cost_unit_base numeric(18, 4) not null,
  cost_amount numeric(18, 4) not null,
  returned_base_qty numeric(14, 3) not null default 0,
  returned_amount numeric(14, 2) not null default 0,
  returned_tax numeric(14, 2) not null default 0,
  returned_cost numeric(18, 4) not null default 0,
  sort int not null default 0,
  check (returned_base_qty <= base_quantity)
);
create index sale_lines_sale on public.sale_lines (sale_id);
create index sale_lines_product on public.sale_lines (product_id);
create index sale_lines_business on public.sale_lines (business_id);
create table public.sale_returns (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  number text not null,
  sale_id uuid not null references public.sales (id),
  customer_id uuid references public.customers (id),
  returned_at timestamptz not null default now(),
  reason text not null,
  restock boolean not null default true,
  total numeric(14, 2) not null default 0,
  tax_amount numeric(14, 2) not null default 0,
  cost_amount numeric(18, 4) not null default 0,
  refund_amount numeric(14, 2) not null default 0,
  refund_method text,
  client_ref uuid,
  created_by uuid,
  created_at timestamptz not null default now()
);
create unique index sale_returns_client_ref on public.sale_returns (business_id, client_ref) where client_ref is not null;
create index sale_returns_business_date on public.sale_returns (business_id, returned_at desc);
create index sale_returns_sale on public.sale_returns (sale_id);
create table public.sale_return_lines (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references public.sale_returns (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  sale_line_id uuid not null references public.sale_lines (id),
  product_id uuid not null references public.products (id),
  base_quantity numeric(14, 3) not null check (base_quantity > 0),
  amount numeric(14, 2) not null,
  tax_amount numeric(14, 2) not null default 0,
  cost_amount numeric(18, 4) not null default 0
);
create index sale_return_lines_product on public.sale_return_lines (product_id);
create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  number text not null,
  client_ref uuid,
  category text not null check (category in ('rent', 'salaries', 'utilities', 'transport', 'communication',
    'packaging', 'repairs', 'marketing', 'bank_fees', 'taxes_licences', 'security', 'cleaning', 'other')),
  description text not null check (length(btrim(description)) between 1 and 200),
  amount numeric(14, 2) not null check (amount > 0),
  expense_date date not null,
  due_date date,
  status text not null default 'unpaid' check (status in ('unpaid', 'partially_paid', 'paid', 'voided')),
  paid_amount numeric(14, 2) not null default 0,
  payee text,
  notes text,
  void_reason text,
  created_by uuid,
  created_at timestamptz not null default now()
);
create unique index expenses_client_ref on public.expenses (business_id, client_ref) where client_ref is not null;
create index expenses_business_date on public.expenses (business_id, expense_date desc);
alter table public.payments add constraint payments_sale_fk foreign key (sale_id) references public.sales (id);
alter table public.payments add constraint payments_return_fk foreign key (sale_return_id) references public.sale_returns (id);
alter table public.payments add constraint payments_expense_fk foreign key (expense_id) references public.expenses (id);
alter table public.payment_allocations add constraint alloc_sale_fk foreign key (sale_id) references public.sales (id);
alter table public.payment_allocations add constraint alloc_expense_fk foreign key (expense_id) references public.expenses (id);
create table public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  kind text not null check (kind in ('transfer', 'deposit', 'withdrawal', 'adjustment')),
  from_account_id uuid references public.cash_accounts (id),
  to_account_id uuid references public.cash_accounts (id),
  amount numeric(14, 2) not null check (amount > 0),
  note text,
  occurred_at timestamptz not null default now(),
  client_ref uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  check ((kind = 'transfer' and from_account_id is not null and to_account_id is not null and from_account_id <> to_account_id)
      or (kind = 'deposit' and from_account_id is null and to_account_id is not null)
      or (kind = 'withdrawal' and from_account_id is not null and to_account_id is null)
      or (kind = 'adjustment' and num_nonnulls(from_account_id, to_account_id) = 1))
);
create unique index cash_movements_client_ref on public.cash_movements (business_id, client_ref) where client_ref is not null;
create index cash_movements_business on public.cash_movements (business_id, occurred_at desc);
create table public.cash_reconciliations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  recon_date date not null,
  notes text,
  total_expected numeric(14, 2) not null,
  total_counted numeric(14, 2) not null,
  total_difference numeric(14, 2) not null,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index cash_reconciliations_business on public.cash_reconciliations (business_id, recon_date desc);
create table public.cash_reconciliation_lines (
  id uuid primary key default gen_random_uuid(),
  reconciliation_id uuid not null references public.cash_reconciliations (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  account_id uuid not null references public.cash_accounts (id),
  expected numeric(14, 2) not null,
  counted numeric(14, 2) not null,
  difference numeric(14, 2) not null,
  day_inflows numeric(14, 2) not null default 0,
  day_outflows numeric(14, 2) not null default 0
);
create or replace function app.customer_balance(p_customer uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(total - returned_total + refunded_total) from public.sales where customer_id = p_customer), 0)
       - coalesce((select sum(amount) from public.payments where customer_id = p_customer
                     and kind in ('sale_payment', 'customer_payment')), 0)
$$;
create or replace function app.rebalance_customer(p_customer uuid, p_sale uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare pay record; s record; avail numeric; take numeric; outstanding numeric;
begin
  create temp table if not exists _cpay (payment_id uuid primary key, sale_id uuid, paid_at timestamptz, amount numeric) on commit drop;
  create temp table if not exists _cowed (sale_id uuid primary key, sold_at timestamptz, owed numeric) on commit drop;
  delete from _cpay where true; delete from _cowed where true;
  if p_customer is null then
    delete from public.payment_allocations a using public.payments p
     where a.payment_id = p.id and p.sale_id = p_sale and p.customer_id is null and p.kind = 'sale_payment';
    insert into _cpay select id, sale_id, paid_at, amount from public.payments
     where sale_id = p_sale and customer_id is null and kind = 'sale_payment';
    insert into _cowed select id, sold_at, total - returned_total + refunded_total from public.sales where id = p_sale;
  else
    delete from public.payment_allocations a using public.payments p
     where a.payment_id = p.id and p.customer_id = p_customer and p.kind in ('sale_payment', 'customer_payment');
    insert into _cpay select id, sale_id, paid_at, amount from public.payments
     where customer_id = p_customer and kind in ('sale_payment', 'customer_payment');
    insert into _cowed select id, sold_at, total - returned_total + refunded_total from public.sales
     where customer_id = p_customer and total - returned_total + refunded_total > 0;
  end if;
  for pay in select * from _cpay where sale_id is not null order by paid_at, payment_id loop
    select owed into outstanding from _cowed where sale_id = pay.sale_id;
    if coalesce(outstanding, 0) > 0 then
      take := least(pay.amount, outstanding);
      insert into public.payment_allocations (business_id, payment_id, sale_id, amount)
      select business_id, pay.payment_id, pay.sale_id, take from public.payments where id = pay.payment_id;
      update _cowed set owed = owed - take where sale_id = pay.sale_id;
      update _cpay set amount = amount - take where payment_id = pay.payment_id;
    end if;
  end loop;
  for pay in select * from _cpay where amount > 0 order by paid_at, payment_id loop
    avail := pay.amount;
    for s in select * from _cowed where owed > 0 order by sold_at, sale_id loop
      exit when avail <= 0;
      take := least(avail, s.owed);
      insert into public.payment_allocations (business_id, payment_id, sale_id, amount)
      select business_id, pay.payment_id, s.sale_id, take from public.payments where id = pay.payment_id;
      update _cowed set owed = owed - take where sale_id = s.sale_id;
      avail := avail - take;
    end loop;
  end loop;
  update public.sales sa set paid_total = coalesce((
      select sum(a.amount) from public.payment_allocations a where a.sale_id = sa.id), 0)
   where (p_customer is not null and sa.customer_id = p_customer) or sa.id = p_sale;
end $$;
create or replace function public.create_sale(p_business uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cref uuid := coalesce(nullif(p ->> 'client_ref', '')::uuid, gen_random_uuid());
  sid uuid; num text; existing public.sales; cust public.customers; st public.business_settings;
  l jsonb; u record; pr public.products; mv public.stock_movements;
  i int := 0; n int;
  v_qty numeric; v_price numeric; v_list numeric; v_disc numeric; v_net numeric;
  list_sum numeric := 0; gross_sum numeric := 0; disc_sum numeric := 0; net_sum numeric := 0;
  sale_disc numeric := coalesce((p ->> 'discount_amount')::numeric, 0);
  alloc numeric; alloc_left numeric; tax numeric; tax_sum numeric := 0; cost_sum numeric := 0;
  pay jsonb; paid numeric := 0; v_tot numeric; disc_pct numeric;
  at timestamptz := coalesce(nullif(p ->> 'sold_at', '')::timestamptz, now());
  line_ids uuid[] := '{}';
begin
  perform app.require_perm(p_business, 'sales.create');
  select * into existing from public.sales where business_id = p_business and client_ref = cref;
  if found then
    return jsonb_build_object('id', existing.id, 'number', existing.number, 'total', existing.total, 'duplicate', true);
  end if;
  perform app.check_limit(p_business, 'max_sales_per_month');
  if at > now() + interval '10 minutes' then perform app.raise('invalid_date'); end if;
  if jsonb_typeof(p -> 'lines') <> 'array' or jsonb_array_length(p -> 'lines') = 0 then
    perform app.raise('lines_required');
  end if;
  if sale_disc < 0 then perform app.raise('invalid_amount'); end if;
  select * into st from public.business_settings where business_id = p_business;
  if nullif(p ->> 'customer_id', '') is not null then
    select * into cust from public.customers where id = (p ->> 'customer_id')::uuid and business_id = p_business;
    if not found then perform app.raise('invalid_customer'); end if;
  end if;
  begin
    insert into public.sales (business_id, number, client_ref, customer_id, sold_at, due_date, notes, offline, created_by)
    values (p_business, app.next_number(p_business, 'sale', 'S-'), cref, cust.id, at,
            nullif(p ->> 'due_date', '')::date, nullif(p ->> 'notes', ''),
            coalesce((p ->> 'offline')::boolean, false), auth.uid())
    returning id, number into sid, num;
  exception when unique_violation then
    select * into existing from public.sales where business_id = p_business and client_ref = cref;
    return jsonb_build_object('id', existing.id, 'number', existing.number, 'total', existing.total, 'duplicate', true);
  end;
  perform 1 from public.products
   where business_id = p_business
     and id in (select (x ->> 'product_id')::uuid from jsonb_array_elements(p -> 'lines') x)
   order by id for update;
  create temp table if not exists _sl (sort int primary key, product_id uuid, unit_id uuid, unit_name text,
    factor numeric, qty numeric, base numeric, list_price numeric, unit_price numeric, disc numeric, net numeric) on commit drop;
  delete from _sl where true;
  for l in select * from jsonb_array_elements(p -> 'lines') loop
    i := i + 1;
    select * into pr from public.products where id = (l ->> 'product_id')::uuid and business_id = p_business;
    if not found then perform app.raise('invalid_product'); end if;
    if pr.status <> 'active' then perform app.raise('product_archived', jsonb_build_object('product', pr.name)); end if;
    select * into u from app.resolve_unit(pr.id, nullif(l ->> 'unit_id', '')::uuid);
    v_qty := (l ->> 'quantity')::numeric;
    if v_qty is null or v_qty <= 0 then perform app.raise('invalid_quantity'); end if;
    v_list := coalesce((select selling_price from public.product_units where id = u.unit_id), pr.selling_price * u.factor);
    v_price := coalesce((l ->> 'unit_price')::numeric, v_list);
    v_disc := coalesce((l ->> 'discount_amount')::numeric, 0);
    if v_price < 0 or v_disc < 0 then perform app.raise('invalid_amount'); end if;
    v_net := app.money(p_business, v_qty * v_price - v_disc);
    if v_net < 0 then perform app.raise('discount_exceeds_line'); end if;
    insert into _sl values (i, pr.id, u.unit_id, u.unit_name, u.factor, v_qty, v_qty * u.factor,
                            v_list, v_price, v_disc, v_net);
    list_sum := list_sum + app.money(p_business, v_qty * v_list);
    gross_sum := gross_sum + app.money(p_business, v_qty * v_price);
    disc_sum := disc_sum + v_disc;
    net_sum := net_sum + v_net;
  end loop;
  if sale_disc > net_sum then perform app.raise('discount_exceeds_total'); end if;
  v_tot := net_sum - sale_disc;
  if list_sum > 0 then
    disc_pct := greatest(0, (list_sum - v_tot) / list_sum * 100);
    if disc_pct > st.cashier_max_discount_pct and not app.has_perm(p_business, 'sales.discount_large') then
      perform app.raise('discount_requires_approval', jsonb_build_object('max_pct', st.cashier_max_discount_pct,
        'pct', round(disc_pct, 1)));
    end if;
  end if;
  alloc_left := sale_disc;
  select count(*) into n from _sl;
  for l in select to_jsonb(_sl) from _sl order by sort loop
    if (l ->> 'sort')::int = n then
      alloc := alloc_left;
    elsif net_sum > 0 then
      alloc := least(alloc_left, app.money(p_business, sale_disc * (l ->> 'net')::numeric / net_sum));
    else
      alloc := 0;
    end if;
    alloc_left := alloc_left - alloc;
    v_net := (l ->> 'net')::numeric - alloc;
    tax := case when st.tax_enabled then app.money(p_business, v_net * st.tax_rate / (100 + st.tax_rate)) else 0 end;
    perform app.consume_batches((l ->> 'product_id')::uuid, (l ->> 'base')::numeric);
    mv := app.apply_movement(p_business, (l ->> 'product_id')::uuid, 'sale', -(l ->> 'base')::numeric, null,
                             'sale', sid, num, null, null, false, null, at);
    insert into public.sale_lines (sale_id, business_id, product_id, unit_id, unit_name, unit_factor, quantity,
      base_quantity, list_price, unit_price, line_discount, sale_discount_alloc, net_amount, tax_amount,
      cost_unit_base, cost_amount, sort)
    values (sid, p_business, (l ->> 'product_id')::uuid, nullif(l ->> 'unit_id', '')::uuid, l ->> 'unit_name',
      (l ->> 'factor')::numeric, (l ->> 'qty')::numeric, (l ->> 'base')::numeric, (l ->> 'list_price')::numeric,
      (l ->> 'unit_price')::numeric, (l ->> 'disc')::numeric, alloc, v_net, tax, mv.unit_cost, -mv.value,
      (l ->> 'sort')::int);
    tax_sum := tax_sum + tax;
    cost_sum := cost_sum - mv.value;
  end loop;
  if p -> 'payments' is not null and jsonb_typeof(p -> 'payments') = 'array' then
    for pay in select * from jsonb_array_elements(p -> 'payments') loop
      continue when coalesce((pay ->> 'amount')::numeric, 0) = 0;
      perform app.insert_payment(p_business, 'sale_payment', coalesce(pay ->> 'method', 'cash'),
        (pay ->> 'amount')::numeric, at, pay ->> 'reference', null, null, cust.id, null, sid);
      paid := paid + app.money(p_business, (pay ->> 'amount')::numeric);
    end loop;
  end if;
  if paid > v_tot then perform app.raise('overpayment', jsonb_build_object('total', v_tot, 'paid', paid)); end if;
  if paid < v_tot then
    if cust.id is null then perform app.raise('customer_required_for_credit'); end if;
    if not st.allow_credit_sales then perform app.raise('credit_sales_disabled'); end if;
    perform app.require_feature(p_business, 'customers_credit');
    if not app.has_perm(p_business, 'customers.credit') then
      perform app.raise('permission_denied', jsonb_build_object('permission', 'customers.credit'));
    end if;
    if cust.credit_limit is not null and app.customer_balance(cust.id) + (v_tot - paid) > cust.credit_limit then
      perform app.raise('credit_limit_exceeded', jsonb_build_object('limit', cust.credit_limit,
        'balance', app.customer_balance(cust.id)));
    end if;
  end if;
  update public.sales set subtotal = gross_sum, list_total = list_sum, line_discount_total = disc_sum,
         sale_discount = sale_disc, total = v_tot, tax_total = tax_sum, cost_total = cost_sum
   where id = sid;
  perform app.rebalance_customer(cust.id, sid);
  perform app.audit(p_business, 'sale.created', 'sale', sid::text,
    jsonb_build_object('number', num, 'total', v_tot, 'paid', paid, 'offline', coalesce((p ->> 'offline')::boolean, false)));
  return jsonb_build_object('id', sid, 'number', num, 'total', v_tot, 'paid', paid, 'duplicate', false);
end $$;
commit;
