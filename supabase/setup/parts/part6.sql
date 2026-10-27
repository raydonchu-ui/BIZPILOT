-- BizPilot setup PART 6 of 23. Run parts in order.
begin;
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
create or replace function app.require_platform_admin() returns void
language plpgsql stable as $$
begin
  perform app.require_auth();
  if not app.is_platform_admin() then perform app.raise('permission_denied'); end if;
end $$;
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
commit;
