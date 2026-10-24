-- BizPilot upgrade: check_before_05b 20261025000200_marketplace_payments_admin 
-- Paste into Supabase Dashboard -> SQL Editor -> New query, then Run. Run it ONCE.
-- Adds features only: existing businesses, products, sales and users are not changed.
begin;

-- ===== check_before_05b.sql =====
do $$
begin
  if to_regclass('public.stores') is null then raise exception 'Run 05a_upgrade_marketplace_part1.sql first.'; end if;
  if to_regclass('public.market_ledger') is not null then raise exception 'This part is already installed. Nothing to do.'; end if;
end $$;

-- ===== 20261025000200_marketplace_payments_admin.sql =====
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
create or replace function public.admin_set_config(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if p_key not in ('trial', 'grace_days', 'renewal_notice_days', 'payment_instructions', 'support_contact', 'ai', 'marketplace') then
    perform app.raise('invalid_config_key');
  end if;
  if p_key = 'marketplace' then
    if jsonb_typeof(p_value) <> 'object'
       or coalesce((p_value ->> 'commission_pct')::numeric, 0) not between 0 and 50
       or coalesce((p_value ->> 'online_fee_pct')::numeric, 0) not between 0 and 20
       or coalesce((p_value ->> 'unpaid_order_minutes')::int, 30) not between 10 and 1440
       or coalesce((p_value ->> 'confirm_hours')::int, 48) not between 1 and 240
       or coalesce((p_value ->> 'max_open_cod_per_phone')::int, 3) not between 1 and 50 then
      perform app.raise('invalid_config_value');
    end if;
    insert into public.app_config (key, value, is_public) values ('marketplace', p_value, true)
    on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  else
    update public.app_config set value = p_value, updated_at = now(), updated_by = auth.uid() where key = p_key;
  end if;
  insert into public.audit_logs (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'admin.config_changed', 'config', p_key, p_value);
end $$;
create or replace function app.admin_audit(act text, ent text, ent_id text, bid uuid, det jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.audit_logs (business_id, user_id, action, entity, entity_id, details) values (bid, auth.uid(), act, ent, ent_id, det)
$$;
create or replace function public.admin_market_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return jsonb_build_object(
    'stores_published', (select count(*) from public.stores where status = 'published'),
    'stores_total', (select count(*) from public.stores),
    'stores_pending_verification', (select count(*) from public.stores where verification = 'pending'),
    'stores_suspended', (select count(*) from public.stores where status = 'suspended'),
    'listings', (select count(*) from public.products where online_published and status = 'active' and variant_of is null),
    'listings_hidden', (select count(*) from public.products where admin_hidden),
    'orders_30d', (select count(*) from public.market_orders where created_at > now() - interval '30 days'),
    'gmv_30d', (select coalesce(sum(total), 0) from public.market_orders where status = 'delivered' and delivered_at > now() - interval '30 days'),
    'open_reports', (select count(*) from public.market_reports where status in ('open', 'reviewing') and kind = 'report'),
    'open_disputes', (select count(*) from public.market_reports where status in ('open', 'reviewing') and kind = 'dispute'),
    'refund_pending', (select count(*) from public.market_orders where payment_status = 'refund_pending'),
    'flagged_orders', (select count(*) from public.market_orders where flagged),
    'payment_issues', (select count(*) from public.online_payments where (mismatch or needs_refund) and refunded_at is null and resolution_note is null),
    'owed_to_sellers', (select coalesce(sum(b), 0) from (select sum(amount) b from public.market_ledger group by business_id) t where b > 0),
    'owed_by_sellers', (select coalesce(-sum(b), 0) from (select sum(amount) b from public.market_ledger group by business_id) t where b < 0));
end $$;
create or replace function public.admin_market_stores(p_search text default null, p_status text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select s.business_id, s.slug, s.name, s.city, s.status, s.verification, s.verification_note, s.suspended_reason,
           s.rating_avg, s.rating_count, s.published_at, s.created_at, b.name business_name, b.status business_status,
           (select u.email from public.business_members m join auth.users u on u.id = m.user_id
             where m.business_id = b.id and m.role = 'owner' and m.active) owner_email,
           (select count(*) from public.products p where p.business_id = s.business_id and p.online_published and p.variant_of is null) listings,
           (select count(*) from public.market_orders o where o.business_id = s.business_id and o.created_at > now() - interval '30 days') orders_30d,
           (select count(*) from public.market_reports r where r.business_id = s.business_id and r.status in ('open', 'reviewing')) open_reports,
           (select coalesce(sum(amount), 0) from public.market_ledger l where l.business_id = s.business_id) balance
      from public.stores s join public.businesses b on b.id = s.business_id
     where (p_status is null or s.status = p_status or (p_status = 'pending_verification' and s.verification = 'pending'))
       and (p_search is null or s.name ilike app.like_term(p_search) or s.slug ilike app.like_term(p_search) or b.name ilike app.like_term(p_search))
     order by (s.verification = 'pending') desc, s.created_at desc limit 200) t), '[]'::jsonb);
end $$;
create or replace function public.admin_market_store_update(p_business uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare s public.stores; reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  perform app.require_platform_admin();
  select * into s from public.stores where business_id = p_business for update;
  if not found then perform app.raise('not_found'); end if;
  if p ? 'status' then
    if p ->> 'status' not in ('draft', 'published', 'suspended') then perform app.raise('invalid_request'); end if;
    if p ->> 'status' = 'suspended' and reason is null then perform app.raise('reason_required'); end if;
    update public.stores set status = p ->> 'status',
           suspended_reason = case when p ->> 'status' = 'suspended' then reason end,
           published_at = case when p ->> 'status' = 'published' then coalesce(published_at, now()) else published_at end
     where business_id = p_business;
  end if;
  if p ? 'verification' then
    if p ->> 'verification' not in ('unverified', 'pending', 'verified', 'rejected') then perform app.raise('invalid_request'); end if;
    if p ->> 'verification' = 'rejected' and reason is null then perform app.raise('reason_required'); end if;
    update public.stores set verification = p ->> 'verification', verification_note = coalesce(reason, verification_note)
     where business_id = p_business;
  end if;
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (p_business, 'market_store_status', case when p ->> 'status' = 'suspended' or p ->> 'verification' = 'rejected' then 'critical' else 'info' end,
          jsonb_build_object('status', coalesce(p ->> 'status', s.status), 'verification', coalesce(p ->> 'verification', s.verification),
                             'reason', reason), '/app/store', 'store.manage');
  perform app.admin_audit('admin.store_updated', 'store', p_business::text, p_business, p);
end $$;
create or replace function public.admin_market_listings(p_search text default null, p_hidden_only boolean default false,
  p_limit int default 100, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select p.id, p.name, p.brand, p.selling_price, p.online_images[1] image, p.admin_hidden, p.admin_hidden_reason, p.online_since,
           s.name store_name, s.slug store_slug, s.business_id,
           (select count(*) from public.market_reports r where r.target_type = 'product' and r.target_id = p.id and r.status in ('open', 'reviewing')) open_reports
      from public.products p join public.stores s on s.business_id = p.business_id
     where p.variant_of is null and (p.online_published or p.admin_hidden)
       and (not p_hidden_only or p.admin_hidden)
       and (p_search is null or p.name ilike app.like_term(p_search) or s.name ilike app.like_term(p_search))
     order by p.online_since desc nulls last limit least(p_limit, 200) offset greatest(p_offset, 0)) t), '[]'::jsonb);
end $$;
create or replace function public.admin_market_hide_product(p_product uuid, p_hidden boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare pr public.products;
begin
  perform app.require_platform_admin();
  if p_hidden and coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  update public.products set admin_hidden = p_hidden, admin_hidden_reason = case when p_hidden then btrim(p_reason) end
   where id = p_product returning * into pr;
  if not found then perform app.raise('not_found'); end if;
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (pr.business_id, case when p_hidden then 'market_listing_hidden' else 'market_listing_restored' end,
          case when p_hidden then 'critical' else 'info' end,
          jsonb_build_object('product', pr.name, 'reason', p_reason), '/app/products/' || pr.id, 'products.manage');
  perform app.admin_audit(case when p_hidden then 'admin.listing_hidden' else 'admin.listing_restored' end, 'product', p_product::text,
                          pr.business_id, jsonb_build_object('name', pr.name, 'reason', p_reason));
end $$;
create or replace function public.admin_market_reports(p_status text default 'open') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select r.*, s.name store_name, s.slug store_slug,
           case r.target_type when 'product' then (select name from public.products where id = r.target_id)
                              when 'store' then s.name
                              when 'order' then (select number from public.market_orders where id = r.target_id) end target_name,
           (select email from auth.users where id = r.reporter_user_id) reporter_email
      from public.market_reports r left join public.stores s on s.business_id = r.business_id
     where p_status is null or r.status = p_status or (p_status = 'open' and r.status = 'reviewing')
     order by r.created_at desc limit 200) t), '[]'::jsonb);
end $$;
create or replace function public.admin_market_report_update(p_report uuid, p_status text, p_resolution text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.market_reports;
begin
  perform app.require_platform_admin();
  if p_status not in ('open', 'reviewing', 'resolved', 'dismissed') then perform app.raise('invalid_request'); end if;
  update public.market_reports set status = p_status, resolution = coalesce(nullif(btrim(coalesce(p_resolution, '')), ''), resolution),
         handled_by = auth.uid(), handled_at = now() where id = p_report returning * into r;
  if not found then perform app.raise('not_found'); end if;
  if r.kind = 'dispute' and r.order_id is not null and p_status in ('resolved', 'dismissed') then
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
    values (r.order_id, r.business_id, 'dispute', p_status, r.resolution, 'admin', auth.uid());
  end if;
  perform app.admin_audit('admin.report_' || p_status, 'market_report', p_report::text, r.business_id,
                          jsonb_build_object('resolution', p_resolution));
end $$;
create or replace function public.admin_market_orders(p_filter text default 'attention', p_search text default null,
  p_limit int default 100, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select o.id, o.number, o.status, o.payment_method, o.payment_status, o.total, o.created_at, o.customer_name, o.customer_phone,
           o.flagged, o.flag_reason, s.name store_name, s.slug store_slug, o.business_id,
           exists (select 1 from public.market_reports r where r.order_id = o.id and r.status in ('open', 'reviewing')) open_dispute
      from public.market_orders o join public.stores s on s.business_id = o.business_id
     where (p_filter = 'all'
            or (p_filter = 'attention' and (o.flagged or o.payment_status = 'refund_pending'
                 or exists (select 1 from public.market_reports r where r.order_id = o.id and r.status in ('open', 'reviewing'))))
            or (p_filter = 'online' and o.payment_method = 'online')
            or (p_filter = 'refund_pending' and o.payment_status = 'refund_pending'))
       and (p_search is null or o.number ilike app.like_term(p_search) or o.customer_phone ilike app.like_term(p_search)
            or o.customer_name ilike app.like_term(p_search) or s.name ilike app.like_term(p_search))
     order by o.created_at desc limit least(p_limit, 200) offset greatest(p_offset, 0)) t), '[]'::jsonb);
end $$;
create or replace function public.admin_market_order(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.market_orders;
begin
  perform app.require_platform_admin();
  select * into o from public.market_orders where id = p_order;
  if not found then perform app.raise('not_found'); end if;
  return to_jsonb(o) - 'access_token_hash' || jsonb_build_object(
    'store', app.store_card(o.business_id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) order by l.sort), '[]'::jsonb) from public.market_order_lines l where l.order_id = o.id),
    'events', (select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at, e.id), '[]'::jsonb) from public.market_order_events e where e.order_id = o.id),
    'payments', (select coalesce(jsonb_agg(to_jsonb(p) - 'link' order by p.created_at), '[]'::jsonb) from public.online_payments p where p.order_id = o.id),
    'reports', (select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at), '[]'::jsonb) from public.market_reports r where r.order_id = o.id));
end $$;
create or replace function public.admin_market_order_action(p_order uuid, p_action text, p jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare o public.market_orders; msg text := nullif(left(btrim(coalesce(p ->> 'message', '')), 1000), '');
        ref text := nullif(left(btrim(coalesce(p ->> 'reference', '')), 120), '');
begin
  perform app.require_platform_admin();
  select * into o from public.market_orders where id = p_order for update;
  if not found then perform app.raise('not_found'); end if;
  if p_action = 'note' then
    if msg is null then perform app.raise('message_required'); end if;
    insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user, visible_to_customer)
    values (o.id, o.business_id, 'message', msg, 'admin', auth.uid(), coalesce((p ->> 'visible')::boolean, true));
  elsif p_action = 'cancel' then
    if msg is null then perform app.raise('reason_required'); end if;
    perform app.market_cancel(o.id, 'admin', msg);
  elsif p_action = 'refund_done' then
    if o.payment_status <> 'refund_pending' then perform app.raise('invalid_order_status'); end if;
    if ref is null then perform app.raise('reference_required'); end if;
    update public.market_orders set payment_status = 'refunded', refunded_at = now(), refund_reference = ref,
           refund_amount = coalesce(refund_amount, total), flagged = false, flag_reason = null where id = o.id;
    update public.online_payments set needs_refund = false, refunded_at = now(), refund_reference = ref
     where order_id = o.id and status = 'successful' and refunded_at is null and (needs_refund or not mismatch);
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
    values (o.id, o.business_id, 'payment', 'refunded', 'refund_sent', 'admin', auth.uid());
  elsif p_action = 'clear_flag' then
    update public.market_orders set flagged = false, flag_reason = null where id = o.id;
  else
    perform app.raise('invalid_action');
  end if;
  perform app.admin_audit('admin.order_' || p_action, 'market_order', o.id::text, o.business_id,
                          jsonb_build_object('number', o.number, 'message', msg, 'reference', ref));
end $$;
create or replace function public.admin_market_payments(p_filter text default 'attention') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select p.id, p.kind, p.status, p.amount, p.amount_received, p.trans_id, p.medium, p.payer_name, p.mismatch, p.needs_refund,
           p.refunded_at, p.refund_reference, p.resolution_note, p.created_at, p.verified_at, p.plan_code, p.billing_period,
           o.number order_number, o.id order_id, b.name business_name
      from public.online_payments p join public.businesses b on b.id = p.business_id
      left join public.market_orders o on o.id = p.order_id
     where p_filter = 'all' or (p_filter = 'attention' and (p.mismatch or p.needs_refund) and p.refunded_at is null and p.resolution_note is null)
     order by p.created_at desc limit 200) t), '[]'::jsonb);
end $$;
create or replace function public.admin_market_payment_resolve(p_payment uuid, p_action text, p_note text, p_reference text default null)
returns void language plpgsql security definer set search_path = public as $$
declare pay public.online_payments; o public.market_orders;
begin
  perform app.require_platform_admin();
  if coalesce(btrim(p_note), '') = '' then perform app.raise('reason_required'); end if;
  select * into pay from public.online_payments where id = p_payment for update;
  if not found or pay.status <> 'successful' then perform app.raise('not_found'); end if;
  if p_action = 'accept' and pay.mismatch then
    update public.online_payments set mismatch = false, resolution_note = p_note where id = pay.id;
    if pay.kind = 'subscription' then
      perform app.activate_fapshi_subscription(pay.id);
    else
      select * into o from public.market_orders where id = pay.order_id for update;
      if o.status = 'pending' and o.payment_status in ('awaiting_payment', 'failed') then
        update public.market_orders set payment_status = 'paid', expires_at = null, flagged = false, flag_reason = null where id = o.id;
        update public.stock_reservations set expires_at = null where order_id = o.id and released_at is null and consumed_at is null;
      else
        update public.online_payments set needs_refund = true where id = pay.id;
      end if;
    end if;
  elsif p_action = 'refunded' then
    if coalesce(btrim(p_reference), '') = '' then perform app.raise('reference_required'); end if;
    update public.online_payments set needs_refund = false, refunded_at = now(), refund_reference = btrim(p_reference),
           resolution_note = p_note where id = pay.id;
  else
    perform app.raise('invalid_action');
  end if;
  perform app.admin_audit('admin.payment_' || p_action, 'online_payment', pay.id::text, pay.business_id,
                          jsonb_build_object('note', p_note, 'reference', p_reference, 'trans_id', pay.trans_id));
end $$;
create or replace function public.admin_market_balances() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t order by t.balance desc) from (
    select s.business_id, s.name store_name, s.slug, s.phone, s.whatsapp,
           coalesce((select sum(amount) from public.market_ledger l where l.business_id = s.business_id), 0) balance,
           (select coalesce(sum(total), 0) from public.market_orders o where o.business_id = s.business_id and o.payment_method = 'online'
             and o.payment_status = 'paid' and o.status in ('pending', 'confirmed', 'processing', 'dispatched')) held_undelivered,
           (select max(created_at) from public.market_ledger l where l.business_id = s.business_id and l.kind = 'payout') last_payout_at
      from public.stores s
     where exists (select 1 from public.market_ledger l where l.business_id = s.business_id)
        or exists (select 1 from public.market_orders o where o.business_id = s.business_id and o.payment_method = 'online')) t), '[]'::jsonb);
end $$;
create or replace function public.admin_market_ledger(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object('order_number', o.number) order by l.created_at desc)
    from (select * from public.market_ledger where business_id = p_business order by created_at desc limit 300) l
    left join public.market_orders o on o.id = l.order_id), '[]'::jsonb);
end $$;
create or replace function public.admin_market_record_payout(p_business uuid, p_amount numeric, p_method text, p_reference text,
  p_note text default null, p_kind text default 'payout') returns bigint
language plpgsql security definer set search_path = public as $$
declare lid bigint;
begin
  perform app.require_platform_admin();
  if p_kind not in ('payout', 'adjustment') then perform app.raise('invalid_request'); end if;
  if p_amount is null or p_amount = 0 or (p_kind = 'payout' and p_amount < 0) then perform app.raise('invalid_amount'); end if;
  if coalesce(btrim(p_reference), '') = '' then perform app.raise('reference_required'); end if;
  if p_kind = 'adjustment' and coalesce(btrim(p_note), '') = '' then perform app.raise('reason_required'); end if;
  if not exists (select 1 from public.stores where business_id = p_business) then perform app.raise('not_found'); end if;
  insert into public.market_ledger (business_id, kind, amount, method, reference, note, created_by)
  values (p_business, p_kind, case when p_kind = 'payout' then -abs(p_amount) else p_amount end, nullif(p_method, ''),
          btrim(p_reference), nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into lid;
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (p_business, 'market_payout', 'success', jsonb_build_object('amount', abs(p_amount), 'reference', p_reference, 'kind', p_kind),
          '/app/payments', 'cash.manage');
  perform app.admin_audit('admin.' || p_kind || '_recorded', 'market_ledger', lid::text, p_business,
                          jsonb_build_object('amount', p_amount, 'method', p_method, 'reference', p_reference, 'note', p_note));
  return lid;
end $$;
create or replace function public.admin_market_block(p_kind text, p_value text, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v text; bid uuid;
begin
  perform app.require_platform_admin();
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  v := case p_kind when 'phone' then app.norm_phone(p_value) when 'email' then lower(btrim(p_value))
                   when 'user' then app.try_uuid(p_value)::text end;
  if v is null then perform app.raise('invalid_request'); end if;
  insert into public.market_blocklist (kind, value, reason, created_by) values (p_kind, v, btrim(p_reason), auth.uid())
  on conflict (kind, value) do update set reason = excluded.reason returning id into bid;
  perform app.admin_audit('admin.contact_blocked', 'market_blocklist', bid::text, null, jsonb_build_object('kind', p_kind, 'reason', p_reason));
  return bid;
end $$;
create or replace function public.admin_market_unblock(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  delete from public.market_blocklist where id = p_id;
  perform app.admin_audit('admin.contact_unblocked', 'market_blocklist', p_id::text, null, null);
end $$;
create or replace function public.admin_market_hide_review(p_review uuid, p_hidden boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.market_reviews;
begin
  perform app.require_platform_admin();
  update public.market_reviews set status = case when p_hidden then 'hidden' else 'visible' end,
         hidden_reason = case when p_hidden then p_reason end where id = p_review returning * into r;
  if not found then perform app.raise('not_found'); end if;
  perform app.refresh_store_rating(r.business_id);
  perform app.admin_audit(case when p_hidden then 'admin.review_hidden' else 'admin.review_restored' end, 'market_review',
                          p_review::text, r.business_id, jsonb_build_object('reason', p_reason));
end $$;
create or replace function public.admin_market_reviews(p_search text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select r.id, r.rating, r.comment, r.author_name, r.status, r.hidden_reason, r.created_at, p.name product_name, s.name store_name
      from public.market_reviews r join public.products p on p.id = r.product_id join public.stores s on s.business_id = r.business_id
     where p_search is null or r.comment ilike app.like_term(p_search) or s.name ilike app.like_term(p_search) or p.name ilike app.like_term(p_search)
     order by r.created_at desc limit 200) t), '[]'::jsonb);
end $$;
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

commit;
