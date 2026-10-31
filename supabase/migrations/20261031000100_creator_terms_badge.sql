-- Phase 11: creator terms and the Verified Premium blue tick given by an administrator.
--   * Commission is 3% to 10% of the verified payment (it was 2% to 10%). An approved rate below 3% moves up to 3%.
--   * A creator gives their Mobile Money details when they apply, so the cashout account is known from the start.
--   * An administrator can give the blue tick only to a business on the Verified Premium plan (5,000 XAF a month).
--     The tick lasts for the verification validity period and stops when the plan does; it is not permanent.
-- Nothing is deleted or rewritten: ledger entries keep the rate they were made at.

-- 1. Program terms.
update public.app_config set value = jsonb_set(value, '{min_rate}', '3'::jsonb, false)
 where key = 'creator_program' and coalesce((value ->> 'min_rate')::numeric, 0) < 3;

update public.creator_profiles set commission_rate = 3 where commission_rate < 3;
alter table public.creator_profiles drop constraint if exists creator_profiles_commission_rate_check;
alter table public.creator_profiles add constraint creator_profiles_commission_rate_check
  check (commission_rate is null or commission_rate between 3 and 10);

-- Administrators set the program within the new range.
create or replace function public.admin_set_creator_program(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cur jsonb := app.creator_cfg(); nxt jsonb; minr numeric; maxr numeric; dr numeric;
begin
  perform app.require_platform_admin();
  nxt := cur || jsonb_strip_nulls(jsonb_build_object('enabled', p -> 'enabled', 'default_rate', p -> 'default_rate',
           'min_rate', p -> 'min_rate', 'max_rate', p -> 'max_rate', 'applies_to', p -> 'applies_to', 'hold_days', p -> 'hold_days',
           'payout_minimum', p -> 'payout_minimum', 'attribution_months', p -> 'attribution_months'));
  minr := (nxt ->> 'min_rate')::numeric; maxr := (nxt ->> 'max_rate')::numeric; dr := (nxt ->> 'default_rate')::numeric;
  if minr < 3 or maxr > 10 or minr > maxr or dr < minr or dr > maxr then perform app.raise('invalid_rate'); end if;
  if nxt ->> 'applies_to' not in ('initial', 'renewal', 'both') then perform app.raise('invalid_request'); end if;
  if (nxt ->> 'hold_days')::int < 0 or (nxt ->> 'hold_days')::int > 90 then perform app.raise('invalid_request'); end if;
  -- The switch-on time is kept: reconciliation only expects commission for payments approved after it.
  if (nxt ->> 'enabled')::boolean and not coalesce((cur ->> 'enabled')::boolean, false) then
    nxt := nxt || jsonb_build_object('enabled_at', now());
  end if;
  update public.app_config set value = nxt, updated_by = auth.uid(), updated_at = now() where key = 'creator_program';
  perform app.admin_audit('admin.creator_program', 'app_config', 'creator_program', null, nxt);
  return nxt;
end $$;

-- An approval sets the rate within the program's range (3% to 10%).
create or replace function public.admin_review_creator(p_user uuid, p_decision text, p_reason text default null,
  p_rate numeric default null, p_applies text default null)
returns void language plpgsql security definer set search_path = public as $$
declare cp public.creator_profiles; cfg jsonb := app.creator_cfg(); reason text := nullif(btrim(coalesce(p_reason, '')), '');
        rate numeric;
begin
  perform app.require_platform_admin();
  select * into cp from public.creator_profiles where user_id = p_user for update;
  if not found then perform app.raise('not_found'); end if;
  if p_decision = 'approve' then
    if cp.status not in ('pending', 'rejected', 'suspended') then perform app.raise('invalid_status'); end if;
    rate := coalesce(p_rate, cp.commission_rate, (cfg ->> 'default_rate')::numeric);
    if rate < 3 or rate > 10 or rate < (cfg ->> 'min_rate')::numeric or rate > (cfg ->> 'max_rate')::numeric then
      perform app.raise('invalid_rate');
    end if;
    if coalesce(p_applies, cp.applies_to, cfg ->> 'applies_to') not in ('initial', 'renewal', 'both') then perform app.raise('invalid_request'); end if;
    update public.creator_profiles set status = 'approved', commission_rate = rate,
           applies_to = coalesce(p_applies, cp.applies_to, cfg ->> 'applies_to'), decision_reason = reason,
           reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now() where user_id = p_user;
  elsif p_decision in ('reject', 'suspend') then
    if reason is null then perform app.raise('reason_required'); end if;
    if (p_decision = 'reject' and cp.status <> 'pending') or (p_decision = 'suspend' and cp.status <> 'approved') then
      perform app.raise('invalid_status');
    end if;
    update public.creator_profiles set status = case when p_decision = 'reject' then 'rejected' else 'suspended' end,
           decision_reason = reason, reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now() where user_id = p_user;
  elsif p_decision = 'reactivate' then
    if cp.status <> 'suspended' then perform app.raise('invalid_status'); end if;
    if reason is null then perform app.raise('reason_required'); end if;
    update public.creator_profiles set status = 'approved', decision_reason = reason, reviewed_by = auth.uid(), reviewed_at = now(),
           updated_at = now() where user_id = p_user;
  else
    perform app.raise('invalid_request');
  end if;
  insert into public.inbox_notifications (user_id, kind, from_name, preview, link)
  values (p_user, 'creator_decision', 'BizPilot', 'Your creator application: ' || p_decision || coalesce('. ' || reason, ''), '/creator');
  perform app.admin_audit('admin.creator_' || p_decision, 'creator', p_user::text, null, jsonb_build_object('reason', reason, 'rate', rate));
end $$;

-- 2. Creator application: the Mobile Money details are part of it. creator_update checks the phone numbers.
create or replace function public.creator_apply(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text := nullif(btrim(coalesce(p ->> 'display_name', '')), ''); st text;
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  if not exists (select 1 from auth.users where id = uid and email_confirmed_at is not null) then perform app.raise('email_not_verified'); end if;
  if nm is null or length(nm) < 2 or length(nm) > 60 then perform app.raise('invalid_request'); end if;
  -- Cashout goes to this Mobile Money account, so it is required from the start.
  if coalesce(p ->> 'payout_provider', '') not in ('mtn_momo', 'orange_money')
     or nullif(regexp_replace(coalesce(p ->> 'payout_phone', ''), '\D', '', 'g'), '') is null then
    perform app.raise('payout_details_required');
  end if;
  perform app.rate_limit('creator_apply:' || uid, 3, 86400);
  if exists (select 1 from public.creator_profiles where user_id = uid) then
    select status into st from public.creator_profiles where user_id = uid;
    return st;
  end if;
  insert into public.creator_profiles (user_id, display_name, bio, channels, referral_code)
  values (uid, nm, nullif(left(btrim(coalesce(p ->> 'bio', '')), 300), ''),
          case when jsonb_typeof(p -> 'channels') = 'array' then p -> 'channels' else '[]'::jsonb end, app.creator_code());
  perform public.creator_update(p);
  perform app.audit(null, 'creator.applied', 'creator', uid::text, null);
  return 'pending';
end $$;

-- 3. The blue tick by an administrator. Only for the Verified Premium plan; it expires with the verification period.
-- Applications approved through the seller's own request keep their existing rules (admin_review_verification).
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
    if p ->> 'verification' = 'verified' then
      if not app.has_feature(p_business, 'verified_badge') then perform app.raise('requires_verified_premium'); end if;
      update public.stores set verification = 'verified',
             verification_expires_at = now() + make_interval(days => app.verification_config('validity_days', 365)),
             verification_note = coalesce(reason, verification_note)
       where business_id = p_business;
    else
      update public.stores set verification = p ->> 'verification', verification_expires_at = null,
             verification_note = coalesce(reason, verification_note)
       where business_id = p_business;
    end if;
  end if;
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (p_business, 'market_store_status', case when p ->> 'status' = 'suspended' or p ->> 'verification' = 'rejected' then 'critical' else 'info' end,
          jsonb_build_object('status', coalesce(p ->> 'status', s.status), 'verification', coalesce(p ->> 'verification', s.verification),
                             'reason', reason), '/app/store', 'store.manage');
  perform app.admin_audit('admin.store_updated', 'store', p_business::text, p_business, p);
end $$;
