-- BizPilot upgrade: check_before_16 20261028000700_notifications_support 
-- Paste into Supabase Dashboard -> SQL Editor -> New query, then Run. Run it ONCE.
-- Adds features only: existing businesses, products, sales and users are not changed.
begin;

-- ===== check_before_16.sql =====
do $$
begin
  if to_regprocedure('public.admin_finance_overview(date,date)') is null then
    raise exception 'Run 15_upgrade_admin_finance.sql (and the earlier upgrades) first, then run this file again.';
  end if;
end $$;

-- ===== 20261028000700_notifications_support.sql =====
create table if not exists public.notification_preferences (
  user_id uuid not null references auth.users (id) on delete cascade,
  category text not null check (category in ('messages', 'orders', 'billing', 'creator', 'support')),
  enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (user_id, category)
);
alter table public.notification_preferences enable row level security;
drop policy if exists notification_preferences_own on public.notification_preferences;
create policy notification_preferences_own on public.notification_preferences for select using (user_id = auth.uid());
revoke all on public.notification_preferences from anon, authenticated;
grant select on public.notification_preferences to authenticated;
create or replace function public.my_notification_preferences() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(c.category, coalesce(p.enabled, true)), '{}'::jsonb)
    from (values ('messages'), ('orders'), ('billing'), ('creator'), ('support')) as c(category)
    left join public.notification_preferences p on p.category = c.category and p.user_id = auth.uid()
$$;
create or replace function public.set_notification_preference(p_category text, p_enabled boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then perform app.raise('not_authenticated'); end if;
  if p_category not in ('messages', 'orders', 'billing', 'creator', 'support') then perform app.raise('invalid_request'); end if;
  insert into public.notification_preferences (user_id, category, enabled) values (auth.uid(), p_category, p_enabled)
  on conflict (user_id, category) do update set enabled = excluded.enabled, updated_at = now();
end $$;
alter table public.inbox_notifications drop constraint if exists inbox_notifications_kind_check;
alter table public.inbox_notifications add constraint inbox_notifications_kind_check
  check (kind in ('message', 'creator_commission', 'creator_payout', 'creator_decision', 'order_update', 'support_reply', 'billing'));
create or replace function app.inbox_category(k text) returns text
language sql immutable as $$
  select case when k = 'message' then 'messages'
              when k in ('order_update') then 'orders'
              when k in ('creator_commission', 'creator_payout', 'creator_decision') then 'creator'
              when k = 'billing' then 'billing'
              when k = 'support_reply' then 'support' end
$$;
create or replace function app.inbox_preference_gate() returns trigger
language plpgsql security definer set search_path = public as $$
declare cat text := app.inbox_category(new.kind);
begin
  if cat is not null and exists (select 1 from public.notification_preferences
       where user_id = new.user_id and category = cat and not enabled) then
    return null;   -- the account has turned this kind of notice off: nothing is stored
  end if;
  return new;
end $$;
drop trigger if exists inbox_preference_gate on public.inbox_notifications;
create trigger inbox_preference_gate before insert on public.inbox_notifications
  for each row execute function app.inbox_preference_gate();
create or replace function app.order_buyer_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare txt text; lnk text := '/order/' || new.id;
begin
  if new.customer_user_id is null then return new; end if;   -- guests have no inbox: they use their order link
  if new.status is distinct from old.status then
    txt := case new.status
      when 'confirmed' then 'Order ' || new.number || ' is confirmed and being prepared.'
      when 'dispatched' then 'Order ' || new.number || ' is on its way.'
      when 'delivered' then 'Order ' || new.number || ' was delivered. Please confirm you received it.'
      when 'cancelled' then 'Order ' || new.number || ' was cancelled.'
      when 'refunded' then 'Order ' || new.number || ' was refunded.' end;
    if txt is not null then
      insert into public.inbox_notifications (user_id, kind, from_name, preview, link)
      values (new.customer_user_id, 'order_update', 'BizPilot', txt, lnk);
    end if;
  end if;
  if new.receipt_status is distinct from old.receipt_status then
    txt := case new.receipt_status
      when 'awaiting' then 'Order ' || new.number || ': please confirm you received it, or report a problem.'
      when 'confirmed' then 'Thank you. You can now rate the products in order ' || new.number || '.'
      when 'disputed' then 'A problem was reported on order ' || new.number || '. BizPilot support is looking into it.'
      when 'resolved' then 'The problem on order ' || new.number || ' was settled. Please confirm when you have it.' end;
    if txt is not null then
      insert into public.inbox_notifications (user_id, kind, from_name, preview, link)
      values (new.customer_user_id, 'order_update', 'BizPilot', txt, lnk);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists market_orders_buyer_notice on public.market_orders;
create trigger market_orders_buyer_notice after update of status, receipt_status on public.market_orders
  for each row execute function app.order_buyer_notice();
create or replace function app.support_reply_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.admin_response is not null and new.admin_response is distinct from old.admin_response then
    if new.business_id is not null then
      insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
      values (new.business_id, 'support_response', 'info', jsonb_build_object('subject', new.subject), '/app/help', 'settings.manage',
              'support_response:' || new.id || ':' || md5(new.admin_response)) on conflict do nothing;
    end if;
    if new.user_id is not null then
      insert into public.inbox_notifications (user_id, kind, from_name, preview, link)
      values (new.user_id, 'support_reply', 'BizPilot support', left(new.subject || ': ' || new.admin_response, 200),
              case when new.business_id is null then '/creator' else '/app/help' end);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists support_reply_notice on public.support_requests;
create trigger support_reply_notice after update of admin_response on public.support_requests
  for each row execute function app.support_reply_notice();
create or replace function app.send_renewal_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare s record; n int := 0; notice int := app.config_int('renewal_notice_days', 7);
begin
  for s in select business_id, plan_code, current_period_end from public.business_subscriptions
            where status = 'active' and not cancel_at_period_end and current_period_end is not null
              and current_period_end > now() and current_period_end - now() <= make_interval(days => notice) loop
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (s.business_id, 'subscription_renewal', 'info',
            jsonb_build_object('plan', s.plan_code, 'period_end', s.current_period_end), '/app/billing', 'billing.manage',
            'renewal:' || s.business_id || ':' || s.current_period_end::date)
    on conflict do nothing;
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;
create or replace function app.prune_notifications(p_days int default 90) returns int
language plpgsql security definer set search_path = public as $$
declare n1 int; n2 int;
begin
  delete from public.notifications where created_at < now() - make_interval(days => p_days)
    and id in (select notification_id from public.notification_reads);
  get diagnostics n1 = row_count;
  delete from public.inbox_notifications where created_at < now() - make_interval(days => p_days) and read_at is not null;
  get diagnostics n2 = row_count;
  return n1 + n2;
end $$;
revoke all on function app.send_renewal_reminders(), app.prune_notifications(int), app.inbox_category(text),
  app.inbox_preference_gate(), app.order_buyer_notice(), app.support_reply_notice() from public, anon, authenticated;
revoke all on function public.my_notification_preferences(), public.set_notification_preference(text, boolean) from public, anon;
grant execute on function public.my_notification_preferences(), public.set_notification_preference(text, boolean) to authenticated;

commit;
