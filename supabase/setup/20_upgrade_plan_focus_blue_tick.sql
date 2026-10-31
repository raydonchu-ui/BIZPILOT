-- BizPilot upgrade: check_before_20 20261031000200_plan_focus_blue_tick
-- Paste into Supabase Dashboard -> SQL Editor -> New query, then Run. Run it ONCE.
-- Changes rules and visibility only: no subscription, payment or verification is edited.
begin;

-- ===== check_before_20.sql =====
do $$
begin
  if to_regprocedure('public.admin_market_store_update(uuid, jsonb)') is null or to_regprocedure('app.verification_eligibility(uuid)') is null then
    raise exception 'Run the earlier upgrades (up to 19_upgrade_creator_terms_badge.sql) first, then run this file again.';
  end if;
end $$;

-- Phase 12: one paid plan for now, and the blue tick for subscribers.
--   * New accounts start on the Free plan (15 products). The automatic Business trial is switched off (0 days).
--     Businesses already on a trial keep it until it ends.
--   * Starter and Business are hidden from the public pricing. They stay active, so current subscribers keep their plan.
--   * Verified Premium (5,000 XAF a month) shows every advantage on its card. It is the only plan that includes the blue tick.
--   * The blue tick is for any business on Verified Premium: new or old, with a published store that is not suspended
--     and has no open report. The follower and account-age rules are removed. An administrator still approves each one.

-- 1. Pricing and trial.
update public.plans set is_public = false where code in ('starter', 'business');
update public.app_config set value = jsonb_set(value, '{days}', '0'::jsonb) where key = 'trial';

-- 2. Blue tick eligibility: the 5,000 XAF plan is the requirement.
create or replace function app.verification_eligibility(bid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare st public.stores; b public.businesses; reasons text[] := '{}';
begin
  select * into st from public.stores where business_id = bid;
  if not found then
    return jsonb_build_object('eligible', false, 'reasons', jsonb_build_array('store_not_found'));
  end if;
  select * into b from public.businesses where id = bid;
  if not app.has_feature(bid, 'verified_badge') then reasons := array_append(reasons, 'requires_verified_premium'); end if;
  if st.status <> 'published' then reasons := array_append(reasons, 'store_not_published'); end if;
  if st.status = 'suspended' or b.status <> 'active' then reasons := array_append(reasons, 'account_suspended'); end if;
  if exists (select 1 from public.market_reports r where r.target_type = 'store' and r.target_id = bid
             and r.status in ('open', 'reviewing')) then reasons := array_append(reasons, 'open_report'); end if;
  if (select status from public.business_subscriptions where business_id = bid) = 'suspended' then
    reasons := array_append(reasons, 'subscription_suspended');
  end if;
  -- The follower and account-age figures are no longer requirements; they are returned as zero for the screens.
  return jsonb_build_object('eligible', cardinality(reasons) = 0, 'followers', 0, 'min_followers', 0,
    'account_age_days', 0, 'min_account_age_days', 0, 'reasons', to_jsonb(reasons));
end $$;

commit;
