-- BizPilot setup PART 5 of 11. Run parts in order.
begin;
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
  available := s.paid_total - (s.total - (s.returned_total + tot) + s.refunded_total);
  if s.customer_id is null then
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
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  type text not null,
  severity text not null default 'info' check (severity in ('info', 'success', 'warning', 'critical')),
  params jsonb not null default '{}'::jsonb,
  link text,
  required_perm text,
  dedupe_key text,
  created_at timestamptz not null default now()
);
create unique index notifications_dedupe on public.notifications (business_id, dedupe_key) where dedupe_key is not null;
create index notifications_business on public.notifications (business_id, created_at desc);
create table public.notification_reads (
  notification_id uuid not null references public.notifications (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (notification_id, user_id)
);
create table public.support_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses (id) on delete set null,
  user_id uuid references auth.users (id) on delete set null,
  name text,
  email text,
  phone text,
  category text not null default 'question' check (category in ('question', 'bug', 'billing', 'feedback',
                                                                  'account_closure', 'data_export', 'other')),
  subject text not null check (length(btrim(subject)) between 3 and 150),
  message text not null check (length(btrim(message)) between 5 and 5000),
  status text not null default 'open' check (status in ('open', 'in_progress', 'resolved', 'closed')),
  admin_response text,
  responded_by uuid,
  responded_at timestamptz,
  created_at timestamptz not null default now()
);
create index support_requests_status on public.support_requests (status, created_at desc);
create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  title_en text not null,
  title_fr text not null,
  body_en text,
  body_fr text,
  level text not null default 'info' check (level in ('info', 'warning', 'maintenance')),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  active boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now()
);
create table public.support_access_grants (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  granted_by uuid not null,
  reason text not null,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create table public.ai_queries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  user_id uuid,
  question text not null,
  answer text,
  model text,
  status text not null default 'started' check (status in ('started', 'completed', 'failed', 'rejected', 'fallback')),
  period_from date,
  period_to date,
  input_tokens int,
  output_tokens int,
  error text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index ai_queries_business on public.ai_queries (business_id, created_at desc);
create table public.rate_limits (
  key text not null,
  window_start timestamptz not null,
  count int not null default 0,
  primary key (key, window_start)
);
create or replace function app.can_read(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_member(bid) or (
    app.is_platform_admin() and exists (
      select 1 from public.support_access_grants g
      where g.business_id = bid and g.revoked_at is null and g.expires_at > now()))
$$;
create or replace function app.rate_limit(k text, max_count int, window_seconds int) returns void
language plpgsql security definer set search_path = public as $$
declare ws timestamptz := to_timestamp(floor(extract(epoch from now()) / window_seconds) * window_seconds); c int;
begin
  insert into public.rate_limits as r (key, window_start, count) values (k, ws, 1)
  on conflict (key, window_start) do update set count = r.count + 1 returning count into c;
  if c > max_count then perform app.raise('rate_limited'); end if;
  delete from public.rate_limits where window_start < now() - interval '2 days';
end $$;
create or replace function app.default_categories(cat text, lang text) returns text[]
language sql immutable as $$
  select case
    when cat = 'grocery' then case when lang = 'fr'
      then array['Alimentation', 'Boissons', 'Entretien ménager', 'Hygiène & beauté', 'Divers']
      else array['Food', 'Beverages', 'Household', 'Personal Care', 'Others'] end
    when cat = 'drinks' then case when lang = 'fr'
      then array['Bières', 'Boissons gazeuses', 'Eaux', 'Jus', 'Vins & spiritueux', 'Emballages']
      else array['Beer', 'Soft Drinks', 'Water', 'Juice', 'Wine & Spirits', 'Crates & Empties'] end
    when cat = 'hardware' then case when lang = 'fr'
      then array['Matériaux de construction', 'Outillage', 'Électricité', 'Plomberie', 'Peinture', 'Divers']
      else array['Building Materials', 'Tools', 'Electrical', 'Plumbing', 'Paint', 'Others'] end
    when cat = 'electronics' then case when lang = 'fr'
      then array['Téléphones', 'Accessoires', 'Électroménager', 'Informatique', 'Divers']
      else array['Phones', 'Accessories', 'Appliances', 'Computers', 'Others'] end
    when cat = 'fashion' then case when lang = 'fr'
      then array['Vêtements', 'Chaussures', 'Sacs & accessoires', 'Tissus', 'Divers']
      else array['Clothing', 'Shoes', 'Bags & Accessories', 'Fabrics', 'Others'] end
    when cat = 'cosmetics' then case when lang = 'fr'
      then array['Soins de la peau', 'Cheveux', 'Maquillage', 'Parfums', 'Hygiène', 'Divers']
      else array['Skin Care', 'Hair Care', 'Make-up', 'Fragrances', 'Hygiene', 'Others'] end
    else case when lang = 'fr'
      then array['Alimentation & boissons', 'Entretien ménager', 'Hygiène & beauté', 'Matériaux', 'Électronique', 'Divers']
      else array['Food & Beverages', 'Household', 'Personal Care', 'Building Materials', 'Electronics', 'Others'] end
  end
$$;
commit;
