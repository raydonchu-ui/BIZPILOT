-- BizPilot setup PART 26 of 26. Run parts in order.
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
commit;
