-- Phase 9: premium automations. Each automation is switched on or off by the seller, runs on demand or on a schedule,
-- records every run (with retry for failures), and never changes stock, prices, customers' accounts, sales or money.
-- What an automation may write: notifications to the seller, and draft lists the seller reviews. Nothing is sent to a
-- customer. Outbound messages are not part of this release.

create table if not exists public.seller_automations (
  business_id uuid not null references public.businesses (id) on delete cascade,
  kind text not null check (kind in ('low_stock_alert', 'weekly_summary', 'restock_list', 'listing_gaps',
    'pending_order_reminder', 'customer_followup', 'marketing_draft')),
  enabled boolean not null default false,
  frequency text not null default 'daily' check (frequency in ('daily', 'weekly')),
  last_run_at timestamptz,
  next_run_at timestamptz,
  updated_by uuid references auth.users (id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (business_id, kind)
);

create table if not exists public.automation_runs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  kind text not null,
  attempt int not null default 1 check (attempt between 1 and 3),
  status text not null check (status in ('running', 'succeeded', 'failed', 'skipped', 'retried')),
  trigger text not null check (trigger in ('manual', 'schedule', 'retry')),
  result jsonb not null default '{}'::jsonb,
  error text,
  started_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists automation_runs_business on public.automation_runs (business_id, started_at desc);

alter table public.seller_automations enable row level security;
alter table public.automation_runs enable row level security;
drop policy if exists seller_automations_read on public.seller_automations;
create policy seller_automations_read on public.seller_automations for select using (app.has_perm(business_id, 'reports.view'));
drop policy if exists automation_runs_read on public.automation_runs;
create policy automation_runs_read on public.automation_runs for select using (app.has_perm(business_id, 'reports.view'));
revoke all on public.seller_automations, public.automation_runs from anon, authenticated;
grant select on public.seller_automations, public.automation_runs to authenticated;

-- Notification types used by automations (display text is in the app translations).
-- Work in one run is done once per day (dedupe keys), so a retry or a second manual run cannot repeat the notice.

-- The work for one kind. Returns a result object; raises on error so the run is recorded as failed.
create or replace function app.run_automation(bid uuid, k text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := app.biz_today(bid); n int; s jsonb; pending int; listing int; top_name text; res jsonb;
begin
  if k = 'low_stock_alert' then
    n := app.build_alerts(bid);
    return jsonb_build_object('notifications_added', n);
  elsif k = 'weekly_summary' then
    s := app.ai_snapshot(bid, today - 6, today);
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (bid, 'automation_summary', 'info', jsonb_build_object('revenue', s ->> 'revenue', 'sales', s -> 'sales' ->> 'count',
            'open_orders', s -> 'orders' ->> 'open', 'out_of_stock', s ->> 'out_of_stock', 'period_from', today - 6, 'period_to', today),
            '/app/reports', 'reports.view', 'automation_summary:' || bid || ':' || (today - 6) || ':' || today)
    on conflict do nothing;
    return jsonb_build_object('revenue', s ->> 'revenue', 'sales', s -> 'sales' ->> 'count', 'period_from', today - 6, 'period_to', today);
  elsif k = 'restock_list' then
    select coalesce(jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'on_hand', p.qty_on_hand,
             'suggested_qty', greatest(ceil(p.min_stock * 2 - p.qty_on_hand), 1)) order by p.name), '[]'::jsonb)
      into res from public.products p
     where p.business_id = bid and p.status = 'active' and p.variant_of is null and p.min_stock > 0 and p.qty_on_hand <= p.min_stock;
    n := jsonb_array_length(res);
    if n > 0 and not exists (select 1 from public.supplier_draft_lists where business_id = bid and status = 'draft'
                              and created_at::date = today and title like 'Automatic restock%') then
      insert into public.supplier_draft_lists (business_id, title, lines) values (bid, 'Automatic restock ' || today, res);
    end if;
    return jsonb_build_object('products_below_minimum', n);
  elsif k = 'listing_gaps' then
    select count(*)::int into listing from public.products p
     where p.business_id = bid and p.status = 'active' and p.variant_of is null and p.online_published
       and (cardinality(p.online_images) = 0 or coalesce(btrim(p.description), '') = '');
    if listing > 0 then
      insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
      values (bid, 'automation_listing', 'info', jsonb_build_object('count', listing), '/app/products', 'products.manage',
              'automation_listing:' || bid || ':' || today) on conflict do nothing;
    end if;
    return jsonb_build_object('listings_to_improve', listing);
  elsif k = 'pending_order_reminder' then
    select count(*)::int into pending from public.market_orders
     where business_id = bid and status = 'pending' and created_at < now() - interval '24 hours';
    if pending > 0 then
      insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
      values (bid, 'automation_orders', 'warning', jsonb_build_object('count', pending), '/app/orders', 'orders.manage',
              'automation_orders:' || bid || ':' || today) on conflict do nothing;
    end if;
    return jsonb_build_object('orders_waiting_over_24h', pending);
  elsif k = 'customer_followup' then
    -- Customers who bought in the last 90 days but not in the last 30: a reminder for the seller, not a message.
    select count(distinct s.customer_id)::int into n from public.sales s
     where s.business_id = bid and s.customer_id is not null and s.cancelled_at is null and s.sold_at > now() - interval '90 days'
       and not exists (select 1 from public.sales s2 where s2.business_id = bid and s2.customer_id = s.customer_id
                        and s2.cancelled_at is null and s2.sold_at > now() - interval '30 days');
    if n > 0 then
      insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
      values (bid, 'automation_followup', 'info', jsonb_build_object('count', n), '/app/customers', 'customers.manage',
              'automation_followup:' || bid || ':' || today) on conflict do nothing;
    end if;
    return jsonb_build_object('customers_to_follow_up', n);
  elsif k = 'marketing_draft' then
    select p.name into top_name from public.products p join public.sale_lines l on l.product_id = p.id
      join public.sales sa on sa.id = l.sale_id
     where p.business_id = bid and sa.cancelled_at is null and sa.sold_at > now() - interval '30 days' and p.status = 'active'
     group by p.id, p.name order by sum(l.base_quantity) desc limit 1;
    return jsonb_build_object('product', top_name, 'note', 'Draft only: open the AI Business Manager to write the text.');
  end if;
  perform app.raise('invalid_request');
  return null;
end $$;

-- Settings: list, switch on or off, change frequency. Only premium businesses; only managers and owners change them.
create or replace function public.automation_list(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'reports.view');
  perform app.require_feature(p_business, 'premium_automations');
  return (select jsonb_agg(jsonb_build_object('kind', k.kind, 'enabled', coalesce(a.enabled, false),
            'frequency', coalesce(a.frequency, 'daily'), 'last_run_at', a.last_run_at, 'next_run_at', a.next_run_at,
            'last_status', (select r.status from public.automation_runs r where r.business_id = p_business and r.kind = k.kind
                             order by r.started_at desc limit 1)) order by k.ord)
            from (values ('low_stock_alert', 1), ('weekly_summary', 2), ('restock_list', 3), ('listing_gaps', 4),
                         ('pending_order_reminder', 5), ('customer_followup', 6), ('marketing_draft', 7)) as k(kind, ord)
            left join public.seller_automations a on a.business_id = p_business and a.kind = k.kind);
end $$;

create or replace function public.automation_set(p_business uuid, p_kind text, p_enabled boolean, p_frequency text default 'daily')
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'settings.manage');
  perform app.require_feature(p_business, 'premium_automations');
  if p_frequency not in ('daily', 'weekly') then perform app.raise('invalid_request'); end if;
  insert into public.seller_automations (business_id, kind, enabled, frequency, next_run_at, updated_by)
  values (p_business, p_kind, p_enabled, p_frequency, case when p_enabled then now() else null end, auth.uid())
  on conflict (business_id, kind) do update set enabled = excluded.enabled, frequency = excluded.frequency,
    next_run_at = case when excluded.enabled then coalesce(seller_automations.next_run_at, now()) else null end,
    updated_by = auth.uid(), updated_at = now();
  perform app.audit(p_business, 'automation.updated', 'automation', p_kind, jsonb_build_object('enabled', p_enabled, 'frequency', p_frequency));
end $$;

-- One run, recorded. Disabled automations do not run. A failure is recorded and can be retried (three attempts at most).
create or replace function app.execute_automation(bid uuid, k text, how text, attempt int) returns uuid
language plpgsql security definer set search_path = public as $$
declare rid uuid; res jsonb; err text;
begin
  insert into public.automation_runs (business_id, kind, attempt, status, trigger)
  values (bid, k, attempt, 'running', how) returning id into rid;
  begin
    res := app.run_automation(bid, k);
    update public.automation_runs set status = 'succeeded', result = res, finished_at = now() where id = rid;
  exception when others then
    err := left(sqlerrm, 300);
    update public.automation_runs set status = 'failed', error = err, finished_at = now() where id = rid;
  end;
  update public.seller_automations set last_run_at = now(),
         next_run_at = now() + case when frequency = 'weekly' then interval '7 days' else interval '1 day' end
   where business_id = bid and kind = k;
  return rid;
end $$;

create or replace function public.automation_run(p_business uuid, p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare rid uuid; r public.automation_runs;
begin
  perform app.require_perm(p_business, 'settings.manage');
  perform app.require_feature(p_business, 'premium_automations');
  perform app.rate_limit('automation:' || p_business, 60, 3600);
  if not exists (select 1 from public.seller_automations where business_id = p_business and kind = p_kind and enabled) then
    perform app.raise('automation_disabled');
  end if;
  rid := app.execute_automation(p_business, p_kind, 'manual', 1);
  select * into r from public.automation_runs where id = rid;
  return jsonb_build_object('run_id', rid, 'status', r.status, 'result', r.result, 'error', r.error);
end $$;

create or replace function public.automation_retry(p_run uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare old public.automation_runs; rid uuid; r public.automation_runs;
begin
  select * into old from public.automation_runs where id = p_run;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(old.business_id, 'settings.manage');
  perform app.require_feature(old.business_id, 'premium_automations');
  if old.status <> 'failed' then perform app.raise('invalid_status'); end if;
  if old.attempt >= 3 then perform app.raise('retry_limit_reached'); end if;
  rid := app.execute_automation(old.business_id, old.kind, 'retry', old.attempt + 1);
  -- The failed run is closed once it has been retried, so it cannot start a second retry.
  update public.automation_runs set status = 'retried' where id = old.id;
  select * into r from public.automation_runs where id = rid;
  return jsonb_build_object('run_id', rid, 'status', r.status, 'result', r.result, 'error', r.error, 'attempt', r.attempt);
end $$;

create or replace function public.automation_history(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'reports.view');
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'kind', r.kind, 'status', r.status, 'attempt', r.attempt,
           'trigger', r.trigger, 'result', r.result, 'error', r.error, 'started_at', r.started_at) order by r.started_at desc)
           from (select * from public.automation_runs where business_id = p_business order by started_at desc limit 50) r), '[]'::jsonb);
end $$;

-- Scheduled work: runs every enabled automation that is due. Called by a scheduler (see the deployment notes).
-- It only runs for businesses that still have the premium entitlement.
create or replace function app.run_due_automations() returns int
language plpgsql security definer set search_path = public as $$
declare a record; n int := 0;
begin
  for a in select sa.business_id, sa.kind from public.seller_automations sa
            where sa.enabled and sa.next_run_at <= now() and app.has_feature(sa.business_id, 'premium_automations')
            order by sa.next_run_at limit 200 loop
    perform app.execute_automation(a.business_id, a.kind, 'schedule', 1);
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function app.run_automation(uuid, text), app.execute_automation(uuid, text, text, int), app.run_due_automations() from public, anon, authenticated;
revoke all on function public.automation_list(uuid), public.automation_set(uuid, text, boolean, text), public.automation_run(uuid, text),
  public.automation_retry(uuid), public.automation_history(uuid) from public, anon;
grant execute on function public.automation_list(uuid), public.automation_set(uuid, text, boolean, text), public.automation_run(uuid, text),
  public.automation_retry(uuid), public.automation_history(uuid) to authenticated;
