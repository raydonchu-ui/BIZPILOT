-- BizPilot setup PART 8 of 27. Run parts in order.
begin;
alter table public.notification_reads enable row level security;
alter table public.support_requests enable row level security;
alter table public.announcements enable row level security;
alter table public.support_access_grants enable row level security;
alter table public.ai_queries enable row level security;
alter table public.rate_limits enable row level security;
create policy notifications_read on public.notifications for select
  using (app.is_member(business_id) and (required_perm is null or app.has_perm(business_id, required_perm)));
create policy notification_reads_read on public.notification_reads for select using (user_id = auth.uid());
create policy support_read on public.support_requests for select
  using (user_id = auth.uid() or app.is_platform_admin());
create policy announcements_read on public.announcements for select
  using ((active and starts_at <= now() and (ends_at is null or ends_at > now())) or app.is_platform_admin());
create policy support_grants_read on public.support_access_grants for select
  using (app.has_perm(business_id, 'settings.manage') or app.is_platform_admin());
create policy ai_queries_read on public.ai_queries for select
  using (user_id = auth.uid() or app.has_perm(business_id, 'settings.manage') or app.is_platform_admin());
create or replace function app.report_guard(bid uuid, feature text default null) returns void
language plpgsql stable as $$
begin
  perform app.require_perm(bid, 'reports.view');
  if feature is not null then perform app.require_feature(bid, feature); end if;
end $$;
create or replace function app.report_from(bid uuid, d date) returns date
language sql stable as $$
  select case when app.history_cutoff(bid) = '-infinity'::timestamptz then d
              else greatest(d, (app.history_cutoff(bid) at time zone app.biz_tz(bid))::date) end
$$;
create or replace function app.period_stats(bid uuid, d1 date, d2 date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s timestamptz := app.range_start(bid, d1); e timestamptz := app.range_end(bid, d2);
        sa record; rt record; ex numeric; loss numeric; pu record; cash record; net numeric; cogs numeric;
begin
  select count(*) n, coalesce(sum(total), 0) total, coalesce(sum(tax_total), 0) tax, coalesce(sum(cost_total), 0) cost,
         coalesce(sum(line_discount_total + sale_discount + (list_total - subtotal)), 0) discounts,
         coalesce(sum(total) filter (where customer_id is not null and total > paid_total), 0) credit_sales
    into sa from public.sales where business_id = bid and sold_at >= s and sold_at < e;
  select count(*) n, coalesce(sum(total), 0) total, coalesce(sum(tax_amount), 0) tax, coalesce(sum(cost_amount), 0) cost,
         coalesce(sum(refund_amount), 0) refunded
    into rt from public.sale_returns where business_id = bid and returned_at >= s and returned_at < e;
  select coalesce(sum(amount), 0) into ex from public.expenses
   where business_id = bid and status <> 'voided' and expense_date between d1 and d2;
  select coalesce(-sum(value), 0) into loss from public.stock_movements
   where business_id = bid and movement_type in ('damaged', 'expired', 'missing', 'found', 'correction', 'count')
     and occurred_at >= s and occurred_at < e;
  select count(*) n, coalesce(sum(total), 0) total, coalesce(sum(tax_total), 0) tax into pu from public.purchases
   where business_id = bid and status in ('ordered', 'partially_received', 'received') and purchase_date between d1 and d2;
  select coalesce(sum(amount) filter (where kind in ('sale_payment', 'customer_payment')), 0) received,
         coalesce(sum(amount) filter (where kind = 'customer_refund'), 0) refunds,
         coalesce(sum(amount) filter (where kind = 'supplier_payment'), 0) supplier_paid,
         coalesce(sum(amount) filter (where kind = 'expense_payment'), 0) expenses_paid
    into cash from public.payments where business_id = bid and paid_at >= s and paid_at < e;
  net := (sa.total - sa.tax) - (rt.total - rt.tax);
  cogs := sa.cost - rt.cost;
  return jsonb_build_object(
    'from', d1, 'to', d2,
    'transactions', sa.n,
    'gross_sales', sa.total,
    'discounts', sa.discounts,
    'returns', rt.total,
    'returns_count', rt.n,
    'tax_collected', sa.tax - rt.tax,
    'net_sales', net,
    'cogs', round(cogs, 2),
    'gross_profit', round(net - cogs, 2),
    'gross_margin_pct', case when net > 0 then round((net - cogs) / net * 100, 1) end,
    'operating_expenses', ex,
    'stock_losses', round(loss, 2),
    'operating_profit', round(net - cogs - ex - loss, 2),
    'avg_sale', case when sa.n > 0 then round(sa.total / sa.n, 0) end,
    'credit_sales', sa.credit_sales,
    'purchases_total', pu.total,
    'purchases_count', pu.n,
    'purchase_tax', pu.tax,
    'cash_received', cash.received,
    'refunds_paid', cash.refunds,
    'supplier_payments', cash.supplier_paid,
    'expenses_paid', cash.expenses_paid,
    'units_sold', coalesce((select sum(l.base_quantity) from public.sale_lines l join public.sales x on x.id = l.sale_id
                             where x.business_id = bid and x.sold_at >= s and x.sold_at < e), 0)
                - coalesce((select sum(rl.base_quantity) from public.sale_return_lines rl join public.sale_returns r on r.id = rl.return_id
                             where r.business_id = bid and r.returned_at >= s and r.returned_at < e), 0)
  );
end $$;
create or replace function app.data_quality(bid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'sales_count', (select count(*) from public.sales where business_id = bid),
    'first_sale_at', (select min(sold_at) from public.sales where business_id = bid),
    'history_days', coalesce((select (app.biz_today(bid) - (min(sold_at) at time zone app.biz_tz(bid))::date) + 1
                              from public.sales where business_id = bid), 0),
    'products', (select count(*) from public.products where business_id = bid and status = 'active'),
    'products_with_stock_records', (select count(distinct product_id) from public.stock_movements where business_id = bid),
    'estimated_cost_entries', (select count(*) from public.stock_movements where business_id = bid and cost_estimated),
    'zero_cost_products_sold', (select count(distinct l.product_id) from public.sale_lines l
                                where l.business_id = bid and l.cost_amount = 0 and l.net_amount > 0),
    'purchases_count', (select count(*) from public.purchases where business_id = bid and status <> 'cancelled'),
    'suppliers', (select count(*) from public.suppliers where business_id = bid),
    'expenses_count', (select count(*) from public.expenses where business_id = bid))
$$;
create or replace function app.product_period(bid uuid, d1 date, d2 date)
returns table (product_id uuid, units numeric, revenue numeric, cogs numeric, sale_count bigint, returned_units numeric)
language sql stable security definer set search_path = public as $$
  with s as (
    select l.product_id, sum(l.base_quantity) units, sum(l.net_amount - l.tax_amount) rev, sum(l.cost_amount) cogs,
           count(distinct l.sale_id) cnt
    from public.sale_lines l join public.sales x on x.id = l.sale_id
    where x.business_id = bid and x.sold_at >= app.range_start(bid, d1) and x.sold_at < app.range_end(bid, d2)
    group by l.product_id),
  r as (
    select rl.product_id, sum(rl.base_quantity) units, sum(rl.amount - rl.tax_amount) rev, sum(rl.cost_amount) cogs
    from public.sale_return_lines rl join public.sale_returns rr on rr.id = rl.return_id
    where rr.business_id = bid and rr.returned_at >= app.range_start(bid, d1) and rr.returned_at < app.range_end(bid, d2)
    group by rl.product_id)
  select coalesce(s.product_id, r.product_id),
         coalesce(s.units, 0) - coalesce(r.units, 0),
         coalesce(s.rev, 0) - coalesce(r.rev, 0),
         coalesce(s.cogs, 0) - coalesce(r.cogs, 0),
         coalesce(s.cnt, 0),
         coalesce(r.units, 0)
  from s full join r on r.product_id = s.product_id
$$;
create or replace function public.dashboard_summary(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; len int; prev jsonb; cur jsonb; st public.business_settings; today date;
begin
  perform app.report_guard(p_business);
  d1 := app.report_from(p_business, p_from);
  len := p_to - d1 + 1;
  today := app.biz_today(p_business);
  select * into st from public.business_settings where business_id = p_business;
  cur := app.period_stats(p_business, d1, p_to);
  prev := app.period_stats(p_business, d1 - len, d1 - 1);
  return jsonb_build_object(
    'period', cur,
    'previous', prev,
    'inventory_value', (select coalesce(sum(stock_value), 0) from public.products where business_id = p_business),
    'inventory_value_at_start', (select coalesce(sum(value), 0) from public.stock_movements
                                 where business_id = p_business and occurred_at < app.range_start(p_business, d1)),
    'inventory_units', (select coalesce(sum(qty_on_hand), 0) from public.products where business_id = p_business and status = 'active'),
    'low_stock', (select count(*) from public.products where business_id = p_business and status = 'active'
                  and qty_on_hand > 0 and min_stock > 0 and qty_on_hand <= min_stock),
    'out_of_stock', (select count(*) from public.products p where business_id = p_business and status = 'active'
                     and qty_on_hand <= 0 and exists (select 1 from public.stock_movements m where m.product_id = p.id)),
    'never_stocked', (select count(*) from public.products p where business_id = p_business and status = 'active'
                      and not exists (select 1 from public.stock_movements m where m.product_id = p.id)),
    'expiring_soon', (select count(*) from public.stock_batches where business_id = p_business and remaining_qty > 0
                      and expiry_date <= today + st.expiry_alert_days),
    'slow_moving', (select count(*) from public.products p where p.business_id = p_business and p.status = 'active'
                    and p.qty_on_hand > 0 and p.created_at < now() - make_interval(days => st.slow_moving_days)
                    and not exists (select 1 from public.sale_lines l join public.sales s on s.id = l.sale_id
                                    where l.product_id = p.id and s.sold_at > now() - make_interval(days => st.slow_moving_days))),
    'receivables', (select coalesce(sum(greatest(total - returned_total + refunded_total - paid_total, 0)), 0)
                    from public.sales where business_id = p_business and customer_id is not null),
    'payables', (select coalesce(sum(greatest(total - credited_total - paid_total, 0)), 0) from public.purchases
                 where business_id = p_business and status in ('ordered', 'partially_received', 'received')),
    'today', app.period_stats(p_business, today, today),
    'data_quality', app.data_quality(p_business),
    'history_clamped', d1 > p_from,
    'effective_from', d1);
end $$;
create or replace function public.counter_summary(p_business uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := app.biz_today(p_business);
begin
  perform app.require_perm(p_business, 'sales.create');
  return jsonb_build_object(
    'my_sales_today', (select count(*) from public.sales where business_id = p_business and created_by = auth.uid()
                       and sold_at >= app.range_start(p_business, today)),
    'my_total_today', (select coalesce(sum(total), 0) from public.sales where business_id = p_business
                       and created_by = auth.uid() and sold_at >= app.range_start(p_business, today)),
    'low_stock', (select count(*) from public.products where business_id = p_business and status = 'active'
                  and qty_on_hand > 0 and min_stock > 0 and qty_on_hand <= min_stock),
    'out_of_stock', (select count(*) from public.products p where business_id = p_business and status = 'active'
                     and qty_on_hand <= 0 and exists (select 1 from public.stock_movements m where m.product_id = p.id)));
end $$;
create or replace function public.sales_timeseries(p_business uuid, p_from date, p_to date, p_grain text default 'day')
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; g text := case when p_grain in ('day', 'week', 'month') then p_grain else 'day' end; tz text;
begin
  perform app.report_guard(p_business);
  d1 := app.report_from(p_business, p_from);
  tz := app.biz_tz(p_business);
  return coalesce((select jsonb_agg(jsonb_build_object('bucket', b.bucket, 'net_sales', coalesce(x.rev, 0) - coalesce(y.rev, 0),
        'gross_profit', round(coalesce(x.rev, 0) - coalesce(y.rev, 0) - coalesce(x.cogs, 0) + coalesce(y.cogs, 0), 2),
        'transactions', coalesce(x.n, 0)) order by b.bucket)
    from (select generate_series(date_trunc(g, d1::timestamp), date_trunc(g, p_to::timestamp), ('1 ' || g)::interval)::date bucket) b
    left join (select date_trunc(g, sold_at at time zone tz)::date bucket, sum(total - tax_total) rev, sum(cost_total) cogs, count(*) n
               from public.sales where business_id = p_business and sold_at >= app.range_start(p_business, d1)
                 and sold_at < app.range_end(p_business, p_to) group by 1) x on x.bucket = b.bucket
    left join (select date_trunc(g, returned_at at time zone tz)::date bucket, sum(total - tax_amount) rev, sum(cost_amount) cogs
               from public.sale_returns where business_id = p_business and returned_at >= app.range_start(p_business, d1)
                 and returned_at < app.range_end(p_business, p_to) group by 1) y on y.bucket = b.bucket), '[]'::jsonb);
end $$;
create or replace function public.inventory_value_series(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; tz text; base numeric;
begin
  perform app.report_guard(p_business);
  d1 := app.report_from(p_business, p_from);
  tz := app.biz_tz(p_business);
  select coalesce(sum(value), 0) into base from public.stock_movements
   where business_id = p_business and occurred_at < app.range_start(p_business, d1);
  return coalesce((select jsonb_agg(jsonb_build_object('day', t.dt, 'value', round(base + t.cum, 0)) order by t.dt)
    from (select d.dt, coalesce(sum(m.v) over (order by d.dt), 0) as cum
          from (select generate_series(d1, p_to, interval '1 day')::date as dt) d
          left join (select (occurred_at at time zone tz)::date as dt, sum(value) as v from public.stock_movements
                     where business_id = p_business and occurred_at >= app.range_start(p_business, d1)
                       and occurred_at < app.range_end(p_business, p_to) group by 1) m on m.dt = d.dt) t), '[]'::jsonb);
end $$;
create or replace function public.top_products(p_business uuid, p_from date, p_to date, p_limit int default 5)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date;
begin
  perform app.report_guard(p_business);
  d1 := app.report_from(p_business, p_from);
  return coalesce((select jsonb_agg(t) from (
    select p.id, p.name, p.sku, p.base_unit, p.image_path, pp.units, pp.revenue, round(pp.revenue - pp.cogs, 2) gross_profit
    from app.product_period(p_business, d1, p_to) pp join public.products p on p.id = pp.product_id
    where pp.units > 0 order by pp.units desc, pp.revenue desc limit least(p_limit, 50)) t), '[]'::jsonb);
end $$;
create or replace function public.product_performance(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; days int;
begin
  perform app.report_guard(p_business, 'basic_analytics');
  d1 := app.report_from(p_business, p_from);
  days := p_to - d1 + 1;
  return coalesce((select jsonb_agg(t order by t.revenue desc nulls last, t.name) from (
    select p.id, p.name, p.sku, p.base_unit, p.status, c.name category, p.qty_on_hand, p.stock_value, p.avg_cost,
           p.selling_price, p.min_stock, p.created_at,
           coalesce(pp.units, 0) units, coalesce(pp.revenue, 0) revenue, round(coalesce(pp.cogs, 0), 2) cogs,
           round(coalesce(pp.revenue, 0) - coalesce(pp.cogs, 0), 2) gross_profit,
           case when coalesce(pp.revenue, 0) > 0 then round((pp.revenue - pp.cogs) / pp.revenue * 100, 1) end margin_pct,
           coalesce(pp.sale_count, 0) sale_count, coalesce(pp.returned_units, 0) returned_units,
           round(coalesce(pp.units, 0) / greatest(1, least(days, (p_to - (p.created_at at time zone app.biz_tz(p_business))::date + 1))), 3) units_per_day,
           case when p.selling_price > 0 then round((p.selling_price - p.avg_cost) / p.selling_price * 100, 1) end price_margin_pct,
           (select max(s.sold_at) from public.sale_lines l join public.sales s on s.id = l.sale_id where l.product_id = p.id) last_sold_at
    from public.products p
    left join app.product_period(p_business, d1, p_to) pp on pp.product_id = p.id
    left join public.categories c on c.id = p.category_id
    where p.business_id = p_business and (p.status = 'active' or pp.units <> 0)) t), '[]'::jsonb);
end $$;
create or replace function public.category_performance(p_business uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d1 date; tot numeric;
begin
  perform app.report_guard(p_business, 'basic_analytics');
  d1 := app.report_from(p_business, p_from);
  select coalesce(sum(revenue), 0) into tot from app.product_period(p_business, d1, p_to);
  return coalesce((select jsonb_agg(t order by t.revenue desc) from (
    select c.id, c.name category,
           coalesce(sum(pp.units), 0) units, coalesce(sum(pp.revenue), 0) revenue,
           round(coalesce(sum(pp.revenue - pp.cogs), 0), 2) gross_profit,
           case when sum(pp.revenue) > 0 then round(sum(pp.revenue - pp.cogs) / sum(pp.revenue) * 100, 1) end margin_pct,
           case when tot > 0 then round(coalesce(sum(pp.revenue), 0) / tot * 100, 1) end revenue_share_pct,
           round(sum(p.stock_value), 0) inventory_value, count(p.id) products
    from public.products p
    left join public.categories c on c.id = p.category_id
    left join app.product_period(p_business, d1, p_to) pp on pp.product_id = p.id
    where p.business_id = p_business
    group by c.id, c.name
    having coalesce(sum(pp.revenue), 0) <> 0 or sum(p.stock_value) > 0) t), '[]'::jsonb);
end $$;
create or replace function public.restock_recommendations(p_business uuid, p_lookback int default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st public.business_settings; today date; lb int := least(greatest(coalesce(p_lookback, 30), 7), 365);
begin
  perform app.report_guard(p_business, 'restock');
  select * into st from public.business_settings where business_id = p_business;
  today := app.biz_today(p_business);
  return coalesce((select jsonb_agg(t order by t.priority_rank, t.days_of_cover nulls last, t.name) from (
    select x.*,
      case when x.recommended_qty > 0 and x.purchase_factor > 1 then ceil(x.recommended_qty / x.purchase_factor) end recommended_purchase_units,
      round(x.recommended_qty * greatest(x.avg_cost, x.purchase_cost), 0) estimated_cost,
      case when x.priority = 'urgent' then 1 when x.priority = 'soon' then 2 else 3 end priority_rank
    from (
      select y.*,
        case when y.target_qty - y.available > 0
             then greatest(ceil(y.target_qty - y.available), coalesce(y.min_order_qty, 0)) else 0 end recommended_qty,
        case when y.qty_on_hand <= 0 and y.avg_daily > 0 then 'urgent'
             when y.avg_daily > 0 and y.qty_on_hand / y.avg_daily < y.lead_days then 'urgent'
             when y.avg_daily > 0 and y.qty_on_hand / y.avg_daily < y.lead_days + st.safety_stock_days then 'soon'
             when y.qty_on_hand <= y.min_stock then 'soon'
             else 'plan' end priority,
        case when y.sales_count < 5 or y.observed_days < 14 then 'low'
             when y.sales_count < 20 then 'medium' else 'high' end confidence
      from (
        select z.*,
          round(z.units / z.observed_days, 3) avg_daily,
          case when z.units > 0 then round(z.qty_on_hand / (z.units / z.observed_days), 1) end days_of_cover,
          round(z.units / z.observed_days * (z.lead_days + st.safety_stock_days), 2) reorder_point,
          greatest(round(z.units / z.observed_days * (z.lead_days + st.safety_stock_days + st.planning_days), 2), z.min_stock) target_qty,
          z.qty_on_hand + z.incoming available
        from (
          select p.id product_id, p.name, p.sku, p.base_unit, p.qty_on_hand, p.min_stock, p.avg_cost, p.purchase_cost,
                 p.min_order_qty, sp.id supplier_id, sp.name supplier_name,
                 coalesce(p.lead_time_days, sp.lead_time_days, st.default_lead_time_days) lead_days,
                 coalesce(pp.units, 0) units, coalesce(pp.sale_count, 0) sales_count,
                 greatest(1, least(lb, today - (p.created_at at time zone app.biz_tz(p_business))::date + 1)) observed_days,
                 coalesce((select sum((pl.qty_ordered - pl.qty_received) * pl.unit_factor) from public.purchase_lines pl
                           join public.purchases pu on pu.id = pl.purchase_id
                           where pl.product_id = p.id and pu.status in ('ordered', 'partially_received')), 0) incoming,
                 coalesce((select pu2.factor from public.product_units pu2 where pu2.product_id = p.id and pu2.is_default_purchase
                           and pu2.active limit 1), 1) purchase_factor,
                 (select pu2.name from public.product_units pu2 where pu2.product_id = p.id and pu2.is_default_purchase
                           and pu2.active limit 1) purchase_unit
          from public.products p
          left join public.suppliers sp on sp.id = p.preferred_supplier_id
          left join app.product_period(p_business, today - lb + 1, today) pp on pp.product_id = p.id
          where p.business_id = p_business and p.status = 'active') z) y
      where (y.avg_daily > 0 or y.min_stock > 0) and y.available <= greatest(y.reorder_point, y.min_stock)) x) t), '[]'::jsonb);
end $$;
create or replace function public.slow_moving_products(p_business uuid, p_days int default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare w int; today date; total_value numeric;
begin
  perform app.report_guard(p_business, 'advanced_analytics');
  select coalesce(p_days, slow_moving_days) into w from public.business_settings where business_id = p_business;
  today := app.biz_today(p_business);
  select coalesce(sum(stock_value), 0) into total_value from public.products where business_id = p_business;
  return coalesce((select jsonb_agg(t order by t.stock_value desc) from (
    select p.id, p.name, p.sku, p.base_unit, p.qty_on_hand, p.stock_value, p.selling_price, p.avg_cost,
      coalesce(pp.units, 0) units_in_window, w window_days,
      case when coalesce(pp.units, 0) = 0 then 'no_sales' else 'slow' end classification,
      case when coalesce(pp.units, 0) > 0 then round(p.qty_on_hand / (pp.units / w), 0) end days_of_cover,
      case when p.selling_price > 0 then round((p.selling_price - p.avg_cost) / p.selling_price * 100, 1) end price_margin_pct,
      case when total_value > 0 then round(p.stock_value / total_value * 100, 1) end inventory_share_pct,
      (select max(s.sold_at) from public.sale_lines l join public.sales s on s.id = l.sale_id where l.product_id = p.id) last_sold_at,
      (select max(m.occurred_at) from public.stock_movements m where m.product_id = p.id
         and m.movement_type in ('purchase_receipt', 'opening')) last_received_at,
      exists (select 1 from public.stock_movements m where m.product_id = p.id and m.qty_after <= 0
              and m.occurred_at > now() - make_interval(days => w)) was_out_of_stock_in_window
    from public.products p
    left join app.product_period(p_business, today - w + 1, today) pp on pp.product_id = p.id
    where p.business_id = p_business and p.status = 'active' and p.qty_on_hand > 0
      and p.created_at < now() - make_interval(days => w)
      and (select min(m.occurred_at) from public.stock_movements m where m.product_id = p.id and m.quantity > 0)
          < now() - make_interval(days => w)
      and (coalesce(pp.units, 0) = 0 or p.qty_on_hand / (pp.units / w) > 90)) t), '[]'::jsonb);
end $$;
create or replace function public.inventory_aging(p_business uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform app.report_guard(p_business, 'advanced_analytics');
  return (with inflows as (
      select m.product_id, m.occurred_at, m.quantity, p.qty_on_hand, p.avg_cost,
             sum(m.quantity) over (partition by m.product_id order by m.occurred_at desc, m.created_at desc, m.id) cum
      from public.stock_movements m join public.products p on p.id = m.product_id
      where m.business_id = p_business and p.qty_on_hand > 0 and m.quantity > 0
        and m.movement_type in ('opening', 'purchase_receipt', 'sale_return', 'found', 'correction', 'count')),
    layers as (
      select product_id, occurred_at, least(quantity, qty_on_hand - (cum - quantity)) qty, avg_cost,
             now()::date - occurred_at::date age_days
      from inflows where cum - quantity < qty_on_hand),
    per_product as (
      select l.product_id, max(l.age_days) oldest_days,
             round(sum(l.qty * l.age_days) / nullif(sum(l.qty), 0), 0) weighted_age_days,
             round(sum(l.qty * l.avg_cost), 0) value
      from layers l group by l.product_id)
    select jsonb_build_object(
      'buckets', (select jsonb_build_object(
          'd0_30', round(coalesce(sum(qty * avg_cost) filter (where age_days <= 30), 0), 0),
          'd31_60', round(coalesce(sum(qty * avg_cost) filter (where age_days between 31 and 60), 0), 0),
          'd61_90', round(coalesce(sum(qty * avg_cost) filter (where age_days between 61 and 90), 0), 0),
          'd90_plus', round(coalesce(sum(qty * avg_cost) filter (where age_days > 90), 0), 0)) from layers),
      'products', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'qty_on_hand', p.qty_on_hand,
           'base_unit', p.base_unit, 'value', pp.value, 'oldest_days', pp.oldest_days,
           'weighted_age_days', pp.weighted_age_days) order by pp.weighted_age_days desc nulls last)
         from per_product pp join public.products p on p.id = pp.product_id), '[]'::jsonb)));
end $$;
commit;
