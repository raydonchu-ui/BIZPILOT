-- BizPilot setup PART 27 of 27. Run parts in order.
begin;
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
