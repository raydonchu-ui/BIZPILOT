-- Sales, returns/refunds, customer balances, expenses, cash movements, reconciliation.
--
-- Reporting conventions (documented in docs/FINANCIAL_RULES.md):
--   * Net sales revenue = sale line amounts after all discounts, excluding any
--     configured sales tax, minus returns. Sales are counted on the sale date,
--     returns on the return date.
--   * COGS = weighted-average cost captured on each sale line at the time of sale,
--     minus the cost of restocked returns.
--   * Customer balance = sum(sale total - returned + refunded) - payments received.

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

-- ---------------------------------------------------------------------------
-- Customer balances
-- ---------------------------------------------------------------------------
create or replace function app.customer_balance(p_customer uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(total - returned_total + refunded_total) from public.sales where customer_id = p_customer), 0)
       - coalesce((select sum(amount) from public.payments where customer_id = p_customer
                     and kind in ('sale_payment', 'customer_payment')), 0)
$$;

-- Deterministic allocation of incoming payments to sales: the targeted sale first,
-- then the oldest sale with an outstanding amount. p_sale is used for walk-in sales.
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

-- ---------------------------------------------------------------------------
-- Sales
-- ---------------------------------------------------------------------------
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
    -- Concurrent retry of the same sale: return the committed one.
    select * into existing from public.sales where business_id = p_business and client_ref = cref;
    return jsonb_build_object('id', existing.id, 'number', existing.number, 'total', existing.total, 'duplicate', true);
  end;

  -- Lock all products of the sale in a stable order to avoid deadlocks.
  perform 1 from public.products
   where business_id = p_business
     and id in (select (x ->> 'product_id')::uuid from jsonb_array_elements(p -> 'lines') x)
   order by id for update;

  -- Pass 1: validate and price lines.
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

  -- Discount control: price reductions + discounts against catalogue prices.
  if list_sum > 0 then
    disc_pct := greatest(0, (list_sum - v_tot) / list_sum * 100);
    if disc_pct > st.cashier_max_discount_pct and not app.has_perm(p_business, 'sales.discount_large') then
      perform app.raise('discount_requires_approval', jsonb_build_object('max_pct', st.cashier_max_discount_pct,
        'pct', round(disc_pct, 1)));
    end if;
  end if;

  -- Pass 2: allocate sale discount, compute tax, move stock, capture cost.
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

  -- Payments
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

create or replace function public.record_customer_payment(
  p_business uuid, p_customer uuid, p_amount numeric, p_method text, p_reference text default null,
  p_sale uuid default null, p_paid_at timestamptz default null, p_notes text default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.payments; existing uuid;
begin
  perform app.require_perm(p_business, 'sales.create');
  if p_client_ref is not null then
    select id into existing from public.payments where business_id = p_business and client_ref = p_client_ref;
    if found then return existing; end if;
  end if;
  if not exists (select 1 from public.customers where id = p_customer and business_id = p_business) then
    perform app.raise('invalid_customer');
  end if;
  if p_sale is not null and not exists (select 1 from public.sales where id = p_sale and customer_id = p_customer) then
    perform app.raise('invalid_sale');
  end if;
  r := app.insert_payment(p_business, 'customer_payment', p_method, p_amount, p_paid_at, p_reference, p_notes,
                          p_client_ref, p_customer, null, p_sale);
  perform app.audit(p_business, 'customer.payment', 'customer', p_customer::text,
                    jsonb_build_object('payment_id', r.id, 'amount', r.amount, 'method', p_method));
  perform app.rebalance_customer(p_customer);
  return r.id;
end $$;

create or replace function public.create_sale_return(p_sale uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
-- p: {client_ref, reason, restock (default true), lines: [{sale_line_id, base_quantity}],
--     refund: {amount, method, reference}}
declare
  s public.sales; sl public.sale_lines; rid uuid; num text; l jsonb; q numeric;
  amt numeric; tx numeric; cst numeric; restock boolean := coalesce((p ->> 'restock')::boolean, true);
  tot numeric := 0; tot_tax numeric := 0; tot_cost numeric := 0; refund numeric := coalesce((p #>> '{refund,amount}')::numeric, 0);
  available numeric; mv public.stock_movements; cref uuid := nullif(p ->> 'client_ref', '')::uuid;
begin
  select * into s from public.sales where id = p_sale for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(s.business_id, 'sales.refund');
  if cref is not null then
    select id into rid from public.sale_returns where business_id = s.business_id and client_ref = cref;
    if found then return rid; end if;
  end if;
  if coalesce(btrim(p ->> 'reason'), '') = '' then perform app.raise('reason_required'); end if;
  num := app.next_number(s.business_id, 'return', 'RT-');
  insert into public.sale_returns (business_id, number, sale_id, customer_id, reason, restock, client_ref, created_by)
  values (s.business_id, num, s.id, s.customer_id, btrim(p ->> 'reason'), restock, cref, auth.uid())
  returning id into rid;

  for l in select * from jsonb_array_elements(p -> 'lines') loop
    q := coalesce((l ->> 'base_quantity')::numeric, 0);
    continue when q = 0;
    if q < 0 then perform app.raise('invalid_quantity'); end if;
    select * into sl from public.sale_lines where id = (l ->> 'sale_line_id')::uuid and sale_id = s.id for update;
    if not found then perform app.raise('invalid_line'); end if;
    if sl.returned_base_qty + q > sl.base_quantity then perform app.raise('return_exceeds_sold'); end if;
    if sl.returned_base_qty + q = sl.base_quantity then
      amt := sl.net_amount - sl.returned_amount;            -- last return takes the exact remainder
      tx := sl.tax_amount - sl.returned_tax;
    else
      amt := app.money(s.business_id, sl.net_amount * q / sl.base_quantity);
      tx := app.money(s.business_id, sl.tax_amount * q / sl.base_quantity);
    end if;
    cst := 0;
    if restock then
      cst := round(sl.cost_amount * q / sl.base_quantity, 4);
      mv := app.apply_movement(s.business_id, sl.product_id, 'sale_return', q, cst / q, 'sale_return', rid, num,
                               p ->> 'reason');
    end if;
    insert into public.sale_return_lines (return_id, business_id, sale_line_id, product_id, base_quantity, amount,
                                          tax_amount, cost_amount)
    values (rid, s.business_id, sl.id, sl.product_id, q, amt, tx, cst);
    update public.sale_lines set returned_base_qty = returned_base_qty + q, returned_amount = returned_amount + amt,
           returned_tax = returned_tax + tx, returned_cost = returned_cost + cst where id = sl.id;
    tot := tot + amt; tot_tax := tot_tax + tx; tot_cost := tot_cost + cst;
  end loop;
  if tot = 0 and tot_cost = 0 and not exists (select 1 from public.sale_return_lines where return_id = rid) then
    perform app.raise('lines_required');
  end if;

  -- Refundable cash: what was paid on this sale beyond what is still charged after the return.
  available := s.paid_total - (s.total - (s.returned_total + tot) + s.refunded_total);
  if s.customer_id is null then
    -- Walk-in customers cannot hold store credit: the returned value must be refunded.
    refund := tot;
  end if;
  if refund < 0 or refund > tot or refund > greatest(available, 0) then
    perform app.raise('invalid_refund_amount', jsonb_build_object('max', least(tot, greatest(available, 0))));
  end if;

  update public.sales set returned_total = returned_total + tot, returned_tax = returned_tax + tot_tax,
         returned_cost = returned_cost + tot_cost, refunded_total = refunded_total + refund
   where id = s.id;
  update public.sale_returns set total = tot, tax_amount = tot_tax, cost_amount = tot_cost, refund_amount = refund,
         refund_method = case when refund > 0 then coalesce(p #>> '{refund,method}', 'cash') end
   where id = rid;
  if refund > 0 then
    perform app.insert_payment(s.business_id, 'customer_refund', coalesce(p #>> '{refund,method}', 'cash'), refund,
      now(), p #>> '{refund,reference}', null, null, s.customer_id, null, s.id, null, null, rid);
  end if;
  perform app.rebalance_customer(s.customer_id, s.id);
  perform app.audit(s.business_id, 'sale.returned', 'sale', s.id::text,
    jsonb_build_object('return_id', rid, 'amount', tot, 'refund', refund, 'restock', restock));
  return rid;
end $$;

-- ---------------------------------------------------------------------------
-- Expenses
-- ---------------------------------------------------------------------------
create or replace function app.refresh_expense(p_expense uuid) returns void
language sql security definer set search_path = public as $$
  update public.expenses e set
    paid_amount = coalesce((select sum(case when p.kind = 'expense_payment' then p.amount else -p.amount end)
                            from public.payments p where p.expense_id = e.id), 0),
    status = case when e.status = 'voided' then 'voided'
      else case
        when coalesce((select sum(case when p.kind = 'expense_payment' then p.amount else -p.amount end)
                       from public.payments p where p.expense_id = e.id), 0) >= e.amount then 'paid'
        when coalesce((select sum(case when p.kind = 'expense_payment' then p.amount else -p.amount end)
                       from public.payments p where p.expense_id = e.id), 0) > 0 then 'partially_paid'
        else 'unpaid' end end
  where e.id = p_expense
$$;

create or replace function public.record_expense(p_business uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare eid uuid; cref uuid := nullif(p ->> 'client_ref', '')::uuid; amt numeric; paid numeric;
begin
  perform app.require_perm(p_business, 'expenses.manage');
  perform app.require_feature(p_business, 'expenses');
  if cref is not null then
    select id into eid from public.expenses where business_id = p_business and client_ref = cref;
    if found then return eid; end if;
  end if;
  amt := app.money(p_business, (p ->> 'amount')::numeric);
  if amt is null or amt <= 0 then perform app.raise('invalid_amount'); end if;
  paid := coalesce((p ->> 'paid_amount')::numeric, 0);
  if paid < 0 or paid > amt then perform app.raise('invalid_amount'); end if;
  insert into public.expenses (business_id, number, client_ref, category, description, amount, expense_date, due_date,
                               payee, notes, created_by)
  values (p_business, app.next_number(p_business, 'expense', 'EXP-'), cref, p ->> 'category', btrim(p ->> 'description'),
          amt, coalesce(nullif(p ->> 'expense_date', '')::date, app.biz_today(p_business)),
          nullif(p ->> 'due_date', '')::date, nullif(p ->> 'payee', ''), nullif(p ->> 'notes', ''), auth.uid())
  returning id into eid;
  if paid > 0 then
    perform app.insert_payment(p_business, 'expense_payment', coalesce(p ->> 'method', 'cash'), paid,
      coalesce(nullif(p ->> 'expense_date', '')::date::timestamp at time zone app.biz_tz(p_business) + interval '12 hours', now()),
      p ->> 'reference', null, null, null, null, null, null, eid);
  end if;
  perform app.refresh_expense(eid);
  perform app.audit(p_business, 'expense.created', 'expense', eid::text,
                    jsonb_build_object('amount', amt, 'category', p ->> 'category', 'paid', paid));
  return eid;
end $$;

create or replace function public.pay_expense(p_expense uuid, p_amount numeric, p_method text,
  p_reference text default null, p_paid_at timestamptz default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare e public.expenses; r public.payments; existing uuid;
begin
  select * into e from public.expenses where id = p_expense for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(e.business_id, 'expenses.manage');
  if p_client_ref is not null then
    select id into existing from public.payments where business_id = e.business_id and client_ref = p_client_ref;
    if found then return existing; end if;
  end if;
  if e.status = 'voided' then perform app.raise('expense_voided'); end if;
  if p_amount is null or p_amount <= 0 or e.paid_amount + p_amount > e.amount then perform app.raise('invalid_amount'); end if;
  r := app.insert_payment(e.business_id, 'expense_payment', p_method, p_amount, p_paid_at, p_reference, null,
                          p_client_ref, null, null, null, null, e.id);
  perform app.refresh_expense(e.id);
  perform app.audit(e.business_id, 'expense.paid', 'expense', e.id::text, jsonb_build_object('amount', p_amount));
  return r.id;
end $$;

create or replace function public.void_expense(p_expense uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare e public.expenses; pm record;
begin
  select * into e from public.expenses where id = p_expense for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(e.business_id, 'expenses.manage');
  if e.status = 'voided' then perform app.raise('expense_voided'); end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  -- Reverse each recorded payment with an explicit counter-entry (history is kept).
  for pm in select method, sum(case when kind = 'expense_payment' then amount else -amount end) amt
            from public.payments where expense_id = e.id group by method loop
    if pm.amt > 0 then
      perform app.insert_payment(e.business_id, 'expense_refund', pm.method, pm.amt, now(), 'VOID ' || e.number,
                                 btrim(p_reason), null, null, null, null, null, e.id);
    end if;
  end loop;
  update public.expenses set status = 'voided', void_reason = btrim(p_reason) where id = e.id;
  perform app.refresh_expense(e.id);
  perform app.audit(e.business_id, 'expense.voided', 'expense', e.id::text, jsonb_build_object('reason', p_reason));
end $$;

-- ---------------------------------------------------------------------------
-- Cash accounts, movements and reconciliation
-- ---------------------------------------------------------------------------
create or replace function app.account_balance(p_account uuid, p_until timestamptz) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select opening_balance from public.cash_accounts where id = p_account), 0)
       + coalesce((select sum(case when direction = 'in' then amount else -amount end)
                   from public.payments where account_id = p_account and paid_at < p_until), 0)
       + coalesce((select sum(amount) from public.cash_movements where to_account_id = p_account and occurred_at < p_until), 0)
       - coalesce((select sum(amount) from public.cash_movements where from_account_id = p_account and occurred_at < p_until), 0)
$$;

create or replace function public.record_cash_movement(p_business uuid, p_kind text, p_from uuid, p_to uuid,
  p_amount numeric, p_note text, p_occurred_at timestamptz default null, p_client_ref uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare mid uuid;
begin
  perform app.require_perm(p_business, 'cash.manage');
  if p_client_ref is not null then
    select id into mid from public.cash_movements where business_id = p_business and client_ref = p_client_ref;
    if found then return mid; end if;
  end if;
  if p_kind in ('withdrawal', 'adjustment') and coalesce(btrim(p_note), '') = '' then perform app.raise('reason_required'); end if;
  if (p_from is not null and not exists (select 1 from public.cash_accounts where id = p_from and business_id = p_business))
     or (p_to is not null and not exists (select 1 from public.cash_accounts where id = p_to and business_id = p_business)) then
    perform app.raise('invalid_account');
  end if;
  insert into public.cash_movements (business_id, kind, from_account_id, to_account_id, amount, note, occurred_at,
                                     client_ref, created_by)
  values (p_business, p_kind, p_from, p_to, app.money(p_business, p_amount), p_note, coalesce(p_occurred_at, now()),
          p_client_ref, auth.uid())
  returning id into mid;
  perform app.audit(p_business, 'cash.movement', 'cash_movement', mid::text,
                    jsonb_build_object('kind', p_kind, 'amount', p_amount, 'note', p_note));
  return mid;
end $$;

create or replace function public.cash_position(p_business uuid, p_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s timestamptz := app.range_start(p_business, p_date); e timestamptz := app.range_end(p_business, p_date);
begin
  perform app.require_perm(p_business, 'cash.manage');
  return (select coalesce(jsonb_agg(row_to_json(t) order by t.sort), '[]'::jsonb) from (
    select a.id as account_id, a.name, a.kind,
      case a.kind when 'cash' then 1 when 'mtn_momo' then 2 when 'orange_money' then 3 when 'bank' then 4 else 5 end as sort,
      app.account_balance(a.id, s) as opening,
      coalesce((select sum(amount) from public.payments where account_id = a.id and paid_at >= s and paid_at < e
                and kind = 'sale_payment'), 0) as sales_in,
      coalesce((select sum(amount) from public.payments where account_id = a.id and paid_at >= s and paid_at < e
                and kind = 'customer_payment'), 0) as debt_collected,
      coalesce((select sum(amount) from public.payments where account_id = a.id and paid_at >= s and paid_at < e
                and kind in ('supplier_refund', 'expense_refund')), 0) as other_in,
      coalesce((select sum(amount) from public.payments where account_id = a.id and paid_at >= s and paid_at < e
                and kind = 'customer_refund'), 0) as refunds_out,
      coalesce((select sum(amount) from public.payments where account_id = a.id and paid_at >= s and paid_at < e
                and kind = 'supplier_payment'), 0) as supplier_out,
      coalesce((select sum(amount) from public.payments where account_id = a.id and paid_at >= s and paid_at < e
                and kind = 'expense_payment'), 0) as expenses_out,
      coalesce((select sum(amount) from public.cash_movements where to_account_id = a.id and occurred_at >= s and occurred_at < e), 0) as transfers_in,
      coalesce((select sum(amount) from public.cash_movements where from_account_id = a.id and occurred_at >= s and occurred_at < e), 0) as transfers_out,
      app.account_balance(a.id, e) as expected
    from public.cash_accounts a where a.business_id = p_business and a.active) t);
end $$;

create or replace function public.save_cash_reconciliation(p_business uuid, p_date date, p_lines jsonb, p_notes text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare rid uuid; pos jsonb; l jsonb; a jsonb; te numeric := 0; tc numeric := 0; cnt numeric;
begin
  perform app.require_perm(p_business, 'cash.manage');
  perform app.require_feature(p_business, 'cash_reconciliation');
  pos := public.cash_position(p_business, p_date);
  insert into public.cash_reconciliations (business_id, recon_date, notes, total_expected, total_counted, total_difference, created_by)
  values (p_business, p_date, p_notes, 0, 0, 0, auth.uid()) returning id into rid;
  for l in select * from jsonb_array_elements(p_lines) loop
    select x into a from jsonb_array_elements(pos) x where x ->> 'account_id' = l ->> 'account_id';
    if a is null then perform app.raise('invalid_account'); end if;
    cnt := (l ->> 'counted')::numeric;
    if cnt is null then continue; end if;
    insert into public.cash_reconciliation_lines (reconciliation_id, business_id, account_id, expected, counted, difference,
                                                  day_inflows, day_outflows)
    values (rid, p_business, (a ->> 'account_id')::uuid, (a ->> 'expected')::numeric, cnt, cnt - (a ->> 'expected')::numeric,
            (a ->> 'sales_in')::numeric + (a ->> 'debt_collected')::numeric + (a ->> 'other_in')::numeric + (a ->> 'transfers_in')::numeric,
            (a ->> 'refunds_out')::numeric + (a ->> 'supplier_out')::numeric + (a ->> 'expenses_out')::numeric + (a ->> 'transfers_out')::numeric);
    te := te + (a ->> 'expected')::numeric; tc := tc + cnt;
  end loop;
  if tc = 0 and te = 0 and not exists (select 1 from public.cash_reconciliation_lines where reconciliation_id = rid) then
    perform app.raise('lines_required');
  end if;
  update public.cash_reconciliations set total_expected = te, total_counted = tc, total_difference = tc - te where id = rid;
  perform app.audit(p_business, 'cash.reconciled', 'cash_reconciliation', rid::text,
                    jsonb_build_object('date', p_date, 'difference', tc - te));
  return rid;
end $$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.sales enable row level security;
alter table public.sale_lines enable row level security;
alter table public.sale_returns enable row level security;
alter table public.sale_return_lines enable row level security;
alter table public.expenses enable row level security;
alter table public.cash_movements enable row level security;
alter table public.cash_reconciliations enable row level security;
alter table public.cash_reconciliation_lines enable row level security;

create policy sales_read on public.sales for select using (
  app.has_perm(business_id, 'sales.view') and sold_at >= app.history_cutoff(business_id)
  or app.can_read(business_id) and not app.is_member(business_id));
create policy sale_lines_read on public.sale_lines for select using (app.has_perm(business_id, 'sales.view') or app.can_read(business_id) and not app.is_member(business_id));
create policy sale_returns_read on public.sale_returns for select using (app.has_perm(business_id, 'sales.view') or app.can_read(business_id) and not app.is_member(business_id));
create policy sale_return_lines_read on public.sale_return_lines for select using (app.has_perm(business_id, 'sales.view') or app.can_read(business_id) and not app.is_member(business_id));
create policy expenses_read on public.expenses for select using (
  app.has_perm(business_id, 'expenses.manage') and created_at >= app.history_cutoff(business_id)
  or app.can_read(business_id) and not app.is_member(business_id));
create policy cash_movements_read on public.cash_movements for select using (app.has_perm(business_id, 'cash.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy cash_recon_read on public.cash_reconciliations for select using (app.has_perm(business_id, 'cash.manage') or app.can_read(business_id) and not app.is_member(business_id));
create policy cash_recon_lines_read on public.cash_reconciliation_lines for select using (app.has_perm(business_id, 'cash.manage') or app.can_read(business_id) and not app.is_member(business_id));
