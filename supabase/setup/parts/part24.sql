-- BizPilot setup PART 24 of 26. Run parts in order.
begin;
create or replace function public.ai_send_message(p_business uuid, p_conversation uuid, p_text text, p_lang text default 'en',
  p_from date default null, p_to date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); txt text := btrim(coalesce(p_text, '')); conv uuid := p_conversation; d1 date; d2 date;
  ans jsonb; lang text := case when p_lang = 'fr' then 'fr' else 'en' end; used numeric;
begin
  perform app.ai_manager_gate(p_business);
  if length(txt) < 1 or length(txt) > 1000 then perform app.raise('invalid_question'); end if;
  perform app.rate_limit('ai_manager:' || uid, 30, 3600);
  perform app.check_limit(p_business, 'ai_queries_per_month');
  d2 := coalesce(p_to, app.biz_today(p_business));
  d1 := coalesce(p_from, d2 - 6);
  if d1 > d2 or d2 - d1 > 366 then perform app.raise('invalid_period'); end if;
  if conv is null then
    insert into public.ai_conversations (business_id, user_id, title) values (p_business, uid, left(txt, 120)) returning id into conv;
  elsif not exists (select 1 from public.ai_conversations where id = conv and business_id = p_business and user_id = uid) then
    perform app.raise('not_found');
  end if;
  insert into public.ai_messages (conversation_id, business_id, user_id, role, content) values (conv, p_business, uid, 'user', txt);
  ans := app.ai_answer(p_business, txt, lang, d1, d2);
  insert into public.ai_messages (conversation_id, business_id, user_id, role, content, intent, data)
  values (conv, p_business, uid, 'assistant', ans ->> 'text', ans ->> 'intent', ans -> 'data');
  update public.ai_conversations set updated_at = now() where id = conv;
  insert into public.ai_queries (business_id, user_id, question, answer, model, status, period_from, period_to, completed_at)
  values (p_business, uid, txt, ans ->> 'text', 'bizpilot-rules', 'completed', d1, d2, now());
  used := app.usage_count(p_business, 'ai_queries_per_month');
  return jsonb_build_object('conversation_id', conv, 'intent', ans ->> 'intent', 'text', ans ->> 'text', 'data', ans -> 'data',
    'suggestions', case when lang = 'fr' then jsonb_build_array('Quel chiffre d’affaires ai-je enregistré cette semaine ?', 'Quels produits doivent être réapprovisionnés ?',
                          'Résumez mes commandes en attente.', 'Préparez mon rapport de ventes hebdomadaire.', 'Quels produits se vendent lentement ?')
                   else jsonb_build_array('How much revenue did I record this week?', 'Which products need restocking?',
                          'Summarize my outstanding orders.', 'Create my weekly sales report.', 'Which products are slow-moving?') end,
    'usage', jsonb_build_object('used', used, 'limit', app.plan_limit(p_business, 'ai_queries_per_month')));
end $$;
create or replace function public.ai_propose_action(p_business uuid, p_kind text, p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare aid uuid; preview jsonb; title text; lang text := 'en';
begin
  perform app.ai_manager_gate(p_business);
  perform app.rate_limit('ai_action:' || auth.uid(), 20, 3600);
  if p_kind = 'draft_restock_list' then
    title := 'Draft restock list';
    preview := jsonb_build_object('lines', coalesce((
      select jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'on_hand', p.qty_on_hand, 'suggested_qty',
                       greatest(ceil(p.min_stock * 2 - p.qty_on_hand), 1)))
        from public.products p where p.business_id = p_business and p.status = 'active' and p.variant_of is null
         and p.min_stock > 0 and p.qty_on_hand <= p.min_stock), '[]'::jsonb),
      'note', 'Saved as a draft. No purchase order, payment or stock change is made.');
  elsif p_kind = 'draft_product_copy' then
    title := 'Draft product text';
    if not exists (select 1 from public.products where id = (p_payload ->> 'product_id')::uuid and business_id = p_business) then
      perform app.raise('not_found');
    end if;
    preview := app.ai_product_copy(p_business, (p_payload ->> 'product_id')::uuid, lang);
  elsif p_kind in ('draft_promotion', 'change_price', 'adjust_stock', 'refund', 'send_message', 'create_promotion', 'place_supplier_order') then
    title := initcap(replace(p_kind, '_', ' '));
    preview := jsonb_build_object('requested', p_payload, 'note', 'Recorded as a proposal only. This action is not available yet.');
  else
    perform app.raise('invalid_request');
  end if;
  insert into public.ai_action_requests (business_id, user_id, kind, title, preview, payload)
  values (p_business, auth.uid(), p_kind, title, preview, coalesce(p_payload, '{}'::jsonb)) returning id into aid;
  return jsonb_build_object('action_id', aid, 'kind', p_kind, 'title', title, 'preview', preview, 'status', 'proposed');
end $$;
create or replace function public.ai_confirm_action(p_action uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.ai_action_requests; did uuid;
begin
  select * into a from public.ai_action_requests where id = p_action for update;
  if not found or a.user_id <> auth.uid() then perform app.raise('not_found'); end if;
  perform app.ai_manager_gate(a.business_id);
  if a.status <> 'proposed' then perform app.raise('invalid_status'); end if;
  if a.kind = 'draft_restock_list' then
    insert into public.supplier_draft_lists (business_id, created_by, title, lines, source_action_id)
    values (a.business_id, auth.uid(), 'Restock draft ' || to_char(now(), 'YYYY-MM-DD'), coalesce(a.preview -> 'lines', '[]'::jsonb), a.id)
    returning id into did;
    update public.ai_action_requests set status = 'executed', decided_at = now(), result = jsonb_build_object('draft_id', did) where id = a.id;
  elsif a.kind = 'draft_product_copy' then
    update public.ai_action_requests set status = 'executed', decided_at = now(), result = jsonb_build_object('saved', true) where id = a.id;
  else
    perform app.raise('action_not_enabled');
  end if;
  perform app.audit(a.business_id, 'ai.action_executed', 'ai_action', a.id::text, jsonb_build_object('kind', a.kind));
  return jsonb_build_object('action_id', a.id, 'status', 'executed', 'result', (select result from public.ai_action_requests where id = a.id));
end $$;
create or replace function public.ai_cancel_action(p_action uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a public.ai_action_requests;
begin
  select * into a from public.ai_action_requests where id = p_action for update;
  if not found or a.user_id <> auth.uid() then perform app.raise('not_found'); end if;
  perform app.ai_manager_gate(a.business_id);
  if a.status <> 'proposed' then perform app.raise('invalid_status'); end if;
  update public.ai_action_requests set status = 'cancelled', decided_at = now() where id = a.id;
end $$;
create or replace function public.ai_list_conversations(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.ai_manager_gate(p_business);
  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'updated_at', c.updated_at) order by c.updated_at desc)
                     from (select * from public.ai_conversations where business_id = p_business and user_id = auth.uid()
                           order by updated_at desc limit 30) c), '[]'::jsonb);
end $$;
create or replace function public.ai_get_conversation(p_conversation uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.ai_conversations;
begin
  select * into c from public.ai_conversations where id = p_conversation and user_id = auth.uid();
  if not found then perform app.raise('not_found'); end if;
  perform app.ai_manager_gate(c.business_id);
  return jsonb_build_object('id', c.id, 'title', c.title, 'messages', coalesce((
    select jsonb_agg(jsonb_build_object('role', m.role, 'content', m.content, 'intent', m.intent, 'data', m.data, 'created_at', m.created_at)
                     order by m.id) from public.ai_messages m where m.conversation_id = c.id), '[]'::jsonb));
end $$;
create or replace function public.ai_clear_history(p_business uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform app.ai_manager_gate(p_business);
  delete from public.ai_conversations where business_id = p_business and user_id = auth.uid();
  get diagnostics n = row_count;
  perform app.audit(p_business, 'ai.history_cleared', 'ai_conversation', null, jsonb_build_object('conversations', n));
  return n;
end $$;
create or replace function public.ai_product_text(p_business uuid, p_product uuid, p_lang text default 'en') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.ai_manager_gate(p_business);
  return app.ai_product_copy(p_business, p_product, case when p_lang = 'fr' then 'fr' else 'en' end);
end $$;
revoke all on function app.ai_snapshot(uuid, date, date), app.ai_answer(uuid, text, text, date, date),
  app.ai_product_copy(uuid, uuid, text), app.ai_manager_gate(uuid), app.ai_money(numeric) from public, anon, authenticated;
revoke all on function public.ai_send_message(uuid, uuid, text, text, date, date), public.ai_propose_action(uuid, text, jsonb),
  public.ai_confirm_action(uuid), public.ai_cancel_action(uuid), public.ai_list_conversations(uuid),
  public.ai_get_conversation(uuid), public.ai_clear_history(uuid), public.ai_product_text(uuid, uuid, text) from public, anon;
grant execute on function public.ai_send_message(uuid, uuid, text, text, date, date), public.ai_propose_action(uuid, text, jsonb),
  public.ai_confirm_action(uuid), public.ai_cancel_action(uuid), public.ai_list_conversations(uuid),
  public.ai_get_conversation(uuid), public.ai_clear_history(uuid), public.ai_product_text(uuid, uuid, text) to authenticated;
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
insert into public.app_config (key, value, is_public) values
  ('creator_program', '{"enabled": false, "default_rate": 5, "min_rate": 2, "max_rate": 10, "applies_to": "both",
    "attribution_days": 30, "attribution_months": 12, "hold_days": 7, "payout_minimum": 5000}', false)
on conflict (key) do nothing;
create or replace function app.creator_cfg() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.app_config where key = 'creator_program'), '{}'::jsonb)
$$;
alter table public.inbox_notifications drop constraint if exists inbox_notifications_kind_check;
alter table public.inbox_notifications add constraint inbox_notifications_kind_check
  check (kind in ('message', 'creator_commission', 'creator_payout', 'creator_decision'));
create table if not exists public.creator_profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'suspended')),
  display_name text not null check (length(btrim(display_name)) between 2 and 60),
  bio text check (length(bio) <= 300),
  channels jsonb not null default '[]'::jsonb check (jsonb_typeof(channels) = 'array' and jsonb_array_length(channels) <= 5),
  contact_phone text check (contact_phone ~ '^6[0-9]{8}$'),
  payout_provider text check (payout_provider in ('mtn_momo', 'orange_money')),
  payout_phone text check (payout_phone ~ '^6[0-9]{8}$'),
  payout_name text check (length(payout_name) <= 80),
  referral_code text not null unique check (referral_code ~ '^[A-Z0-9]{6,10}$'),
  commission_rate numeric(4, 2) check (commission_rate is null or commission_rate between 2 and 10),
  applies_to text check (applies_to in ('initial', 'renewal', 'both')),
  decision_reason text check (length(decision_reason) <= 500),
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.creator_clicks (
  id bigserial primary key,
  code text not null,
  created_at timestamptz not null default now()
);
create index if not exists creator_clicks_code on public.creator_clicks (code, created_at);
create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null unique references public.businesses (id) on delete cascade,
  creator_id uuid not null references auth.users (id) on delete cascade,
  referred_user_id uuid references auth.users (id) on delete set null,
  code text not null,
  status text not null default 'attributed' check (status in ('attributed', 'refused')),
  attributed_at timestamptz not null default now(),
  window_ends_at timestamptz not null
);
commit;
