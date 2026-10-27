-- BizPilot upgrade: check_before_15 20261028000600_admin_finance 
-- Paste into Supabase Dashboard -> SQL Editor -> New query, then Run. Run it ONCE.
-- Adds features only: existing businesses, products, sales and users are not changed.
begin;

-- ===== check_before_15.sql =====
do $$
begin
  if to_regprocedure('public.admin_creator_reconcile()') is null or to_regprocedure('public.admin_set_creator_program(jsonb)') is null then
    raise exception 'Run 14_upgrade_creator_program.sql (and the earlier upgrades) first, then run this file again.';
  end if;
end $$;

-- ===== 20261028000600_admin_finance.sql =====
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

commit;
