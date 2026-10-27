-- Phase 15: security hardening. Anonymous visitors may run only the public catalogue, the guest order pages (which check
-- the order token), guest support, and the creator link counter. Every other new function is closed to them, so the
-- database does not depend on each function's own check alone.

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

-- The shopper dashboard is for signed-in shoppers only.
revoke all on function public.buyer_dashboard() from public, anon;
grant execute on function public.buyer_dashboard() to authenticated;
