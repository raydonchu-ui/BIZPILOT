-- BizPilot setup PART 19 of 19. Run parts in order.
begin;
alter table public.business_settings add column if not exists alert_settings jsonb not null default '{}'::jsonb;
alter table public.business_settings drop constraint if exists business_settings_alert_settings_check;
alter table public.business_settings add constraint business_settings_alert_settings_check
  check (jsonb_typeof(alert_settings) = 'object' and pg_column_size(alert_settings) <= 2048);
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
commit;
