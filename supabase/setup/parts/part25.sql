-- BizPilot setup PART 25 of 26. Run parts in order.
begin;
create index if not exists referrals_creator on public.referrals (creator_id);
create table if not exists public.creator_ledger (
  id bigserial primary key,
  creator_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('accrual', 'reversal', 'adjustment')),
  amount numeric(12, 0) not null check (amount <> 0),
  rate numeric(4, 2),
  basis_amount numeric(12, 0),
  payment_kind text check (payment_kind in ('initial', 'renewal')),
  billing_payment_id uuid references public.billing_payments (id) on delete restrict,
  referral_id uuid references public.referrals (id) on delete restrict,
  available_at timestamptz not null,
  note text not null check (length(note) <= 200),
  created_by uuid,
  created_at timestamptz not null default now(),
  check ((kind = 'adjustment') or billing_payment_id is not null),
  check ((kind = 'accrual') = (amount > 0) or kind <> 'accrual')
);
create unique index if not exists creator_ledger_one_accrual on public.creator_ledger (billing_payment_id) where kind = 'accrual';
create unique index if not exists creator_ledger_one_reversal on public.creator_ledger (billing_payment_id) where kind = 'reversal';
create index if not exists creator_ledger_creator on public.creator_ledger (creator_id, created_at);
create or replace function app.ledger_append_only() returns trigger
language plpgsql as $$
begin
  raise exception 'ledger_is_append_only';
end $$;
drop trigger if exists creator_ledger_no_change on public.creator_ledger;
create trigger creator_ledger_no_change before update or delete on public.creator_ledger
  for each row execute function app.ledger_append_only();
create table if not exists public.creator_payout_requests (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references auth.users (id) on delete cascade,
  amount numeric(12, 0) not null check (amount > 0),
  provider text not null check (provider in ('mtn_momo', 'orange_money')),
  phone text not null check (phone ~ '^6[0-9]{8}$'),
  account_name text check (length(account_name) <= 80),
  status text not null default 'requested'
    check (status in ('requested', 'approved', 'processing', 'paid', 'failed', 'cancelled', 'reversed')),
  provider_reference text check (length(provider_reference) between 4 and 80),
  decision_note text check (length(decision_note) <= 500),
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid,
  paid_at timestamptz
);
create unique index if not exists creator_payout_one_open on public.creator_payout_requests (creator_id)
  where status in ('requested', 'approved', 'processing');
create unique index if not exists creator_payout_paid_reference on public.creator_payout_requests (provider_reference)
  where status in ('paid', 'reversed');
alter table public.creator_profiles enable row level security;
alter table public.creator_clicks enable row level security;
alter table public.referrals enable row level security;
alter table public.creator_ledger enable row level security;
alter table public.creator_payout_requests enable row level security;
drop policy if exists creator_profiles_own on public.creator_profiles;
create policy creator_profiles_own on public.creator_profiles for select using (user_id = auth.uid() or app.is_platform_admin());
drop policy if exists referrals_own on public.referrals;
create policy referrals_own on public.referrals for select using (creator_id = auth.uid() or app.is_platform_admin());
drop policy if exists creator_ledger_own on public.creator_ledger;
create policy creator_ledger_own on public.creator_ledger for select using (creator_id = auth.uid() or app.is_platform_admin());
drop policy if exists creator_payouts_own on public.creator_payout_requests;
create policy creator_payouts_own on public.creator_payout_requests for select using (creator_id = auth.uid() or app.is_platform_admin());
revoke all on public.creator_profiles, public.creator_clicks, public.referrals, public.creator_ledger, public.creator_payout_requests from anon, authenticated;
grant select on public.creator_profiles, public.referrals, public.creator_ledger, public.creator_payout_requests to authenticated;
create or replace function app.creator_code() returns text
language plpgsql volatile as $$
declare c text;
begin
  loop
    c := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.creator_profiles where referral_code = c);
  end loop;
  return c;
end $$;
create or replace function app.creator_balance(uid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'pending', coalesce(sum(amount) filter (where available_at > now()), 0),
    'available', coalesce(sum(amount) filter (where available_at <= now()), 0),
    'paid', (select coalesce(sum(amount), 0) from public.creator_payout_requests where creator_id = uid and status = 'paid'),
    'reserved', (select coalesce(sum(amount), 0) from public.creator_payout_requests where creator_id = uid and status in ('requested', 'approved', 'processing')),
    'withdrawable', coalesce(sum(amount) filter (where available_at <= now()), 0)
                    - (select coalesce(sum(amount), 0) from public.creator_payout_requests where creator_id = uid and status in ('paid', 'requested', 'approved', 'processing')),
    'reversed', coalesce(sum(amount) filter (where kind = 'reversal'), 0))
  from public.creator_ledger where creator_id = uid
$$;
create or replace function app.creator_accrue(bp uuid) returns void
language plpgsql security definer set search_path = public as $$
declare pay public.billing_payments; ref public.referrals; cp public.creator_profiles; cfg jsonb := app.creator_cfg();
        prior int; kind_ text; amt numeric; avail timestamptz;
begin
  if not coalesce((cfg ->> 'enabled')::boolean, false) then return; end if;
  select * into pay from public.billing_payments where id = bp;
  select * into ref from public.referrals where business_id = pay.business_id and status = 'attributed';
  if not found or pay.submitted_at > ref.window_ends_at then return; end if;
  select * into cp from public.creator_profiles where user_id = ref.creator_id;
  if not found or cp.status <> 'approved' or cp.commission_rate is null then return; end if;
  prior := (select count(*)::int from public.billing_payments
             where business_id = pay.business_id and status in ('verified', 'refunded') and id <> pay.id and submitted_at < pay.submitted_at);
  kind_ := case when prior = 0 then 'initial' else 'renewal' end;
  if cp.applies_to <> 'both' and cp.applies_to <> kind_ then return; end if;
  amt := round(pay.amount * cp.commission_rate / 100);
  if amt <= 0 then return; end if;
  avail := now() + make_interval(days => coalesce((cfg ->> 'hold_days')::int, 7));
  if exists (select 1 from public.creator_ledger where billing_payment_id = pay.id and kind = 'accrual') then return; end if;
  insert into public.creator_ledger (creator_id, kind, amount, rate, basis_amount, payment_kind, billing_payment_id, referral_id,
    available_at, note)
  values (ref.creator_id, 'accrual', amt, cp.commission_rate, pay.amount, kind_, pay.id, ref.id, avail,
          'Commission on ' || kind_ || ' payment ' || pay.transaction_ref);
  insert into public.inbox_notifications (user_id, kind, from_name, preview, link)
  values (ref.creator_id, 'creator_commission', 'BizPilot', 'You earned ' || amt || ' FCFA (' || cp.commission_rate || '%) on a ' || kind_ || ' payment.', '/creator');
end $$;
create or replace function app.creator_reverse(bp uuid) returns void
language plpgsql security definer set search_path = public as $$
declare acc public.creator_ledger;
begin
  select * into acc from public.creator_ledger where billing_payment_id = bp and kind = 'accrual';
  if not found or exists (select 1 from public.creator_ledger where billing_payment_id = bp and kind = 'reversal') then return; end if;
  insert into public.creator_ledger (creator_id, kind, amount, rate, basis_amount, payment_kind, billing_payment_id, referral_id,
    available_at, note)
  values (acc.creator_id, 'reversal', -acc.amount, acc.rate, acc.basis_amount, acc.payment_kind, bp, acc.referral_id,
          acc.available_at, 'Reversed: the payment was refunded');
end $$;
create or replace function app.billing_commission_hook() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'verified' and old.status is distinct from 'verified' then perform app.creator_accrue(new.id); end if;
  if new.status = 'refunded' and old.status = 'verified' then perform app.creator_reverse(new.id); end if;
  return new;
end $$;
drop trigger if exists billing_payments_commission on public.billing_payments;
create trigger billing_payments_commission after update of status on public.billing_payments
  for each row execute function app.billing_commission_hook();
create or replace function public.creator_apply(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text := nullif(btrim(coalesce(p ->> 'display_name', '')), ''); st text;
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  if not exists (select 1 from auth.users where id = uid and email_confirmed_at is not null) then perform app.raise('email_not_verified'); end if;
  if nm is null or length(nm) < 2 or length(nm) > 60 then perform app.raise('invalid_request'); end if;
  perform app.rate_limit('creator_apply:' || uid, 3, 86400);
  if exists (select 1 from public.creator_profiles where user_id = uid) then
    select status into st from public.creator_profiles where user_id = uid;
    return st;
  end if;
  insert into public.creator_profiles (user_id, display_name, bio, channels, referral_code)
  values (uid, nm, nullif(left(btrim(coalesce(p ->> 'bio', '')), 300), ''),
          case when jsonb_typeof(p -> 'channels') = 'array' then p -> 'channels' else '[]'::jsonb end, app.creator_code());
  perform app.audit(null, 'creator.applied', 'creator', uid::text, null);
  return 'pending';
end $$;
create or replace function public.creator_update(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); cp public.creator_profiles;
        ph text := nullif(regexp_replace(coalesce(p ->> 'payout_phone', ''), '\D', '', 'g'), '');
        cph text := nullif(regexp_replace(coalesce(p ->> 'contact_phone', ''), '\D', '', 'g'), '');
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  select * into cp from public.creator_profiles where user_id = uid for update;
  if not found then perform app.raise('not_found'); end if;
  if ph is not null then ph := right(ph, 9); end if;
  if cph is not null then cph := right(cph, 9); end if;
  if ph is not null and ph !~ '^6[0-9]{8}$' then perform app.raise('invalid_phone'); end if;
  if cph is not null and cph !~ '^6[0-9]{8}$' then perform app.raise('invalid_phone'); end if;
  if (p ->> 'payout_provider') is not null and (p ->> 'payout_provider') not in ('mtn_momo', 'orange_money') then
    perform app.raise('invalid_request');
  end if;
  update public.creator_profiles set
    display_name = coalesce(nullif(btrim(p ->> 'display_name'), ''), display_name),
    bio = case when p ? 'bio' then nullif(left(btrim(coalesce(p ->> 'bio', '')), 300), '') else bio end,
    channels = case when jsonb_typeof(p -> 'channels') = 'array' and jsonb_array_length(p -> 'channels') <= 5 then p -> 'channels' else channels end,
    contact_phone = coalesce(cph, contact_phone),
    payout_provider = coalesce(nullif(p ->> 'payout_provider', ''), payout_provider),
    payout_phone = coalesce(ph, payout_phone),
    payout_name = case when p ? 'payout_name' then nullif(left(btrim(coalesce(p ->> 'payout_name', '')), 80), '') else payout_name end,
    updated_at = now()
   where user_id = uid;
end $$;
create or replace function public.creator_track_click(p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare c text := upper(btrim(coalesce(p_code, '')));
begin
  if c !~ '^[A-Z0-9]{6,10}$' or not exists (select 1 from public.creator_profiles where referral_code = c and status = 'approved') then
    return;
  end if;
  perform app.rate_limit('creator_click:' || app.client_ip() || ':' || c, 30, 3600);
  insert into public.creator_clicks (code) values (c);
end $$;
create or replace function public.creator_attach_referral(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); c text := upper(btrim(coalesce(p_code, ''))); cp public.creator_profiles; b uuid; cfg jsonb := app.creator_cfg();
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  select * into cp from public.creator_profiles where referral_code = c;
  if not found or cp.status <> 'approved' then perform app.raise('creator_not_active'); end if;
  if cp.user_id = uid then perform app.raise('self_referral'); end if;
  select m.business_id into b from public.business_members m
   join public.businesses bz on bz.id = m.business_id
   where m.user_id = uid and m.role = 'owner' and m.active and bz.created_at > now() - interval '30 days'
     and not exists (select 1 from public.referrals r where r.business_id = m.business_id)
     and not exists (select 1 from public.billing_payments p where p.business_id = m.business_id and p.status = 'verified')
   order by bz.created_at desc limit 1;
  if b is null then perform app.raise('no_eligible_business'); end if;
  if exists (select 1 from public.business_members m where m.business_id = b and m.user_id = cp.user_id) then
    perform app.raise('self_referral');
  end if;
  insert into public.referrals (business_id, creator_id, referred_user_id, code, window_ends_at)
  values (b, cp.user_id, uid, c, now() + make_interval(months => coalesce((cfg ->> 'attribution_months')::int, 12)));
  return jsonb_build_object('business_id', b, 'status', 'attributed');
end $$;
create or replace function public.creator_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid(); cp public.creator_profiles; cfg jsonb := app.creator_cfg(); st jsonb; stats jsonb;
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  select * into cp from public.creator_profiles where user_id = uid;
  if not found then return jsonb_build_object('applied', false); end if;
  st := app.creator_balance(uid);
  stats := jsonb_build_object(
    'clicks', (select count(*) from public.creator_clicks where code = cp.referral_code),
    'referrals', (select count(*) from public.referrals where creator_id = uid and status = 'attributed'),
    'registered', (select count(distinct referred_user_id) from public.referrals where creator_id = uid and status = 'attributed'),
    'paying', (select count(distinct r.business_id) from public.referrals r where r.creator_id = uid and r.status = 'attributed'
                and exists (select 1 from public.billing_payments p where p.business_id = r.business_id and p.status = 'verified')));
  stats := stats || jsonb_build_object('conversion_pct', case when (stats ->> 'registered')::int = 0 then 0
            else round(100.0 * (stats ->> 'paying')::int / (stats ->> 'registered')::int, 1) end);
  return jsonb_build_object('applied', true, 'profile', jsonb_build_object('display_name', cp.display_name, 'status', cp.status,
      'referral_code', cp.referral_code, 'commission_rate', cp.commission_rate, 'applies_to', cp.applies_to,
      'payout_provider', cp.payout_provider, 'payout_phone', cp.payout_phone, 'payout_name', cp.payout_name,
      'channels', cp.channels, 'bio', cp.bio, 'decision_reason', cp.decision_reason),
    'program', jsonb_build_object('enabled', coalesce((cfg ->> 'enabled')::boolean, false), 'hold_days', cfg -> 'hold_days',
      'payout_minimum', cfg -> 'payout_minimum', 'min_rate', cfg -> 'min_rate', 'max_rate', cfg -> 'max_rate',
      'attribution_months', cfg -> 'attribution_months'),
    'stats', stats, 'balance', st,
    'payouts', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'amount', r.amount, 'status', r.status,
        'provider_reference', r.provider_reference, 'requested_at', r.requested_at, 'paid_at', r.paid_at) order by r.requested_at desc)
        from (select * from public.creator_payout_requests where creator_id = uid order by requested_at desc limit 20) r), '[]'::jsonb),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('kind', l.kind, 'amount', l.amount, 'rate', l.rate,
        'basis', l.basis_amount, 'payment_kind', l.payment_kind, 'available_at', l.available_at, 'note', l.note, 'created_at', l.created_at)
        order by l.created_at desc) from (select * from public.creator_ledger where creator_id = uid order by created_at desc limit 50) l), '[]'::jsonb));
end $$;
create or replace function public.creator_request_payout(p_amount numeric) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); cp public.creator_profiles; cfg jsonb := app.creator_cfg(); bal jsonb; rid uuid;
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  select * into cp from public.creator_profiles where user_id = uid for update;
  if not found or cp.status <> 'approved' then perform app.raise('creator_not_active'); end if;
  if not coalesce((cfg ->> 'enabled')::boolean, false) then perform app.raise('creator_program_closed'); end if;
  if cp.payout_provider is null or cp.payout_phone is null then perform app.raise('payout_details_required'); end if;
  if exists (select 1 from public.creator_payout_requests where creator_id = uid and status in ('requested', 'approved', 'processing')) then
    perform app.raise('payout_already_open');
  end if;
  if p_amount is null or p_amount < coalesce((cfg ->> 'payout_minimum')::numeric, 5000) then perform app.raise('below_payout_minimum'); end if;
  bal := app.creator_balance(uid);
  if p_amount > (bal ->> 'withdrawable')::numeric then perform app.raise('insufficient_available_balance'); end if;
  begin
    insert into public.creator_payout_requests (creator_id, amount, provider, phone, account_name)
    values (uid, round(p_amount), cp.payout_provider, cp.payout_phone, cp.payout_name) returning id into rid;
  exception when unique_violation then
    perform app.raise('payout_already_open');
  end;
  perform app.audit(null, 'creator.payout_requested', 'creator_payout', rid::text, jsonb_build_object('amount', round(p_amount)));
  return rid;
end $$;
create or replace function public.creator_cancel_payout(p_request uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.creator_payout_requests set status = 'cancelled', decided_at = now()
   where id = p_request and creator_id = auth.uid() and status = 'requested';
  if not found then perform app.raise('invalid_status'); end if;
end $$;
create or replace function public.admin_set_payout_status(p_request uuid, p_status text, p_reference text default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r public.creator_payout_requests; ref text := nullif(btrim(coalesce(p_reference, '')), ''); note text := nullif(btrim(coalesce(p_note, '')), '');
        ok boolean := false;
begin
  perform app.require_platform_admin();
  select * into r from public.creator_payout_requests where id = p_request for update;
  if not found then perform app.raise('not_found'); end if;
  ok := (r.status, p_status) in (('requested', 'approved'), ('requested', 'cancelled'), ('approved', 'processing'),
         ('approved', 'cancelled'), ('processing', 'paid'), ('processing', 'failed'), ('paid', 'reversed'));
  if not ok then perform app.raise('invalid_status'); end if;
  if p_status = 'paid' then
    if ref is null or length(ref) < 4 then perform app.raise('provider_reference_required'); end if;
  end if;
  if p_status in ('cancelled', 'failed', 'reversed') and note is null then perform app.raise('reason_required'); end if;
  begin
    update public.creator_payout_requests set status = p_status, decided_at = now(), decided_by = auth.uid(),
           provider_reference = coalesce(ref, provider_reference), decision_note = coalesce(note, decision_note),
           paid_at = case when p_status = 'paid' then now() else paid_at end
     where id = r.id;
  exception when unique_violation then
    perform app.raise('provider_reference_already_used');
  end;
  insert into public.inbox_notifications (user_id, kind, from_name, preview, link)
  values (r.creator_id, 'creator_payout', 'BizPilot', 'Withdrawal of ' || r.amount || ' FCFA: ' || p_status, '/creator');
  perform app.admin_audit('admin.payout_' || p_status, 'creator_payout', r.id::text, null,
                          jsonb_build_object('amount', r.amount, 'reference', ref, 'note', note));
end $$;
create or replace function public.admin_set_creator_program(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cur jsonb := app.creator_cfg(); nxt jsonb; minr numeric; maxr numeric; dr numeric;
begin
  perform app.require_platform_admin();
  nxt := cur || jsonb_strip_nulls(jsonb_build_object('enabled', p -> 'enabled', 'default_rate', p -> 'default_rate',
           'min_rate', p -> 'min_rate', 'max_rate', p -> 'max_rate', 'applies_to', p -> 'applies_to', 'hold_days', p -> 'hold_days',
           'payout_minimum', p -> 'payout_minimum', 'attribution_months', p -> 'attribution_months'));
  minr := (nxt ->> 'min_rate')::numeric; maxr := (nxt ->> 'max_rate')::numeric; dr := (nxt ->> 'default_rate')::numeric;
  if minr < 2 or maxr > 10 or minr > maxr or dr < minr or dr > maxr then perform app.raise('invalid_rate'); end if;
  if nxt ->> 'applies_to' not in ('initial', 'renewal', 'both') then perform app.raise('invalid_request'); end if;
  if (nxt ->> 'hold_days')::int < 0 or (nxt ->> 'hold_days')::int > 90 then perform app.raise('invalid_request'); end if;
  if (nxt ->> 'enabled')::boolean and not coalesce((cur ->> 'enabled')::boolean, false) then
    nxt := nxt || jsonb_build_object('enabled_at', now());
  end if;
  update public.app_config set value = nxt, updated_by = auth.uid(), updated_at = now() where key = 'creator_program';
  perform app.admin_audit('admin.creator_program', 'app_config', 'creator_program', null, nxt);
  return nxt;
end $$;
create or replace function public.admin_creator_program_get() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return app.creator_cfg();
end $$;
create or replace function public.admin_creator_list(p_status text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', c.user_id, 'display_name', c.display_name, 'status', c.status,
      'referral_code', c.referral_code, 'commission_rate', c.commission_rate, 'applies_to', c.applies_to,
      'decision_reason', c.decision_reason, 'created_at', c.created_at, 'balance', app.creator_balance(c.user_id)) order by c.created_at)
      from public.creator_profiles c where p_status is null or c.status = p_status), '[]'::jsonb);
end $$;
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
    if rate < 2 or rate > 10 or rate < (cfg ->> 'min_rate')::numeric or rate > (cfg ->> 'max_rate')::numeric then
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
commit;
