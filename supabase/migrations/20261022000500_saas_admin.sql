-- Onboarding, staff, billing verification, platform administration, notifications,
-- support, announcements, AI usage tracking, imports and data export.

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  type text not null,
  severity text not null default 'info' check (severity in ('info', 'success', 'warning', 'critical')),
  params jsonb not null default '{}'::jsonb,
  link text,
  required_perm text,
  dedupe_key text,
  created_at timestamptz not null default now()
);
create unique index notifications_dedupe on public.notifications (business_id, dedupe_key) where dedupe_key is not null;
create index notifications_business on public.notifications (business_id, created_at desc);

create table public.notification_reads (
  notification_id uuid not null references public.notifications (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (notification_id, user_id)
);

create table public.support_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses (id) on delete set null,
  user_id uuid references auth.users (id) on delete set null,
  name text,
  email text,
  phone text,
  category text not null default 'question' check (category in ('question', 'bug', 'billing', 'feedback',
                                                                  'account_closure', 'data_export', 'other')),
  subject text not null check (length(btrim(subject)) between 3 and 150),
  message text not null check (length(btrim(message)) between 5 and 5000),
  status text not null default 'open' check (status in ('open', 'in_progress', 'resolved', 'closed')),
  admin_response text,
  responded_by uuid,
  responded_at timestamptz,
  created_at timestamptz not null default now()
);
create index support_requests_status on public.support_requests (status, created_at desc);

create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  title_en text not null,
  title_fr text not null,
  body_en text,
  body_fr text,
  level text not null default 'info' check (level in ('info', 'warning', 'maintenance')),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  active boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now()
);

create table public.support_access_grants (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  granted_by uuid not null,
  reason text not null,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.ai_queries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  user_id uuid,
  question text not null,
  answer text,
  model text,
  status text not null default 'started' check (status in ('started', 'completed', 'failed', 'rejected', 'fallback')),
  period_from date,
  period_to date,
  input_tokens int,
  output_tokens int,
  error text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index ai_queries_business on public.ai_queries (business_id, created_at desc);

create table public.rate_limits (
  key text not null,
  window_start timestamptz not null,
  count int not null default 0,
  primary key (key, window_start)
);

-- Support access: a platform admin may read a business's records only while the
-- owner has granted (time-limited, revocable, audited) support access.
create or replace function app.can_read(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_member(bid) or (
    app.is_platform_admin() and exists (
      select 1 from public.support_access_grants g
      where g.business_id = bid and g.revoked_at is null and g.expires_at > now()))
$$;

create or replace function app.rate_limit(k text, max_count int, window_seconds int) returns void
language plpgsql security definer set search_path = public as $$
declare ws timestamptz := to_timestamp(floor(extract(epoch from now()) / window_seconds) * window_seconds); c int;
begin
  insert into public.rate_limits as r (key, window_start, count) values (k, ws, 1)
  on conflict (key, window_start) do update set count = r.count + 1 returning count into c;
  if c > max_count then perform app.raise('rate_limited'); end if;
  delete from public.rate_limits where window_start < now() - interval '2 days';
end $$;

-- ---------------------------------------------------------------------------
-- Onboarding
-- ---------------------------------------------------------------------------
create or replace function app.default_categories(cat text, lang text) returns text[]
language sql immutable as $$
  select case
    when cat = 'grocery' then case when lang = 'fr'
      then array['Alimentation', 'Boissons', 'Entretien ménager', 'Hygiène & beauté', 'Divers']
      else array['Food', 'Beverages', 'Household', 'Personal Care', 'Others'] end
    when cat = 'drinks' then case when lang = 'fr'
      then array['Bières', 'Boissons gazeuses', 'Eaux', 'Jus', 'Vins & spiritueux', 'Emballages']
      else array['Beer', 'Soft Drinks', 'Water', 'Juice', 'Wine & Spirits', 'Crates & Empties'] end
    when cat = 'hardware' then case when lang = 'fr'
      then array['Matériaux de construction', 'Outillage', 'Électricité', 'Plomberie', 'Peinture', 'Divers']
      else array['Building Materials', 'Tools', 'Electrical', 'Plumbing', 'Paint', 'Others'] end
    when cat = 'electronics' then case when lang = 'fr'
      then array['Téléphones', 'Accessoires', 'Électroménager', 'Informatique', 'Divers']
      else array['Phones', 'Accessories', 'Appliances', 'Computers', 'Others'] end
    when cat = 'fashion' then case when lang = 'fr'
      then array['Vêtements', 'Chaussures', 'Sacs & accessoires', 'Tissus', 'Divers']
      else array['Clothing', 'Shoes', 'Bags & Accessories', 'Fabrics', 'Others'] end
    when cat = 'cosmetics' then case when lang = 'fr'
      then array['Soins de la peau', 'Cheveux', 'Maquillage', 'Parfums', 'Hygiène', 'Divers']
      else array['Skin Care', 'Hair Care', 'Make-up', 'Fragrances', 'Hygiene', 'Others'] end
    else case when lang = 'fr'
      then array['Alimentation & boissons', 'Entretien ménager', 'Hygiène & beauté', 'Matériaux', 'Électronique', 'Divers']
      else array['Food & Beverages', 'Household', 'Personal Care', 'Building Materials', 'Electronics', 'Others'] end
  end
$$;

create or replace function public.create_business(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := app.require_auth(); c public.countries; bid uuid; lang text; cat text; nm text;
begin
  perform app.rate_limit('create_business:' || uid, 5, 86400);
  if (select count(*) from public.business_members where user_id = uid and role = 'owner' and active) >= 5 then
    perform app.raise('too_many_businesses');
  end if;
  select * into c from public.countries where code = coalesce(nullif(p ->> 'country_code', ''), 'CM');
  if not found or not c.registration_enabled then perform app.raise('country_not_available'); end if;
  lang := case when p ->> 'language' in ('en', 'fr') then p ->> 'language' else c.default_language end;
  cat := coalesce(nullif(p ->> 'category', ''), 'general');
  if cat not in ('grocery', 'general', 'drinks', 'hardware', 'electronics', 'fashion', 'cosmetics', 'other') then
    perform app.raise('invalid_category');
  end if;
  nm := btrim(coalesce(p ->> 'name', ''));
  if length(nm) < 2 then perform app.raise('business_name_required'); end if;

  insert into public.businesses (name, owner_name, email, phone, address, city, country_code, currency,
    currency_decimals, timezone, language, category, reporting_start_date, created_by)
  values (nm, nullif(p ->> 'owner_name', ''), nullif(p ->> 'email', ''), nullif(p ->> 'phone', ''),
    nullif(p ->> 'address', ''), nullif(p ->> 'city', ''), c.code, c.currency, c.currency_decimals, c.timezone,
    lang, cat, coalesce(nullif(p ->> 'reporting_start_date', '')::date, (now() at time zone c.timezone)::date), uid)
  returning id into bid;

  insert into public.business_settings (business_id) values (bid);
  insert into public.business_members (business_id, user_id, role, display_name)
  values (bid, uid, 'owner', nullif(p ->> 'owner_name', ''));
  perform app.init_accounts(bid);
  perform app.init_subscription(bid);
  insert into public.categories (business_id, name)
  select bid, x from unnest(app.default_categories(cat, lang)) x on conflict do nothing;

  update public.profiles set full_name = coalesce(nullif(p ->> 'owner_name', ''), full_name),
         phone = coalesce(nullif(p ->> 'phone', ''), phone), language = lang
   where id = uid;
  perform app.audit(bid, 'business.created', 'business', bid::text, jsonb_build_object('name', nm, 'category', cat));
  return bid;
end $$;

create or replace function public.update_business(p_business uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'settings.manage');
  if p ? 'name' and length(btrim(p ->> 'name')) < 2 then perform app.raise('business_name_required'); end if;
  update public.businesses set
    name = coalesce(btrim(p ->> 'name'), name),
    owner_name = case when p ? 'owner_name' then nullif(p ->> 'owner_name', '') else owner_name end,
    email = case when p ? 'email' then nullif(p ->> 'email', '') else email end,
    phone = case when p ? 'phone' then nullif(p ->> 'phone', '') else phone end,
    address = case when p ? 'address' then nullif(p ->> 'address', '') else address end,
    city = case when p ? 'city' then nullif(p ->> 'city', '') else city end,
    language = case when p ->> 'language' in ('en', 'fr') then p ->> 'language' else language end,
    category = case when p ->> 'category' in ('grocery', 'general', 'drinks', 'hardware', 'electronics', 'fashion', 'cosmetics', 'other')
                    then p ->> 'category' else category end,
    logo_path = case when p ? 'logo_path' then nullif(p ->> 'logo_path', '') else logo_path end,
    tax_id = case when p ? 'tax_id' then nullif(p ->> 'tax_id', '') else tax_id end,
    trade_register = case when p ? 'trade_register' then nullif(p ->> 'trade_register', '') else trade_register end,
    reporting_start_date = coalesce(nullif(p ->> 'reporting_start_date', '')::date, reporting_start_date)
  where id = p_business;
  perform app.audit(p_business, 'business.updated', 'business', p_business::text, p);
end $$;

create or replace function public.update_business_settings(p_business uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'settings.manage');
  update public.business_settings set
    allow_negative_stock = coalesce((p ->> 'allow_negative_stock')::boolean, allow_negative_stock),
    cashier_max_discount_pct = coalesce((p ->> 'cashier_max_discount_pct')::numeric, cashier_max_discount_pct),
    allow_credit_sales = coalesce((p ->> 'allow_credit_sales')::boolean, allow_credit_sales),
    tax_enabled = coalesce((p ->> 'tax_enabled')::boolean, tax_enabled),
    tax_rate = coalesce((p ->> 'tax_rate')::numeric, tax_rate),
    tax_label = coalesce(nullif(p ->> 'tax_label', ''), tax_label),
    default_lead_time_days = coalesce((p ->> 'default_lead_time_days')::int, default_lead_time_days),
    safety_stock_days = coalesce((p ->> 'safety_stock_days')::int, safety_stock_days),
    planning_days = coalesce((p ->> 'planning_days')::int, planning_days),
    slow_moving_days = coalesce((p ->> 'slow_moving_days')::int, slow_moving_days),
    expiry_alert_days = coalesce((p ->> 'expiry_alert_days')::int, expiry_alert_days),
    weak_margin_pct = coalesce((p ->> 'weak_margin_pct')::numeric, weak_margin_pct),
    low_stock_default = coalesce((p ->> 'low_stock_default')::numeric, low_stock_default),
    receipt_header = case when p ? 'receipt_header' then nullif(p ->> 'receipt_header', '') else receipt_header end,
    receipt_footer = case when p ? 'receipt_footer' then nullif(p ->> 'receipt_footer', '') else receipt_footer end
  where business_id = p_business;
  perform app.audit(p_business, 'settings.updated', 'business_settings', p_business::text, p);
end $$;

create or replace function public.get_my_context()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return null; end if;
  return jsonb_build_object(
    'user_id', uid,
    'email', (select email from auth.users where id = uid),
    'email_confirmed', (select email_confirmed_at is not null from auth.users where id = uid),
    'profile', (select to_jsonb(pr) from public.profiles pr where pr.id = uid),
    'is_platform_admin', app.is_platform_admin(),
    'pending_invites', (select count(*) from public.business_invites i
                        where lower(i.email) = lower((select email from auth.users where id = uid))
                          and i.accepted_at is null and i.revoked_at is null),
    'businesses', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', b.id, 'name', b.name, 'role', m.role, 'status', b.status, 'currency', b.currency,
        'currency_decimals', b.currency_decimals, 'language', b.language, 'timezone', b.timezone,
        'category', b.category, 'logo_path', b.logo_path, 'country_code', b.country_code,
        'permissions', to_jsonb(app.my_permissions(b.id)),
        'subscription', app.subscription_info(b.id),
        'plan', (select jsonb_build_object('code', ep.code, 'name_en', ep.name_en, 'name_fr', ep.name_fr,
                                           'features', ep.features, 'limits', ep.limits)
                 from app.effective_plan(b.id) ep)
      ) order by b.created_at)
      from public.business_members m join public.businesses b on b.id = m.business_id
      where m.user_id = uid and m.active and b.status <> 'closed'), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------------
create or replace function public.invite_member(p_business uuid, p_email text, p_role text,
  p_display_name text default null, p_permissions jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare iid uuid; em text := lower(btrim(p_email));
begin
  perform app.require_perm(p_business, 'staff.manage');
  perform app.require_feature(p_business, 'staff');
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then perform app.raise('invalid_email'); end if;
  if p_role not in ('manager', 'cashier') then perform app.raise('invalid_role'); end if;
  if exists (select 1 from public.business_members m join auth.users u on u.id = m.user_id
             where m.business_id = p_business and lower(u.email) = em and m.active) then
    perform app.raise('already_member');
  end if;
  perform app.check_limit(p_business, 'max_staff');
  insert into public.business_invites (business_id, email, role, permissions, display_name, invited_by)
  values (p_business, em, p_role, coalesce(p_permissions, '{}'), p_display_name, auth.uid())
  returning id into iid;
  perform app.audit(p_business, 'staff.invited', 'invite', iid::text, jsonb_build_object('email', em, 'role', p_role));
  return iid;
end $$;

create or replace function public.revoke_invite(p_invite uuid)
returns void language plpgsql security definer set search_path = public as $$
declare i public.business_invites;
begin
  select * into i from public.business_invites where id = p_invite;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(i.business_id, 'staff.manage');
  update public.business_invites set revoked_at = now() where id = p_invite and accepted_at is null;
  perform app.audit(i.business_id, 'staff.invite_revoked', 'invite', p_invite::text);
end $$;

create or replace function public.accept_invites()
returns int language plpgsql security definer set search_path = public as $$
declare uid uuid := app.require_auth(); u auth.users; i record; n int := 0;
begin
  select * into u from auth.users where id = uid;
  if u.email_confirmed_at is null then return 0; end if;   -- only verified addresses can claim invites
  for i in select * from public.business_invites
           where lower(email) = lower(u.email) and accepted_at is null and revoked_at is null for update loop
    insert into public.business_members (business_id, user_id, role, permissions, display_name, invited_by)
    values (i.business_id, uid, i.role, i.permissions, i.display_name, i.invited_by)
    on conflict (business_id, user_id) do update set active = true, role = excluded.role,
       permissions = excluded.permissions;
    update public.business_invites set accepted_at = now(), accepted_by = uid where id = i.id;
    perform app.audit(i.business_id, 'staff.joined', 'member', uid::text, jsonb_build_object('role', i.role));
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.update_member(p_member uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare m public.business_members;
begin
  select * into m from public.business_members where id = p_member;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(m.business_id, 'staff.manage');
  if m.role = 'owner' then perform app.raise('cannot_modify_owner'); end if;
  if m.user_id = auth.uid() then perform app.raise('cannot_modify_self'); end if;
  if p ? 'role' and p ->> 'role' not in ('manager', 'cashier') then perform app.raise('invalid_role'); end if;
  if coalesce((p ->> 'active')::boolean, m.active) and not m.active then
    perform app.check_limit(m.business_id, 'max_staff');
  end if;
  update public.business_members set
    role = coalesce(p ->> 'role', role),
    permissions = coalesce(p -> 'permissions', permissions),
    active = coalesce((p ->> 'active')::boolean, active),
    display_name = case when p ? 'display_name' then nullif(p ->> 'display_name', '') else display_name end
  where id = p_member;
  perform app.audit(m.business_id, 'staff.updated', 'member', p_member::text, p);
end $$;

create or replace function public.transfer_ownership(p_business uuid, p_member uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m public.business_members;
begin
  perform app.require_auth();
  if app.member_role(p_business) <> 'owner' then perform app.raise('permission_denied'); end if;
  select * into m from public.business_members where id = p_member and business_id = p_business and active;
  if not found or m.user_id = auth.uid() then perform app.raise('invalid_member'); end if;
  update public.business_members set role = 'manager' where business_id = p_business and user_id = auth.uid();
  update public.business_members set role = 'owner', permissions = '{}' where id = p_member;
  perform app.audit(p_business, 'business.ownership_transferred', 'member', p_member::text);
end $$;

-- ---------------------------------------------------------------------------
-- Billing (manual verification workflow)
-- ---------------------------------------------------------------------------
create or replace function public.submit_billing_payment(p_business uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare pl public.plans; per text := coalesce(p ->> 'billing_period', 'monthly'); expected numeric; pid uuid;
begin
  perform app.require_perm(p_business, 'billing.manage');
  perform app.rate_limit('billing:' || p_business, 10, 86400);
  select * into pl from public.plans where code = p ->> 'plan_code' and active and price_monthly > 0;
  if not found then perform app.raise('invalid_plan'); end if;
  if per not in ('monthly', 'annual') then perform app.raise('invalid_billing_period'); end if;
  expected := case when per = 'annual' then coalesce(pl.price_annual, pl.price_monthly * 12) else pl.price_monthly end;
  if (select count(*) from public.billing_payments where business_id = p_business and status = 'pending') >= 3 then
    perform app.raise('too_many_pending_payments');
  end if;
  begin
    insert into public.billing_payments (business_id, plan_code, billing_period, amount, expected_amount, method,
      transaction_ref, payer_phone, payer_name, proof_path, note, submitted_by)
    values (p_business, pl.code, per, coalesce((p ->> 'amount')::numeric, expected), expected, p ->> 'method',
      btrim(p ->> 'transaction_ref'), nullif(p ->> 'payer_phone', ''), nullif(p ->> 'payer_name', ''),
      nullif(p ->> 'proof_path', ''), nullif(p ->> 'note', ''), auth.uid())
    returning id into pid;
  exception when unique_violation then
    perform app.raise('duplicate_transaction_reference');
  end;
  perform app.audit(p_business, 'billing.payment_submitted', 'billing_payment', pid::text,
                    jsonb_build_object('plan', pl.code, 'amount', expected, 'method', p ->> 'method'));
  return pid;
end $$;

create or replace function public.cancel_subscription(p_business uuid, p_cancel boolean default true)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'billing.manage');
  update public.business_subscriptions set cancel_at_period_end = p_cancel where business_id = p_business;
  perform app.audit(p_business, case when p_cancel then 'subscription.cancel_requested' else 'subscription.resumed' end,
                    'subscription', p_business::text);
end $$;

-- ---------------------------------------------------------------------------
-- Platform administration
-- ---------------------------------------------------------------------------
create or replace function app.require_platform_admin() returns void
language plpgsql stable as $$
begin
  perform app.require_auth();
  if not app.is_platform_admin() then perform app.raise('permission_denied'); end if;
end $$;

-- Run once by the deployer (SQL editor / psql as postgres). Not callable through the API.
create or replace function app.bootstrap_platform_admin(p_email text) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  select id into uid from auth.users where lower(email) = lower(btrim(p_email));
  if uid is null then raise exception 'No user with email % - sign up first', p_email; end if;
  insert into public.platform_admins (user_id, note) values (uid, 'bootstrap') on conflict do nothing;
  insert into public.audit_logs (action, entity, entity_id, details)
  values ('platform.admin_bootstrapped', 'user', uid::text, jsonb_build_object('email', p_email));
  return uid;
end $$;
revoke all on function app.bootstrap_platform_admin(text) from public, anon, authenticated;

create or replace function public.admin_review_billing_payment(p_payment uuid, p_approve boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare bp public.billing_payments; s public.business_subscriptions; start_at timestamptz; end_at timestamptz;
begin
  perform app.require_platform_admin();
  select * into bp from public.billing_payments where id = p_payment for update;
  if not found then perform app.raise('not_found'); end if;
  if bp.status <> 'pending' then perform app.raise('already_reviewed'); end if;
  if not p_approve then
    if coalesce(btrim(p_note), '') = '' then perform app.raise('reason_required'); end if;
    update public.billing_payments set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(),
           review_note = p_note where id = p_payment;
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (bp.business_id, 'billing_payment_rejected', 'warning',
            jsonb_build_object('reference', bp.transaction_ref, 'note', p_note), '/app/billing', 'billing.manage');
  else
    select * into s from public.business_subscriptions where business_id = bp.business_id for update;
    -- Extend from the current paid period end when still running, otherwise from now.
    start_at := case when s.status in ('active', 'cancelled') and s.plan_code = bp.plan_code
                          and s.current_period_end > now() then s.current_period_end else now() end;
    end_at := start_at + case when bp.billing_period = 'annual' then interval '1 year' else interval '1 month' end;
    insert into public.business_subscriptions (business_id, plan_code, status, billing_period, current_period_start,
                                               current_period_end, cancel_at_period_end)
    values (bp.business_id, bp.plan_code, 'active', bp.billing_period, start_at, end_at, false)
    on conflict (business_id) do update set plan_code = excluded.plan_code, status = 'active',
      billing_period = excluded.billing_period, current_period_start = excluded.current_period_start,
      current_period_end = excluded.current_period_end, cancel_at_period_end = false, suspended_reason = null;
    update public.billing_payments set status = 'verified', reviewed_by = auth.uid(), reviewed_at = now(),
           review_note = p_note, period_start = start_at, period_end = end_at where id = p_payment;
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (bp.business_id, 'billing_payment_verified', 'success',
            jsonb_build_object('plan', bp.plan_code, 'period_end', end_at), '/app/billing', 'billing.manage');
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity, entity_id, details)
  values (bp.business_id, auth.uid(), case when p_approve then 'billing.payment_verified' else 'billing.payment_rejected' end,
          'billing_payment', p_payment::text, jsonb_build_object('note', p_note, 'amount', bp.amount,
          'expected', bp.expected_amount, 'reference', bp.transaction_ref));
  return jsonb_build_object('status', case when p_approve then 'verified' else 'rejected' end, 'period_end', end_at);
end $$;

create or replace function public.admin_set_subscription(p_business uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if coalesce(btrim(p ->> 'reason'), '') = '' then perform app.raise('reason_required'); end if;
  update public.business_subscriptions set
    plan_code = coalesce(p ->> 'plan_code', plan_code),
    status = coalesce(p ->> 'status', status),
    current_period_end = coalesce(nullif(p ->> 'current_period_end', '')::timestamptz, current_period_end),
    trial_ends_at = coalesce(nullif(p ->> 'trial_ends_at', '')::timestamptz, trial_ends_at),
    suspended_reason = case when p ->> 'status' = 'suspended' then p ->> 'reason' else null end
  where business_id = p_business;
  insert into public.audit_logs (business_id, user_id, action, entity, entity_id, details)
  values (p_business, auth.uid(), 'admin.subscription_changed', 'subscription', p_business::text, p);
end $$;

create or replace function public.admin_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return jsonb_build_object(
    'businesses', (select count(*) from public.businesses),
    'businesses_30d', (select count(*) from public.businesses where created_at > now() - interval '30 days'),
    'users', (select count(*) from auth.users),
    'active_paid', (select count(*) from public.businesses b where (app.subscription_info(b.id) ->> 'effective_plan') <> 'free'
                     and (app.subscription_info(b.id) ->> 'state') <> 'trial'),
    'trials', (select count(*) from public.businesses b where app.subscription_info(b.id) ->> 'state' = 'trial'),
    'pending_payments', (select count(*) from public.billing_payments where status = 'pending'),
    'verified_revenue_30d', (select coalesce(sum(amount), 0) from public.billing_payments
                             where status = 'verified' and reviewed_at > now() - interval '30 days'),
    'open_support', (select count(*) from public.support_requests where status in ('open', 'in_progress')),
    'ai_queries_30d', (select count(*) from public.ai_queries where created_at > now() - interval '30 days'),
    'ai_failures_30d', (select count(*) from public.ai_queries where status = 'failed' and created_at > now() - interval '30 days'),
    'sales_30d', (select count(*) from public.sales where created_at > now() - interval '30 days'),
    'plans', (select jsonb_object_agg(code, n) from (
      select app.subscription_info(b.id) ->> 'effective_plan' code, count(*) n from public.businesses b group by 1) t));
end $$;

-- Platform-level listing: business metadata and usage counts only (no private records).
create or replace function public.admin_list_businesses(p_search text default null, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select b.id, b.name, b.category, b.country_code, b.status, b.created_at, b.phone,
           (select u.email from public.business_members m join auth.users u on u.id = m.user_id
             where m.business_id = b.id and m.role = 'owner' and m.active) as owner_email,
           app.subscription_info(b.id) as subscription,
           (select count(*) from public.business_members m where m.business_id = b.id and m.active) as members,
           (select count(*) from public.products p where p.business_id = b.id) as products,
           (select count(*) from public.sales s where s.business_id = b.id) as sales_count,
           (select max(s.created_at) from public.sales s where s.business_id = b.id) as last_sale_at,
           exists (select 1 from public.support_access_grants g where g.business_id = b.id
                   and g.revoked_at is null and g.expires_at > now()) as support_access
    from public.businesses b
    where p_search is null or b.name ilike '%' || p_search || '%' or exists (
      select 1 from public.business_members m join auth.users u on u.id = m.user_id
      where m.business_id = b.id and u.email ilike '%' || p_search || '%')
    order by b.created_at desc limit least(p_limit, 200) offset p_offset) t), '[]'::jsonb);
end $$;

create or replace function public.admin_upsert_plan(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  insert into public.plans (code, name_en, name_fr, description_en, description_fr, price_monthly, price_annual,
                            features, limits, is_public, active, highlight, sort)
  values (p ->> 'code', p ->> 'name_en', p ->> 'name_fr', p ->> 'description_en', p ->> 'description_fr',
          (p ->> 'price_monthly')::numeric, nullif(p ->> 'price_annual', '')::numeric,
          array(select jsonb_array_elements_text(p -> 'features')), coalesce(p -> 'limits', '{}'),
          coalesce((p ->> 'is_public')::boolean, true), coalesce((p ->> 'active')::boolean, true),
          coalesce((p ->> 'highlight')::boolean, false), coalesce((p ->> 'sort')::int, 0))
  on conflict (code) do update set name_en = excluded.name_en, name_fr = excluded.name_fr,
    description_en = excluded.description_en, description_fr = excluded.description_fr,
    price_monthly = excluded.price_monthly, price_annual = excluded.price_annual, features = excluded.features,
    limits = excluded.limits, is_public = excluded.is_public, active = excluded.active,
    highlight = excluded.highlight, sort = excluded.sort;
  insert into public.audit_logs (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'admin.plan_saved', 'plan', p ->> 'code', p);
end $$;

create or replace function public.admin_set_config(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if p_key not in ('trial', 'grace_days', 'renewal_notice_days', 'payment_instructions', 'support_contact', 'ai') then
    perform app.raise('invalid_config_key');
  end if;
  update public.app_config set value = p_value, updated_at = now(), updated_by = auth.uid() where key = p_key;
  insert into public.audit_logs (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'admin.config_changed', 'config', p_key, p_value);
end $$;

create or replace function public.admin_save_announcement(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare aid uuid := nullif(p ->> 'id', '')::uuid;
begin
  perform app.require_platform_admin();
  if aid is null then
    insert into public.announcements (title_en, title_fr, body_en, body_fr, level, starts_at, ends_at, active, created_by)
    values (p ->> 'title_en', p ->> 'title_fr', p ->> 'body_en', p ->> 'body_fr', coalesce(p ->> 'level', 'info'),
            coalesce(nullif(p ->> 'starts_at', '')::timestamptz, now()), nullif(p ->> 'ends_at', '')::timestamptz,
            coalesce((p ->> 'active')::boolean, true), auth.uid())
    returning id into aid;
  else
    update public.announcements set title_en = p ->> 'title_en', title_fr = p ->> 'title_fr', body_en = p ->> 'body_en',
      body_fr = p ->> 'body_fr', level = coalesce(p ->> 'level', level),
      ends_at = nullif(p ->> 'ends_at', '')::timestamptz, active = coalesce((p ->> 'active')::boolean, active)
    where id = aid;
  end if;
  insert into public.audit_logs (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'admin.announcement_saved', 'announcement', aid::text, p);
  return aid;
end $$;

create or replace function public.admin_respond_support(p_request uuid, p_status text, p_response text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  update public.support_requests set status = p_status,
    admin_response = coalesce(nullif(p_response, ''), admin_response),
    responded_by = auth.uid(), responded_at = now()
  where id = p_request;
  insert into public.audit_logs (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'admin.support_updated', 'support_request', p_request::text, jsonb_build_object('status', p_status));
end $$;

create or replace function public.admin_add_platform_admin(p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  perform app.require_platform_admin();
  select id into uid from auth.users where lower(email) = lower(btrim(p_email)) and email_confirmed_at is not null;
  if uid is null then perform app.raise('user_not_found'); end if;
  insert into public.platform_admins (user_id, note) values (uid, 'added by ' || auth.uid()) on conflict do nothing;
  insert into public.audit_logs (user_id, action, entity, entity_id) values (auth.uid(), 'admin.admin_added', 'user', uid::text);
end $$;

create or replace function public.admin_ai_usage()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select date_trunc('day', created_at)::date as day, count(*) as queries,
           count(*) filter (where status = 'completed') as completed,
           count(*) filter (where status = 'failed') as failed,
           count(*) filter (where status = 'fallback') as fallback,
           coalesce(sum(input_tokens), 0) as input_tokens, coalesce(sum(output_tokens), 0) as output_tokens,
           count(distinct business_id) as businesses
    from public.ai_queries where created_at > now() - interval '30 days'
    group by 1 order by 1 desc) t), '[]'::jsonb);
end $$;

-- Support access granted by the owner (time-limited).
create or replace function public.grant_support_access(p_business uuid, p_hours int, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
  perform app.require_perm(p_business, 'settings.manage');
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  insert into public.support_access_grants (business_id, granted_by, reason, expires_at)
  values (p_business, auth.uid(), btrim(p_reason), now() + make_interval(hours => least(greatest(p_hours, 1), 72)))
  returning id into gid;
  perform app.audit(p_business, 'support_access.granted', 'support_access', gid::text,
                    jsonb_build_object('hours', p_hours, 'reason', p_reason));
  return gid;
end $$;

create or replace function public.revoke_support_access(p_grant uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g public.support_access_grants;
begin
  select * into g from public.support_access_grants where id = p_grant;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(g.business_id, 'settings.manage');
  update public.support_access_grants set revoked_at = now() where id = p_grant;
  perform app.audit(g.business_id, 'support_access.revoked', 'support_access', p_grant::text);
end $$;

-- Admins must open (and thereby log) a support session before viewing a business.
create or replace function public.admin_open_support_session(p_business uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if not exists (select 1 from public.support_access_grants where business_id = p_business
                 and revoked_at is null and expires_at > now()) then
    perform app.raise('no_support_access');
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity, entity_id, details)
  values (p_business, auth.uid(), 'admin.support_session_opened', 'business', p_business::text,
          jsonb_build_object('reason', p_reason));
end $$;

-- ---------------------------------------------------------------------------
-- Support & contact
-- ---------------------------------------------------------------------------
create or replace function public.submit_support_request(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare rid uuid; uid uuid := auth.uid(); bid uuid := nullif(p ->> 'business_id', '')::uuid; em text;
begin
  em := lower(btrim(coalesce(p ->> 'email', (select email from auth.users where id = uid), '')));
  if uid is null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then perform app.raise('invalid_email'); end if;
  perform app.rate_limit('support:' || coalesce(uid::text, em), 5, 3600);
  if bid is not null and not app.is_member(bid) then bid := null; end if;
  insert into public.support_requests (business_id, user_id, name, email, phone, category, subject, message)
  values (bid, uid, nullif(p ->> 'name', ''), nullif(em, ''), nullif(p ->> 'phone', ''),
          coalesce(nullif(p ->> 'category', ''), 'question'), btrim(p ->> 'subject'), btrim(p ->> 'message'))
  returning id into rid;
  return rid;
end $$;

-- ---------------------------------------------------------------------------
-- Notifications (generated from real records; in-app delivery only)
-- ---------------------------------------------------------------------------
create or replace function public.generate_alerts(p_business uuid)
returns int language plpgsql security definer set search_path = public as $$
declare today date; n int := 0; c int; st public.business_settings; sub jsonb; r record; added int;
begin
  if not app.is_member(p_business) then perform app.raise('permission_denied'); end if;
  today := app.biz_today(p_business);
  select * into st from public.business_settings where business_id = p_business;

  select count(*) into c from public.products where business_id = p_business and status = 'active'
     and qty_on_hand <= 0 and exists (select 1 from public.stock_movements m where m.product_id = products.id);
  if c > 0 then
    insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
    values (p_business, 'out_of_stock', 'critical', jsonb_build_object('count', c), '/app/inventory?filter=out',
            'out_of_stock:' || today) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;

  select count(*) into c from public.products where business_id = p_business and status = 'active'
     and qty_on_hand > 0 and qty_on_hand <= greatest(min_stock, 0) and min_stock > 0;
  if c > 0 then
    insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
    values (p_business, 'low_stock', 'warning', jsonb_build_object('count', c), '/app/inventory?filter=low',
            'low_stock:' || today) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;

  select count(*), min(expiry_date) into r from public.stock_batches
   where business_id = p_business and remaining_qty > 0 and expiry_date <= today + st.expiry_alert_days;
  if r.count > 0 then
    insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
    values (p_business, 'expiring_soon', 'warning', jsonb_build_object('count', r.count, 'first_expiry', r.min),
            '/app/inventory?tab=expiry', 'expiring:' || today) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;

  for r in select pu.id, pu.number, pu.due_date, pu.total - pu.credited_total - pu.paid_total as owed, s.name
           from public.purchases pu join public.suppliers s on s.id = pu.supplier_id
           where pu.business_id = p_business and pu.status in ('ordered', 'partially_received', 'received')
             and pu.due_date is not null and pu.due_date <= today + 3
             and pu.total - pu.credited_total - pu.paid_total > 0 loop
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (p_business, case when r.due_date < today then 'supplier_payment_overdue' else 'supplier_payment_due' end,
            case when r.due_date < today then 'critical' else 'warning' end,
            jsonb_build_object('supplier', r.name, 'number', r.number, 'due_date', r.due_date, 'amount', r.owed),
            '/app/purchases/' || r.id, 'purchases.manage',
            'supplier_due:' || r.id || ':' || (r.due_date < today)) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end loop;

  select count(*), coalesce(sum(s.total - s.returned_total + s.refunded_total - s.paid_total), 0) into r
    from public.sales s where s.business_id = p_business and s.customer_id is not null
     and s.due_date is not null and s.due_date < today and s.total - s.returned_total + s.refunded_total - s.paid_total > 0;
  if r.count > 0 then
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (p_business, 'customer_overdue', 'warning', jsonb_build_object('count', r.count, 'amount', r.coalesce),
            '/app/customers?filter=overdue', 'customers.credit', 'customer_overdue:' || today) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;

  sub := app.subscription_info(p_business);
  if sub ->> 'state' in ('renewal_due', 'grace', 'expired') or
     (sub ->> 'state' = 'trial' and (sub ->> 'trial_ends_at')::timestamptz < now() + interval '5 days') then
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (p_business, 'subscription_' || (sub ->> 'state'),
            case when sub ->> 'state' in ('grace', 'expired') then 'critical' else 'warning' end,
            sub, '/app/billing', 'billing.manage',
            'subscription:' || (sub ->> 'state') || ':' || coalesce(sub ->> 'current_period_end', sub ->> 'trial_ends_at', ''))
    on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;
  return n;
end $$;

create or replace function public.mark_notifications_read(p_business uuid, p_ids uuid[] default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not app.is_member(p_business) then perform app.raise('permission_denied'); end if;
  insert into public.notification_reads (notification_id, user_id)
  select id, auth.uid() from public.notifications
   where business_id = p_business and (p_ids is null or id = any (p_ids))
  on conflict do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- AI usage metering (called by the ai-advisor Edge Function with the user's JWT)
-- ---------------------------------------------------------------------------
create or replace function public.ai_begin_query(p_business uuid, p_question text, p_from date, p_to date)
returns uuid language plpgsql security definer set search_path = public as $$
declare qid uuid;
begin
  perform app.require_perm(p_business, 'reports.view');
  perform app.require_feature(p_business, 'ai_advisor');
  if coalesce(btrim(p_question), '') = '' or length(p_question) > 1000 then perform app.raise('invalid_question'); end if;
  perform app.rate_limit('ai:' || auth.uid(), 20, 3600);
  perform app.check_limit(p_business, 'ai_queries_per_month');
  insert into public.ai_queries (business_id, user_id, question, period_from, period_to)
  values (p_business, auth.uid(), btrim(p_question), p_from, p_to) returning id into qid;
  return qid;
end $$;

create or replace function public.ai_complete_query(p_query uuid, p_status text, p_answer text, p_model text,
  p_input_tokens int default null, p_output_tokens int default null, p_error text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('completed', 'failed', 'fallback') then perform app.raise('invalid_status'); end if;
  update public.ai_queries set status = p_status, answer = p_answer, model = p_model, input_tokens = p_input_tokens,
         output_tokens = p_output_tokens, error = left(p_error, 500), completed_at = now()
   where id = p_query and user_id = auth.uid() and status = 'started';
  if not found then perform app.raise('not_found'); end if;
end $$;

-- ---------------------------------------------------------------------------
-- Imports (validated, previewable, duplicate-safe, reversible)
-- ---------------------------------------------------------------------------
create or replace function app.num_or_null(v text) returns numeric language plpgsql immutable as $$
begin
  if v is null or btrim(v) = '' then return null; end if;
  return replace(replace(btrim(v), ' ', ''), ',', '.')::numeric;
exception when others then
  return 'NaN'::numeric;
end $$;

create or replace function public.preview_product_import(p_business uuid, p_rows jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb; i int := 0; errs text[]; out jsonb := '[]'; seen_sku text[] := '{}'; seen_bc text[] := '{}';
        v_sku text; v_bc text; ok int := 0; bad int := 0; v numeric; f text;
begin
  perform app.require_perm(p_business, 'imports.manage');
  if jsonb_typeof(p_rows) <> 'array' then perform app.raise('invalid_file'); end if;
  if jsonb_array_length(p_rows) > 2000 then perform app.raise('too_many_rows'); end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1; errs := '{}';
    if coalesce(btrim(r ->> 'name'), '') = '' then errs := errs || 'name_required'::text; end if;
    v_sku := lower(btrim(coalesce(r ->> 'sku', '')));
    if v_sku <> '' then
      if v_sku = any (seen_sku) then errs := errs || 'duplicate_sku_in_file'::text;
      elsif exists (select 1 from public.products where business_id = p_business and lower(products.sku) = v_sku) then
        errs := errs || 'duplicate_sku'::text;
      end if;
      seen_sku := seen_sku || v_sku;
    end if;
    v_bc := btrim(coalesce(r ->> 'barcode', ''));
    if v_bc <> '' then
      if v_bc = any (seen_bc) then errs := errs || 'duplicate_barcode_in_file'::text;
      elsif exists (select 1 from public.products where business_id = p_business and barcode = v_bc) then
        errs := errs || 'duplicate_barcode'::text;
      end if;
      seen_bc := seen_bc || v_bc;
    end if;
    foreach f in array array['purchase_cost', 'selling_price', 'min_stock', 'opening_qty', 'opening_unit_cost'] loop
      v := app.num_or_null(r ->> f);
      if v = 'NaN'::numeric then errs := errs || ('invalid_number:' || f);
      elsif v < 0 then errs := errs || ('negative_number:' || f); end if;
    end loop;
    if app.num_or_null(r ->> 'opening_qty') > 0 and app.num_or_null(r ->> 'opening_qty') <> trunc(app.num_or_null(r ->> 'opening_qty'))
       and lower(coalesce(r ->> 'allow_fraction', '')) not in ('yes', 'true', '1', 'oui') then
      errs := errs || 'fractional_quantity_not_allowed'::text;
    end if;
    if cardinality(errs) = 0 then ok := ok + 1; else bad := bad + 1; end if;
    out := out || jsonb_build_object('row', i, 'ok', cardinality(errs) = 0, 'errors', to_jsonb(errs));
  end loop;
  return jsonb_build_object('rows', out, 'valid', ok, 'invalid', bad, 'total', i,
    'limit', app.plan_limit(p_business, 'max_products'), 'current_products', app.usage_count(p_business, 'max_products'));
end $$;

create or replace function public.import_products(p_business uuid, p_rows jsonb, p_file_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pv jsonb; r jsonb; i int := 0; bid uuid; created int := 0; skipped int := 0; v_issues jsonb := '[]';
        pid uuid; cat uuid; sku text; oq numeric; oc numeric; lim numeric; known boolean;
begin
  perform app.require_perm(p_business, 'imports.manage');
  perform app.require_feature(p_business, 'import');
  pv := public.preview_product_import(p_business, p_rows);
  lim := app.plan_limit(p_business, 'max_products');
  if lim is not null and app.usage_count(p_business, 'max_products') + (pv ->> 'valid')::int > lim then
    perform app.raise('plan_limit_reached', jsonb_build_object('limit', 'max_products', 'max', lim,
      'used', app.usage_count(p_business, 'max_products')));
  end if;
  insert into public.import_batches (business_id, kind, file_name, total_rows, created_by)
  values (p_business, 'products', p_file_name, jsonb_array_length(p_rows), auth.uid()) returning id into bid;

  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    if not ((pv -> 'rows' -> (i - 1)) ->> 'ok')::boolean then
      skipped := skipped + 1;
      v_issues := v_issues || jsonb_build_object('row', i, 'errors', (pv -> 'rows' -> (i - 1)) -> 'errors');
      continue;
    end if;
    cat := null;
    if coalesce(btrim(r ->> 'category'), '') <> '' then
      insert into public.categories (business_id, name) values (p_business, btrim(r ->> 'category'))
      on conflict (business_id, lower(name)) do nothing;
      select id into cat from public.categories where business_id = p_business and lower(name) = lower(btrim(r ->> 'category'));
    end if;
    sku := coalesce(nullif(btrim(r ->> 'sku'), ''), app.next_number(p_business, 'sku', 'SKU-'));
    insert into public.products (business_id, name, sku, barcode, category_id, brand, description, base_unit,
      allow_fraction, purchase_cost, selling_price, min_stock, location, import_batch_id, created_by)
    values (p_business, btrim(r ->> 'name'), sku, nullif(btrim(r ->> 'barcode'), ''), cat, nullif(r ->> 'brand', ''),
      nullif(r ->> 'description', ''), coalesce(nullif(btrim(r ->> 'base_unit'), ''), 'piece'),
      lower(coalesce(r ->> 'allow_fraction', '')) in ('yes', 'true', '1', 'oui'),
      coalesce(app.num_or_null(r ->> 'purchase_cost'), 0), coalesce(app.num_or_null(r ->> 'selling_price'), 0),
      coalesce(app.num_or_null(r ->> 'min_stock'), 0), nullif(r ->> 'location', ''), bid, auth.uid())
    returning id into pid;
    oq := coalesce(app.num_or_null(r ->> 'opening_qty'), 0);
    if oq > 0 then
      oc := app.num_or_null(r ->> 'opening_unit_cost');
      known := oc is not null;
      oc := coalesce(oc, app.num_or_null(r ->> 'purchase_cost'), 0);
      perform app.apply_movement(p_business, pid, 'opening', oq, oc, 'import', bid, null, 'Imported opening stock',
                                 null, not known);
    end if;
    created := created + 1;
  end loop;
  update public.import_batches set created_count = created, skipped_count = skipped, issues = v_issues where id = bid;
  perform app.audit(p_business, 'import.products', 'import_batch', bid::text,
                    jsonb_build_object('created', created, 'skipped', skipped, 'file', p_file_name));
  return jsonb_build_object('batch_id', bid, 'created', created, 'skipped', skipped, 'issues', v_issues);
end $$;

create or replace function public.rollback_import(p_batch uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.import_batches; blocked text[]; n int;
begin
  select * into b from public.import_batches where id = p_batch for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(b.business_id, 'imports.manage');
  if b.status <> 'completed' then perform app.raise('already_rolled_back'); end if;
  if b.kind = 'products' then
    select array_agg(p.name) into blocked from public.products p where p.import_batch_id = p_batch and (
      exists (select 1 from public.stock_movements m where m.product_id = p.id and not (m.ref_type = 'import' and m.ref_id = p_batch))
      or exists (select 1 from public.sale_lines where product_id = p.id)
      or exists (select 1 from public.purchase_lines where product_id = p.id)
      or exists (select 1 from public.stock_count_lines where product_id = p.id));
    if blocked is not null then
      perform app.raise('import_has_activity', jsonb_build_object('products', to_jsonb(blocked[1:10])));
    end if;
    delete from public.stock_movements where ref_type = 'import' and ref_id = p_batch;
    delete from public.products where import_batch_id = p_batch;
    get diagnostics n = row_count;
  elsif b.kind = 'suppliers' then
    if exists (select 1 from public.suppliers s where s.import_batch_id = p_batch and (
         exists (select 1 from public.purchases where supplier_id = s.id)
         or exists (select 1 from public.payments where supplier_id = s.id))) then
      perform app.raise('import_has_activity');
    end if;
    update public.products set preferred_supplier_id = null
     where preferred_supplier_id in (select id from public.suppliers where import_batch_id = p_batch);
    delete from public.suppliers where import_batch_id = p_batch;
    get diagnostics n = row_count;
  else
    if exists (select 1 from public.customers c where c.import_batch_id = p_batch and (
         exists (select 1 from public.sales where customer_id = c.id)
         or exists (select 1 from public.payments where customer_id = c.id))) then
      perform app.raise('import_has_activity');
    end if;
    delete from public.customers where import_batch_id = p_batch;
    get diagnostics n = row_count;
  end if;
  update public.import_batches set status = 'rolled_back', rolled_back_at = now(), rolled_back_by = auth.uid()
   where id = p_batch;
  perform app.audit(b.business_id, 'import.rolled_back', 'import_batch', p_batch::text, jsonb_build_object('removed', n));
  return jsonb_build_object('removed', n);
end $$;

create or replace function public.import_parties(p_business uuid, p_kind text, p_rows jsonb, p_file_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; i int := 0; bid uuid; created int := 0; skipped int := 0; v_issues jsonb := '[]'; nm text;
begin
  if p_kind = 'suppliers' then
    perform app.require_perm(p_business, 'suppliers.manage');
    perform app.require_feature(p_business, 'suppliers');
  elsif p_kind = 'customers' then
    perform app.require_perm(p_business, 'customers.manage');
  else
    perform app.raise('invalid_kind');
  end if;
  perform app.require_feature(p_business, 'import');
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 2000 then perform app.raise('invalid_file'); end if;
  insert into public.import_batches (business_id, kind, file_name, total_rows, created_by)
  values (p_business, p_kind, p_file_name, jsonb_array_length(p_rows), auth.uid()) returning id into bid;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    nm := btrim(coalesce(r ->> 'name', ''));
    if nm = '' then
      skipped := skipped + 1; v_issues := v_issues || jsonb_build_object('row', i, 'errors', '["name_required"]'::jsonb);
      continue;
    end if;
    if p_kind = 'suppliers' then
      if exists (select 1 from public.suppliers where business_id = p_business and lower(name) = lower(nm)) then
        skipped := skipped + 1; v_issues := v_issues || jsonb_build_object('row', i, 'errors', '["duplicate_name"]'::jsonb);
        continue;
      end if;
      insert into public.suppliers (business_id, name, contact_person, phone, email, address, reference,
                                    payment_terms_days, notes, import_batch_id, created_by)
      values (p_business, nm, nullif(r ->> 'contact_person', ''), nullif(r ->> 'phone', ''), nullif(r ->> 'email', ''),
              nullif(r ->> 'address', ''), nullif(r ->> 'reference', ''),
              case when app.num_or_null(r ->> 'payment_terms_days') >= 0 then app.num_or_null(r ->> 'payment_terms_days')::int end,
              nullif(r ->> 'notes', ''), bid, auth.uid());
    else
      if exists (select 1 from public.customers where business_id = p_business and
                 (lower(name) = lower(nm) and coalesce(phone, '') = coalesce(nullif(r ->> 'phone', ''), ''))) then
        skipped := skipped + 1; v_issues := v_issues || jsonb_build_object('row', i, 'errors', '["duplicate_name"]'::jsonb);
        continue;
      end if;
      insert into public.customers (business_id, name, phone, email, address, notes, import_batch_id, created_by)
      values (p_business, nm, nullif(r ->> 'phone', ''), nullif(r ->> 'email', ''), nullif(r ->> 'address', ''),
              nullif(r ->> 'notes', ''), bid, auth.uid());
    end if;
    created := created + 1;
  end loop;
  update public.import_batches set created_count = created, skipped_count = skipped, issues = v_issues where id = bid;
  perform app.audit(p_business, 'import.' || p_kind, 'import_batch', bid::text, jsonb_build_object('created', created));
  return jsonb_build_object('batch_id', bid, 'created', created, 'skipped', skipped, 'issues', v_issues);
end $$;

-- ---------------------------------------------------------------------------
-- Full data export (owner/settings managers)
-- ---------------------------------------------------------------------------
create or replace function public.export_business_data(p_business uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare res jsonb := '{}'; t text; part jsonb;
begin
  perform app.require_perm(p_business, 'settings.manage');
  res := jsonb_build_object('exported_at', now(), 'format_version', 1,
    'business', (select to_jsonb(b) from public.businesses b where id = p_business),
    'settings', (select to_jsonb(s) from public.business_settings s where business_id = p_business));
  foreach t in array array['categories', 'suppliers', 'customers', 'products', 'product_units', 'stock_batches',
    'stock_movements', 'stock_counts', 'stock_count_lines', 'purchases', 'purchase_lines', 'purchase_receipts',
    'purchase_receipt_lines', 'supplier_credits', 'supplier_returns', 'supplier_return_lines', 'sales', 'sale_lines',
    'sale_returns', 'sale_return_lines', 'payments', 'payment_allocations', 'expenses', 'cash_accounts',
    'cash_movements', 'cash_reconciliations', 'cash_reconciliation_lines', 'attachments']::text[] loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from public.%I x where business_id = $1', t)
      into part using p_business;
    res := res || jsonb_build_object(t, part);
  end loop;
  return res;
end $$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.notifications enable row level security;
alter table public.notification_reads enable row level security;
alter table public.support_requests enable row level security;
alter table public.announcements enable row level security;
alter table public.support_access_grants enable row level security;
alter table public.ai_queries enable row level security;
alter table public.rate_limits enable row level security;

create policy notifications_read on public.notifications for select
  using (app.is_member(business_id) and (required_perm is null or app.has_perm(business_id, required_perm)));
create policy notification_reads_read on public.notification_reads for select using (user_id = auth.uid());
create policy support_read on public.support_requests for select
  using (user_id = auth.uid() or app.is_platform_admin());
create policy announcements_read on public.announcements for select
  using ((active and starts_at <= now() and (ends_at is null or ends_at > now())) or app.is_platform_admin());
create policy support_grants_read on public.support_access_grants for select
  using (app.has_perm(business_id, 'settings.manage') or app.is_platform_admin());
create policy ai_queries_read on public.ai_queries for select
  using (user_id = auth.uid() or app.has_perm(business_id, 'settings.manage') or app.is_platform_admin());
