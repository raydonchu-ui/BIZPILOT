-- BizPilot setup PART 26 of 27. Run parts in order.
begin;
create or replace function public.admin_creator_referrals(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('business_id', r.business_id, 'business_name', b.name, 'status', r.status,
      'attributed_at', r.attributed_at, 'window_ends_at', r.window_ends_at, 'code', r.code,
      'shared_member', exists (select 1 from public.business_members m where m.business_id = r.business_id and m.user_id = r.creator_id),
      'verified_payments', (select count(*) from public.billing_payments p where p.business_id = r.business_id and p.status = 'verified'))
      order by r.attributed_at desc)
    from public.referrals r join public.businesses b on b.id = r.business_id where r.creator_id = p_user), '[]'::jsonb);
end $$;
create or replace function public.admin_creator_adjustment(p_user uuid, p_amount numeric, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform app.require_platform_admin();
  if p_amount is null or p_amount = 0 or abs(p_amount) > 1000000 then perform app.raise('invalid_request'); end if;
  if reason is null then perform app.raise('reason_required'); end if;
  if not exists (select 1 from public.creator_profiles where user_id = p_user) then perform app.raise('not_found'); end if;
  insert into public.creator_ledger (creator_id, kind, amount, available_at, note, created_by)
  values (p_user, 'adjustment', round(p_amount), now(), left(reason, 200), auth.uid());
  perform app.admin_audit('admin.creator_adjustment', 'creator', p_user::text, null, jsonb_build_object('amount', round(p_amount), 'reason', reason));
end $$;
create or replace function public.admin_list_payouts(p_status text default 'requested') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'creator_id', q.creator_id, 'display_name', c.display_name,
      'amount', q.amount, 'provider', q.provider, 'phone', q.phone, 'account_name', q.account_name, 'status', q.status,
      'provider_reference', q.provider_reference, 'decision_note', q.decision_note, 'requested_at', q.requested_at,
      'paid_at', q.paid_at, 'available_now', (app.creator_balance(q.creator_id) ->> 'withdrawable')::numeric)
      order by q.requested_at)
    from public.creator_payout_requests q join public.creator_profiles c on c.user_id = q.creator_id
    where p_status is null or q.status = p_status), '[]'::jsonb);
end $$;
create or replace function public.admin_creator_reconcile() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare missing int; extra_reversals int; overpaid int;
begin
  perform app.require_platform_admin();
  select count(*)::int into missing from (
    select p.id, p.business_id, p.submitted_at, r.window_ends_at, c.applies_to,
           (select count(*) from public.billing_payments q where q.business_id = p.business_id and q.status in ('verified', 'refunded')
             and q.id <> p.id and q.submitted_at < p.submitted_at) as prior
      from public.billing_payments p join public.referrals r on r.business_id = p.business_id
      join public.creator_profiles c on c.user_id = r.creator_id
     where p.status = 'verified' and r.status = 'attributed' and c.status = 'approved' and c.commission_rate is not null
       and p.reviewed_at >= coalesce((app.creator_cfg() ->> 'enabled_at')::timestamptz, 'infinity'::timestamptz)
       and p.submitted_at <= r.window_ends_at
  ) x
   where (x.applies_to = 'both' or x.applies_to = case when x.prior = 0 then 'initial' else 'renewal' end)
     and not exists (select 1 from public.creator_ledger l where l.billing_payment_id = x.id and l.kind = 'accrual');
  select count(*)::int into extra_reversals from public.creator_ledger l
   where l.kind = 'reversal' and not exists (select 1 from public.billing_payments p where p.id = l.billing_payment_id and p.status = 'refunded');
  select count(*)::int into overpaid from (select creator_id from public.creator_payout_requests where status in ('paid', 'requested', 'approved', 'processing')
     group by creator_id) x where (select sum(amount) from public.creator_ledger l where l.creator_id = x.creator_id and l.available_at <= now())
     < (select sum(amount) from public.creator_payout_requests q where q.creator_id = x.creator_id and q.status in ('paid', 'requested', 'approved', 'processing'));
  return jsonb_build_object('verified_payments_without_accrual', missing, 'reversals_without_refund', extra_reversals,
    'creators_paid_above_available', overpaid, 'balanced', missing = 0 and extra_reversals = 0 and overpaid = 0,
    'checked_at', now());
end $$;
revoke all on function app.creator_cfg(), app.creator_code(), app.creator_balance(uuid), app.creator_accrue(uuid), app.creator_reverse(uuid),
  app.billing_commission_hook(), app.ledger_append_only() from public, anon, authenticated;
revoke all on function public.creator_apply(jsonb), public.creator_update(jsonb), public.creator_attach_referral(text),
  public.creator_dashboard(), public.creator_request_payout(numeric), public.creator_cancel_payout(uuid),
  public.admin_set_payout_status(uuid, text, text, text), public.admin_set_creator_program(jsonb), public.admin_creator_list(text),
  public.admin_review_creator(uuid, text, text, numeric, text), public.admin_creator_referrals(uuid),
  public.admin_creator_adjustment(uuid, numeric, text), public.admin_creator_reconcile(), public.admin_list_payouts(text), public.admin_creator_program_get() from public, anon;
grant execute on function public.creator_apply(jsonb), public.creator_update(jsonb), public.creator_attach_referral(text),
  public.creator_dashboard(), public.creator_request_payout(numeric), public.creator_cancel_payout(uuid),
  public.admin_set_payout_status(uuid, text, text, text), public.admin_set_creator_program(jsonb), public.admin_creator_list(text),
  public.admin_review_creator(uuid, text, text, numeric, text), public.admin_creator_referrals(uuid),
  public.admin_creator_adjustment(uuid, numeric, text), public.admin_creator_reconcile(), public.admin_list_payouts(text), public.admin_creator_program_get() to authenticated;
revoke all on function public.creator_track_click(text) from public;
grant execute on function public.creator_track_click(text) to anon, authenticated;
alter table public.billing_payments add column if not exists refunded_at timestamptz;
create or replace function public.admin_refund_billing_payment(p_payment uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare bp public.billing_payments; s public.business_subscriptions; reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform app.require_platform_admin();
  if reason is null then perform app.raise('reason_required'); end if;
  select * into bp from public.billing_payments where id = p_payment for update;
  if not found then perform app.raise('not_found'); end if;
  if bp.status <> 'verified' then perform app.raise('invalid_status'); end if;
  update public.billing_payments set status = 'refunded', review_note = reason, reviewed_by = auth.uid(), refunded_at = now()
   where id = bp.id;
  select * into s from public.business_subscriptions where business_id = bp.business_id for update;
  if found and s.plan_code = bp.plan_code and s.current_period_end = bp.period_end then
    update public.business_subscriptions set current_period_end = now(), status = 'cancelled', cancel_at_period_end = true
     where business_id = bp.business_id;
  end if;
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (bp.business_id, 'billing_payment_refunded', 'warning', jsonb_build_object('reference', bp.transaction_ref, 'reason', reason),
          '/app/billing', 'billing.manage');
  perform app.admin_audit('admin.billing_refunded', 'billing_payment', bp.id::text, bp.business_id,
                          jsonb_build_object('amount', bp.amount, 'reason', reason));
end $$;
create or replace function public.admin_finance_overview(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare gross numeric; gross_n int; by_plan jsonb; renewals int; firsts int; rej_n int; rej_amt numeric;
        ref_n int; ref_amt numeric; pend_n int; pend_amt numeric; accrued numeric; reversed numeric; adj numeric;
        on_hold numeric; avail numeric; paid_out numeric; open_out numeric; failed_out int; ai_n int; ai_ok int; ai_fail int;
        ai_tokens numeric; st_bytes numeric; st_files int; rec jsonb; net numeric; d1 timestamptz := app.range_start(null, p_from);
        d2 timestamptz;
begin
  perform app.require_platform_admin();
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 732 then perform app.raise('invalid_period'); end if;
  d2 := (p_to + 1)::timestamptz;
  select coalesce(sum(p.amount), 0), count(*)::int into gross, gross_n from public.billing_payments p
   where p.status in ('verified', 'refunded') and p.reviewed_at >= d1 and p.reviewed_at < d2;
  select coalesce(jsonb_agg(x order by x.amount desc), '[]'::jsonb) into by_plan from (
    select p.plan_code, count(*)::int n, sum(p.amount) amount from public.billing_payments p
     where p.status in ('verified', 'refunded') and p.reviewed_at >= d1 and p.reviewed_at < d2 group by p.plan_code) x;
  select count(*) filter (where exists (select 1 from public.billing_payments q where q.business_id = p.business_id and q.status in ('verified', 'refunded')
           and q.id <> p.id and q.submitted_at < p.submitted_at)), count(*) filter (where not exists (select 1 from public.billing_payments q
           where q.business_id = p.business_id and q.status in ('verified', 'refunded') and q.id <> p.id and q.submitted_at < p.submitted_at))
    into renewals, firsts from public.billing_payments p where p.status in ('verified', 'refunded') and p.reviewed_at >= d1 and p.reviewed_at < d2;
  select count(*)::int, coalesce(sum(amount), 0) into rej_n, rej_amt from public.billing_payments
   where status = 'rejected' and reviewed_at >= d1 and reviewed_at < d2;
  select count(*)::int, coalesce(sum(amount), 0) into ref_n, ref_amt from public.billing_payments
   where status = 'refunded' and refunded_at >= d1 and refunded_at < d2;
  select count(*)::int, coalesce(sum(amount), 0) into pend_n, pend_amt from public.billing_payments where status = 'pending';
  select coalesce(sum(amount) filter (where kind = 'accrual' and created_at >= d1 and created_at < d2), 0),
         coalesce(-sum(amount) filter (where kind = 'reversal' and created_at >= d1 and created_at < d2), 0),
         coalesce(sum(amount) filter (where kind = 'adjustment' and created_at >= d1 and created_at < d2), 0),
         coalesce(sum(amount) filter (where available_at > now()), 0),
         coalesce(sum(amount) filter (where available_at <= now()), 0)
    into accrued, reversed, adj, on_hold, avail from public.creator_ledger;
  select coalesce(sum(amount) filter (where status = 'paid' and paid_at >= d1 and paid_at < d2), 0),
         coalesce(sum(amount) filter (where status in ('requested', 'approved', 'processing')), 0),
         count(*) filter (where status = 'failed' and decided_at >= d1 and decided_at < d2)::int
    into paid_out, open_out, failed_out from public.creator_payout_requests;
  select count(*)::int, count(*) filter (where status = 'completed')::int, count(*) filter (where status = 'failed')::int,
         coalesce(sum(coalesce(input_tokens, 0) + coalesce(output_tokens, 0)), 0)
    into ai_n, ai_ok, ai_fail, ai_tokens from public.ai_queries where created_at >= d1 and created_at < d2;
  select coalesce(sum(bytes), 0), count(*)::int into st_bytes, st_files from public.stored_images;
  rec := public.admin_creator_reconcile();
  net := gross - ref_amt - (accrued - reversed);
  return jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'collections', jsonb_build_object('gross', gross, 'count', gross_n, 'by_plan', by_plan,
       'first_payments', firsts, 'renewals', renewals,
       'rejected', jsonb_build_object('count', rej_n, 'amount', rej_amt),
       'refunded', jsonb_build_object('count', ref_n, 'amount', ref_amt),
       'pending', jsonb_build_object('count', pend_n, 'amount', pend_amt)),
    'commissions', jsonb_build_object('accrued', accrued, 'reversed', reversed, 'adjustments', adj,
       'on_hold', on_hold, 'available', avail),
    'payouts', jsonb_build_object('paid_in_period', paid_out, 'open', open_out, 'failed_in_period', failed_out),
    'net', jsonb_build_object('after_refunds_and_commission', net, 'is_profit', false),
    'ai', jsonb_build_object('answers', ai_n, 'completed', ai_ok, 'failed', ai_fail, 'tokens', ai_tokens),
    'storage', jsonb_build_object('bytes', st_bytes, 'files', st_files),
    'reconciliation', rec,
    'not_recorded', jsonb_build_array('hosting', 'ai_provider_fees', 'payment_provider_fees', 'staff_costs'));
end $$;
create or replace function public.admin_finance_payments(p_from date, p_to date, p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if p_to < p_from or p_to - p_from > 732 then perform app.raise('invalid_period'); end if;
  return coalesce((select jsonb_agg(x order by x.submitted_at desc) from (
    select p.id, p.business_id, b.name as business_name, p.plan_code, p.amount, p.expected_amount, p.status, p.method,
           p.transaction_ref, p.submitted_at, p.reviewed_at, p.review_note
      from public.billing_payments p join public.businesses b on b.id = p.business_id
     where p.submitted_at >= app.range_start(null, p_from) and p.submitted_at < (p_to + 1)::timestamptz
       and (p_status is null or p.status = p_status)
     order by p.submitted_at desc limit 300) x), '[]'::jsonb);
end $$;
create or replace function public.admin_platform_health() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return jsonb_build_object(
    'open_support', (select count(*) from public.support_requests where status in ('open', 'in_progress')),
    'open_reports', (select count(*) from public.market_reports where status in ('open', 'reviewing') and kind = 'report'),
    'open_disputes', (select count(*) from public.market_reports where status in ('open', 'reviewing') and kind = 'dispute'),
    'stale_pending_payments', (select count(*) from public.billing_payments where status = 'pending' and submitted_at < now() - interval '3 days'),
    'verifications_waiting', (select count(*) from public.verification_applications where status in ('submitted', 'under_review') and submitted_at < now() - interval '3 days'),
    'failed_automation_runs_7d', (select count(*) from public.automation_runs where status = 'failed' and started_at > now() - interval '7 days'),
    'failed_online_payments_7d', (select count(*) from public.online_payments where status in ('failed', 'error') and created_at > now() - interval '7 days'),
    'failed_payouts', (select count(*) from public.creator_payout_requests where status = 'failed'),
    'checked_at', now());
end $$;
create or replace function public.admin_locations_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return jsonb_build_object(
    'regions', coalesce((select jsonb_agg(jsonb_build_object('code', r.code, 'name_en', r.name_en, 'name_fr', r.name_fr) order by r.sort)
                         from public.cameroon_regions r), '[]'::jsonb),
    'localities', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'region', l.region_code, 'name', l.name, 'key', l.key,
                              'active', l.active) order by l.region_code, l.name)
                            from public.cameroon_localities l), '[]'::jsonb));
end $$;
create or replace function public.admin_add_locality(p_region text, p_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare nm text := btrim(coalesce(p_name, '')); id uuid; srt int;
begin
  perform app.require_platform_admin();
  if not exists (select 1 from public.cameroon_regions where code = p_region) then perform app.raise('region_not_found'); end if;
  if length(nm) < 2 or length(nm) > 80 then perform app.raise('invalid_request'); end if;
  if exists (select 1 from public.cameroon_localities where region_code = p_region and key = app.city_key(nm)) then
    perform app.raise('locality_exists');
  end if;
  select coalesce(max(sort), 0) + 1 into srt from public.cameroon_localities where region_code = p_region;
  insert into public.cameroon_localities (region_code, name, sort) values (p_region, nm, srt) returning cameroon_localities.id into id;
  perform app.admin_audit('admin.locality_added', 'cameroon_locality', id::text, null, jsonb_build_object('region', p_region, 'name', nm));
  return id;
end $$;
create or replace function public.admin_update_locality(p_id uuid, p_name text default null, p_active boolean default null)
returns void language plpgsql security definer set search_path = public as $$
declare l public.cameroon_localities; nm text := nullif(btrim(coalesce(p_name, '')), '');
begin
  perform app.require_platform_admin();
  select * into l from public.cameroon_localities where id = p_id for update;
  if not found then perform app.raise('not_found'); end if;
  if nm is not null then
    if length(nm) < 2 or length(nm) > 80 then perform app.raise('invalid_request'); end if;
    if app.city_key(nm) <> l.key then perform app.raise('locality_key_change_not_allowed'); end if;
    update public.cameroon_localities set name = nm where id = p_id;
  end if;
  if p_active is not null then
    update public.cameroon_localities set active = p_active where id = p_id;
  end if;
  perform app.admin_audit('admin.locality_updated', 'cameroon_locality', p_id::text, null,
                          jsonb_build_object('name', nm, 'active', p_active));
end $$;
create or replace function public.admin_set_region_names(p_code text, p_en text, p_fr text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if not exists (select 1 from public.cameroon_regions where code = p_code) then perform app.raise('region_not_found'); end if;
  if length(btrim(coalesce(p_en, ''))) < 2 or length(btrim(coalesce(p_fr, ''))) < 2 then perform app.raise('invalid_request'); end if;
  update public.cameroon_regions set name_en = btrim(p_en), name_fr = btrim(p_fr) where code = p_code;
  perform app.admin_audit('admin.region_names', 'cameroon_region', p_code, null, jsonb_build_object('en', p_en, 'fr', p_fr));
end $$;
revoke all on function public.admin_finance_overview(date, date), public.admin_finance_payments(date, date, text), public.admin_platform_health(),
  public.admin_locations_list(), public.admin_add_locality(text, text), public.admin_update_locality(uuid, text, boolean),
  public.admin_set_region_names(text, text, text) from public, anon;
grant execute on function public.admin_finance_overview(date, date), public.admin_finance_payments(date, date, text), public.admin_platform_health(),
  public.admin_locations_list(), public.admin_add_locality(text, text), public.admin_update_locality(uuid, text, boolean),
  public.admin_set_region_names(text, text, text) to authenticated;
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
commit;
