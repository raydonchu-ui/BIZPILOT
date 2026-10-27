-- BizPilot upgrade: check_before_17 20261028000800_security_hardening 
-- Paste into Supabase Dashboard -> SQL Editor -> New query, then Run. Run it ONCE.
-- Adds features only: existing businesses, products, sales and users are not changed.
begin;

-- ===== check_before_17.sql =====
do $$
begin
  if to_regprocedure('public.creator_apply(jsonb)') is null or to_regprocedure('public.admin_finance_overview(date,date)') is null then
    raise exception 'Run the earlier upgrades (up to 16_upgrade_notifications_support.sql) first, then run this file again.';
  end if;
end $$;

-- ===== 20261028000800_security_hardening.sql =====
revoke all on function public.admin_refund_billing_payment(uuid, text),
  public.admin_review_verification(uuid, text, text),
  public.admin_revoke_verification(uuid, text),
  public.admin_verification_applications(text),
  public.billing_payment_cancel(uuid),
  public.verification_apply(uuid, jsonb),
  public.verification_status(uuid),
  public.verification_withdraw(uuid)
from public, anon;
grant execute on function public.billing_payment_cancel(uuid), public.verification_apply(uuid, jsonb),
  public.verification_status(uuid), public.verification_withdraw(uuid) to authenticated;
grant execute on function public.admin_refund_billing_payment(uuid, text), public.admin_review_verification(uuid, text, text),
  public.admin_revoke_verification(uuid, text), public.admin_verification_applications(text) to authenticated;
revoke all on function public.buyer_dashboard() from public, anon;
grant execute on function public.buyer_dashboard() to authenticated;

commit;
