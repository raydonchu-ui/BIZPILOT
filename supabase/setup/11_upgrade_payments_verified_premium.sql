-- BizPilot upgrade: check_before_11 20261028000100_seller_payment_settings 20261028000200_verified_premium 
-- Paste into Supabase Dashboard -> SQL Editor -> New query, then Run. Run it ONCE.
-- Adds features only: existing businesses, products, sales and users are not changed.
begin;

-- ===== check_before_11.sql =====
do $$
begin
  if to_regprocedure('public.market_order_customer_action(uuid,text,text,text)') is null
     or to_regclass('public.market_reviews') is null or to_regprocedure('app.review_gate(public.market_orders)') is null then
    raise exception 'Run 10_upgrade_order_lifecycle.sql (and the earlier upgrades) first, then run this file again.';
  end if;
end $$;

-- ===== 20261028000100_seller_payment_settings.sql =====
create or replace function app.payment_text_ok(t text) returns boolean
language sql immutable as $$
  select t is null or t !~* '(\mpin\M|\motp\M|password|mot de passe|code secret|secret code|passcode|one.time code|code a usage unique|wallet pass)'
$$;
alter table public.stores
  add column if not exists momo_mtn_enabled boolean not null default false,
  add column if not exists momo_orange_enabled boolean not null default false,
  add column if not exists momo_mtn_instructions text,
  add column if not exists momo_orange_instructions text,
  add column if not exists momo_proof_required boolean not null default false,
  add column if not exists momo_settings_updated_at timestamptz;
update public.stores set
  momo_mtn_enabled = momo_direct_enabled and momo_mtn_number is not null,
  momo_orange_enabled = momo_direct_enabled and momo_orange_number is not null
where not momo_mtn_enabled and not momo_orange_enabled;
alter table public.stores drop constraint if exists stores_momo_mtn_instructions_check;
alter table public.stores add constraint stores_momo_mtn_instructions_check
  check (momo_mtn_instructions is null or (length(momo_mtn_instructions) <= 300 and app.payment_text_ok(momo_mtn_instructions)));
alter table public.stores drop constraint if exists stores_momo_orange_instructions_check;
alter table public.stores add constraint stores_momo_orange_instructions_check
  check (momo_orange_instructions is null or (length(momo_orange_instructions) <= 300 and app.payment_text_ok(momo_orange_instructions)));
create or replace function public.store_save_payments(p_business uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  mtn text := nullif(right(regexp_replace(coalesce(p ->> 'momo_mtn_number', ''), '\D', '', 'g'), 9), '');
  ora text := nullif(right(regexp_replace(coalesce(p ->> 'momo_orange_number', ''), '\D', '', 'g'), 9), '');
  mtn_on boolean := coalesce((p ->> 'momo_mtn_enabled')::boolean, mtn is not null);
  ora_on boolean := coalesce((p ->> 'momo_orange_enabled')::boolean, ora is not null);
  wanted boolean := coalesce((p ->> 'momo_direct_enabled')::boolean, false);
  mtn_ins text := nullif(left(btrim(coalesce(p ->> 'momo_mtn_instructions', '')), 300), '');
  ora_ins text := nullif(left(btrim(coalesce(p ->> 'momo_orange_instructions', '')), 300), '');
  enabled boolean;
begin
  perform app.require_perm(p_business, 'store.manage');
  if not exists (select 1 from public.stores where business_id = p_business) then perform app.raise('store_not_found'); end if;
  if (mtn is not null and mtn !~ '^6[0-9]{8}$') or (ora is not null and ora !~ '^6[0-9]{8}$') then perform app.raise('invalid_phone'); end if;
  if (mtn_on and mtn is null) or (ora_on and ora is null) then perform app.raise('momo_number_required'); end if;
  if not app.payment_text_ok(mtn_ins) or not app.payment_text_ok(ora_ins) then perform app.raise('payment_secret_not_allowed'); end if;
  enabled := wanted and (mtn_on or ora_on);
  if wanted and not enabled then perform app.raise('momo_number_required'); end if;
  update public.stores set
    momo_direct_enabled = enabled,
    momo_mtn_enabled = enabled and mtn_on, momo_orange_enabled = enabled and ora_on,
    momo_mtn_number = mtn, momo_orange_number = ora,
    momo_mtn_name = nullif(left(btrim(coalesce(p ->> 'momo_mtn_name', '')), 80), ''),
    momo_orange_name = nullif(left(btrim(coalesce(p ->> 'momo_orange_name', '')), 80), ''),
    momo_mtn_instructions = mtn_ins, momo_orange_instructions = ora_ins,
    momo_proof_required = coalesce((p ->> 'momo_proof_required')::boolean, momo_proof_required),
    payment_note = nullif(left(btrim(coalesce(p ->> 'payment_note', '')), 300), ''),
    return_policy = nullif(left(btrim(coalesce(p ->> 'return_policy', '')), 1500), ''),
    neighborhood = nullif(left(btrim(coalesce(p ->> 'neighborhood', '')), 80), ''),
    service_area = nullif(left(btrim(coalesce(p ->> 'service_area', '')), 200), ''),
    cod_enabled = coalesce((p ->> 'cod_enabled')::boolean, cod_enabled),
    online_payment_enabled = false, momo_settings_updated_at = now(), updated_at = now()
   where business_id = p_business;
  perform app.audit(p_business, 'store.payments', 'store', p_business::text,
    jsonb_build_object('momo_direct', enabled, 'mtn', enabled and mtn_on, 'orange', enabled and ora_on,
                       'proof_required', coalesce((p ->> 'momo_proof_required')::boolean, false)));
end $$;
create or replace function public.market_order_view(p_order uuid, p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.market_orders; s public.stores;
begin
  perform app.market_expire();
  o := app.order_for_customer(p_order, p_token);
  select * into s from public.stores where business_id = o.business_id;
  return jsonb_build_object(
    'id', o.id, 'number', o.number, 'status', o.status, 'payment_method', o.payment_method, 'payment_status', o.payment_status,
    'created_at', o.created_at, 'confirmed_at', o.confirmed_at, 'dispatched_at', o.dispatched_at, 'delivered_at', o.delivered_at,
    'cancelled_at', o.cancelled_at, 'cancel_reason', o.cancel_reason, 'cancelled_by', o.cancelled_by,
    'expires_at', case when o.status = 'pending' then o.expires_at end,
    'receipt_status', o.receipt_status, 'receipt_due_at', o.receipt_due_at, 'receipt_confirmed_at', o.receipt_confirmed_at,
    'customer_name', o.customer_name, 'customer_phone', o.customer_phone, 'customer_email', o.customer_email,
    'delivery_method', o.delivery_method, 'zone_name', o.zone_name, 'delivery_eta', o.delivery_eta, 'address', o.address,
    'notes', o.notes, 'subtotal', o.subtotal, 'discount', o.discount, 'delivery_fee', o.delivery_fee, 'total', o.total,
    'currency', o.currency, 'promo_code', o.promo_code, 'refund_amount', o.refund_amount, 'refunded_at', o.refunded_at,
    'buyer_payment_ref', o.buyer_payment_ref, 'buyer_payment_reported_at', o.buyer_payment_reported_at,
    'payment_confirmed_at', o.payment_confirmed_at, 'paid_with', o.cod_method,
    'store', jsonb_build_object('slug', s.slug, 'name', s.name, 'logo_path', s.logo_path, 'city', s.city,
       'phone', case when s.show_phone then s.phone end, 'whatsapp', case when s.show_whatsapp then s.whatsapp end,
       'email', case when s.show_email then s.email end,
       'address', case when o.delivery_method = 'pickup' or s.show_address then s.address end,
       'pickup_note', case when o.delivery_method = 'pickup' then s.pickup_note end,
       'return_policy', s.return_policy,
       'momo', case when o.payment_method = 'momo_direct' then jsonb_build_object(
          'mtn', case when s.momo_mtn_enabled and s.momo_mtn_number is not null then jsonb_build_object(
             'number', s.momo_mtn_number, 'name', s.momo_mtn_name, 'instructions', s.momo_mtn_instructions) end,
          'orange', case when s.momo_orange_enabled and s.momo_orange_number is not null then jsonb_build_object(
             'number', s.momo_orange_number, 'name', s.momo_orange_name, 'instructions', s.momo_orange_instructions) end,
          'note', s.payment_note, 'proof_required', s.momo_proof_required,
          'source', 'seller_entered') end),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('product_id', l.product_id, 'listing_id', l.listing_id, 'name', l.name,
       'variant_label', l.variant_label, 'image_path', l.image_path, 'unit_price', l.unit_price, 'quantity', l.quantity,
       'line_total', l.line_total,
       'reviewed', exists (select 1 from public.market_reviews r where r.order_id = o.id and r.product_id = l.product_id),
       'review', (select jsonb_build_object('id', r.id, 'rating', r.rating, 'comment', r.comment, 'created_at', r.created_at,
                    'edited_at', r.edited_at, 'can_edit', r.edited_at is null and r.created_at > now() - interval '48 hours')
                  from public.market_reviews r where r.order_id = o.id and r.product_id = l.product_id))
       order by l.sort) from public.market_order_lines l where l.order_id = o.id), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'status', e.status, 'message', e.message,
       'actor', e.actor, 'created_at', e.created_at) order by e.created_at, e.id)
       from public.market_order_events e where e.order_id = o.id and e.visible_to_customer), '[]'::jsonb),
    'can_cancel', o.status = 'pending' and o.payment_status <> 'seller_confirmed',
    'can_pay', false,
    'can_report_payment', o.payment_method = 'momo_direct' and o.payment_status = 'cod_pending'
       and o.status in ('pending', 'confirmed', 'processing', 'dispatched'),
    'can_confirm_receipt', o.status = 'delivered' and o.receipt_status in ('awaiting', 'resolved'),
    'can_report_problem', o.receipt_status <> 'confirmed',
    'can_review', app.review_gate(o) is null,
    'signed_in_owner', coalesce(o.customer_user_id = auth.uid(), false));
end $$;

-- ===== 20261028000200_verified_premium.sql =====
insert into public.plans (code, name_en, name_fr, description_en, description_fr, price_monthly, price_annual,
                          features, limits, highlight, sort)
values ('verified_premium', 'Verified Premium', 'Premium vérifié',
  'Everything in Business, plus the verified blue tick, premium automations and the AI Business Manager.',
  'Tout Business, plus le badge bleu vérifié, les automatisations premium et le Gestionnaire IA.',
  5000, null,
  '{stocktaking,purchases,suppliers,expenses,customers_credit,staff,import,cash_reconciliation,basic_analytics,advanced_analytics,restock,reports_export,batch_tracking,ai_advisor,verified_badge,premium_automations,ai_business_manager}',
  '{"max_products": 10000, "max_sales_per_month": null, "max_staff": 15, "history_days": null, "ai_queries_per_month": 500}',
  true, 4)
on conflict (code) do nothing;
insert into public.app_config (key, value, is_public) values
  ('verification', '{"min_followers": 300, "min_account_age_days": 7, "validity_days": 365, "purge_after_days": 90}', false)
on conflict (key) do nothing;
alter table public.billing_payments drop constraint if exists billing_payments_status_check;
alter table public.billing_payments add constraint billing_payments_status_check
  check (status in ('pending', 'verified', 'rejected', 'cancelled', 'refunded'));
drop index if exists public.billing_payments_ref_unique;
create unique index billing_payments_ref_unique on public.billing_payments (method, lower(btrim(transaction_ref)))
  where status not in ('rejected', 'cancelled');
alter table public.stores add column if not exists verification_expires_at timestamptz;
create table if not exists public.verification_applications (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  applicant_id uuid references auth.users (id) on delete set null,
  legal_name text not null check (length(btrim(legal_name)) between 3 and 120),
  id_type text not null check (id_type in ('national_id', 'passport', 'business_registration')),
  id_last4 text check (id_last4 ~ '^[0-9]{0,4}$'),
  id_document_path text not null,
  business_document_path text,
  followers_at_submission int not null,
  account_age_days int not null,
  status text not null default 'submitted'
    check (status in ('submitted', 'under_review', 'approved', 'rejected', 'withdrawn', 'revoked', 'expired')),
  decision_reason text check (length(decision_reason) <= 1000),
  reviewed_by uuid,
  reviewed_at timestamptz,
  approved_at timestamptz,
  expires_at timestamptz,
  documents_purge_after timestamptz,
  submitted_at timestamptz not null default now(),
  check (split_part(id_document_path, '/', 1) = business_id::text and split_part(id_document_path, '/', 2) = 'verification')
);
create unique index if not exists verification_one_open on public.verification_applications (business_id)
  where status in ('submitted', 'under_review');
create index if not exists verification_applications_status on public.verification_applications (status, submitted_at);
alter table public.verification_applications enable row level security;
drop policy if exists verification_read on public.verification_applications;
create policy verification_read on public.verification_applications for select
  using (app.has_perm(business_id, 'store.manage') or app.is_platform_admin());
revoke all on public.verification_applications from anon, authenticated;
grant select on public.verification_applications to authenticated;
create or replace function app.verification_config(k text, dflt int) returns int
language sql stable as $$
  select coalesce((select (value ->> k)::int from public.app_config where key = 'verification'), dflt)
$$;
create or replace function app.blue_tick(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.stores s where s.business_id = bid and s.verification = 'verified'
                   and (s.verification_expires_at is null
                        or (s.verification_expires_at > now() and app.has_feature(bid, 'verified_badge'))))
$$;
create or replace function app.verification_eligibility(bid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  st public.stores; b public.businesses; followers int; age_days int; reasons text[] := '{}';
  min_followers int := app.verification_config('min_followers', 300);
  min_age int := app.verification_config('min_account_age_days', 7);
begin
  select * into st from public.stores where business_id = bid;
  if not found then
    return jsonb_build_object('eligible', false, 'reasons', jsonb_build_array('store_not_found'));
  end if;
  select * into b from public.businesses where id = bid;
  followers := (select count(distinct f.user_id)::int from public.market_store_follows f
                  join auth.users u on u.id = f.user_id
                 where f.business_id = bid and u.email_confirmed_at is not null
                   and f.user_id not in (select m.user_id from public.business_members m where m.business_id = bid));
  age_days := coalesce((select floor(extract(epoch from now() - min(u.created_at)) / 86400)::int
                          from public.business_members m join auth.users u on u.id = m.user_id
                         where m.business_id = bid and m.role = 'owner'), 0);
  if followers < min_followers then reasons := array_append(reasons, 'followers_below_minimum'); end if;
  if age_days < min_age then reasons := array_append(reasons, 'account_too_new'); end if;
  if st.status <> 'published' then reasons := array_append(reasons, 'store_not_published'); end if;
  if st.status = 'suspended' or b.status <> 'active' then reasons := array_append(reasons, 'account_suspended'); end if;
  if exists (select 1 from public.market_reports r where r.target_type = 'store' and r.target_id = bid
             and r.status in ('open', 'reviewing')) then reasons := array_append(reasons, 'open_report'); end if;
  if (select status from public.business_subscriptions where business_id = bid) = 'suspended' then
    reasons := array_append(reasons, 'subscription_suspended');
  end if;
  return jsonb_build_object('eligible', cardinality(reasons) = 0, 'followers', followers, 'min_followers', min_followers,
    'account_age_days', age_days, 'min_account_age_days', min_age, 'reasons', to_jsonb(reasons));
end $$;
create or replace function public.verification_apply(p_business uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare e jsonb; aid uuid; legal text := nullif(btrim(coalesce(p ->> 'legal_name', '')), '');
        idt text := coalesce(p ->> 'id_type', ''); idpath text := nullif(p ->> 'id_document_path', '');
        bpath text := nullif(p ->> 'business_document_path', ''); last4 text;
begin
  perform app.require_perm(p_business, 'store.manage');
  perform app.rate_limit('verify:' || p_business, 5, 86400);
  e := app.verification_eligibility(p_business);
  if not (e ->> 'eligible')::boolean then perform app.raise('verification_not_eligible', e); end if;
  if exists (select 1 from public.verification_applications where business_id = p_business and status in ('submitted', 'under_review')) then
    perform app.raise('verification_already_open');
  end if;
  if legal is null or length(legal) < 3 or length(legal) > 120 then perform app.raise('invalid_request'); end if;
  if idt not in ('national_id', 'passport', 'business_registration') then perform app.raise('invalid_request'); end if;
  if idpath is null or split_part(idpath, '/', 1) <> p_business::text or split_part(idpath, '/', 2) <> 'verification' then
    perform app.raise('invalid_document');
  end if;
  if bpath is not null and (split_part(bpath, '/', 1) <> p_business::text or split_part(bpath, '/', 2) <> 'verification') then
    perform app.raise('invalid_document');
  end if;
  last4 := right(regexp_replace(coalesce(p ->> 'id_last4', ''), '\D', '', 'g'), 4);
  insert into public.verification_applications (business_id, applicant_id, legal_name, id_type, id_last4, id_document_path,
    business_document_path, followers_at_submission, account_age_days)
  values (p_business, auth.uid(), legal, idt, nullif(last4, ''), idpath, bpath,
    (e ->> 'followers')::int, (e ->> 'account_age_days')::int)
  returning id into aid;
  update public.stores set verification = 'pending', verification_note = null where business_id = p_business;
  perform app.audit(p_business, 'verification.submitted', 'verification_application', aid::text, jsonb_build_object('id_type', idt));
  return aid;
end $$;
create or replace function public.verification_withdraw(p_application uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a public.verification_applications;
begin
  select * into a from public.verification_applications where id = p_application for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(a.business_id, 'store.manage');
  if a.status not in ('submitted', 'under_review') then perform app.raise('invalid_status'); end if;
  update public.verification_applications set status = 'withdrawn' where id = a.id;
  update public.stores set verification = 'unverified' where business_id = a.business_id and verification = 'pending';
  perform app.audit(a.business_id, 'verification.withdrawn', 'verification_application', a.id::text, null);
end $$;
create or replace function public.verification_status(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare st public.stores; a public.verification_applications;
begin
  if not app.is_member(p_business) then perform app.raise('not_found'); end if;
  select * into st from public.stores where business_id = p_business;
  select * into a from public.verification_applications where business_id = p_business order by submitted_at desc limit 1;
  return jsonb_build_object(
    'blue_tick', app.blue_tick(p_business),
    'verification', coalesce(st.verification, 'unverified'), 'verification_note', st.verification_note,
    'expires_at', st.verification_expires_at,
    'plan_code', (select plan_code from public.business_subscriptions where business_id = p_business),
    'premium_active', app.has_feature(p_business, 'verified_badge'),
    'eligibility', case when app.has_perm(p_business, 'store.manage') then app.verification_eligibility(p_business) end,
    'application', case when a.id is null then null else jsonb_build_object('id', a.id, 'status', a.status,
       'decision_reason', a.decision_reason, 'submitted_at', a.submitted_at, 'reviewed_at', a.reviewed_at,
       'expires_at', a.expires_at, 'legal_name', a.legal_name, 'id_type', a.id_type) end);
end $$;
create or replace function public.admin_verification_applications(p_status text default 'submitted')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'business_id', a.business_id, 'status', a.status,
      'business_name', b.name, 'slug', s.slug, 'legal_name', a.legal_name, 'id_type', a.id_type, 'id_last4', a.id_last4,
      'id_document_path', a.id_document_path, 'business_document_path', a.business_document_path,
      'submitted_at', a.submitted_at, 'decision_reason', a.decision_reason, 'expires_at', a.expires_at,
      'eligibility', app.verification_eligibility(a.business_id),
      'plan_code', (select plan_code from public.business_subscriptions where business_id = a.business_id))
      order by a.submitted_at)
    from public.verification_applications a join public.businesses b on b.id = a.business_id
    left join public.stores s on s.business_id = a.business_id
    where p_status is null or a.status = p_status), '[]'::jsonb);
end $$;
create or replace function public.admin_review_verification(p_application uuid, p_decision text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.verification_applications; e jsonb;
        validity int := app.verification_config('validity_days', 365);
        purge int := app.verification_config('purge_after_days', 90);
        reason text := nullif(left(btrim(coalesce(p_reason, '')), 1000), '');
begin
  perform app.require_platform_admin();
  select * into a from public.verification_applications where id = p_application for update;
  if not found then perform app.raise('not_found'); end if;
  if a.status not in ('submitted', 'under_review') then perform app.raise('already_reviewed'); end if;
  if p_decision = 'approve' then
    e := app.verification_eligibility(a.business_id);
    if not (e ->> 'eligible')::boolean then perform app.raise('verification_not_eligible', e); end if;
    update public.verification_applications set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(),
           approved_at = now(), expires_at = now() + make_interval(days => validity), decision_reason = reason,
           documents_purge_after = now() + make_interval(days => purge) where id = a.id;
    update public.stores set verification = 'verified', verification_expires_at = now() + make_interval(days => validity),
           verification_note = null where business_id = a.business_id;
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (a.business_id, 'verification_decision', 'success',
            jsonb_build_object('decision', 'approved', 'expires_at', now() + make_interval(days => validity)),
            '/app/store', 'store.manage');
  elsif p_decision = 'reject' then
    if reason is null then perform app.raise('reason_required'); end if;
    update public.verification_applications set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(),
           decision_reason = reason, documents_purge_after = now() + make_interval(days => purge) where id = a.id;
    update public.stores set verification = 'rejected', verification_note = reason where business_id = a.business_id;
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (a.business_id, 'verification_decision', 'warning',
            jsonb_build_object('decision', 'rejected', 'reason', reason), '/app/store', 'store.manage');
  else
    perform app.raise('invalid_request');
  end if;
  perform app.admin_audit('admin.verification_' || p_decision, 'verification_application', a.id::text, a.business_id,
                          jsonb_build_object('reason', reason));
  return jsonb_build_object('status', (select status from public.verification_applications where id = a.id));
end $$;
create or replace function public.admin_revoke_verification(p_business uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare reason text := nullif(left(btrim(coalesce(p_reason, '')), 1000), '');
begin
  perform app.require_platform_admin();
  if reason is null then perform app.raise('reason_required'); end if;
  if not exists (select 1 from public.stores where business_id = p_business and verification = 'verified') then
    perform app.raise('not_verified');
  end if;
  update public.stores set verification = 'unverified', verification_expires_at = null, verification_note = reason
   where business_id = p_business;
  update public.verification_applications set status = 'revoked', decision_reason = reason
   where business_id = p_business and status = 'approved';
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (p_business, 'verification_decision', 'warning', jsonb_build_object('decision', 'revoked', 'reason', reason),
          '/app/store', 'store.manage');
  perform app.admin_audit('admin.verification_revoked', 'store', p_business::text, p_business, jsonb_build_object('reason', reason));
end $$;
create or replace function app.expire_verifications() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select business_id from public.stores where verification = 'verified' and verification_expires_at < now() loop
    update public.stores set verification = 'unverified', verification_note = 'Verification expired. Apply again to show the blue tick.'
     where business_id = r.business_id;
    update public.verification_applications set status = 'expired' where business_id = r.business_id and status = 'approved';
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (r.business_id, 'verification_expired', 'info', '{}'::jsonb, '/app/store', 'store.manage',
            'verification_expired:' || r.business_id || ':' || now()::date) on conflict do nothing;
    n := n + 1;
  end loop;
  return n;
end $$;
create or replace function public.billing_payment_cancel(p_payment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare bp public.billing_payments;
begin
  select * into bp from public.billing_payments where id = p_payment for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(bp.business_id, 'billing.manage');
  if bp.status <> 'pending' then perform app.raise('invalid_status'); end if;
  update public.billing_payments set status = 'cancelled', reviewed_at = now(), review_note = 'Cancelled by the business'
   where id = bp.id;
  perform app.audit(bp.business_id, 'billing.payment_cancelled', 'billing_payment', bp.id::text, null);
end $$;
create or replace function public.admin_refund_billing_payment(p_payment uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare bp public.billing_payments; s public.business_subscriptions; reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform app.require_platform_admin();
  if reason is null then perform app.raise('reason_required'); end if;
  select * into bp from public.billing_payments where id = p_payment for update;
  if not found then perform app.raise('not_found'); end if;
  if bp.status <> 'verified' then perform app.raise('invalid_status'); end if;
  update public.billing_payments set status = 'refunded', review_note = reason, reviewed_by = auth.uid(), reviewed_at = now()
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
create or replace function app.storage_can_write(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select case (storage.foldername(object_name))[2]
    when 'logos' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'settings.manage')
    when 'products' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'products.manage')
    when 'purchases' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'purchases.manage')
    when 'suppliers' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'suppliers.manage')
    when 'expenses' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'expenses.manage')
    when 'billing' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'billing.manage')
    when 'stock' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'stock.adjust')
    when 'orders' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'orders.manage')
    when 'verification' then app.has_perm(app.try_uuid((storage.foldername(object_name))[1]), 'store.manage')
    else false end
$$;
create or replace function app.storage_can_read(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select app.can_read(app.try_uuid((storage.foldername(object_name))[1]))
      or (app.is_platform_admin() and (storage.foldername(object_name))[2] in ('billing', 'verification'))
$$;
create or replace function app.store_card(bid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('business_id', s.business_id, 'slug', s.slug, 'name', s.name, 'tagline', s.tagline,
    'logo_path', s.logo_path, 'city', s.city, 'verified', app.blue_tick(s.business_id),
    'rating_avg', s.rating_avg, 'rating_count', s.rating_count, 'business_type', b.category,
    'cover_path', case when app.has_feature(s.business_id, 'store_customization') then s.cover_path end,
    'brand_color', case when app.has_feature(s.business_id, 'store_customization') then s.brand_color end,
    'products', (select count(*) from public.products p where p.business_id = s.business_id and p.online_published
                  and p.status = 'active' and not p.admin_hidden and p.variant_of is null))
  from public.stores s join public.businesses b on b.id = s.business_id where s.business_id = bid
$$;
create or replace function app.product_card(p_listing uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', p.id, 'name', p.name, 'brand', p.brand,
    'image', p.online_images[1], 'unit', p.base_unit,
    'price', o.min_price, 'max_price', o.max_price, 'compare_at_price',
      case when p.compare_at_price > o.min_price then p.compare_at_price end,
    'available', least(o.available, 99), 'options', o.n,
    'stock', case when coalesce(o.available, 0) <= 0 then 'out'
                  when coalesce(p.min_stock, 0) > 0 and o.available <= p.min_stock then 'low'
                  else 'in' end,
    'category', c.name, 'subcategory', p.subcategory,
    'condition', p.condition, 'sold', p.single_item and coalesce(o.available, 0) <= 0,
    'rating_avg', r.avg, 'rating_count', coalesce(r.n, 0),
    'store', jsonb_build_object('slug', s.slug, 'name', s.name, 'city', s.city, 'verified', app.blue_tick(s.business_id),
                                'logo_path', s.logo_path))
  from public.products p
  join public.stores s on s.business_id = p.business_id
  left join public.categories c on c.id = p.category_id
  cross join lateral (select min(x.price) min_price, max(x.price) max_price, sum(x.available) available, count(*) n
                        from app.listing_options(p.id) x) o
  left join lateral (select round(avg(rating), 1) avg, count(*) n from public.market_reviews
                      where listing_id = p.id and status = 'visible') r on true
  where p.id = p_listing
$$;
create or replace function public.market_home(p_city text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare ck text := app.city_key(p_city);
begin
  return jsonb_build_object(
    'types', coalesce((select jsonb_agg(jsonb_build_object('type', t.category, 'products', t.n) order by t.n desc) from (
                  select b.category, count(*) n from public.products pr
                    join public.stores s on s.business_id = pr.business_id and s.status = 'published'
                    join public.businesses b on b.id = pr.business_id and b.status = 'active'
                   where pr.online_published and pr.status = 'active' and not pr.admin_hidden and pr.variant_of is null
                     and (p_city is null or app.city_key(s.city) = ck or app.city_key(s.region) = ck)
                   group by b.category) t), '[]'::jsonb),
    'stores', coalesce((select jsonb_agg(app.store_card(x.business_id)) from (
                  select s.business_id from public.stores s join public.businesses b on b.id = s.business_id
                   where s.status = 'published' and b.status = 'active'
                     and (p_city is null or app.city_key(s.city) = ck or app.city_key(s.region) = ck)
                   order by (app.blue_tick(s.business_id)) desc, s.rating_count desc, s.published_at desc limit 12) x), '[]'::jsonb),
    'cities', coalesce((select jsonb_agg(jsonb_build_object('city', x.c, 'shops', x.n) order by x.n desc, x.c) from (
                  select min(btrim(s.city)) c, count(*) n from public.stores s join public.businesses b on b.id = s.business_id
                   where s.status = 'published' and b.status = 'active' and coalesce(btrim(s.city), '') <> ''
                   group by app.city_key(s.city)) x), '[]'::jsonb),
    'city_shops', (select count(*) from public.stores s join public.businesses b on b.id = s.business_id
                    where s.status = 'published' and b.status = 'active'
                      and (p_city is null or app.city_key(s.city) = ck or app.city_key(s.region) = ck)),
    'city_products', (select count(*) from public.products pr
                        join public.stores s on s.business_id = pr.business_id and s.status = 'published'
                        join public.businesses b on b.id = pr.business_id and b.status = 'active'
                       where pr.online_published and pr.status = 'active' and not pr.admin_hidden and pr.variant_of is null
                         and (p_city is null or app.city_key(s.city) = ck or app.city_key(s.region) = ck)),
    'latest', (public.market_search(jsonb_build_object('sort', 'newest', 'page_size', 12, 'city', p_city)) -> 'items'));
end $$;
create or replace function public.market_store(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.stores; b public.businesses; custom boolean;
begin
  select * into s from public.stores where lower(slug) = lower(btrim(p_slug));
  if not found then return null; end if;
  select * into b from public.businesses where id = s.business_id;
  if s.status <> 'published' or b.status <> 'active' then
    return jsonb_build_object('slug', s.slug, 'name', s.name, 'unavailable', true);
  end if;
  custom := app.has_feature(s.business_id, 'store_customization');
  return jsonb_build_object(
    'business_id', s.business_id, 'slug', s.slug, 'name', s.name, 'tagline', s.tagline, 'description', s.description,
    'logo_path', s.logo_path, 'cover_path', case when custom then s.cover_path end,
    'brand_color', case when custom then s.brand_color end,
    'business_type', b.category, 'city', s.city, 'region', s.region, 'neighborhood', s.neighborhood, 'service_area', s.service_area,
    'address', case when s.show_address then s.address end,
    'phone', case when s.show_phone then s.phone end,
    'whatsapp', case when s.show_whatsapp then s.whatsapp end,
    'email', case when s.show_email then s.email end,
    'facebook_url', s.facebook_url, 'instagram_url', s.instagram_url, 'tiktok_url', s.tiktok_url,
    'opening_hours', s.opening_hours, 'hours_note', s.hours_note, 'delivery_note', s.delivery_note,
    'pickup_enabled', s.pickup_enabled, 'pickup_note', s.pickup_note, 'cod_enabled', s.cod_enabled,
    'online_payment_enabled', false,
    'momo_direct_enabled', s.momo_direct_enabled and coalesce(s.momo_mtn_number, s.momo_orange_number) is not null,
    'momo_networks', array_remove(array[case when s.momo_direct_enabled and s.momo_mtn_number is not null then 'mtn' end,
                                        case when s.momo_direct_enabled and s.momo_orange_number is not null then 'orange' end], null),
    'payment_note', s.payment_note, 'return_policy', s.return_policy,
    'min_order_amount', s.min_order_amount, 'currency', b.currency,
    'verified', app.blue_tick(s.business_id), 'rating_avg', s.rating_avg, 'rating_count', s.rating_count,
    'joined', s.published_at,
    'zones', coalesce((select jsonb_agg(jsonb_build_object('id', z.id, 'name', z.name, 'fee', z.fee, 'eta', z.eta, 'regions', z.regions, 'localities', z.localities) order by z.sort, z.name)
                       from public.store_delivery_zones z where z.business_id = s.business_id and z.active), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'products', t.n) order by t.sort, t.name) from (
                     select c.name, min(c.sort_order) sort, count(*) n from public.products pr join public.categories c on c.id = pr.category_id
                      where pr.business_id = s.business_id and pr.online_published and pr.status = 'active' and not pr.admin_hidden
                        and pr.variant_of is null group by c.name) t), '[]'::jsonb),
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('rating', r.rating, 'comment', r.comment, 'author', r.author_name,
                     'product', pr.name, 'reply', r.seller_reply, 'created_at', r.created_at) order by r.created_at desc)
                   from (select * from public.market_reviews where business_id = s.business_id and status = 'visible'
                          order by created_at desc limit 10) r join public.products pr on pr.id = r.product_id), '[]'::jsonb));
end $$;
create or replace function public.market_shops(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_city text := nullif(btrim(coalesce(p ->> 'city', '')), '');
  v_type text := nullif(p ->> 'type', '');
  v_q text := nullif(btrim(coalesce(p ->> 'q', '')), '');
  size int := least(greatest(coalesce((p ->> 'page_size')::int, 24), 1), 60);
  pg int := greatest(coalesce((p ->> 'page')::int, 1), 1);
  res jsonb;
begin
  with base as (
    select s.business_id, s.name, s.verification, s.rating_count, s.published_at
      from public.stores s join public.businesses b on b.id = s.business_id
     where s.status = 'published' and b.status = 'active'
       and (v_city is null or app.city_key(s.city) = app.city_key(v_city) or app.city_key(s.region) = app.city_key(v_city))
       and (v_type is null or b.category = v_type)
       and (v_q is null or s.name ilike app.like_term(v_q) or s.tagline ilike app.like_term(v_q))
  ), ranked as (
    select business_id, row_number() over (order by app.blue_tick(business_id) desc, rating_count desc, published_at desc, name) ord
      from base
  )
  select jsonb_build_object(
    'total', (select count(*) from base), 'page', pg, 'page_size', size,
    'items', coalesce((select jsonb_agg(app.store_card(r.business_id) order by r.ord) from ranked r
                        where r.ord > (pg - 1) * size and r.ord <= pg * size), '[]'::jsonb))
    into res;
  return res;
end $$;

commit;
