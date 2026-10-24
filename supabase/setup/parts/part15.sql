-- BizPilot setup PART 15 of 17. Run parts in order.
begin;
create or replace function public.seller_market_summary(p_business uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare tz_start timestamptz := app.range_start(p_business, app.biz_today(p_business));
begin
  if not app.has_perm(p_business, 'orders.manage') then perform app.raise('permission_denied'); end if;
  perform app.market_expire();
  return jsonb_build_object(
    'readiness', public.store_readiness(p_business),
    'to_confirm', (select count(*) from public.market_orders where business_id = p_business and status = 'pending'
                    and (payment_method = 'cod' or payment_status = 'paid')),
    'awaiting_payment', (select count(*) from public.market_orders where business_id = p_business and status = 'pending'
                          and payment_method = 'online' and payment_status in ('awaiting_payment', 'failed')),
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
alter table public.stores enable row level security;
alter table public.store_delivery_zones enable row level security;
alter table public.market_promotions enable row level security;
alter table public.market_orders enable row level security;
alter table public.market_order_lines enable row level security;
alter table public.market_order_events enable row level security;
alter table public.stock_reservations enable row level security;
alter table public.market_reviews enable row level security;
alter table public.market_reports enable row level security;
alter table public.customer_addresses enable row level security;
alter table public.market_favorites enable row level security;
alter table public.market_store_follows enable row level security;
alter table public.market_blocklist enable row level security;
create policy stores_read on public.stores for select using (app.can_read(business_id) or app.is_platform_admin());
create policy zones_read on public.store_delivery_zones for select using (app.can_read(business_id));
create policy promotions_read on public.market_promotions for select using (app.has_perm(business_id, 'store.manage'));
create policy market_orders_read on public.market_orders for select
  using (app.has_perm(business_id, 'orders.manage') or app.is_platform_admin());
create policy market_order_lines_read on public.market_order_lines for select
  using (app.has_perm(business_id, 'orders.manage') or app.is_platform_admin());
create policy market_order_events_read on public.market_order_events for select
  using (app.has_perm(business_id, 'orders.manage') or app.is_platform_admin());
create policy reservations_read on public.stock_reservations for select using (app.can_read(business_id));
create policy reviews_read on public.market_reviews for select using (app.can_read(business_id) or app.is_platform_admin());
create policy reports_read on public.market_reports for select
  using (app.is_platform_admin() or (reporter_user_id is not null and reporter_user_id = auth.uid()));
create policy blocklist_read on public.market_blocklist for select using (app.is_platform_admin());
create policy addresses_own_read on public.customer_addresses for select using (user_id = auth.uid());
create policy addresses_own_insert on public.customer_addresses for insert with check (user_id = auth.uid());
create policy addresses_own_update on public.customer_addresses for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy addresses_own_delete on public.customer_addresses for delete using (user_id = auth.uid());
create policy favorites_own_read on public.market_favorites for select using (user_id = auth.uid());
create policy favorites_own_insert on public.market_favorites for insert with check (user_id = auth.uid() and app.listing_public(product_id));
create policy favorites_own_delete on public.market_favorites for delete using (user_id = auth.uid());
create policy follows_own_read on public.market_store_follows for select using (user_id = auth.uid());
create policy follows_own_insert on public.market_store_follows for insert with check (user_id = auth.uid() and app.store_is_live(business_id));
create policy follows_own_delete on public.market_store_follows for delete using (user_id = auth.uid());
grant select, insert, update, delete on public.customer_addresses to authenticated;
grant select, insert, delete on public.market_favorites, public.market_store_follows to authenticated;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('storefront', 'storefront', true, 5242880, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
create or replace function app.storefront_can_write(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select case (storage.foldername(object_name))[2]
    when 'store' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'store.manage')
    when 'products' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'products.manage')
    else false end
$$;
create policy "storefront insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'storefront' and app.storefront_can_write(name));
create policy "storefront delete" on storage.objects for delete to authenticated
  using (bucket_id = 'storefront' and app.storefront_can_write(name));
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
    when 'orders' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'orders.manage')
    else false end
$$;
create table public.market_ledger (
  id bigserial primary key,
  business_id uuid not null references public.businesses (id) on delete cascade,
  order_id uuid references public.market_orders (id) on delete set null,
  kind text not null check (kind in ('order_payment', 'commission', 'processing_fee', 'refund', 'payout', 'adjustment')),
  amount numeric(14, 2) not null,           -- positive: BizPilot owes the seller; negative: deducted / paid out
  method text,
  reference text check (length(reference) <= 120),
  note text check (length(note) <= 300),
  created_by uuid,
  created_at timestamptz not null default now()
);
create index market_ledger_business on public.market_ledger (business_id, created_at desc);
create table public.online_payments (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('order', 'subscription')),
  business_id uuid not null references public.businesses (id) on delete cascade,
  order_id uuid references public.market_orders (id) on delete set null,
  plan_code text references public.plans (code),
  billing_period text check (billing_period in ('monthly', 'annual')),
  billing_payment_id uuid references public.billing_payments (id),
  amount numeric(14, 0) not null check (amount >= 100),
  currency text not null default 'XAF',
  provider text not null default 'fapshi',
  trans_id text unique check (trans_id ~ '^[A-Za-z0-9_-]{4,64}$'),
  link text,
  status text not null default 'created' check (status in ('created', 'pending', 'successful', 'failed', 'expired', 'error')),
  provider_status text,
  medium text,
  payer_name text,
  financial_trans_id text,
  revenue numeric(14, 0),
  amount_received numeric(14, 0),
  mismatch boolean not null default false,
  needs_refund boolean not null default false,
  refunded_at timestamptz,
  refund_reference text,
  resolution_note text,
  check_count int not null default 0,
  last_checked_at timestamptz,
  verified_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index online_payments_order on public.online_payments (order_id);
create index online_payments_business on public.online_payments (business_id, created_at desc);
create index online_payments_attention on public.online_payments (created_at) where mismatch or needs_refund;
create trigger online_payments_touch before update on public.online_payments for each row execute function app.touch_updated_at();
alter table public.billing_payments drop constraint if exists billing_payments_method_check;
alter table public.billing_payments add constraint billing_payments_method_check
  check (method in ('mtn_momo', 'orange_money', 'bank_transfer', 'cash', 'other', 'fapshi'));
create or replace function app.online_payments_on() returns boolean
language sql stable as $$ select coalesce((app.market_config() ->> 'online_payments_enabled')::boolean, false) $$;
create or replace function app.market_try_reopen(p_order uuid, p_expires timestamptz) returns boolean
language plpgsql security definer set search_path = public as $$
declare o public.market_orders; l record;
begin
  select * into o from public.market_orders where id = p_order;
  perform 1 from public.products where id in (select product_id from public.market_order_lines where order_id = o.id) order by id for update;
  for l in select product_id, sum(quantity) q from public.market_order_lines where order_id = o.id group by product_id loop
    if (select qty_on_hand from public.products where id = l.product_id) - app.reserved_qty(l.product_id) < l.q then
      return false;
    end if;
  end loop;
  insert into public.stock_reservations (business_id, product_id, order_id, quantity, expires_at)
  select o.business_id, product_id, o.id, quantity, p_expires from public.market_order_lines where order_id = o.id;
  if o.promo_id is not null then
    update public.market_promotions set used_count = used_count + 1 where id = o.promo_id;
  end if;
  update public.market_orders set status = 'pending', cancelled_at = null, cancelled_by = null, cancel_reason = null,
         expires_at = p_expires where id = o.id;
  return true;
end $$;
create or replace function public.market_payment_begin(p_order uuid, p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.market_orders; exp timestamptz; pid uuid; prev jsonb;
begin
  if not app.online_payments_on() then perform app.raise('online_payments_not_available'); end if;
  o := app.order_for_customer(p_order, p_token, true);
  perform app.rate_limit('pay_begin:' || o.id, 10, 3600);
  if o.payment_method <> 'online' then perform app.raise('invalid_payment_method'); end if;
  if o.payment_status = 'paid' then perform app.raise('already_paid'); end if;
  if o.total <> round(o.total) or o.total < 100 then perform app.raise('online_minimum_amount', jsonb_build_object('min', 100)); end if;
  exp := now() + make_interval(mins => coalesce((app.market_config() ->> 'unpaid_order_minutes')::int, 30));
  if o.status = 'cancelled' and o.cancel_reason = 'payment_not_completed' and o.cancelled_at > now() - interval '12 hours' then
    if not app.market_try_reopen(o.id, exp) then perform app.raise('insufficient_stock'); end if;
    update public.market_orders set payment_status = 'awaiting_payment' where id = o.id;
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
    values (o.id, o.business_id, 'status', 'pending', 'reopened_for_payment', 'customer', auth.uid());
  elsif o.status <> 'pending' then
    perform app.raise('order_not_payable');
  else
    update public.market_orders set expires_at = exp, payment_status = 'awaiting_payment' where id = o.id;
    update public.stock_reservations set expires_at = exp where order_id = o.id and released_at is null and consumed_at is null;
  end if;
  select coalesce(jsonb_agg(trans_id), '[]'::jsonb) into prev from public.online_payments
   where order_id = o.id and status in ('created', 'pending') and trans_id is not null;
  insert into public.online_payments (kind, business_id, order_id, amount, created_by)
  values ('order', o.business_id, o.id, o.total, auth.uid()) returning id into pid;
  return jsonb_build_object('payment_id', pid, 'amount', o.total, 'email', o.customer_email,
    'user_id', replace(coalesce(o.customer_user_id, o.id)::text, '-', ''), 'message', 'BizPilot ' || o.number,
    'previous', prev, 'return_path', '/pay/return?p=' || pid);
end $$;
create or replace function public.billing_fapshi_begin(p_business uuid, p_plan text, p_period text default 'monthly') returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl public.plans; amt numeric; pid uuid;
begin
  perform app.require_perm(p_business, 'billing.manage');
  if not app.online_payments_on() then perform app.raise('online_payments_not_available'); end if;
  perform app.rate_limit('billing_pay:' || p_business, 10, 86400);
  select * into pl from public.plans where code = p_plan and active and price_monthly > 0;
  if not found then perform app.raise('invalid_plan'); end if;
  if p_period not in ('monthly', 'annual') then perform app.raise('invalid_billing_period'); end if;
  amt := case when p_period = 'annual' then coalesce(pl.price_annual, pl.price_monthly * 12) else pl.price_monthly end;
  insert into public.online_payments (kind, business_id, plan_code, billing_period, amount, created_by)
  values ('subscription', p_business, pl.code, p_period, amt, auth.uid()) returning id into pid;
  perform app.audit(p_business, 'billing.online_payment_started', 'online_payment', pid::text,
                    jsonb_build_object('plan', pl.code, 'period', p_period, 'amount', amt));
  return jsonb_build_object('payment_id', pid, 'amount', amt, 'email', (select email from auth.users where id = auth.uid()),
    'user_id', replace(p_business::text, '-', ''), 'message', 'BizPilot ' || pl.name_en || ' (' || p_period || ')',
    'previous', '[]'::jsonb, 'return_path', '/pay/return?p=' || pid);
end $$;
create or replace function public.fapshi_attach(p_payment uuid, p_trans_id text, p_link text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.online_payments set trans_id = p_trans_id, link = left(p_link, 500)
   where id = p_payment and trans_id is null;
  if not found then perform app.raise('not_found'); end if;
end $$;
create or replace function public.fapshi_payment_lookup(p_payment uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pay public.online_payments;
begin
  select * into pay from public.online_payments where id = p_payment for update;
  if not found then return null; end if;
  if pay.last_checked_at > now() - interval '10 seconds' then
    return jsonb_build_object('id', pay.id, 'trans_id', pay.trans_id, 'status', pay.status, 'kind', pay.kind,
                              'order_id', pay.order_id, 'throttled', true);
  end if;
  update public.online_payments set last_checked_at = now(), check_count = check_count + 1 where id = pay.id;
  return jsonb_build_object('id', pay.id, 'trans_id', pay.trans_id, 'status', pay.status, 'kind', pay.kind,
                            'order_id', pay.order_id, 'throttled', false);
end $$;
create or replace function app.activate_fapshi_subscription(p_payment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare pay public.online_payments; bp uuid; s public.business_subscriptions; start_at timestamptz; end_at timestamptz;
begin
  select * into pay from public.online_payments where id = p_payment;
  if pay.billing_payment_id is not null then return; end if;
  insert into public.billing_payments (business_id, plan_code, billing_period, amount, expected_amount, method, transaction_ref,
    payer_name, note, status, submitted_by, submitted_at, reviewed_at, review_note)
  values (pay.business_id, pay.plan_code, pay.billing_period, coalesce(pay.amount_received, pay.amount), pay.amount, 'fapshi',
    pay.trans_id, pay.payer_name, 'Fapshi ' || coalesce(pay.medium, ''), 'pending', pay.created_by, pay.created_at, null, null)
  returning id into bp;
  select * into s from public.business_subscriptions where business_id = pay.business_id for update;
  start_at := case when s.status in ('active', 'cancelled') and s.plan_code = pay.plan_code
                        and s.current_period_end > now() then s.current_period_end else now() end;
  end_at := start_at + case when pay.billing_period = 'annual' then interval '1 year' else interval '1 month' end;
  insert into public.business_subscriptions (business_id, plan_code, status, billing_period, current_period_start,
                                             current_period_end, cancel_at_period_end)
  values (pay.business_id, pay.plan_code, 'active', pay.billing_period, start_at, end_at, false)
  on conflict (business_id) do update set plan_code = excluded.plan_code, status = 'active',
    billing_period = excluded.billing_period, current_period_start = excluded.current_period_start,
    current_period_end = excluded.current_period_end, cancel_at_period_end = false, suspended_reason = null;
  update public.billing_payments set status = 'verified', reviewed_at = now(), review_note = 'Verified with Fapshi',
         period_start = start_at, period_end = end_at where id = bp;
  update public.online_payments set billing_payment_id = bp where id = pay.id;
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (pay.business_id, 'billing_payment_verified', 'success',
          jsonb_build_object('plan', pay.plan_code, 'period_end', end_at), '/app/billing', 'billing.manage');
  insert into public.audit_logs (business_id, user_id, action, entity, entity_id, details)
  values (pay.business_id, null, 'billing.payment_verified', 'billing_payment', bp::text,
          jsonb_build_object('provider', 'fapshi', 'trans_id', pay.trans_id, 'amount', pay.amount_received));
end $$;
create or replace function public.fapshi_apply(p_trans_id text, p_tx jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pay public.online_payments; o public.market_orders; st text := upper(coalesce(p_tx ->> 'status', ''));
  amt numeric := nullif(p_tx ->> 'amount', '')::numeric; ext text := nullif(p_tx ->> 'externalId', ''); mism boolean;
begin
  select * into pay from public.online_payments where trans_id = p_trans_id for update;
  if not found then return jsonb_build_object('ignored', 'unknown_transaction'); end if;
  if st not in ('CREATED', 'PENDING', 'SUCCESSFUL', 'FAILED', 'EXPIRED') then
    return jsonb_build_object('ignored', 'unknown_status', 'payment_id', pay.id);
  end if;
  update public.online_payments set provider_status = st, last_checked_at = now(),
         medium = coalesce(nullif(p_tx ->> 'medium', ''), medium), payer_name = coalesce(nullif(left(p_tx ->> 'payerName', 120), ''), payer_name),
         financial_trans_id = coalesce(nullif(left(p_tx ->> 'financialTransId', 120), ''), financial_trans_id),
         revenue = coalesce(nullif(p_tx ->> 'revenue', '')::numeric, revenue)
   where id = pay.id;
  if pay.status = 'successful' then
    return jsonb_build_object('payment_id', pay.id, 'status', 'successful', 'kind', pay.kind, 'order_id', pay.order_id, 'duplicate', true);
  end if;
  if st in ('CREATED', 'PENDING') then
    update public.online_payments set status = lower(st) where id = pay.id;
    return jsonb_build_object('payment_id', pay.id, 'status', lower(st), 'kind', pay.kind, 'order_id', pay.order_id);
  end if;
  if st in ('FAILED', 'EXPIRED') then
    update public.online_payments set status = lower(st) where id = pay.id;
    if pay.kind = 'order' and pay.status not in ('failed', 'expired') then
      update public.market_orders set payment_status = 'failed'
       where id = pay.order_id and payment_status = 'awaiting_payment'
         and not exists (select 1 from public.online_payments x where x.order_id = pay.order_id and x.id <> pay.id
                         and x.status in ('created', 'pending'));
      if found then
        insert into public.market_order_events (order_id, business_id, kind, status, message, actor)
        values (pay.order_id, pay.business_id, 'payment', 'failed', lower(st), 'system');
      end if;
    end if;
    return jsonb_build_object('payment_id', pay.id, 'status', lower(st), 'kind', pay.kind, 'order_id', pay.order_id);
  end if;
  mism := amt is distinct from pay.amount or (ext is not null and ext <> pay.id::text);
  update public.online_payments set status = 'successful', verified_at = now(), amount_received = amt, mismatch = mism where id = pay.id;
  if pay.kind = 'subscription' then
    if not mism then perform app.activate_fapshi_subscription(pay.id); end if;
    return jsonb_build_object('payment_id', pay.id, 'status', 'successful', 'kind', 'subscription', 'mismatch', mism);
  end if;
  select * into o from public.market_orders where id = pay.order_id for update;
  if mism then
    update public.market_orders set flagged = true, flag_reason = 'payment_amount_mismatch' where id = o.id;
    insert into public.market_order_events (order_id, business_id, kind, message, actor, visible_to_customer)
    values (o.id, o.business_id, 'payment', 'amount_mismatch', 'system', false);
  elsif o.payment_status in ('paid', 'refund_pending', 'refunded') then
    update public.online_payments set needs_refund = true where id = pay.id;
    update public.market_orders set flagged = true, flag_reason = 'duplicate_payment' where id = o.id;
  elsif o.status = 'pending' then
    update public.market_orders set payment_status = 'paid', expires_at = null where id = o.id;
    update public.stock_reservations set expires_at = null where order_id = o.id and released_at is null and consumed_at is null;
  elsif o.status = 'cancelled' and o.cancel_reason = 'payment_not_completed' and app.market_try_reopen(o.id, null) then
    update public.market_orders set payment_status = 'paid', expires_at = null where id = o.id;
  else
    update public.online_payments set needs_refund = true where id = pay.id;
    update public.market_orders set payment_status = 'refund_pending', flagged = true, flag_reason = 'paid_after_cancellation'
     where id = o.id;
  end if;
  select * into o from public.market_orders where id = pay.order_id;
  if not mism then
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor)
    values (o.id, o.business_id, 'payment', o.payment_status, 'online_payment_verified', 'system');
  end if;
  if o.payment_status = 'paid' and o.status = 'pending' then
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (o.business_id, 'market_order_paid', 'success',
            jsonb_build_object('number', o.number, 'amount', o.total, 'customer', o.customer_name), '/app/orders/' || o.id, 'orders.manage');
  end if;
  return jsonb_build_object('payment_id', pay.id, 'status', 'successful', 'kind', 'order', 'order_id', o.id,
                            'order_payment_status', o.payment_status, 'mismatch', mism);
end $$;
create or replace function public.online_payment_status(p_payment uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', p.id, 'kind', p.kind, 'status', p.status, 'order_id', p.order_id, 'amount', p.amount,
                            'order_payment_status', o.payment_status, 'order_status', o.status)
    from public.online_payments p left join public.market_orders o on o.id = p.order_id where p.id = p_payment
$$;
create or replace function public.seller_payments_summary(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare since timestamptz := now() - interval '30 days';
begin
  perform app.require_perm(p_business, 'cash.manage');
  return jsonb_build_object(
    'balance', (select coalesce(sum(amount), 0) from public.market_ledger where business_id = p_business),
    'held_undelivered', (select coalesce(sum(total), 0) from public.market_orders where business_id = p_business
                          and payment_method = 'online' and payment_status = 'paid' and status in ('pending', 'confirmed', 'processing', 'dispatched')),
    'paid_out_total', (select coalesce(-sum(amount), 0) from public.market_ledger where business_id = p_business and kind = 'payout'),
    'online_delivered_30d', (select coalesce(sum(total), 0) from public.market_orders where business_id = p_business
                              and payment_method = 'online' and status in ('delivered', 'refunded') and delivered_at >= since),
    'cod_collected_30d', (select coalesce(sum(cod_collected_amount), 0) from public.market_orders where business_id = p_business
                           and cod_collected_at >= since),
    'delivery_fees_30d', (select coalesce(sum(delivery_fee), 0) from public.market_orders where business_id = p_business
                           and status = 'delivered' and delivered_at >= since),
    'commission_30d', (select coalesce(-sum(amount), 0) from public.market_ledger where business_id = p_business
                        and kind in ('commission', 'processing_fee') and created_at >= since),
    'refund_pending', (select count(*) from public.market_orders where business_id = p_business and payment_status = 'refund_pending'),
    'config', public.market_config_public());
end $$;
commit;
