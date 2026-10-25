-- BizPilot Market: buyers pay sellers directly; every sale is recorded with its channel.
--
--   * Marketplace orders: cash on delivery or Mobile Money paid straight to the seller's own MTN /
--     Orange number. BizPilot never holds buyer-seller money. A buyer can report a payment
--     (reference only); it stays pending until the seller confirms it ("seller-confirmed").
--     Fapshi is used for BizPilot subscriptions only: new online-paid orders are refused.
--   * Sales channel (in person, WhatsApp, Facebook, phone, marketplace, ...) on every sale,
--     sale-specific costs (delivery paid by the seller) recorded as linked expenses, and
--     cancelling a sale as a full return that keeps the original sale.
--   * Product condition and one-of-a-kind items (shown as sold, hidden from search once sold).
--   * Seller payment details and policies on the storefront, comparing sellers, report by channel,
--     and more business alerts with configurable thresholds.
-- Safe to run once on a database that has the marketplace upgrade. Existing data is kept.

-- ---------------------------------------------------------------------------
-- Sales channel, cancellation, sale-linked expenses
-- ---------------------------------------------------------------------------
alter table public.sales
  add column if not exists channel text not null default 'in_person',
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancel_reason text check (length(cancel_reason) <= 300);
alter table public.sales drop constraint if exists sales_channel_check;
alter table public.sales add constraint sales_channel_check
  check (channel in ('in_person', 'whatsapp', 'facebook', 'instagram', 'tiktok', 'phone', 'marketplace', 'other'));
create index if not exists sales_business_channel on public.sales (business_id, channel, sold_at);

-- Sales created from marketplace orders use the order id as client_ref.
update public.sales s set channel = 'marketplace'
  from public.market_orders o where o.sale_id = s.id and s.channel <> 'marketplace';

create or replace function app.sales_channel_default() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.market_orders o where o.id = new.client_ref and o.business_id = new.business_id) then
    new.channel := 'marketplace';
  end if;
  return new;
end $$;
drop trigger if exists sales_channel_default on public.sales;
create trigger sales_channel_default before insert on public.sales
  for each row execute function app.sales_channel_default();

alter table public.expenses add column if not exists sale_id uuid references public.sales (id);
create index if not exists expenses_sale on public.expenses (sale_id) where sale_id is not null;
alter table public.expenses drop constraint if exists expenses_category_check;
alter table public.expenses add constraint expenses_category_check check (category in ('rent', 'salaries', 'utilities',
  'transport', 'delivery', 'communication', 'packaging', 'repairs', 'marketing', 'bank_fees', 'taxes_licences', 'security',
  'cleaning', 'other'));

-- Records a sale from any channel (shop, WhatsApp, Facebook, phone, ...). Same rules as create_sale
-- (stock deducted once, duplicate submissions return the first sale) plus the channel and the
-- seller's own costs for this sale (e.g. delivery paid to a courier), recorded as a paid expense.
-- p: create_sale payload + {channel, delivery_cost, delivery_cost_method}
create or replace function public.record_sale(p_business uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ch text := coalesce(nullif(p ->> 'channel', ''), 'in_person');
  cost numeric := coalesce(nullif(p ->> 'delivery_cost', '')::numeric, 0);
  res jsonb; sid uuid; num text; eid uuid; at timestamptz;
begin
  if ch not in ('in_person', 'whatsapp', 'facebook', 'instagram', 'tiktok', 'phone', 'other') then
    perform app.raise('invalid_channel');   -- marketplace sales come from delivered orders only
  end if;
  if cost < 0 or cost > 100000000 then perform app.raise('invalid_amount'); end if;
  res := public.create_sale(p_business, p - 'channel' - 'delivery_cost' - 'delivery_cost_method');
  if coalesce((res ->> 'duplicate')::boolean, false) then return res; end if;
  sid := (res ->> 'id')::uuid; num := res ->> 'number';
  update public.sales set channel = ch where id = sid returning sold_at into at;
  if cost > 0 then
    cost := app.money(p_business, cost);
    insert into public.expenses (business_id, number, category, description, amount, expense_date, notes, sale_id, created_by)
    values (p_business, app.next_number(p_business, 'expense', 'EXP-'), 'delivery', 'Delivery for sale ' || num, cost,
            (at at time zone app.biz_tz(p_business))::date, null, sid, auth.uid())
    returning id into eid;
    perform app.insert_payment(p_business, 'expense_payment', coalesce(nullif(p ->> 'delivery_cost_method', ''), 'cash'), cost,
      at, null, null, null, null, null, null, null, eid);
    perform app.refresh_expense(eid);
    perform app.audit(p_business, 'expense.created', 'expense', eid::text,
                      jsonb_build_object('amount', cost, 'category', 'delivery', 'sale', num));
  end if;
  perform app.audit(p_business, 'sale.channel', 'sale', sid::text, jsonb_build_object('number', num, 'channel', ch));
  return res || jsonb_build_object('channel', ch, 'delivery_expense_id', eid);
end $$;

-- Cancels a sale: a full return of what is left (stock back when restockable), the money paid is
-- refunded, and the sale is marked cancelled. The original sale and its history are kept.
create or replace function public.cancel_sale(p_sale uuid, p_reason text, p_restock boolean default true,
  p_refund_method text default null, p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.sales; rid uuid; lines jsonb; refund numeric; v_method text;
begin
  select * into s from public.sales where id = p_sale for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(s.business_id, 'sales.refund');
  if s.cancelled_at is not null then
    return jsonb_build_object('id', s.id, 'already_cancelled', true);
  end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  if exists (select 1 from public.market_orders where sale_id = s.id) then
    perform app.raise('use_order_refund');   -- marketplace sales are refunded from the order
  end if;
  select jsonb_agg(jsonb_build_object('sale_line_id', id, 'base_quantity', base_quantity - returned_base_qty))
    into lines from public.sale_lines where sale_id = s.id and base_quantity > returned_base_qty;
  refund := greatest(0, least(s.paid_total - s.refunded_total, s.total - s.returned_total));
  v_method := coalesce(nullif(p_refund_method, ''),
    (select x.method from public.payments x where x.sale_id = s.id and x.kind = 'sale_payment' order by x.paid_at limit 1), 'cash');
  if lines is not null then
    rid := public.create_sale_return(s.id, jsonb_build_object('client_ref', p_client_ref, 'reason', 'Cancelled: ' || btrim(p_reason),
      'restock', p_restock, 'lines', lines,
      'refund', case when refund > 0 then jsonb_build_object('amount', refund, 'method', v_method, 'reference', 'Cancel ' || s.number) end));
  end if;
  update public.sales set cancelled_at = now(), cancel_reason = left(btrim(p_reason), 300) where id = s.id;
  perform app.audit(s.business_id, 'sale.cancelled', 'sale', s.id::text,
    jsonb_build_object('number', s.number, 'reason', btrim(p_reason), 'restock', p_restock, 'refund', refund, 'return_id', rid));
  return jsonb_build_object('id', s.id, 'return_id', rid, 'refund', refund);
end $$;

-- Sales by channel for a period: revenue net of returns, cost, gross profit, paid and outstanding.
create or replace function public.sales_by_channel(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; s timestamptz; e timestamptz;
begin
  perform app.report_guard(p_business, 'basic_analytics');
  d1 := app.report_from(p_business, p_from);
  s := app.range_start(p_business, d1); e := app.range_end(p_business, p_to);
  return coalesce((select jsonb_agg(t order by t.revenue desc) from (
    select x.channel, count(*) sales,
           count(*) filter (where x.cancelled_at is not null) cancelled,
           sum(x.total - x.tax_total - (x.returned_total - x.returned_tax)) revenue,
           round(sum(x.cost_total - x.returned_cost), 2) cost,
           round(sum(x.total - x.tax_total - (x.returned_total - x.returned_tax) - (x.cost_total - x.returned_cost)), 2) gross_profit,
           sum(x.paid_total - x.refunded_total) paid,
           sum(greatest(0, x.total - x.returned_total + x.refunded_total - x.paid_total)) outstanding,
           count(*) filter (where exists (select 1 from public.sale_lines l where l.sale_id = x.id and l.cost_amount = 0 and l.net_amount > 0)) missing_cost
      from public.sales x where x.business_id = p_business and x.sold_at >= s and x.sold_at < e
     group by x.channel) t), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- Products: condition and one-of-a-kind items
-- ---------------------------------------------------------------------------
alter table public.products
  add column if not exists condition text,
  add column if not exists single_item boolean not null default false;
alter table public.products drop constraint if exists products_condition_check;
alter table public.products add constraint products_condition_check
  check (condition is null or condition in ('new', 'like_new', 'used_good', 'used_fair', 'refurbished', 'for_parts'));

-- ---------------------------------------------------------------------------
-- Stores: the seller's own Mobile Money details and policies
-- ---------------------------------------------------------------------------
alter table public.stores
  add column if not exists momo_direct_enabled boolean not null default false,
  add column if not exists momo_mtn_number text check (momo_mtn_number ~ '^6[0-9]{8}$'),
  add column if not exists momo_mtn_name text check (length(momo_mtn_name) <= 80),
  add column if not exists momo_orange_number text check (momo_orange_number ~ '^6[0-9]{8}$'),
  add column if not exists momo_orange_name text check (length(momo_orange_name) <= 80),
  add column if not exists payment_note text check (length(payment_note) <= 300),
  add column if not exists return_policy text check (length(return_policy) <= 1500),
  add column if not exists neighborhood text check (length(neighborhood) <= 80),
  add column if not exists service_area text check (length(service_area) <= 200);

-- BizPilot no longer collects payments for orders: online payment can never be switched on again.
update public.stores set online_payment_enabled = false where online_payment_enabled;
create or replace function app.stores_no_online_payment() returns trigger
language plpgsql set search_path = public as $$
begin
  new.online_payment_enabled := false;
  return new;
end $$;
drop trigger if exists stores_no_online_payment on public.stores;
create trigger stores_no_online_payment before insert or update on public.stores
  for each row execute function app.stores_no_online_payment();

create or replace function public.store_save_payments(p_business uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare mtn text; ora text; enabled boolean := coalesce((p ->> 'momo_direct_enabled')::boolean, false);
begin
  perform app.require_perm(p_business, 'store.manage');
  if not exists (select 1 from public.stores where business_id = p_business) then perform app.raise('store_not_found'); end if;
  mtn := nullif(right(regexp_replace(coalesce(p ->> 'momo_mtn_number', ''), '\D', '', 'g'), 9), '');
  ora := nullif(right(regexp_replace(coalesce(p ->> 'momo_orange_number', ''), '\D', '', 'g'), 9), '');
  if (mtn is not null and mtn !~ '^6[0-9]{8}$') or (ora is not null and ora !~ '^6[0-9]{8}$') then perform app.raise('invalid_phone'); end if;
  if enabled and mtn is null and ora is null then perform app.raise('momo_number_required'); end if;
  update public.stores set
    momo_direct_enabled = enabled, momo_mtn_number = mtn, momo_orange_number = ora,
    momo_mtn_name = nullif(left(btrim(coalesce(p ->> 'momo_mtn_name', '')), 80), ''),
    momo_orange_name = nullif(left(btrim(coalesce(p ->> 'momo_orange_name', '')), 80), ''),
    payment_note = nullif(left(btrim(coalesce(p ->> 'payment_note', '')), 300), ''),
    return_policy = nullif(left(btrim(coalesce(p ->> 'return_policy', '')), 1500), ''),
    neighborhood = nullif(left(btrim(coalesce(p ->> 'neighborhood', '')), 80), ''),
    service_area = nullif(left(btrim(coalesce(p ->> 'service_area', '')), 200), ''),
    cod_enabled = coalesce((p ->> 'cod_enabled')::boolean, cod_enabled),
    online_payment_enabled = false, updated_at = now()
   where business_id = p_business;
  perform app.audit(p_business, 'store.payments', 'store', p_business::text,
    jsonb_build_object('momo_direct', enabled, 'mtn', mtn is not null, 'orange', ora is not null));
end $$;

-- A store can publish with cash on delivery or Mobile Money to the seller (online payment no longer counts).
create or replace function public.store_readiness(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.stores; listed int; zones int;
begin
  if not app.can_read(p_business) then perform app.raise('permission_denied'); end if;
  select * into s from public.stores where business_id = p_business;
  select count(*) into listed from public.products where business_id = p_business and online_published and status = 'active' and variant_of is null;
  select count(*) into zones from public.store_delivery_zones where business_id = p_business and active;
  return jsonb_build_object(
    'store_created', s.business_id is not null,
    'profile', coalesce(s.business_id is not null and s.name is not null and (s.phone is not null or s.whatsapp is not null), false),
    'logo', s.logo_path is not null,
    'products', listed > 0, 'listed', listed,
    'payment', coalesce(s.cod_enabled or (s.momo_direct_enabled and coalesce(s.momo_mtn_number, s.momo_orange_number) is not null), false),
    'delivery', coalesce(s.pickup_enabled, false) or zones > 0,
    'published', coalesce(s.status = 'published', false), 'status', s.status, 'slug', s.slug,
    'verification', s.verification, 'suspended_reason', s.suspended_reason);
end $$;

-- Dashboard summary for the seller: "awaiting payment" now means Mobile Money paid to the seller
-- that the seller has not confirmed yet.
create or replace function public.seller_market_summary(p_business uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare tz_start timestamptz := app.range_start(p_business, app.biz_today(p_business));
begin
  if not app.has_perm(p_business, 'orders.manage') then perform app.raise('permission_denied'); end if;
  perform app.market_expire();
  return jsonb_build_object(
    'readiness', public.store_readiness(p_business),
    'to_confirm', (select count(*) from public.market_orders where business_id = p_business and status = 'pending'
                    and (payment_method in ('cod', 'momo_direct') or payment_status = 'paid')),
    'awaiting_payment', (select count(*) from public.market_orders where business_id = p_business
                          and status in ('pending', 'confirmed', 'processing', 'dispatched')
                          and payment_method = 'momo_direct' and payment_status = 'cod_pending'),
    'to_deliver', (select count(*) from public.market_orders where business_id = p_business and status in ('confirmed', 'processing', 'dispatched')),
    'disputes', (select count(*) from public.market_reports where business_id = p_business and kind = 'dispute' and status in ('open', 'reviewing')),
    'today_orders', (select count(*) from public.market_orders where business_id = p_business and created_at >= tz_start),
    'today_delivered_total', (select coalesce(sum(total), 0) from public.market_orders where business_id = p_business
                               and status = 'delivered' and delivered_at >= tz_start),
    'balance', case when app.has_perm(p_business, 'cash.manage')
                    then (select coalesce(sum(amount), 0) from public.market_ledger where business_id = p_business) end,
    'recent', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'number', number, 'status', status, 'payment_method', payment_method,
                  'payment_status', payment_status, 'total', total, 'customer_name', customer_name, 'created_at', created_at) order by created_at desc)
                from (select * from public.market_orders where business_id = p_business order by created_at desc limit 6) r), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- Orders: direct Mobile Money to the seller, buyer-reported and seller-confirmed payments
-- ---------------------------------------------------------------------------
alter table public.market_orders
  add column if not exists buyer_payment_ref text check (length(buyer_payment_ref) <= 120),
  add column if not exists buyer_payment_reported_at timestamptz,
  add column if not exists payment_confirmed_at timestamptz,
  add column if not exists payment_confirmed_by uuid,
  add column if not exists payment_reference text check (length(payment_reference) <= 120);
alter table public.market_orders drop constraint if exists market_orders_payment_method_check;
alter table public.market_orders add constraint market_orders_payment_method_check
  check (payment_method in ('cod', 'momo_direct', 'online'));
alter table public.market_orders drop constraint if exists market_orders_payment_status_check;
alter table public.market_orders add constraint market_orders_payment_status_check
  check (payment_status in ('awaiting_payment', 'paid', 'failed', 'cod_pending', 'seller_confirmed',
    'cod_collected', 'refund_pending', 'refunded', 'void'));

create or replace function public.market_place_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); cfg jsonb := app.market_config(); q jsonb; s public.stores; b public.businesses;
  cref uuid := nullif(p ->> 'client_ref', '')::uuid; tok text := nullif(p ->> 'access_token', '');
  existing public.market_orders; oid uuid; num text; cname text; cphone text; cemail text; addr jsonb;
  pay text := p ->> 'payment_method'; cid uuid; l jsonb; exp timestamptz; comm numeric;
begin
  if cref is null then perform app.raise('invalid_request'); end if;
  if uid is null and (tok is null or length(tok) < 32 or length(tok) > 128) then perform app.raise('invalid_request'); end if;
  select * into existing from public.market_orders where client_ref = cref;
  if found then
    if existing.customer_user_id is distinct from uid and existing.access_token_hash is distinct from app.sha256(coalesce(tok, '')) then
      perform app.raise('invalid_request');
    end if;
    return jsonb_build_object('order_id', existing.id, 'number', existing.number, 'total', existing.total,
      'payment_method', existing.payment_method, 'payment_status', existing.payment_status, 'duplicate', true);
  end if;
  if not coalesce((cfg ->> 'enabled')::boolean, true) then perform app.raise('marketplace_closed'); end if;
  -- Mobile networks share IP addresses between many customers: the IP limit is generous, the
  -- per-phone limit (below) is what stops repeated fake orders.
  perform app.rate_limit('order_ip:' || app.client_ip(), 120, 3600);
  if uid is not null then perform app.rate_limit('order_user:' || uid, 20, 3600); end if;
  perform app.market_expire();

  cname := btrim(coalesce(p #>> '{customer,name}', ''));
  cphone := app.norm_phone(p #>> '{customer,phone}');
  cemail := nullif(lower(btrim(coalesce(p #>> '{customer,email}', ''))), '');
  if length(cname) < 2 or length(cname) > 80 then perform app.raise('customer_name_required'); end if;
  if cphone is null then perform app.raise('invalid_phone'); end if;
  perform app.rate_limit('order_phone:' || cphone, 10, 3600);
  if cemail is not null and not app.valid_email(cemail) then perform app.raise('invalid_email'); end if;
  if exists (select 1 from public.market_blocklist where (kind = 'phone' and value = cphone)
             or (kind = 'email' and value = cemail) or (kind = 'user' and value = uid::text)) then
    perform app.raise('checkout_blocked');
  end if;
  -- Buyers pay the seller directly. BizPilot does not collect order payments (Fapshi is for
  -- BizPilot subscriptions only), so 'online' is no longer accepted.
  if pay is null or pay not in ('cod', 'momo_direct') then perform app.raise('invalid_payment_method'); end if;

  -- Lock the products, then price the cart again under the lock.
  perform 1 from public.products where id in (select (x ->> 'product_id')::uuid from jsonb_array_elements(p -> 'items') x)
   order by id for update;
  q := app.market_price(p);
  if uid is not null and nullif(q ->> 'business_id', '') is not null and app.is_member((q ->> 'business_id')::uuid) then
    perform app.raise('cannot_order_from_own_store');
  end if;
  if jsonb_array_length(q -> 'errors') > 0 then
    perform app.raise('checkout_invalid', jsonb_build_object('errors', q -> 'errors'));
  end if;
  select * into s from public.stores where business_id = (q ->> 'business_id')::uuid;
  select * into b from public.businesses where id = s.business_id;

  if pay = 'cod' and not s.cod_enabled then perform app.raise('payment_method_not_available'); end if;
  if pay = 'momo_direct' and not (s.momo_direct_enabled and coalesce(s.momo_mtn_number, s.momo_orange_number) is not null) then
    perform app.raise('payment_method_not_available');
  end if;
  if (select count(*) from public.market_orders where business_id = s.business_id and customer_phone = cphone
       and payment_method in ('cod', 'momo_direct') and status in ('pending', 'confirmed', 'processing', 'dispatched'))
     >= coalesce((cfg ->> 'max_open_cod_per_phone')::int, 3) then
    perform app.raise('too_many_open_orders');
  end if;

  if q ->> 'delivery_method' = 'delivery' then
    addr := jsonb_build_object('city', btrim(coalesce(p #>> '{address,city}', '')), 'area', nullif(btrim(coalesce(p #>> '{address,area}', '')), ''),
      'line', nullif(btrim(coalesce(p #>> '{address,line}', '')), ''), 'landmark', nullif(btrim(coalesce(p #>> '{address,landmark}', '')), ''));
    if length(addr ->> 'city') < 2 or coalesce(addr ->> 'line', addr ->> 'area', '') = '' then perform app.raise('address_required'); end if;
    if length(addr::text) > 800 then perform app.raise('invalid_request'); end if;
  end if;

  exp := now() + make_interval(hours => coalesce((cfg ->> 'confirm_hours')::int, 48));
  comm := coalesce((cfg ->> 'commission_pct')::numeric, 0);

  -- The seller's customer record (matched by phone) so online buyers appear under Customers.
  select id into cid from public.customers where business_id = s.business_id and phone = cphone and status = 'active' limit 1;
  if cid is null then
    insert into public.customers (business_id, name, phone, email, address, source, user_id, created_by)
    values (s.business_id, cname, cphone, cemail, nullif(concat_ws(', ', addr ->> 'line', addr ->> 'area', addr ->> 'city'), ''),
            'online', uid, uid)
    returning id into cid;
  else
    update public.customers set email = coalesce(email, cemail), user_id = coalesce(user_id, uid) where id = cid;
  end if;

  num := app.next_number(s.business_id, 'order', 'ORD-');
  insert into public.market_orders (business_id, number, client_ref, customer_user_id, access_token_hash, customer_id,
    customer_name, customer_phone, customer_email, delivery_method, zone_id, zone_name, delivery_eta, address, notes,
    subtotal, discount, delivery_fee, total, currency, promo_id, promo_code, payment_method, payment_status,
    commission_pct, commission_amount, online_fee_pct, online_fee_amount, expires_at)
  values (s.business_id, num, cref, uid, case when tok is not null then app.sha256(tok) end, cid,
    cname, cphone, cemail, q ->> 'delivery_method', nullif(p ->> 'zone_id', '')::uuid, q ->> 'zone_name', q ->> 'delivery_eta',
    addr, nullif(left(btrim(coalesce(p ->> 'notes', '')), 500), ''),
    (q ->> 'subtotal')::numeric, (q ->> 'discount')::numeric, (q ->> 'delivery_fee')::numeric, (q ->> 'total')::numeric,
    b.currency, nullif(q ->> 'promo_id', '')::uuid, q ->> 'promo_code', pay, 'cod_pending',
    comm, app.money(s.business_id, ((q ->> 'subtotal')::numeric - (q ->> 'discount')::numeric) * comm / 100),
    0, 0, exp)
  returning id into oid;

  for l in select * from jsonb_array_elements(q -> 'lines') loop
    insert into public.market_order_lines (order_id, business_id, product_id, listing_id, name, variant_label, sku, image_path,
      unit_price, quantity, line_total, sort)
    values (oid, s.business_id, (l ->> 'product_id')::uuid, (l ->> 'listing_id')::uuid, l ->> 'name', l ->> 'variant_label',
      l ->> 'sku', l ->> 'image_path', (l ->> 'unit_price')::numeric, (l ->> 'quantity')::numeric,
      (l ->> 'line_total')::numeric, (l ->> 'sort')::int);
    insert into public.stock_reservations (business_id, product_id, order_id, quantity, expires_at)
    values (s.business_id, (l ->> 'product_id')::uuid, oid, (l ->> 'quantity')::numeric, exp);
  end loop;
  if nullif(q ->> 'promo_id', '') is not null then
    update public.market_promotions set used_count = used_count + 1 where id = (q ->> 'promo_id')::uuid;
  end if;

  insert into public.market_order_events (order_id, business_id, kind, status, actor, actor_user)
  values (oid, s.business_id, 'status', 'pending', 'customer', uid);
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (s.business_id, 'market_order_new', 'info',
          jsonb_build_object('number', num, 'amount', (q ->> 'total')::numeric, 'customer', cname), '/app/orders/' || oid, 'orders.manage');

  if uid is not null and coalesce((p ->> 'save_address')::boolean, false) and addr is not null
     and (select count(*) from public.customer_addresses where user_id = uid) < 10
     and not exists (select 1 from public.customer_addresses where user_id = uid and lower(city) = lower(addr ->> 'city')
                     and coalesce(lower(line), '') = coalesce(lower(addr ->> 'line'), '')) then
    insert into public.customer_addresses (user_id, recipient_name, phone, city, area, line, landmark, is_default)
    values (uid, cname, cphone, addr ->> 'city', addr ->> 'area', addr ->> 'line', addr ->> 'landmark',
            not exists (select 1 from public.customer_addresses where user_id = uid));
  end if;

  return jsonb_build_object('order_id', oid, 'number', num, 'total', (q ->> 'total')::numeric,
    'payment_method', pay, 'payment_status', 'cod_pending', 'duplicate', false);
end $$;

-- Buyer reports a direct Mobile Money payment (transaction ID / sender). It is only evidence:
-- the order stays unpaid until the seller confirms the money arrived.
create or replace function public.market_order_report_payment(p_order uuid, p_token text, p_reference text)
returns void language plpgsql security definer set search_path = public as $$
declare o public.market_orders; ref text := nullif(left(btrim(coalesce(p_reference, '')), 120), '');
begin
  o := app.order_for_customer(p_order, p_token, true);
  perform app.rate_limit('order_msg:' || o.id, 30, 3600);
  if o.payment_method <> 'momo_direct' or o.payment_status <> 'cod_pending'
     or o.status not in ('pending', 'confirmed', 'processing', 'dispatched') then
    perform app.raise('invalid_order_status');
  end if;
  if ref is null or length(ref) < 4 then perform app.raise('reference_required'); end if;
  update public.market_orders set buyer_payment_ref = ref, buyer_payment_reported_at = now() where id = o.id;
  insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user)
  values (o.id, o.business_id, 'payment', 'reported: ' || ref, 'customer', auth.uid());
  insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
  values (o.business_id, 'market_payment_reported', 'warning', jsonb_build_object('number', o.number, 'amount', o.total),
          '/app/orders/' || o.id, 'orders.manage', 'payment_reported:' || o.id || ':' || ref) on conflict do nothing;
end $$;

-- Seller actions on an order. p: {reason, message, method (cash|mtn_momo|orange_money), reference,
--   proof_note, proof_path, received_by, restock}
create or replace function public.market_order_action(p_order uuid, p_action text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o public.market_orders; msg text := nullif(left(btrim(coalesce(p ->> 'message', '')), 1000), '');
  reason text := nullif(left(btrim(coalesce(p ->> 'reason', '')), 300), ''); sid uuid; rid uuid;
  goods numeric; refund numeric; method text := coalesce(p ->> 'method', p ->> 'cod_method', '');
  ref text := nullif(left(btrim(coalesce(p ->> 'reference', '')), 120), '');
begin
  select * into o from public.market_orders where id = p_order for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(o.business_id, 'orders.manage');

  if p_action = 'confirm' then
    if o.status <> 'pending' then perform app.raise('invalid_order_status'); end if;
    if o.payment_method = 'online' and o.payment_status <> 'paid' then perform app.raise('order_not_paid'); end if;
    update public.market_orders set status = 'confirmed', confirmed_at = now(), expires_at = null where id = o.id;
    update public.stock_reservations set expires_at = null where order_id = o.id and released_at is null and consumed_at is null;
  elsif p_action = 'processing' then
    if o.status <> 'confirmed' then perform app.raise('invalid_order_status'); end if;
    update public.market_orders set status = 'processing' where id = o.id;
  elsif p_action = 'dispatch' then
    if o.status not in ('confirmed', 'processing') then perform app.raise('invalid_order_status'); end if;
    update public.market_orders set status = 'dispatched', dispatched_at = now() where id = o.id;
  elsif p_action = 'payment_received' then
    -- The seller confirms the buyer's money arrived on their own account (seller-confirmed).
    if o.payment_method not in ('cod', 'momo_direct') or o.payment_status <> 'cod_pending'
       or o.status not in ('pending', 'confirmed', 'processing', 'dispatched') then
      perform app.raise('invalid_order_status');
    end if;
    if method not in ('cash', 'mtn_momo', 'orange_money') then perform app.raise('payment_method_required'); end if;
    update public.market_orders set payment_status = 'seller_confirmed', cod_method = method, cod_collected_amount = o.total,
           payment_confirmed_at = now(), payment_confirmed_by = auth.uid(), payment_reference = coalesce(ref, o.buyer_payment_ref)
     where id = o.id;
  elsif p_action = 'deliver' then
    if o.status not in ('confirmed', 'processing', 'dispatched') then perform app.raise('invalid_order_status'); end if;
    if o.payment_method in ('cod', 'momo_direct') then
      -- Paid to the seller: on delivery (cash / Mobile Money) or confirmed earlier.
      if o.payment_status = 'seller_confirmed' then method := o.cod_method; end if;
      if method not in ('cash', 'mtn_momo', 'orange_money') then perform app.raise('payment_method_required'); end if;
      sid := app.market_order_to_sale(o.id, method, coalesce(ref, o.payment_reference, o.buyer_payment_ref, 'Order ' || o.number));
      if o.delivery_fee > 0 then
        -- The delivery fee was collected with the goods: it goes into the same cash account.
        insert into public.cash_movements (business_id, kind, to_account_id, amount, note, client_ref, created_by)
        values (o.business_id, 'deposit', app.account_for_method(o.business_id, method), o.delivery_fee,
                'Delivery fee ' || o.number, null, auth.uid());
      end if;
      update public.market_orders set payment_status = 'cod_collected', cod_collected_amount = o.total, cod_method = method,
             cod_collected_at = coalesce(payment_confirmed_at, now()), cod_collected_by = coalesce(payment_confirmed_by, auth.uid()),
             payment_confirmed_at = coalesce(payment_confirmed_at, now()), payment_confirmed_by = coalesce(payment_confirmed_by, auth.uid()),
             payment_reference = coalesce(payment_reference, ref)
       where id = o.id;
      if o.commission_amount > 0 then
        insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
        values (o.business_id, o.id, 'commission', -o.commission_amount, 'Commission ' || o.number, auth.uid());
      end if;
    else
      -- Orders paid online before BizPilot stopped collecting order payments.
      if o.payment_status <> 'paid' then perform app.raise('order_not_paid'); end if;
      sid := app.market_order_to_sale(o.id, 'other', 'BizPilot Market ' || o.number);
      insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
      values (o.business_id, o.id, 'order_payment', o.total, 'Online payment ' || o.number, auth.uid());
      if o.commission_amount > 0 then
        insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
        values (o.business_id, o.id, 'commission', -o.commission_amount, 'Commission ' || o.number, auth.uid());
      end if;
      if o.online_fee_amount > 0 then
        insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
        values (o.business_id, o.id, 'processing_fee', -o.online_fee_amount, 'Payment processing ' || o.number, auth.uid());
      end if;
    end if;
    update public.market_orders set status = 'delivered', delivered_at = now(), delivered_by = auth.uid(), sale_id = sid,
           delivery_proof_note = nullif(left(btrim(coalesce(p ->> 'proof_note', '')), 300), ''),
           delivery_proof_path = case when split_part(coalesce(p ->> 'proof_path', ''), '/', 1) = o.business_id::text then p ->> 'proof_path' end,
           received_by = nullif(left(btrim(coalesce(p ->> 'received_by', '')), 80), ''), expires_at = null
     where id = o.id;
  elsif p_action in ('reject', 'cancel') then
    if reason is null then perform app.raise('reason_required'); end if;
    if o.payment_status = 'seller_confirmed' then
      -- The seller already has the buyer's money: they must send it back (recorded on the order).
      update public.market_orders set payment_status = 'refund_pending' where id = o.id;
    end if;
    perform app.market_cancel(o.id, 'seller', reason);
  elsif p_action = 'refunded' then
    -- The seller sent the buyer's money back after cancelling a seller-confirmed payment.
    if o.status <> 'cancelled' or o.payment_status <> 'refund_pending' or o.payment_method = 'online' then
      perform app.raise('invalid_order_status');
    end if;
    update public.market_orders set payment_status = 'refunded', refunded_at = now(), refund_amount = o.total,
           refund_reference = coalesce(ref, 'Refund ' || o.number) where id = o.id;
  elsif p_action = 'refund' then
    -- After delivery: the goods come back (optionally to stock) through a normal sale return.
    if o.status <> 'delivered' then perform app.raise('invalid_order_status'); end if;
    if reason is null then perform app.raise('reason_required'); end if;
    perform app.require_perm(o.business_id, 'sales.refund');
    goods := (select total - returned_total from public.sales where id = o.sale_id);
    refund := goods;
    rid := public.create_sale_return(o.sale_id, jsonb_build_object('reason', reason,
      'restock', coalesce((p ->> 'restock')::boolean, true),
      'lines', (select jsonb_agg(jsonb_build_object('sale_line_id', sl.id, 'base_quantity', sl.base_quantity - sl.returned_base_qty))
                  from public.sale_lines sl where sl.sale_id = o.sale_id and sl.base_quantity > sl.returned_base_qty),
      'refund', jsonb_build_object('amount', refund, 'method', case when o.payment_method = 'online' then 'other' else o.cod_method end,
                                   'reference', 'Refund ' || o.number)));
    if o.payment_method = 'online' then
      insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
      values (o.business_id, o.id, 'refund', -(refund + o.delivery_fee) + o.commission_amount + o.online_fee_amount,
              'Refund ' || o.number, auth.uid());
      update public.market_orders set status = 'refunded', payment_status = 'refund_pending', refund_amount = refund + o.delivery_fee,
             flagged = true, flag_reason = 'refund_after_delivery' where id = o.id;
    else
      if o.commission_amount > 0 then
        insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
        values (o.business_id, o.id, 'commission', o.commission_amount, 'Commission reversed ' || o.number, auth.uid());
      end if;
      update public.market_orders set status = 'refunded', payment_status = 'refunded', refund_amount = refund,
             refunded_at = now(), refund_reference = 'Refund ' || o.number where id = o.id;
    end if;
  elsif p_action in ('message', 'note') then
    if msg is null then perform app.raise('message_required'); end if;
  else
    perform app.raise('invalid_action');
  end if;

  if p_action in ('message', 'note') then
    insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user, visible_to_customer)
    values (o.id, o.business_id, p_action, msg, 'seller', auth.uid(), p_action = 'message');
  elsif p_action = 'payment_received' then
    insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user)
    values (o.id, o.business_id, 'payment', 'confirmed: ' || method, 'seller', auth.uid());
  elsif p_action not in ('reject', 'cancel') then
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
    values (o.id, o.business_id, 'status', (select status from public.market_orders where id = o.id), coalesce(msg, reason), 'seller', auth.uid());
  end if;
  perform app.audit(o.business_id, 'order.' || p_action, 'market_order', o.id::text,
                    jsonb_build_object('number', o.number, 'reason', reason, 'method', nullif(method, '')));
  return (select to_jsonb(x) from public.market_orders x where x.id = o.id);
end $$;

-- What the buyer sees, including the seller's Mobile Money details for direct payment.
create or replace function public.market_order_view(p_order uuid, p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.market_orders; s public.stores;
begin
  perform app.market_expire();
  o := app.order_for_customer(p_order, p_token);
  select * into s from public.stores where business_id = o.business_id;
  return jsonb_build_object(
    'id', o.id, 'number', o.number, 'status', o.status, 'payment_method', o.payment_method, 'payment_status', o.payment_status,
    'created_at', o.created_at, 'confirmed_at', o.confirmed_at, 'dispatched_at', o.dispatched_at, 'delivered_at', o.delivered_at,
    'cancelled_at', o.cancelled_at, 'cancel_reason', o.cancel_reason, 'cancelled_by', o.cancelled_by,
    'expires_at', case when o.status = 'pending' then o.expires_at end,
    'customer_name', o.customer_name, 'customer_phone', o.customer_phone, 'customer_email', o.customer_email,
    'delivery_method', o.delivery_method, 'zone_name', o.zone_name, 'delivery_eta', o.delivery_eta, 'address', o.address,
    'notes', o.notes, 'subtotal', o.subtotal, 'discount', o.discount, 'delivery_fee', o.delivery_fee, 'total', o.total,
    'currency', o.currency, 'promo_code', o.promo_code, 'refund_amount', o.refund_amount, 'refunded_at', o.refunded_at,
    'buyer_payment_ref', o.buyer_payment_ref, 'buyer_payment_reported_at', o.buyer_payment_reported_at,
    'payment_confirmed_at', o.payment_confirmed_at, 'paid_with', o.cod_method,
    'store', jsonb_build_object('slug', s.slug, 'name', s.name, 'logo_path', s.logo_path, 'city', s.city,
       'phone', case when s.show_phone then s.phone end, 'whatsapp', case when s.show_whatsapp then s.whatsapp end,
       'email', case when s.show_email then s.email end,
       'address', case when o.delivery_method = 'pickup' or s.show_address then s.address end,
       'pickup_note', case when o.delivery_method = 'pickup' then s.pickup_note end,
       'return_policy', s.return_policy,
       'momo', case when o.payment_method = 'momo_direct' then jsonb_build_object(
          'mtn_number', s.momo_mtn_number, 'mtn_name', s.momo_mtn_name,
          'orange_number', s.momo_orange_number, 'orange_name', s.momo_orange_name, 'note', s.payment_note) end),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('product_id', l.product_id, 'listing_id', l.listing_id, 'name', l.name,
       'variant_label', l.variant_label, 'image_path', l.image_path, 'unit_price', l.unit_price, 'quantity', l.quantity,
       'line_total', l.line_total,
       'reviewed', exists (select 1 from public.market_reviews r where r.order_id = o.id and r.product_id = l.product_id))
       order by l.sort) from public.market_order_lines l where l.order_id = o.id), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'status', e.status, 'message', e.message,
       'actor', e.actor, 'created_at', e.created_at) order by e.created_at, e.id)
       from public.market_order_events e where e.order_id = o.id and e.visible_to_customer), '[]'::jsonb),
    'can_cancel', o.status = 'pending' and o.payment_status <> 'seller_confirmed',
    'can_pay', false,
    'can_report_payment', o.payment_method = 'momo_direct' and o.payment_status = 'cod_pending'
       and o.status in ('pending', 'confirmed', 'processing', 'dispatched'),
    'can_review', o.status = 'delivered',
    'signed_in_owner', auth.uid() is not null and o.customer_user_id = auth.uid());
end $$;

-- Customers cannot cancel after the seller confirmed their payment (the seller must refund).
create or replace function public.market_order_customer_action(p_order uuid, p_token text, p_action text, p_text text default null)
returns void language plpgsql security definer set search_path = public as $$
declare o public.market_orders; msg text := nullif(left(btrim(coalesce(p_text, '')), 1000), '');
begin
  o := app.order_for_customer(p_order, p_token, true);
  perform app.rate_limit('order_msg:' || o.id, 30, 3600);
  if p_action = 'cancel' then
    if o.status <> 'pending' or o.payment_status = 'seller_confirmed' then perform app.raise('order_not_cancellable'); end if;
    perform app.market_cancel(o.id, 'customer', coalesce(msg, 'cancelled_by_customer'));
  elsif p_action = 'message' then
    if msg is null then perform app.raise('message_required'); end if;
    insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user)
    values (o.id, o.business_id, 'message', msg, 'customer', auth.uid());
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (o.business_id, 'market_message', 'info', jsonb_build_object('number', o.number), '/app/orders/' || o.id,
            'orders.manage', 'market_message:' || o.id || ':' || date_trunc('hour', now())) on conflict do nothing;
  else
    perform app.raise('invalid_action');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Public marketplace data
-- ---------------------------------------------------------------------------
create or replace function app.product_card(p_listing uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', p.id, 'name', p.name, 'brand', p.brand,
    'image', p.online_images[1], 'unit', p.base_unit,
    'price', o.min_price, 'max_price', o.max_price, 'compare_at_price',
      case when p.compare_at_price > o.min_price then p.compare_at_price end,
    'available', least(o.available, 99), 'options', o.n,
    'category', c.name, 'subcategory', p.subcategory,
    'condition', p.condition, 'sold', p.single_item and coalesce(o.available, 0) <= 0,
    'rating_avg', r.avg, 'rating_count', coalesce(r.n, 0),
    'store', jsonb_build_object('slug', s.slug, 'name', s.name, 'city', s.city, 'verified', s.verification = 'verified',
                                'logo_path', s.logo_path))
  from public.products p
  join public.stores s on s.business_id = p.business_id
  left join public.categories c on c.id = p.category_id
  cross join lateral (select min(x.price) min_price, max(x.price) max_price, sum(x.available) available, count(*) n
                        from app.listing_options(p.id) x) o
  left join lateral (select round(avg(rating), 1) avg, count(*) n from public.market_reviews
                      where listing_id = p.id and status = 'visible') r on true
  where p.id = p_listing
$$;

-- Search. Adds: min_rating, delivery (only stores that deliver), sort 'newest'; sold one-of-a-kind
-- items are left out.
create or replace function public.market_search(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  q text := nullif(btrim(coalesce(p ->> 'q', '')), '');
  v_type text := nullif(p ->> 'type', '');
  v_cat text := nullif(btrim(coalesce(p ->> 'category', '')), '');
  v_store text := nullif(lower(p ->> 'store'), '');
  v_city text := nullif(btrim(coalesce(p ->> 'city', '')), '');
  minp numeric := nullif(p ->> 'min_price', '')::numeric;
  maxp numeric := nullif(p ->> 'max_price', '')::numeric;
  minr numeric := nullif(p ->> 'min_rating', '')::numeric;
  instock boolean := coalesce((p ->> 'in_stock')::boolean, false);
  v_delivery boolean := coalesce((p ->> 'delivery')::boolean, false);
  v_cond text := nullif(p ->> 'condition', '');
  v_sort text := coalesce(nullif(p ->> 'sort', ''), 'relevance');
  size int := least(greatest(coalesce((p ->> 'page_size')::int, 24), 1), 60);
  pg int := greatest(coalesce((p ->> 'page')::int, 1), 1);
  res jsonb;
begin
  if q is not null and length(q) > 80 then q := left(q, 80); end if;
  with base as (
    select pr.id, pr.name, pr.online_since, o.min_price, o.available,
           coalesce(r.avg, 0) rating,
           case when q is null then 0
                when lower(pr.name) = lower(q) then 3
                when pr.name ilike app.like_term(q) then 2 else 1 end rel
      from public.products pr
      join public.stores s on s.business_id = pr.business_id and s.status = 'published'
      join public.businesses b on b.id = pr.business_id and b.status = 'active'
      left join public.categories c on c.id = pr.category_id
      cross join lateral (select min(x.price) min_price, sum(x.available) available from app.listing_options(pr.id) x) o
      left join lateral (select avg(rating) avg from public.market_reviews mr where mr.listing_id = pr.id and mr.status = 'visible') r on true
     where pr.online_published and pr.status = 'active' and not pr.admin_hidden and pr.variant_of is null
       and app.listing_within_limit(pr.business_id, pr.online_since, pr.id)
       and not (pr.single_item and coalesce(o.available, 0) <= 0)
       and (q is null or pr.name ilike app.like_term(q) or pr.brand ilike app.like_term(q)
            or pr.description ilike app.like_term(q) or c.name ilike app.like_term(q)
            or pr.subcategory ilike app.like_term(q) or s.name ilike app.like_term(q))
       and (v_type is null or b.category = v_type)
       and (v_cat is null or lower(c.name) = lower(v_cat) or lower(pr.subcategory) = lower(v_cat))
       and (v_store is null or lower(s.slug) = v_store)
       and (v_city is null or s.city ilike app.like_term(v_city) or s.region ilike app.like_term(v_city)
            or s.neighborhood ilike app.like_term(v_city))
       and (minp is null or o.min_price >= minp)
       and (maxp is null or o.min_price <= maxp)
       and (minr is null or coalesce(r.avg, 0) >= minr)
       and (not instock or o.available > 0)
       and (not v_delivery or exists (select 1 from public.store_delivery_zones z where z.business_id = s.business_id and z.active))
       and (v_cond is null or pr.condition = v_cond)
  ), ranked as (
    select id, row_number() over (
             order by case when v_sort = 'relevance' then rel end desc nulls last,
                      case when v_sort = 'price_asc' then min_price end asc nulls last,
                      case when v_sort = 'price_desc' then min_price end desc nulls last,
                      case when v_sort = 'rating' then rating end desc nulls last,
                      case when v_sort = 'newest' then online_since end desc nulls last,
                      (available > 0) desc, online_since desc, id) ord
      from base
  )
  select jsonb_build_object(
    'total', (select count(*) from base),
    'page', pg, 'page_size', size,
    'items', coalesce((select jsonb_agg(app.product_card(r.id) order by r.ord) from ranked r
                        where r.ord > (pg - 1) * size and r.ord <= pg * size), '[]'::jsonb))
    into res;
  return res;
end $$;

-- Product page: adds condition, sold state and the same product from other sellers (compare).
create or replace function public.market_product(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare pr public.products; lid uuid; words text[]; term text;
begin
  lid := app.listing_of(p_id);
  if lid is null then return null; end if;
  select * into pr from public.products where id = lid;
  -- First two meaningful words of the name, e.g. "iPhone 13" from "iPhone 13 Pro 128GB blue".
  words := array(select w from regexp_split_to_table(lower(pr.name), '[^[:alnum:]]+') w where length(w) >= 2 limit 2);
  term := array_to_string(words, '%');
  return app.product_card(lid) || jsonb_build_object(
    'description', pr.description, 'images', to_jsonb(pr.online_images), 'attributes', pr.attributes,
    'business_type', (select category from public.businesses where id = pr.business_id),
    'store_id', pr.business_id, 'single_item', pr.single_item,
    'options', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label, 'price', o.price,
                          'compare_at_price', case when o.compare_at > o.price then o.compare_at end,
                          'available', least(o.available, 99), 'attributes', o.attributes, 'allow_fraction', o.allow_fraction)
                          order by o.label nulls first) from app.listing_options(lid) o), '[]'::jsonb),
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('rating', r.rating, 'comment', r.comment, 'author', r.author_name,
                          'reply', r.seller_reply, 'created_at', r.created_at) order by r.created_at desc)
                         from (select * from public.market_reviews where listing_id = lid and status = 'visible'
                                order by created_at desc limit 20) r), '[]'::jsonb),
    'related', coalesce((select jsonb_agg(app.product_card(x.id)) from (
                          select p2.id from public.products p2 where p2.business_id = pr.business_id and p2.id <> lid
                             and p2.online_published and p2.status = 'active' and not p2.admin_hidden and p2.variant_of is null
                           order by (p2.category_id is not distinct from pr.category_id) desc, p2.online_since desc limit 8) x), '[]'::jsonb),
    'other_sellers', case when coalesce(term, '') = '' then '[]'::jsonb else coalesce((select jsonb_agg(app.product_card(x.id) order by x.price) from (
                          select p3.id, (select min(o.price) from app.listing_options(p3.id) o) price
                            from public.products p3 join public.stores s3 on s3.business_id = p3.business_id and s3.status = 'published'
                            join public.businesses b3 on b3.id = p3.business_id and b3.status = 'active'
                           where p3.business_id <> pr.business_id and p3.online_published and p3.status = 'active'
                             and not p3.admin_hidden and p3.variant_of is null
                             and app.listing_within_limit(p3.business_id, p3.online_since, p3.id)
                             and lower(p3.name) like '%' || term || '%'
                           limit 12) x), '[]'::jsonb) end);
end $$;

-- Storefront: payment methods (cash on delivery / Mobile Money to the seller) and policies.
create or replace function public.market_store(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.stores; b public.businesses; custom boolean;
begin
  select * into s from public.stores where lower(slug) = lower(btrim(p_slug));
  if not found then return null; end if;
  select * into b from public.businesses where id = s.business_id;
  if s.status <> 'published' or b.status <> 'active' then
    return jsonb_build_object('slug', s.slug, 'name', s.name, 'unavailable', true);
  end if;
  custom := app.has_feature(s.business_id, 'store_customization');
  return jsonb_build_object(
    'business_id', s.business_id, 'slug', s.slug, 'name', s.name, 'tagline', s.tagline, 'description', s.description,
    'logo_path', s.logo_path, 'cover_path', case when custom then s.cover_path end,
    'brand_color', case when custom then s.brand_color end,
    'business_type', b.category, 'city', s.city, 'region', s.region, 'neighborhood', s.neighborhood, 'service_area', s.service_area,
    'address', case when s.show_address then s.address end,
    'phone', case when s.show_phone then s.phone end,
    'whatsapp', case when s.show_whatsapp then s.whatsapp end,
    'email', case when s.show_email then s.email end,
    'facebook_url', s.facebook_url, 'instagram_url', s.instagram_url, 'tiktok_url', s.tiktok_url,
    'opening_hours', s.opening_hours, 'hours_note', s.hours_note, 'delivery_note', s.delivery_note,
    'pickup_enabled', s.pickup_enabled, 'pickup_note', s.pickup_note, 'cod_enabled', s.cod_enabled,
    'online_payment_enabled', false,
    'momo_direct_enabled', s.momo_direct_enabled and coalesce(s.momo_mtn_number, s.momo_orange_number) is not null,
    'momo_networks', array_remove(array[case when s.momo_direct_enabled and s.momo_mtn_number is not null then 'mtn' end,
                                        case when s.momo_direct_enabled and s.momo_orange_number is not null then 'orange' end], null),
    'payment_note', s.payment_note, 'return_policy', s.return_policy,
    'min_order_amount', s.min_order_amount, 'currency', b.currency,
    'verified', s.verification = 'verified', 'rating_avg', s.rating_avg, 'rating_count', s.rating_count,
    'joined', s.published_at,
    'zones', coalesce((select jsonb_agg(jsonb_build_object('id', z.id, 'name', z.name, 'fee', z.fee, 'eta', z.eta) order by z.sort, z.name)
                       from public.store_delivery_zones z where z.business_id = s.business_id and z.active), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'products', t.n) order by t.sort, t.name) from (
                     select c.name, min(c.sort_order) sort, count(*) n from public.products pr join public.categories c on c.id = pr.category_id
                      where pr.business_id = s.business_id and pr.online_published and pr.status = 'active' and not pr.admin_hidden
                        and pr.variant_of is null group by c.name) t), '[]'::jsonb),
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('rating', r.rating, 'comment', r.comment, 'author', r.author_name,
                     'product', pr.name, 'reply', r.seller_reply, 'created_at', r.created_at) order by r.created_at desc)
                   from (select * from public.market_reviews where business_id = s.business_id and status = 'visible'
                          order by created_at desc limit 10) r join public.products pr on pr.id = r.product_id), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- Alerts: more checks, thresholds set per business
-- ---------------------------------------------------------------------------
alter table public.business_settings add column if not exists alert_settings jsonb not null default '{}'::jsonb;
alter table public.business_settings drop constraint if exists business_settings_alert_settings_check;
alter table public.business_settings add constraint business_settings_alert_settings_check
  check (jsonb_typeof(alert_settings) = 'object' and pg_column_size(alert_settings) <= 2048);

-- p: {fast_selling_days (3-60), large_adjustment_value (>= 0), order_wait_hours (1-72), disabled: [alert types]}
create or replace function public.save_alert_settings(p_business uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  perform app.require_perm(p_business, 'settings.manage');
  v := jsonb_build_object(
    'fast_selling_days', least(greatest(coalesce((p ->> 'fast_selling_days')::int, 7), 3), 60),
    'large_adjustment_value', greatest(coalesce((p ->> 'large_adjustment_value')::numeric, 50000), 0),
    'order_wait_hours', least(greatest(coalesce((p ->> 'order_wait_hours')::int, 2), 1), 72),
    'disabled', coalesce((select jsonb_agg(x) from jsonb_array_elements_text(coalesce(p -> 'disabled', '[]'::jsonb)) x
                           where x in ('out_of_stock', 'low_stock', 'expiring_soon', 'fast_selling', 'customer_overdue',
                                       'orders_waiting', 'payment_to_confirm', 'large_adjustment', 'possible_duplicate_sale')), '[]'::jsonb));
  update public.business_settings set alert_settings = v, updated_at = now() where business_id = p_business;
  perform app.audit(p_business, 'settings.alerts', 'business', p_business::text, v);
  return v;
end $$;

create or replace function app.build_alerts(p_business uuid)
returns int language plpgsql security definer set search_path = public as $$
declare today date; n int := 0; c int; st public.business_settings; sub jsonb; r record; added int;
        al jsonb; off jsonb; fast int; big numeric; wait_h int;
begin
  today := app.biz_today(p_business);
  select * into st from public.business_settings where business_id = p_business;
  al := coalesce(st.alert_settings, '{}'::jsonb);
  off := coalesce(al -> 'disabled', '[]'::jsonb);
  fast := coalesce((al ->> 'fast_selling_days')::int, 7);
  big := coalesce((al ->> 'large_adjustment_value')::numeric, 50000);
  wait_h := coalesce((al ->> 'order_wait_hours')::int, 2);

  if not off ? 'out_of_stock' then
    select count(*) into c from public.products where business_id = p_business and status = 'active'
       and qty_on_hand <= 0 and exists (select 1 from public.stock_movements m where m.product_id = products.id);
    if c > 0 then
      insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
      values (p_business, 'out_of_stock', 'critical', jsonb_build_object('count', c), '/app/inventory?filter=out',
              'out_of_stock:' || today) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;

  if not off ? 'low_stock' then
    select count(*) into c from public.products where business_id = p_business and status = 'active'
       and qty_on_hand > 0 and qty_on_hand <= greatest(min_stock, 0) and min_stock > 0;
    if c > 0 then
      insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
      values (p_business, 'low_stock', 'warning', jsonb_build_object('count', c), '/app/inventory?filter=low',
              'low_stock:' || today) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;

  -- Selling fast: at the last 14 days' pace, the stock left lasts fewer than `fast` days.
  if not off ? 'fast_selling' then
    select count(*) into c from (
      select pr.id from public.products pr
        join public.stock_movements m on m.product_id = pr.id and m.movement_type = 'sale'
         and m.occurred_at >= now() - interval '14 days'
       where pr.business_id = p_business and pr.status = 'active' and pr.qty_on_hand > 0
       group by pr.id, pr.qty_on_hand
      having pr.qty_on_hand / nullif(-sum(m.quantity) / 14.0, 0) < fast) t;
    if c > 0 then
      insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
      values (p_business, 'fast_selling', 'warning', jsonb_build_object('count', c, 'days', fast), '/app/reports?tab=restock',
              'fast_selling:' || today) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;

  if not off ? 'expiring_soon' then
    select count(*), min(expiry_date) into r from public.stock_batches
     where business_id = p_business and remaining_qty > 0 and expiry_date <= today + st.expiry_alert_days;
    if r.count > 0 then
      insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
      values (p_business, 'expiring_soon', 'warning', jsonb_build_object('count', r.count, 'first_expiry', r.min),
              '/app/inventory?tab=expiry', 'expiring:' || today) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;

  for r in select pu.id, pu.number, pu.due_date, pu.total - pu.credited_total - pu.paid_total as owed, s.name
           from public.purchases pu join public.suppliers s on s.id = pu.supplier_id
           where pu.business_id = p_business and pu.status in ('ordered', 'partially_received', 'received')
             and pu.due_date is not null and pu.due_date <= today + 3
             and pu.total - pu.credited_total - pu.paid_total > 0 loop
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (p_business, case when r.due_date < today then 'supplier_payment_overdue' else 'supplier_payment_due' end,
            case when r.due_date < today then 'critical' else 'warning' end,
            jsonb_build_object('supplier', r.name, 'number', r.number, 'due_date', r.due_date, 'amount', r.owed),
            '/app/purchases/' || r.id, 'purchases.manage',
            'supplier_due:' || r.id || ':' || (r.due_date < today)) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end loop;

  if not off ? 'customer_overdue' then
    select count(*), coalesce(sum(s.total - s.returned_total + s.refunded_total - s.paid_total), 0) into r
      from public.sales s where s.business_id = p_business and s.customer_id is not null
       and s.due_date is not null and s.due_date < today and s.total - s.returned_total + s.refunded_total - s.paid_total > 0;
    if r.count > 0 then
      insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
      values (p_business, 'customer_overdue', 'warning', jsonb_build_object('count', r.count, 'amount', r.coalesce),
              '/app/customers?filter=overdue', 'customers.credit', 'customer_overdue:' || today) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;

  -- Orders waiting: new orders not confirmed after `wait_h` hours, confirmed ones not sent after a day.
  if not off ? 'orders_waiting' then
    select count(*) into c from public.market_orders where business_id = p_business
       and ((status = 'pending' and created_at < now() - make_interval(hours => wait_h))
            or (status in ('confirmed', 'processing') and coalesce(confirmed_at, created_at) < now() - interval '24 hours'));
    if c > 0 then
      insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
      values (p_business, 'orders_waiting', 'warning', jsonb_build_object('count', c), '/app/orders', 'orders.manage',
              'orders_waiting:' || today || ':' || c) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;

  if not off ? 'payment_to_confirm' then
    select count(*) into c from public.market_orders where business_id = p_business and payment_method = 'momo_direct'
       and payment_status = 'cod_pending' and buyer_payment_reported_at is not null
       and status in ('pending', 'confirmed', 'processing', 'dispatched');
    if c > 0 then
      insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
      values (p_business, 'payment_to_confirm', 'warning', jsonb_build_object('count', c), '/app/orders', 'orders.manage',
              'payment_to_confirm:' || today || ':' || c) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;

  -- Unusual stock adjustments: manual corrections or losses worth at least `big` in one movement.
  if not off ? 'large_adjustment' and big > 0 then
    select count(*) into c from public.stock_movements where business_id = p_business
       and movement_type in ('damaged', 'expired', 'missing', 'found', 'correction', 'count')
       and occurred_at >= now() - interval '24 hours' and abs(value) >= big;
    if c > 0 then
      insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
      values (p_business, 'large_adjustment', 'warning', jsonb_build_object('count', c, 'threshold', big),
              '/app/inventory?tab=movements', 'stock.adjust', 'large_adjustment:' || today) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;

  -- Possible duplicates: same total, same customer and same products within 3 minutes today.
  if not off ? 'possible_duplicate_sale' then
    select count(*) into c from public.sales a join public.sales b2 on b2.business_id = a.business_id and b2.id > a.id
       and b2.total = a.total and b2.customer_id is not distinct from a.customer_id
       and abs(extract(epoch from b2.sold_at - a.sold_at)) <= 180
       and b2.cancelled_at is null and a.cancelled_at is null
       and (select array_agg(product_id order by product_id) from public.sale_lines where sale_id = a.id)
           = (select array_agg(product_id order by product_id) from public.sale_lines where sale_id = b2.id)
     where a.business_id = p_business and a.sold_at >= now() - interval '24 hours';
    if c > 0 then
      insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
      values (p_business, 'possible_duplicate_sale', 'warning', jsonb_build_object('count', c), '/app/sales', 'sales.view',
              'dup_sale:' || today || ':' || c) on conflict do nothing;
      get diagnostics added = row_count; n := n + added;
    end if;
  end if;

  sub := app.subscription_info(p_business);
  if sub ->> 'state' in ('renewal_due', 'grace', 'expired') or
     (sub ->> 'state' = 'trial' and (sub ->> 'trial_ends_at')::timestamptz < now() + interval '5 days') then
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (p_business, 'subscription_' || (sub ->> 'state'),
            case when sub ->> 'state' in ('grace', 'expired') then 'critical' else 'warning' end,
            sub, '/app/billing', 'billing.manage',
            'subscription:' || (sub ->> 'state') || ':' || coalesce(sub ->> 'current_period_end', sub ->> 'trial_ends_at', ''))
    on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;
  return n;
end $$;
revoke all on function app.build_alerts(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function public.record_sale(uuid, jsonb), public.cancel_sale(uuid, text, boolean, text, uuid),
  public.sales_by_channel(uuid, date, date), public.store_save_payments(uuid, jsonb), public.save_alert_settings(uuid, jsonb),
  public.market_order_report_payment(uuid, text, text)
  from public, anon;
grant execute on function public.record_sale(uuid, jsonb), public.cancel_sale(uuid, text, boolean, text, uuid),
  public.sales_by_channel(uuid, date, date), public.store_save_payments(uuid, jsonb), public.save_alert_settings(uuid, jsonb)
  to authenticated;
grant execute on function public.market_order_report_payment(uuid, text, text) to anon, authenticated;
revoke all on function app.sales_channel_default() from public, anon, authenticated;
revoke all on function app.stores_no_online_payment() from public, anon, authenticated;
