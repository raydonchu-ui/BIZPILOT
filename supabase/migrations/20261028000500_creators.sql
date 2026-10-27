-- Phase 10: content creator and promoter program.
--
-- Money rules (all in SQL; the browser cannot change them):
--   * The program is OFF until an administrator switches it on (app_config 'creator_program'.enabled = true).
--   * Commission is calculated only from a verified subscription payment, as a whole-XAF share of the amount paid, at
--     the creator's approved rate (2% to 10%). It applies to the initial payment, to renewals, or to both, as agreed.
--   * A referral attributes one business, once, within 30 days of the business's creation and before its first
--     verified payment. It stays attributed for 12 months.
--   * Self-referrals (the creator is a member of the business, or the referred account is the creator's) are refused.
--   * Commission entries are append-only. A refund writes a reversal; nothing is edited or deleted.
--   * An entry becomes available after a hold period (7 days by default). Entries are not moved between states; their
--     status is read from the date, so nothing is rewritten.
--   * A payout is a request. It is reserved from the available balance at once, and marked paid only by an administrator
--     who records the provider reference. A reference can be used for one paid payout only.
-- The payout is made outside BizPilot until a verified payout integration exists (not configured in this release).

-- 1. Program settings. Defaults are conservative: off, 5% suggested, both payment kinds, 7-day hold, 5,000 XAF minimum.
insert into public.app_config (key, value, is_public) values
  ('creator_program', '{"enabled": false, "default_rate": 5, "min_rate": 2, "max_rate": 10, "applies_to": "both",
    "attribution_days": 30, "attribution_months": 12, "hold_days": 7, "payout_minimum": 5000}', false)
on conflict (key) do nothing;

create or replace function app.creator_cfg() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.app_config where key = 'creator_program'), '{}'::jsonb)
$$;

-- Inbox kinds: messages (existing) and the creator notices. Dropped and re-added so the rule names every kind.
alter table public.inbox_notifications drop constraint if exists inbox_notifications_kind_check;
alter table public.inbox_notifications add constraint inbox_notifications_kind_check
  check (kind in ('message', 'creator_commission', 'creator_payout', 'creator_decision'));

-- 2. Creator profiles.
create table if not exists public.creator_profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'suspended')),
  display_name text not null check (length(btrim(display_name)) between 2 and 60),
  bio text check (length(bio) <= 300),
  channels jsonb not null default '[]'::jsonb check (jsonb_typeof(channels) = 'array' and jsonb_array_length(channels) <= 5),
  contact_phone text check (contact_phone ~ '^6[0-9]{8}$'),
  payout_provider text check (payout_provider in ('mtn_momo', 'orange_money')),
  payout_phone text check (payout_phone ~ '^6[0-9]{8}$'),
  payout_name text check (length(payout_name) <= 80),
  referral_code text not null unique check (referral_code ~ '^[A-Z0-9]{6,10}$'),
  commission_rate numeric(4, 2) check (commission_rate is null or commission_rate between 2 and 10),
  applies_to text check (applies_to in ('initial', 'renewal', 'both')),
  decision_reason text check (length(decision_reason) <= 500),
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.creator_clicks (
  id bigserial primary key,
  code text not null,
  created_at timestamptz not null default now()
);
create index if not exists creator_clicks_code on public.creator_clicks (code, created_at);

create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null unique references public.businesses (id) on delete cascade,
  creator_id uuid not null references auth.users (id) on delete cascade,
  referred_user_id uuid references auth.users (id) on delete set null,
  code text not null,
  status text not null default 'attributed' check (status in ('attributed', 'refused')),
  attributed_at timestamptz not null default now(),
  window_ends_at timestamptz not null
);
create index if not exists referrals_creator on public.referrals (creator_id);

-- Append-only ledger.
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

-- Payout requests.
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

-- Row-level security: creators read their own rows; no direct writes.
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

-- 3. Helpers.
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

-- Balances, from the ledger (matured or not) and the payout requests. Never edited by hand.
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

-- Accrual: a verified subscription payment for an attributed business.
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

-- A refund reverses the commission made from that payment, once.
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

-- 4. Creator: apply, update, track a link visit, attach a referral.
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

-- The seller's account is linked to the creator's code once, to a business created within 30 days that has no payment yet.
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

-- 5. Creator dashboard.
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

-- 6. Payout requests (creator) and their state changes (administrator).
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
    -- Never marked paid on a request alone: the provider reference must be recorded.
    if ref is null or length(ref) < 4 then perform app.raise('provider_reference_required'); end if;
  end if;
  if p_status in ('cancelled', 'failed', 'reversed') and note is null then perform app.raise('reason_required'); end if;
  begin
    update public.creator_payout_requests set status = p_status, decided_at = now(), decided_by = auth.uid(),
           provider_reference = coalesce(ref, provider_reference), decision_note = coalesce(note, decision_note),
           paid_at = case when p_status = 'paid' then now() else paid_at end
     where id = r.id;
  exception when unique_violation then
    -- The same provider reference cannot pay two withdrawals.
    perform app.raise('provider_reference_already_used');
  end;
  insert into public.inbox_notifications (user_id, kind, from_name, preview, link)
  values (r.creator_id, 'creator_payout', 'BizPilot', 'Withdrawal of ' || r.amount || ' FCFA: ' || p_status, '/creator');
  perform app.admin_audit('admin.payout_' || p_status, 'creator_payout', r.id::text, null,
                          jsonb_build_object('amount', r.amount, 'reference', ref, 'note', note));
end $$;

-- 7. Administrator: programme settings, creator decisions, referral investigation, adjustments, reconciliation.
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
  -- The switch-on time is kept: reconciliation only expects commission for payments approved after it.
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

-- Referrals of one creator, with the checks that matter for abuse: shared membership and payments.
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

-- A manual, recorded adjustment (for example an agreed correction). Needs a reason; the ledger stays append-only.
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

-- Reconciliation: each verified payment for an attributed business should have one accrual when the program was on,
-- and each refunded payment one reversal. Paid payouts must not exceed the commissions available to them.
create or replace function public.admin_creator_reconcile() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare missing int; extra_reversals int; overpaid int;
begin
  perform app.require_platform_admin();
  -- Expected commission: approved after the programme was switched on, inside the attribution window, creator approved
  -- with terms that cover the payment's kind (initial or renewal), and no accrual recorded.
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

-- Function privileges.
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
