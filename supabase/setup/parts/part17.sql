-- BizPilot setup PART 17 of 26. Run parts in order.
begin;
alter table public.market_ledger enable row level security;
alter table public.online_payments enable row level security;
create policy market_ledger_read on public.market_ledger for select
  using (app.has_perm(business_id, 'cash.manage') or app.is_platform_admin());
create policy online_payments_read on public.online_payments for select
  using ((kind = 'order' and (app.has_perm(business_id, 'orders.manage') or app.has_perm(business_id, 'cash.manage')))
         or (kind = 'subscription' and app.has_perm(business_id, 'billing.manage'))
         or app.is_platform_admin());
revoke all on public.stores, public.store_delivery_zones, public.market_promotions, public.market_orders,
  public.market_order_lines, public.market_order_events, public.stock_reservations, public.market_reviews,
  public.market_reports, public.customer_addresses, public.market_favorites, public.market_store_follows,
  public.market_blocklist, public.market_ledger, public.online_payments from anon;
revoke insert, update, delete, truncate, references, trigger on public.stores, public.store_delivery_zones,
  public.market_promotions, public.market_orders, public.market_order_lines, public.market_order_events,
  public.stock_reservations, public.market_reviews, public.market_reports, public.market_blocklist,
  public.market_ledger, public.online_payments from authenticated;
grant select on public.stores, public.store_delivery_zones, public.market_promotions, public.market_orders,
  public.market_order_lines, public.market_order_events, public.stock_reservations, public.market_reviews,
  public.market_reports, public.market_blocklist, public.market_ledger, public.online_payments to authenticated;
revoke execute on function app.market_cancel(uuid, text, text) from public, anon, authenticated;
revoke execute on function app.market_expire() from public, anon, authenticated;
revoke execute on function app.market_order_to_sale(uuid, text, text) from public, anon, authenticated;
revoke execute on function app.market_try_reopen(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function app.activate_fapshi_subscription(uuid) from public, anon, authenticated;
revoke execute on function app.refresh_store_rating(uuid) from public, anon, authenticated;
revoke execute on function app.admin_audit(text, text, text, uuid, jsonb) from public, anon, authenticated;
revoke execute on function app.order_for_customer(uuid, text, boolean) from public, anon, authenticated;
grant execute on function app.listing_public(uuid), app.listing_of(uuid), app.store_is_live(uuid), app.reserved_qty(uuid, uuid),
  app.listing_within_limit(uuid, timestamptz, uuid), app.market_config(), app.norm_phone(text), app.products_market_guard(),
  app.customer_addresses_guard(), app.storefront_can_write(text), app.storage_can_write(text), app.usage_count(uuid, text)
  to anon, authenticated;
revoke execute on function public.market_config_public(), public.market_search(jsonb), public.market_home(text),
  public.market_store(text), public.market_product(uuid), public.market_products_by_ids(uuid[]), public.market_store_cards(uuid[]),
  public.market_quote(jsonb), public.market_place_order(jsonb), public.market_order_view(uuid, text),
  public.market_order_customer_action(uuid, text, text, text), public.market_submit_review(uuid, text, uuid, int, text),
  public.market_report(jsonb), public.market_payment_begin(uuid, text), public.online_payment_status(uuid),
  public.store_slug_available(text, uuid) from public;
grant execute on function public.market_config_public(), public.market_search(jsonb), public.market_home(text),
  public.market_store(text), public.market_product(uuid), public.market_products_by_ids(uuid[]), public.market_store_cards(uuid[]),
  public.market_quote(jsonb), public.market_place_order(jsonb), public.market_order_view(uuid, text),
  public.market_order_customer_action(uuid, text, text, text), public.market_submit_review(uuid, text, uuid, int, text),
  public.market_report(jsonb), public.market_payment_begin(uuid, text), public.online_payment_status(uuid),
  public.store_slug_available(text, uuid) to anon, authenticated;
revoke execute on function public.market_my_orders(int, int), public.market_claim_orders(jsonb),
  public.store_save(uuid, jsonb), public.store_save_zones(uuid, jsonb), public.store_readiness(uuid),
  public.store_set_published(uuid, boolean), public.store_request_verification(uuid, text),
  public.products_set_online(uuid, uuid[], boolean), public.promo_save(uuid, jsonb), public.market_review_reply(uuid, text),
  public.market_order_action(uuid, text, jsonb), public.seller_market_summary(uuid), public.seller_payments_summary(uuid),
  public.billing_fapshi_begin(uuid, text, text), public.admin_set_config(text, jsonb), public.admin_market_overview(),
  public.admin_market_stores(text, text), public.admin_market_store_update(uuid, jsonb),
  public.admin_market_listings(text, boolean, int, int), public.admin_market_hide_product(uuid, boolean, text),
  public.admin_market_reports(text), public.admin_market_report_update(uuid, text, text),
  public.admin_market_orders(text, text, int, int), public.admin_market_order(uuid),
  public.admin_market_order_action(uuid, text, jsonb), public.admin_market_payments(text),
  public.admin_market_payment_resolve(uuid, text, text, text), public.admin_market_balances(), public.admin_market_ledger(uuid),
  public.admin_market_record_payout(uuid, numeric, text, text, text, text), public.admin_market_block(text, text, text),
  public.admin_market_unblock(uuid), public.admin_market_hide_review(uuid, boolean, text), public.admin_market_reviews(text)
  from public, anon;
grant execute on function public.market_my_orders(int, int), public.market_claim_orders(jsonb),
  public.store_save(uuid, jsonb), public.store_save_zones(uuid, jsonb), public.store_readiness(uuid),
  public.store_set_published(uuid, boolean), public.store_request_verification(uuid, text),
  public.products_set_online(uuid, uuid[], boolean), public.promo_save(uuid, jsonb), public.market_review_reply(uuid, text),
  public.market_order_action(uuid, text, jsonb), public.seller_market_summary(uuid), public.seller_payments_summary(uuid),
  public.billing_fapshi_begin(uuid, text, text), public.admin_set_config(text, jsonb), public.admin_market_overview(),
  public.admin_market_stores(text, text), public.admin_market_store_update(uuid, jsonb),
  public.admin_market_listings(text, boolean, int, int), public.admin_market_hide_product(uuid, boolean, text),
  public.admin_market_reports(text), public.admin_market_report_update(uuid, text, text),
  public.admin_market_orders(text, text, int, int), public.admin_market_order(uuid),
  public.admin_market_order_action(uuid, text, jsonb), public.admin_market_payments(text),
  public.admin_market_payment_resolve(uuid, text, text, text), public.admin_market_balances(), public.admin_market_ledger(uuid),
  public.admin_market_record_payout(uuid, numeric, text, text, text, text), public.admin_market_block(text, text, text),
  public.admin_market_unblock(uuid), public.admin_market_hide_review(uuid, boolean, text), public.admin_market_reviews(text)
  to authenticated;
revoke execute on function public.fapshi_attach(uuid, text, text), public.fapshi_payment_lookup(uuid),
  public.fapshi_apply(text, jsonb) from public, anon, authenticated;
grant execute on function public.fapshi_attach(uuid, text, text), public.fapshi_payment_lookup(uuid),
  public.fapshi_apply(text, jsonb) to service_role;
alter table public.sales
  add column if not exists channel text not null default 'in_person',
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancel_reason text check (length(cancel_reason) <= 300);
alter table public.sales drop constraint if exists sales_channel_check;
alter table public.sales add constraint sales_channel_check
  check (channel in ('in_person', 'whatsapp', 'facebook', 'instagram', 'tiktok', 'phone', 'marketplace', 'other'));
create index if not exists sales_business_channel on public.sales (business_id, channel, sold_at);
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
alter table public.products
  add column if not exists condition text,
  add column if not exists single_item boolean not null default false;
alter table public.products drop constraint if exists products_condition_check;
alter table public.products add constraint products_condition_check
  check (condition is null or condition in ('new', 'like_new', 'used_good', 'used_fair', 'refurbished', 'for_parts'));
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
  if pay is null or pay not in ('cod', 'momo_direct') then perform app.raise('invalid_payment_method'); end if;
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
commit;
